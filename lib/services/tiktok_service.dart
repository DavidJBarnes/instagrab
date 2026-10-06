import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/media_item.dart';

/// Extracts the video, or the photos of a photo (slideshow) post, from a
/// TikTok post.
///
/// Unlike Instagram, TikTok still serves the full post data to anonymous
/// clients: the public video page embeds it as JSON in a
/// `__UNIVERSAL_DATA_FOR_REHYDRATION__` script (older builds used
/// `SIGI_STATE`). The catch is the CDN — the clean, unwatermarked files it
/// lists are refused with a 403 unless the request carries the
/// `tt_chain_token` cookie the page fetch was given, and a TikTok Referer.
/// Those headers ride along on the returned [MediaItem.headers].
///
/// Static and pure Dart; the parsers ([mediaFromHtml], [mediaFromItem]) are
/// public so they can be tested against fixtures with no network.
class TikTokService {
  static const _userAgent =
      'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

  /// A full post URL; group 2 is `video` or `photo`, group 3 the post id.
  static final _postUrl = RegExp(
    r'https?://(?:www\.|m\.)?tiktok\.com/@([A-Za-z0-9._-]+)/(video|photo)/(\d+)',
  );

  /// Short share links (`vm.tiktok.com/<code>`, `tiktok.com/t/<code>`) — the
  /// form the mobile app's Share button hands out. They redirect to the
  /// full video URL.
  static final _shortUrl = RegExp(
    r'https?://(?:vm|vt)\.tiktok\.com/[A-Za-z0-9]+|'
    r'https?://(?:www\.)?tiktok\.com/t/[A-Za-z0-9]+',
  );

  /// Whether [input] looks like any TikTok video, photo or share link this service
  /// accepts. Cheap and synchronous; short links are only resolved by
  /// [extractMedia].
  static bool isTikTokUrl(String input) {
    final s = input.trim();
    return _postUrl.hasMatch(s) || _shortUrl.hasMatch(s);
  }

  /// The canonical `https://www.tiktok.com/@<user>/<video|photo>/<id>` form
  /// of a full post URL (query string such as `?lang=en` dropped), or null if
  /// [input] isn't one.
  static String? normalizeUrl(String input) {
    final m = _postUrl.firstMatch(input.trim());
    if (m == null) return null;
    return 'https://www.tiktok.com/@${m.group(1)}/${m.group(2)}/${m.group(3)}';
  }

  /// Library key for a TikTok post: `tt_<id>`. Plays the role Instagram's
  /// shortcode does in filenames and library ids; the prefix keeps the two
  /// sites' posts apart.
  static String libraryKey(String videoId) => 'tt_$videoId';

  /// Fetches the media in the TikTok post at [url] — one video, or one image
  /// per photo of a photo post — which may be a full post URL or a short
  /// share link.
  ///
  /// Throws [TikTokExtractionException] with an actionable message on any
  /// failure.
  static Future<TikTokPost> extractMedia(String url) async {
    var canonical = normalizeUrl(url);
    if (canonical == null && _shortUrl.hasMatch(url.trim())) {
      canonical = await _resolveShortUrl(_shortUrl.firstMatch(url.trim())![0]!);
    }
    if (canonical == null) {
      throw const TikTokExtractionException(
        'Invalid TikTok URL. Expected a tiktok.com/@user/video/... or /photo/... link.',
      );
    }
    final videoId = _postUrl.firstMatch(canonical)!.group(3)!;

    // A `/photo/` page carries no post data at all; the same id under
    // `/video/` does, photo posts included (as `imagePost`). So always fetch
    // that form, and keep [canonical] as the post's source URL.
    final pageUrl = fetchUrlFor(canonical);
    final http.Response response;
    try {
      response = await http.get(Uri.parse(pageUrl), headers: {
        'User-Agent': _userAgent,
        'Accept': 'text/html,application/xhtml+xml',
        'Accept-Language': 'en-US,en;q=0.9',
      }).timeout(const Duration(seconds: 20));
    } catch (e) {
      throw TikTokExtractionException('Could not reach TikTok: $e');
    }
    // As with Instagram, most "nothing found" results are a 200 that is a
    // captcha or bot wall rather than a parser bug — log enough to tell.
    print('[TikTokService] GET $pageUrl -> HTTP ${response.statusCode}, '
        '${response.body.length} chars');
    if (response.statusCode == 404) {
      throw const TikTokExtractionException('TikTok video not found.');
    }
    if (response.statusCode != 200) {
      throw TikTokExtractionException(
        'TikTok returned HTTP ${response.statusCode}. Try again in a moment.',
      );
    }

    final item = itemFromHtml(response.body, videoId: videoId);
    if (item == null) {
      throw TikTokExtractionException(
        _statusMessageFrom(response.body) ??
            'TikTok returned a page without the video data (probably a '
                'captcha or rate limit). Try again in a moment.',
      );
    }
    final headers = {
      'Referer': 'https://www.tiktok.com/',
      'Cookie': cookieHeaderFrom(response.headers['set-cookie']),
    };
    final media = mediaFromItem(item, headers: headers);
    if (media.isEmpty) {
      throw const TikTokExtractionException(
        'TikTok returned this post without any video or photo URLs.',
      );
    }
    return TikTokPost(
      videoId: videoId,
      canonicalUrl: canonical,
      media: media,
    );
  }

  /// The page to fetch for the post at [canonical]: its `/video/` form,
  /// since TikTok only embeds the post data there, even for photo posts.
  static String fetchUrlFor(String canonical) =>
      canonical.replaceFirst(RegExp(r'/photo/(?=\d+$)'), '/video/');

  /// Follows a short share link's redirect to the full video URL, without
  /// fetching the (large) video page itself.
  static Future<String> _resolveShortUrl(String shortUrl) async {
    final client = http.Client();
    try {
      var current = Uri.parse(shortUrl);
      for (var hop = 0; hop < 5; hop++) {
        final request = http.Request('GET', current)
          ..followRedirects = false
          ..headers['User-Agent'] = _userAgent;
        final response =
            await client.send(request).timeout(const Duration(seconds: 20));
        await response.stream.drain<void>();
        final location = response.headers['location'];
        if (location == null) break;
        current = current.resolve(location);
        final canonical = normalizeUrl(current.toString());
        if (canonical != null) return canonical;
      }
    } on TikTokExtractionException {
      rethrow;
    } catch (e) {
      throw TikTokExtractionException('Could not resolve TikTok link: $e');
    } finally {
      client.close();
    }
    throw const TikTokExtractionException(
      'This TikTok share link does not lead to a video.',
    );
  }

  // ---------------------------------------------------------------------
  // Parsers. Pure functions of their input, public so tests can feed them
  // fixtures without touching the network.
  // ---------------------------------------------------------------------

  /// Turns a `Set-Cookie` header — which `package:http` folds into one
  /// comma-joined string — into a `Cookie:` request header. Only the
  /// leading `name=value` of each cookie is kept; attributes such as
  /// `Expires=Fri, 01 Oct 2027` are dropped.
  static String cookieHeaderFrom(String? setCookie) {
    if (setCookie == null || setCookie.isEmpty) return '';
    const attributes = {
      'path', 'domain', 'expires', 'max-age', 'samesite', 'secure', //
      'httponly', 'priority', 'partitioned',
    };
    final pairs = <String>[];
    final pattern = RegExp(r'(?:^|[,;])\s*([A-Za-z0-9_\-]+)=([^;,]*)');
    for (final m in pattern.allMatches(setCookie)) {
      final name = m.group(1)!;
      if (attributes.contains(name.toLowerCase())) continue;
      pairs.add('$name=${m.group(2)}');
    }
    return pairs.join('; ');
  }

  /// The post's `itemStruct` from a video page's HTML, or null if the page
  /// doesn't carry it. When [videoId] is given, an item with a different id
  /// is ignored.
  ///
  /// Tried in order: the `__UNIVERSAL_DATA_FOR_REHYDRATION__` script
  /// (`webapp.video-detail.itemInfo.itemStruct`), then the older
  /// `SIGI_STATE` (`ItemModule.<id>`).
  static Map<String, dynamic>? itemFromHtml(String html, {String? videoId}) {
    bool matches(Object? item) =>
        item is Map<String, dynamic> &&
        (videoId == null || item['id']?.toString() == videoId);

    final universal = _scriptJson(html, '__UNIVERSAL_DATA_FOR_REHYDRATION__');
    if (universal is Map) {
      final scope = universal['__DEFAULT_SCOPE__'];
      final detail = scope is Map ? scope['webapp.video-detail'] : null;
      final info = detail is Map ? detail['itemInfo'] : null;
      final item = info is Map ? info['itemStruct'] : null;
      if (matches(item)) return item as Map<String, dynamic>;
    }

    final sigi = _scriptJson(html, 'SIGI_STATE');
    if (sigi is Map && sigi['ItemModule'] is Map) {
      final module = sigi['ItemModule'] as Map;
      final item =
          videoId != null ? module[videoId] : module.values.firstOrNull;
      if (matches(item)) return item as Map<String, dynamic>;
    }
    return null;
  }

  /// TikTok's own explanation when the page carries a video-detail block
  /// with an error status instead of an item (deleted, private, region
  /// locked), or null.
  static String? _statusMessageFrom(String html) {
    final universal = _scriptJson(html, '__UNIVERSAL_DATA_FOR_REHYDRATION__');
    if (universal is! Map) return null;
    final scope = universal['__DEFAULT_SCOPE__'];
    final detail = scope is Map ? scope['webapp.video-detail'] : null;
    if (detail is! Map) return null;
    final code = detail['statusCode'];
    if (code == null || code == 0) return null;
    final msg = detail['statusMsg'];
    return 'TikTok could not show this video '
        '(${msg is String && msg.isNotEmpty ? msg : 'status $code'}). It may '
        'be deleted, private, or unavailable in your region.';
  }

  /// Converts a TikTok `itemStruct` into its media, with [headers] attached
  /// for the download: one image per photo, in post order, for a photo post
  /// (see [_mediaFromImagePost]), else its video. Empty when there is no
  /// usable URL.
  ///
  /// For a video,
  /// From `video.bitrateInfo`, H.264 entries always beat H.265 ones, then
  /// the highest resolution wins, then the higher bitrate. TikTok's largest
  /// file is often H.265, but stock Fedora builds of VLC and ffmpeg can't
  /// decode HEVC (patents), so the video would neither play nor split into
  /// frames. H.265 is used only when no H.264 file is listed.
  /// Each is a progressive mp4 with the audio muxed in and no watermark.
  /// `video.playAddr` is the fallback; `downloadAddr` is never used — it is
  /// the watermarked copy.
  static List<MediaItem> mediaFromItem(
    Map<String, dynamic> item, {
    Map<String, String>? headers,
  }) {
    final imagePost = item['imagePost'];
    if (imagePost is Map) {
      final images = _mediaFromImagePost(imagePost, headers);
      if (images.isNotEmpty) return images;
    }

    final video = item['video'];
    if (video is! Map) return const [];

    String? url;
    int? width;
    int? height;
    var bestArea = -1;
    var bestH264 = false;
    var bestBitrate = -1;
    final bitrates = video['bitrateInfo'];
    if (bitrates is List) {
      for (final b in bitrates.whereType<Map>()) {
        final play = b['PlayAddr'];
        if (play is! Map) continue;
        final urls = play['UrlList'];
        final first =
            urls is List ? urls.whereType<String>().firstOrNull : null;
        if (first == null || first.isEmpty) continue;
        final w = _int(play['Width']) ?? 0;
        final h = _int(play['Height']) ?? 0;
        final area = w * h;
        final h264 = '${b['CodecType'] ?? ''}'.toLowerCase().startsWith('h264');
        final bitrate = _int(b['Bitrate']) ?? 0;
        final better = (h264 && !bestH264) ||
            (h264 == bestH264 &&
                (area > bestArea ||
                    (area == bestArea && bitrate > bestBitrate)));
        if (better) {
          url = first;
          width = w > 0 ? w : null;
          height = h > 0 ? h : null;
          bestArea = area;
          bestH264 = h264;
          bestBitrate = bitrate;
        }
      }
    }
    if (url == null) {
      final play = video['playAddr'];
      if (play is String && play.isNotEmpty) {
        url = play;
        width = _int(video['width']);
        height = _int(video['height']);
      }
    }
    if (url == null) return const [];

    final cover = [video['originCover'], video['cover']]
        .whereType<String>()
        .where((s) => s.isNotEmpty)
        .firstOrNull;
    return [
      MediaItem.video(
        url,
        thumbnailUrl: cover,
        width: width,
        height: height,
        durationSeconds: _double(video['duration']),
        headers: headers,
      ),
    ];
  }

  /// The photos of a photo post: `imagePost.images[]`, each with its URLs in
  /// `imageURL.urlList` and its size in `imageWidth`/`imageHeight`. The
  /// slideshow's background music is not fetched.
  ///
  /// A URL's format is in its path (`...~tplv-photomode-image.jpeg?...`); a
  /// JPEG, PNG or WebP one is preferred, since `package:image` cannot decode
  /// the HEIC variants TikTok also lists.
  static List<MediaItem> _mediaFromImagePost(
    Map imagePost,
    Map<String, String>? headers,
  ) {
    final images = imagePost['images'];
    if (images is! List) return const [];
    final out = <MediaItem>[];
    for (final image in images.whereType<Map>()) {
      final imageUrl = image['imageURL'];
      final list = imageUrl is Map ? imageUrl['urlList'] : null;
      if (list is! List) continue;
      final urls = list.whereType<String>().where((u) => u.isNotEmpty);
      final url = urls
              .where((u) =>
                  RegExp(r'\.(jpe?g|png|webp)(\?|$)', caseSensitive: false)
                      .hasMatch(Uri.tryParse(u)?.path ?? u))
              .firstOrNull ??
          urls.firstOrNull;
      if (url == null) continue;
      out.add(MediaItem.image(
        url,
        width: _int(image['imageWidth']),
        height: _int(image['imageHeight']),
        headers: headers,
      ));
    }
    return out;
  }

  /// Convenience for tests: [itemFromHtml] then [mediaFromItem].
  static List<MediaItem> mediaFromHtml(String html, {String? videoId}) {
    final item = itemFromHtml(html, videoId: videoId);
    return item == null ? const [] : mediaFromItem(item);
  }

  /// Decoded JSON body of `<script id="[id]">`, or null.
  static Object? _scriptJson(String html, String id) {
    final m = RegExp(
      '<script\\b[^>]*\\bid="${RegExp.escape(id)}"[^>]*>([\\s\\S]*?)</script>',
      caseSensitive: false,
    ).firstMatch(html);
    if (m == null) return null;
    try {
      return jsonDecode(m.group(1)!);
    } on FormatException {
      return null;
    }
  }

  static int? _int(Object? v) =>
      v is num ? v.toInt() : (v is String ? int.tryParse(v) : null);
  static double? _double(Object? v) =>
      v is num ? v.toDouble() : (v is String ? double.tryParse(v) : null);
}

/// A resolved TikTok post: its id, canonical URL, and media.
class TikTokPost {
  final String videoId;
  final String canonicalUrl;
  final List<MediaItem> media;
  const TikTokPost({
    required this.videoId,
    required this.canonicalUrl,
    required this.media,
  });
}

/// Exception thrown when extracting a video from TikTok fails.
class TikTokExtractionException implements Exception {
  final String message;
  const TikTokExtractionException(this.message);
  @override
  String toString() => 'TikTokExtractionException: $message';
}
