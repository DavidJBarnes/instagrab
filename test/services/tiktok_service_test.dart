import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:insta_grab/models/media_item.dart';
import 'package:insta_grab/services/tiktok_service.dart';

String _fixture(String name) => File('test/fixtures/$name').readAsStringSync();

const _videoId = '7642445196734614817';

void main() {
  group('URL recognition', () {
    test('accepts a full video URL and drops the query string', () {
      const url = 'https://www.tiktok.com/@joana.rodrigues96x/video/'
          '$_videoId?lang=en';
      expect(TikTokService.isTikTokUrl(url), isTrue);
      expect(
        TikTokService.normalizeUrl(url),
        'https://www.tiktok.com/@joana.rodrigues96x/video/$_videoId',
      );
    });

    test('accepts mobile and bare-domain video URLs', () {
      expect(
        TikTokService.normalizeUrl('https://m.tiktok.com/@a_b/video/123'),
        'https://www.tiktok.com/@a_b/video/123',
      );
      expect(
        TikTokService.normalizeUrl('https://tiktok.com/@a/video/123/'),
        'https://www.tiktok.com/@a/video/123',
      );
    });

    test('accepts short share links but cannot normalise them offline', () {
      for (final url in [
        'https://vm.tiktok.com/ZMabc123/',
        'https://vt.tiktok.com/ZSabc123/',
        'https://www.tiktok.com/t/ZTabc123/',
      ]) {
        expect(TikTokService.isTikTokUrl(url), isTrue, reason: url);
        expect(TikTokService.normalizeUrl(url), isNull, reason: url);
      }
    });

    test('accepts photo post URLs, keeping the /photo/ path', () {
      const url = 'https://www.tiktok.com/@some.one/photo/7512345678901234567'
          '?is_from_webapp=1';
      expect(TikTokService.isTikTokUrl(url), isTrue);
      expect(
        TikTokService.normalizeUrl(url),
        'https://www.tiktok.com/@some.one/photo/7512345678901234567',
      );
    });

    test('a photo post is fetched via its /video/ page', () {
      expect(
        TikTokService.fetchUrlFor('https://www.tiktok.com/@a.b/photo/123'),
        'https://www.tiktok.com/@a.b/video/123',
      );
      expect(
        TikTokService.fetchUrlFor('https://www.tiktok.com/@a.b/video/123'),
        'https://www.tiktok.com/@a.b/video/123',
      );
    });

    test('rejects Instagram and non-post TikTok URLs', () {
      expect(
        TikTokService.isTikTokUrl('https://www.instagram.com/p/DXfEDOzDZjz/'),
        isFalse,
      );
      expect(
        TikTokService.isTikTokUrl('https://www.tiktok.com/@someone'),
        isFalse,
      );
    });

    test('library key is prefixed and filename-safe', () {
      expect(TikTokService.libraryKey(_videoId), 'tt_$_videoId');
    });
  });

  group('mediaFromHtml (public video page)', () {
    test('picks the largest H.264 clean file, not downloadAddr', () {
      final media = TikTokService.mediaFromHtml(
        _fixture('tiktok_video_page.html'),
        videoId: _videoId,
      );
      expect(media, hasLength(1));
      final video = media.single;
      expect(video.kind, MediaKind.video);
      // The 1080p and 720p gears are H.265; of the H.264 ones (both 540p)
      // the higher bitrate wins.
      expect(video.url, contains('normal_540_0'));
      expect(video.url, isNot(contains('logo_type')));
      expect(video.width, 576);
      expect(video.height, 1024);
      expect(video.durationSeconds, 10);
      expect(video.thumbnailUrl, contains('origin_cover'));
    });

    test('an item with a different id is ignored', () {
      expect(
        TikTokService.mediaFromHtml(
          _fixture('tiktok_video_page.html'),
          videoId: '1',
        ),
        isEmpty,
      );
    });

    test('a page without the data script yields nothing', () {
      expect(
        TikTokService.mediaFromHtml('<html><body>captcha</body></html>'),
        isEmpty,
      );
    });

    test('photo post (fetched via /video/): one full-size image per photo', () {
      final media = TikTokService.mediaFromHtml(
        _fixture('tiktok_photo_page.html'),
        videoId: '7626728952958127392',
      );
      expect(media, hasLength(3));
      expect(media.every((m) => m.kind == MediaKind.image), isTrue);
      expect(media.map((m) => m.url), [
        contains('photo0~'),
        contains('photo1~'),
        contains('photo2~'),
      ]);
      expect(media.first.width, 2160);
      expect(media.first.height, 3838);
    });

    test('reads the older SIGI_STATE layout', () {
      const html = '<script id="SIGI_STATE" type="application/json">'
          '{"ItemModule":{"42":{"id":"42","video":{"playAddr":'
          '"https://v16.tiktok.com/play.mp4","width":720,"height":1280,'
          '"duration":7,"cover":"https://p16.tiktok.com/c.jpg"}}}}</script>';
      final video = TikTokService.mediaFromHtml(html, videoId: '42').single;
      expect(video.url, 'https://v16.tiktok.com/play.mp4');
      expect(video.width, 720);
      expect(video.thumbnailUrl, 'https://p16.tiktok.com/c.jpg');
    });
  });

  group('mediaFromItem', () {
    Map<String, dynamic> gear(String codec, int width, int bitrate) => {
          'CodecType': codec,
          'Bitrate': bitrate,
          'PlayAddr': {
            'Width': width,
            'Height': width * 16 ~/ 9,
            'UrlList': ['https://cdn/${codec}_$width.mp4'],
          },
        };

    test('prefers H.264 over a larger H.265 file', () {
      final video = TikTokService.mediaFromItem({
        'video': {
          'bitrateInfo': [
            gear('h265_hvc1', 1080, 900),
            gear('h264', 540, 500),
            gear('h264', 720, 400),
          ],
        },
      }).single;
      expect(video.url, 'https://cdn/h264_720.mp4');
    });

    test('falls back to H.265 when no H.264 file is listed', () {
      final video = TikTokService.mediaFromItem({
        'video': {
          'bitrateInfo': [
            gear('h265_hvc1', 720, 500),
            gear('h265_hvc1', 1080, 900),
          ],
        },
      }).single;
      expect(video.url, 'https://cdn/h265_hvc1_1080.mp4');
    });

    test('attaches the download headers', () {
      final video = TikTokService.mediaFromItem(
        {
          'video': {'playAddr': 'https://cdn/p.mp4'},
        },
        headers: {'Referer': 'https://www.tiktok.com/'},
      ).single;
      expect(video.headers, {'Referer': 'https://www.tiktok.com/'});
    });

    test('a photo post yields one image per photo, in order', () {
      final media = TikTokService.mediaFromItem(
        {
          'imagePost': {
            'images': [
              {
                'imageURL': {
                  'urlList': [
                    'https://p16-sign.tiktokcdn-us.com/a~tplv-photomode-image.heic?x=1',
                    'https://p16-sign.tiktokcdn-us.com/a~tplv-photomode-image.jpeg?x=1',
                  ],
                },
                'imageWidth': 1080,
                'imageHeight': 1440,
              },
              {
                'imageURL': {
                  'urlList': [
                    'https://p16-sign.tiktokcdn-us.com/b~tplv-photomode-image.webp?x=2',
                  ],
                },
                'imageWidth': 1080,
                'imageHeight': 1920,
              },
              {
                'imageURL': {'urlList': []}
              },
            ],
          },
          // Photo posts also carry a video block (the slideshow render); the
          // photos win.
          'video': {'playAddr': 'https://cdn/slideshow.mp4'},
        },
        headers: {'Referer': 'https://www.tiktok.com/'},
      );
      expect(media.map((m) => m.kind), [MediaKind.image, MediaKind.image]);
      // The HEIC variant is skipped in favour of a format package:image reads.
      expect(media[0].url, contains('image.jpeg'));
      expect(media[0].width, 1080);
      expect(media[0].height, 1440);
      expect(media[0].headers, {'Referer': 'https://www.tiktok.com/'});
      expect(media[1].url, contains('image.webp'));
      expect(media[1].height, 1920);
    });

    test('an empty imagePost falls back to the video', () {
      final media = TikTokService.mediaFromItem({
        'imagePost': {'images': []},
        'video': {'playAddr': 'https://cdn/p.mp4'},
      });
      expect(media.single.kind, MediaKind.video);
    });
  });

  group('cookieHeaderFrom', () {
    test('keeps name=value pairs and drops attributes, including Expires', () {
      const setCookie = 'ttwid=1%7Cabc%7C179; Domain=.tiktok.com; Path=/; '
          'Expires=Fri, 01 Oct 2027 21:13:57 GMT; HttpOnly; Secure,'
          'tt_csrf_token=0aUY-tD; path=/; domain=.tiktok.com; samesite=lax; '
          'secure; httponly,tt_chain_token=HitzXlLflH51aj1sLfLMCQ==; path=/; '
          'expires=Sun, 04 Apr 2027 21:13:57 GMT; domain=.tiktok.com';
      expect(
        TikTokService.cookieHeaderFrom(setCookie),
        'ttwid=1%7Cabc%7C179; tt_csrf_token=0aUY-tD; '
        'tt_chain_token=HitzXlLflH51aj1sLfLMCQ==',
      );
    });

    test('empty when there is no Set-Cookie', () {
      expect(TikTokService.cookieHeaderFrom(null), '');
    });
  });
}
