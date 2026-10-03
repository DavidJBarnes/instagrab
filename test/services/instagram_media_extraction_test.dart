import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:insta_grab/models/media_item.dart';
import 'package:insta_grab/services/instagram_service.dart';

String _fixture(String name) => File('test/fixtures/$name').readAsStringSync();

Map<String, dynamic> _firstApiItem(String name) {
  final body = jsonDecode(_fixture(name)) as Map<String, dynamic>;
  return (body['items'] as List).first as Map<String, dynamic>;
}

void main() {
  group('mediaFromApiItem (logged-in /api/v1/ responses)', () {
    test('reel: picks the highest-resolution progressive mp4', () {
      final media = InstagramService.mediaFromApiItem(
        _firstApiItem('api_reel_video_versions.json'),
      );
      expect(media, hasLength(1));
      final video = media.single;
      expect(video.kind, MediaKind.video);
      // Two 720x1280 versions tie on area; the higher bandwidth wins.
      expect(video.url, contains('reel_720_high.mp4'));
      expect(video.width, 720);
      expect(video.height, 1280);
      expect(video.durationSeconds, closeTo(32.533, 1e-9));
    });

    test('reel: uses the largest image candidate as the cover', () {
      final video = InstagramService.mediaFromApiItem(
        _firstApiItem('api_reel_video_versions.json'),
      ).single;
      expect(video.thumbnailUrl, contains('cover_1080.jpg'));
    });

    test('mixed carousel: yields image, video, image in post order', () {
      final media = InstagramService.mediaFromApiItem(
        _firstApiItem('api_carousel_mixed.json'),
      );
      expect(media.map((m) => m.kind), [
        MediaKind.image,
        MediaKind.video,
        MediaKind.image,
      ]);
      expect(media[0].url, contains('frame0.jpg'));
      expect(media[0].width, 1080);
      expect(media[1].url, contains('frame1_1080.mp4'));
      expect(media[1].thumbnailUrl, contains('frame1_cover.jpg'));
      expect(media[1].durationSeconds, 9.8);
      expect(media[2].url, contains('frame2.jpg'));
    });

    test('a video item without video_versions yields nothing, not its cover',
        () {
      final media = InstagramService.mediaFromApiItem({
        'media_type': 2,
        'image_versions2': {
          'candidates': [
            {'width': 1080, 'height': 1920, 'url': 'https://x/cover.jpg'},
          ],
        },
      });
      expect(media, isEmpty);
    });

    test('skips DASH segment URLs in video_versions', () {
      final media = InstagramService.mediaFromApiItem({
        'media_type': 2,
        'video_versions': [
          {
            'width': 1080,
            'height': 1920,
            'url': 'https://a.cdninstagram.com/v.mp4?bytestart=0&byteend=9',
          },
          {
            'width': 720,
            'height': 1280,
            'url': 'https://a.cdninstagram.com/p.mp4'
          },
        ],
      });
      expect(media.single.url, 'https://a.cdninstagram.com/p.mp4');
    });
  });

  group('mediaFromHtml (public post and embed pages)', () {
    test('og:video: prefers og:video:secure_url and decodes &amp;', () {
      final media = InstagramService.mediaFromHtml(
        _fixture('page_og_video.html'),
        shortcode: 'Cx1y2Z3aBcD',
      );
      expect(media, hasLength(1));
      final video = media.single;
      expect(video.kind, MediaKind.video);
      expect(video.url, contains('og_reel_secure.mp4'));
      expect(video.url, isNot(contains('&amp;')));
      expect(video.url, contains('&_nc_ht=scontent'));
      expect(video.thumbnailUrl, contains('og_cover.jpg'));
      expect(video.width, 720);
      expect(video.height, 1280);
    });

    test('embed page: finds video_url in JSON nested as a string', () {
      final media = InstagramService.mediaFromHtml(
        _fixture('embed_video_url.html'),
        shortcode: 'Cx1y2Z3aBcD',
      );
      expect(media, hasLength(1));
      final video = media.single;
      expect(video.kind, MediaKind.video);
      expect(video.url, contains('embed_reel.mp4'));
      expect(video.url, contains('&_nc_ht=scontent'));
      expect(video.thumbnailUrl, contains('embed_cover.jpg'));
      expect(video.durationSeconds, 14.2);
      expect(video.width, 720);
    });

    test('mixed sidecar in page JSON, skipping another post\'s node', () {
      final media = InstagramService.mediaFromHtml(
        _fixture('page_shared_data_carousel.html'),
        shortcode: 'DcjCb9PEYMR',
      );
      expect(media.map((m) => m.kind), [
        MediaKind.image,
        MediaKind.video,
        MediaKind.image,
      ]);
      // display_resources' largest entry beats display_url.
      expect(media[0].url, contains('side0_1080.jpg'));
      expect(media[1].url, contains('side1_video.mp4'));
      expect(media[1].thumbnailUrl, contains('side1_cover.jpg'));
      expect(media[1].durationSeconds, 6.0);
      expect(media[2].url, contains('side2.jpg'));
      expect(media.any((m) => m.url.contains('other_post')), isFalse);
    });

    test('falls back to escaped .mp4 CDN URLs in script text', () {
      final media =
          InstagramService.mediaFromHtml(_fixture('page_raw_mp4.html'));
      expect(media, hasLength(1));
      final video = media.single;
      expect(video.kind, MediaKind.video);
      expect(
          video.url, startsWith('https://scontent-lax3-1.cdninstagram.com/'));
      expect(video.url, contains('raw_reel.mp4?efg=abc&_nc_ht=scontent'));
      expect(video.url, isNot(contains(r'\/')));
      expect(video.thumbnailUrl, contains('raw_cover.jpg'));
    });

    test('a video post behind a login wall does not return its cover image',
        () {
      expect(
        InstagramService.mediaFromHtml(_fixture('page_login_wall_video.html')),
        isEmpty,
      );
    });

    test('an image-only page still yields og:image', () {
      final media = InstagramService.mediaFromHtml(
        '<meta property="og:image" content="https://x.cdninstagram.com/a.jpg?a=1&amp;b=2">',
      );
      expect(media.single.kind, MediaKind.image);
      expect(media.single.url, 'https://x.cdninstagram.com/a.jpg?a=1&b=2');
    });

    test('an empty shell yields nothing', () {
      expect(
        InstagramService.mediaFromHtml(
          '<html><body><div id="root"></div></body></html>',
        ),
        isEmpty,
      );
    });
  });

  group('cdnVideoUrls', () {
    test('dedupes, drops DASH segments and ignores non-Instagram hosts', () {
      const text =
          '"https:\\/\\/scontent.cdninstagram.com\\/v\\/a.mp4?x=1\\u00262"'
          ' "https://scontent.cdninstagram.com/v/a.mp4?x=1&2"'
          ' "https://video.xx.fbcdn.net/v/b.mp4?bytestart=0&byteend=10"'
          ' "https://video.xx.fbcdn.net/v/c.mp4"'
          ' "https://example.com/d.mp4"';
      expect(InstagramService.cdnVideoUrls(text), [
        'https://scontent.cdninstagram.com/v/a.mp4?x=1&2',
        'https://video.xx.fbcdn.net/v/c.mp4',
      ]);
    });
  });
}
