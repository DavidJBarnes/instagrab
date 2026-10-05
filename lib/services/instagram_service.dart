import 'dart:convert';
import 'package:http/http.dart' as http;
import 'chrome_cookies.dart';
import 'instagram_cookies.dart';
import '../models/media_item.dart';

/// Extracts image and video URLs from Instagram posts.
///
/// Instagram exposes little to unauthenticated clients (the post page is
/// usually a JS-only shell, the embed endpoint often the same), so the
/// primary strategy authenticates by borrowing session cookies from the
/// user's browser — see [FirefoxCookieJar] and [ChromeCookieJar]. The public
/// page and embed strategies are kept as fallbacks: they are all Android
/// has (there is no browser cookie store to read there), and they still
/// succeed for some posts.
///
/// Static and pure Dart; the parsers ([mediaFromApiItem], [mediaFromHtml])
/// are public so they can be tested against fixtures with no network.
class InstagramService {
  /// IG's public web-app ID, hardcoded in their own JavaScript. Not a
  /// secret — required as a header on `/api/v1/` calls.
  static const _appId = '936619743392459';

  static const _userAgent =
      'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

  /// Alphabet used by IG to encode shortcodes. Decoding to the numeric
  /// `media_id` is a straight base64-like conversion.
  static const _shortcodeAlphabet =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';

  /// Extracts the shortcode from any IG share URL and returns the
  /// canonical `https://www.instagram.com/p/<shortcode>/` form, or null
  /// if the input isn't an IG post/reel(s)/TV URL.
  ///
  /// Shortcodes are exactly 11 characters. Share links often append a
  /// token built from the same alphabet (`/p/<shortcode><token>`), so the
  /// match is length-bounded — a greedy capture swallows the token and
  /// decodes to a media id that Instagram rejects with a 400.
  static String? normalizeUrl(String input) {
    final match = RegExp(
      r'https?://(?:www\.)?instagram\.com/(?:p|reels?|tv)/([A-Za-z0-9_-]{11})',
    ).firstMatch(input.trim());
    if (match == null) return null;
    return 'https://www.instagram.com/p/${match.group(1)}/';
  }

  /// Decodes an Instagram shortcode to its numeric `media_id`.
  ///
  /// The result exceeds 2^53 so a `BigInt` is used throughout; the
  /// stringified form is what the `/api/v1/` endpoint expects.
  static String shortcodeToMediaId(String shortcode) {
    var n = BigInt.zero;
    final base = BigInt.from(64);
    for (final rune in shortcode.runes) {
      final idx = _shortcodeAlphabet.indexOf(String.fromCharCode(rune));
      if (idx < 0) {
        throw InstagramExtractionException(
          'Shortcode "$shortcode" contains invalid character '
          '"${String.fromCharCode(rune)}".',
        );
      }
      n = n * base + BigInt.from(idx);
    }
    return n.toString();
  }

  /// Fetches every downloadable image and video in the post at [url].
  ///
  /// Returns one item for a single image or a reel, one per frame (in post
  /// order) for a carousel, which may mix images and videos.
  ///
  /// Strategies run in sequence and the first non-empty result wins:
  ///   1. the logged-in `/api/v1/media/<id>/info/` call (browser cookies);
  ///   2. the public post page — embedded JSON, then `og:video`/`og:image`,
  ///      then any `.mp4` CDN URL;
  ///   3. the public `/embed/captioned/` page, parsed the same way.
  ///
  /// Throws [InstagramExtractionException] only after all of them come back
  /// empty, carrying the logged-in strategy's message when it had one —
  /// that is the actionable one (log in, session expired, post not found),
  /// since the public pages are a login wall more often than not.
  static Future<List<MediaItem>> extractMedia(String url) async {
    final canonical = normalizeUrl(url);
    if (canonical == null) {
      throw const InstagramExtractionException(
        'Invalid Instagram URL. Expected a post, reel, or TV URL.',
      );
    }
    final shortcode = RegExp(r'/p/([^/]+)/').firstMatch(canonical)!.group(1)!;
    final mediaId = shortcodeToMediaId(shortcode);

    // Strategy 1: the logged-in API. Richest data, and the only one that
    // reliably works today.
    InstagramExtractionException? apiError;
    try {
      final media = await _fromApi(mediaId);
      if (media.isNotEmpty) return media;
    } on InstagramExtractionException catch (e) {
      apiError = e;
    } catch (e) {
      apiError = InstagramExtractionException('Could not reach Instagram: $e');
    }
    print('[InstagramService] API strategy gave nothing '
        '(${apiError?.message ?? 'empty'}); trying public pages');

    // Strategy 2: the public post page.
    final page = await _fromPublicPage(canonical, shortcode);
    if (page.isNotEmpty) return page;

    // Strategy 3: the public embed page, which sometimes still carries the
    // media JSON when the post page is a bare shell.
    final embed =
        await _fromPublicPage('${canonical}embed/captioned/', shortcode);
    if (embed.isNotEmpty) return embed;

    throw apiError ??
        const InstagramExtractionException(
          'Instagram returned no downloadable media for this post.',
        );
  }

  /// Strategy 1: `/api/v1/media/<id>/info/` with each browser's session
  /// cookies in turn. Throws an actionable [InstagramExtractionException]
  /// for every failure mode it can recognise.
  static Future<List<MediaItem>> _fromApi(String mediaId) async {
    final sources = await _cookieSources();
    if (sources.isEmpty) {
      throw const InstagramExtractionException(
        'Not logged into Instagram in Firefox or Chrome. Log into '
        'instagram.com in one of them, then try again.',
      );
    }

    // One browser can hold a session Instagram no longer honours while
    // another holds a good one, and nothing in the cookie jar tells them
    // apart — only the API's answer does. Try each in turn and keep the first
    // that works, the same "return if it worked, otherwise continue" shape
    // the rest of this file uses.
    final endpoint = 'https://www.instagram.com/api/v1/media/$mediaId/info/';
    http.Response? attempt;
    for (final source in sources) {
      attempt = await _get(endpoint, source.header);
      if (attempt.statusCode == 200) break;
    }
    final response = attempt!;

    if (response.statusCode == 401 || response.statusCode == 403) {
      throw const InstagramExtractionException(
        'Instagram session expired or invalid. Log into instagram.com '
        'in Firefox again, then retry.',
      );
    }
    // An unauthorised API call is answered with a redirect rather than a 401
    // — sometimes to the login page, sometimes back to the same URL. Neither
    // is worth following, and the self-redirect is an infinite loop.
    if (response.statusCode >= 300 && response.statusCode < 400) {
      throw const InstagramExtractionException(
        'Instagram would not authorise the request with any browser session '
        'found. Open instagram.com in Firefox or Chrome, make sure you are '
        'logged in and any identity-confirmation prompt is finished, then '
        'retry.',
      );
    }
    if (response.statusCode == 404) {
      throw const InstagramExtractionException(
        'Post not found. It may be deleted or from a private account you '
        "don't follow.",
      );
    }
    // A media id that is malformed or refers to something this account
    // cannot see comes back as 400 with an explanation. It never succeeds on
    // retry, so surface Instagram's own wording instead of suggesting one.
    if (response.statusCode == 400) {
      throw InstagramExtractionException(
        'Instagram rejected the request: ${_messageFrom(response.body)}',
      );
    }
    if (response.statusCode != 200) {
      throw InstagramExtractionException(
        'Instagram returned HTTP ${response.statusCode}. Try again in a moment.',
      );
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final items = body['items'] as List?;
    if (items == null || items.isEmpty) {
      throw const InstagramExtractionException(
        'Instagram returned no media for this post.',
      );
    }

    final media = mediaFromApiItem(items.first as Map<String, dynamic>);
    if (media.isEmpty) {
      throw const InstagramExtractionException(
        'Instagram returned this post without any image or video URLs.',
      );
    }
    return media;
  }

  /// Strategies 2 and 3: an unauthenticated GET of a public page, parsed by
  /// [mediaFromHtml]. Never throws — a network error or a login wall is just
  /// an empty result, so the chain moves on.
  static Future<List<MediaItem>> _fromPublicPage(
      String url, String shortcode) async {
    try {
      final response = await http.get(Uri.parse(url), headers: {
        'User-Agent': _userAgent,
        'Accept': 'text/html,application/xhtml+xml',
        'Accept-Language': 'en-US,en;q=0.9',
      }).timeout(const Duration(seconds: 20));
      // Most "nothing found" results here are a 200 login wall, not a parser
      // bug — log enough to tell those apart.
      print('[InstagramService] GET $url -> HTTP ${response.statusCode}, '
          '${response.body.length} chars');
      if (response.statusCode != 200) return const [];
      final media = mediaFromHtml(response.body, shortcode: shortcode);
      print('[InstagramService]   parsed ${media.length} item(s)');
      return media;
    } catch (e) {
      print('[InstagramService] GET $url failed: $e');
      return const [];
    }
  }

  /// Cookie headers from every browser that currently holds an Instagram
  /// session. A browser that is absent contributes nothing; one that is
  /// present but unreadable is reported only if no browser worked at all.
  static Future<List<_CookieSource>> _cookieSources() async {
    final sources = <_CookieSource>[];
    final problems = <String>[];

    try {
      final chrome = await ChromeCookieJar.readInstagramCookieHeader();
      if (chrome != null) sources.add(_CookieSource('Chrome', chrome));
    } on ChromeCookieException catch (e) {
      problems.add('Chrome: ${e.message}');
    }

    try {
      final firefox = await FirefoxCookieJar.readInstagramCookieHeader();
      if (firefox != null) sources.add(_CookieSource('Firefox', firefox));
    } on CookieReadException catch (e) {
      problems.add('Firefox: ${e.message}');
    }

    if (sources.isEmpty && problems.isNotEmpty) {
      throw InstagramExtractionException(
        'Could not read browser cookies. ${problems.join('; ')}',
      );
    }
    return sources;
  }

  /// GETs [url] with the session cookies attached, leaving redirects
  /// unfollowed — a 3xx carries meaning here, and following Instagram's
  /// self-redirect just exhausts the client's redirect limit.
  static Future<http.Response> _get(String url, String cookieHeader) async {
    final client = http.Client();
    try {
      final request = http.Request('GET', Uri.parse(url))
        ..followRedirects = false
        ..headers.addAll({
          'User-Agent': _userAgent,
          'X-IG-App-ID': _appId,
          'Cookie': cookieHeader,
          'Accept': 'application/json',
        });
      final streamed =
          await client.send(request).timeout(const Duration(seconds: 20));
      return await http.Response.fromStream(streamed);
    } finally {
      client.close();
    }
  }

  /// Pulls Instagram's own `message` field out of an error body, falling
  /// back to the raw body when it isn't the JSON we expect.
  static String _messageFrom(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) {
        final message = decoded['message'];
        if (message is String && message.isNotEmpty) return message;
      }
    } on FormatException {
      // Not JSON — fall through to the raw body.
    }
    final trimmed = body.trim();
    return trimmed.isEmpty ? 'no details given' : trimmed;
  }

  // ---------------------------------------------------------------------
  // Parsers. Pure functions of their input, public so tests can feed them
  // fixtures without touching the network.
  // ---------------------------------------------------------------------

  /// Converts one `/api/v1/` media item (also the shape embedded in
  /// logged-in web pages) into media items: one for an image (`media_type`
  /// 1) or video (2), one per frame for a carousel (8).
  static List<MediaItem> mediaFromApiItem(Map<String, dynamic> item) {
    final mediaType = item['media_type'];
    if (mediaType == 8) {
      final carousel = item['carousel_media'] as List? ?? const [];
      return [
        for (final child in carousel.whereType<Map<String, dynamic>>())
          ...mediaFromApiItem(child),
      ];
    }
    if (mediaType == 2 || item['video_versions'] is List) {
      final video = _bestVideoVersion(item['video_versions'] as List?);
      if (video == null) return const [];
      return [
        MediaItem.video(
          video['url'] as String,
          thumbnailUrl: _bestCandidate(item)?['url'] as String?,
          width: _int(video['width']) ?? _int(item['original_width']),
          height: _int(video['height']) ?? _int(item['original_height']),
          durationSeconds: _double(item['video_duration']),
        ),
      ];
    }
    if (mediaType == 1) {
      final best = _bestCandidate(item);
      final url = best?['url'] as String?;
      if (url == null) return const [];
      return [
        MediaItem.image(
          url,
          width: _int(best!['width']),
          height: _int(best['height']),
        ),
      ];
    }
    return const [];
  }

  /// Converts a GraphQL-style `shortcode_media` node — the shape found in the
  /// public page and embed JSON — into media items.
  static List<MediaItem> mediaFromGraphNode(Map<String, dynamic> node) {
    final sidecar = node['edge_sidecar_to_children'];
    if (sidecar is Map && sidecar['edges'] is List) {
      return [
        for (final edge in (sidecar['edges'] as List).whereType<Map>())
          if (edge['node'] is Map<String, dynamic>)
            ...mediaFromGraphNode(edge['node'] as Map<String, dynamic>),
      ];
    }
    final dims = node['dimensions'] is Map ? node['dimensions'] as Map : null;
    final width = _int(dims?['width']);
    final height = _int(dims?['height']);
    final videoUrl = node['video_url'];
    if (videoUrl is String && videoUrl.isNotEmpty) {
      return [
        MediaItem.video(
          videoUrl,
          thumbnailUrl: node['display_url'] as String?,
          width: width,
          height: height,
          durationSeconds: _double(node['video_duration']),
        ),
      ];
    }
    // A video node without its URL (the embed page omits it for some posts)
    // must not be passed off as an image — its display_url is only a cover.
    if (node['is_video'] == true) return const [];

    // display_resources lists every size; the largest beats display_url.
    String? url = node['display_url'] as String?;
    final resources = node['display_resources'];
    if (resources is List) {
      var bestWidth = -1;
      for (final r in resources.whereType<Map>()) {
        final w = _int(r['config_width']) ?? 0;
        if (w > bestWidth && r['src'] is String) {
          bestWidth = w;
          url = r['src'] as String;
        }
      }
    }
    if (url == null || url.isEmpty) return const [];
    return [MediaItem.image(url, width: width, height: height)];
  }

  /// Extracts media from a post or embed page's HTML.
  ///
  /// Tried in order, first non-empty wins:
  ///   1. JSON embedded in `<script>` blocks — API-shaped items or
  ///      GraphQL `shortcode_media` nodes. Only this one sees every
  ///      carousel frame. When [shortcode] is given, a node carrying a
  ///      different `code`/`shortcode` (a "more posts" entry) is skipped.
  ///   2. `og:video` / `og:video:secure_url` (with `og:image` as the cover),
  ///      else `og:image` — unless `og:type` says the post is a video, in
  ///      which case the cover is not passed off as the post's image.
  ///   3. Any `.mp4` URL on `cdninstagram.com` / `fbcdn.net`.
  static List<MediaItem> mediaFromHtml(String html, {String? shortcode}) {
    final fromJson = _mediaFromEmbeddedJson(html, shortcode);
    if (fromJson.isNotEmpty) return fromJson;

    final meta = _metaTags(html);
    final cover = meta['og:image'] ?? meta['twitter:image'];
    final ogVideo = meta['og:video:secure_url'] ??
        meta['og:video'] ??
        meta['og:video:url'] ??
        meta['twitter:player:stream'];
    if (ogVideo != null && ogVideo.isNotEmpty) {
      return [
        MediaItem.video(
          ogVideo,
          thumbnailUrl: cover,
          width: int.tryParse(meta['og:video:width'] ?? ''),
          height: int.tryParse(meta['og:video:height'] ?? ''),
        ),
      ];
    }

    final mp4s = cdnVideoUrls(html);
    if (mp4s.isNotEmpty) {
      return [MediaItem.video(mp4s.first, thumbnailUrl: cover)];
    }

    final isVideoPost = (meta['og:type'] ?? '').startsWith('video');
    if (cover != null && cover.isNotEmpty && !isVideoPost) {
      return [MediaItem.image(cover)];
    }
    return const [];
  }

  /// Every distinct progressive `.mp4` URL on Instagram's CDNs in [text],
  /// in order of appearance, with JSON and HTML escaping undone. DASH
  /// segment URLs (`bytestart=`) are dropped — they are fragments, not
  /// playable files.
  static List<String> cdnVideoUrls(String text) {
    final pattern = RegExp(
      r'''https?:(?:\\?/){2}[^\s"'<>]*?(?:cdninstagram\.com|fbcdn\.net)'''
      r'''[^\s"'<>]*?\.mp4(?:[?#][^\s"'<>]*)?''',
    );
    final seen = <String>{};
    final out = <String>[];
    for (final m in pattern.allMatches(text)) {
      final url = _unescape(m.group(0)!);
      if (url.contains('bytestart=')) continue;
      if (seen.add(url)) out.add(url);
    }
    return out;
  }

  /// Picks the highest-resolution progressive mp4 from `video_versions`.
  ///
  /// Every `video_versions` entry is a single progressive file with the
  /// audio muxed in (the video-only/audio-only split lives in the separate
  /// DASH manifest, which this never touches), so the largest area wins,
  /// with the reported bandwidth as the tie-break.
  static Map<String, dynamic>? _bestVideoVersion(List? versions) {
    if (versions == null) return null;
    Map<String, dynamic>? best;
    var bestArea = -1;
    var bestBandwidth = -1;
    for (final v in versions.whereType<Map<String, dynamic>>()) {
      final url = v['url'];
      if (url is! String || url.isEmpty || url.contains('bytestart=')) {
        continue;
      }
      final area = (_int(v['width']) ?? 0) * (_int(v['height']) ?? 0);
      final bandwidth = _int(v['bandwidth']) ?? 0;
      if (area > bestArea || (area == bestArea && bandwidth > bestBandwidth)) {
        best = v;
        bestArea = area;
        bestBandwidth = bandwidth;
      }
    }
    return best;
  }

  /// Picks the largest candidate from `image_versions2.candidates`, or null
  /// if none are available.
  static Map<String, dynamic>? _bestCandidate(Map<String, dynamic> item) {
    final versions = item['image_versions2'] as Map<String, dynamic>?;
    final candidates = versions?['candidates'] as List?;
    if (candidates == null || candidates.isEmpty) return null;
    Map<String, dynamic>? best;
    var bestArea = -1;
    for (final c in candidates.whereType<Map<String, dynamic>>()) {
      if (c['url'] is! String) continue;
      final area = (_int(c['width']) ?? 0) * (_int(c['height']) ?? 0);
      if (area > bestArea) {
        bestArea = area;
        best = c;
      }
    }
    return best;
  }

  /// Keys whose value is a media node in the JSON Instagram embeds in pages,
  /// for script bodies that are JS rather than bare JSON.
  static const _mediaJsonKeys = [
    '"xdt_api__v1__media__shortcode__web_info"',
    '"xdt_shortcode_media"',
    '"shortcode_media"',
  ];

  static List<MediaItem> _mediaFromEmbeddedJson(String html, String? code) {
    final roots = <Object?>[];
    final scripts =
        RegExp(r'<script\b[^>]*>([\s\S]*?)</script>', caseSensitive: false);
    for (final m in scripts.allMatches(html)) {
      final body = m.group(1)!.trim();
      if (body.isEmpty) continue;
      final whole = _tryJson(body);
      if (whole != null) {
        roots.add(whole);
        continue;
      }
      // JS like `window._sharedData = {...};` — lift out the object that
      // follows each known key.
      for (final key in _mediaJsonKeys) {
        var from = 0;
        while (true) {
          final at = body.indexOf(key, from);
          if (at < 0) break;
          from = at + key.length;
          final brace = body.indexOf('{', from);
          if (brace < 0) break;
          final obj = _balancedObject(body, brace);
          final decoded = obj == null ? null : _tryJson(obj);
          if (decoded != null) roots.add(decoded);
        }
      }
    }

    List<MediaItem>? firstFound;
    for (final root in roots) {
      final found = _findMediaNode(root, code, 0);
      if (found == null) continue;
      if (found.$2) return found.$1; // shortcode confirmed
      firstFound ??= found.$1;
    }
    return firstFound ?? const [];
  }

  /// Depth-first search for the first media node under [node]. Returns the
  /// parsed media and whether the node's own shortcode matched [code].
  /// String values that are themselves JSON (the embed page nests its data
  /// as `"contextJSON": "{...}"`) are decoded and searched too.
  static (List<MediaItem>, bool)? _findMediaNode(
      Object? node, String? code, int depth) {
    if (depth > 40) return null;
    if (node is Map<String, dynamic>) {
      final nodeCode = node['code'] ?? node['shortcode'];
      final mismatched = code != null && nodeCode is String && nodeCode != code;
      final isApiItem = node['media_type'] is int &&
          (node['image_versions2'] is Map ||
              node['video_versions'] is List ||
              node['carousel_media'] is List);
      final isGraphNode = node['display_url'] is String &&
          (node.containsKey('__typename') || node.containsKey('is_video'));
      if ((isApiItem || isGraphNode) && !mismatched) {
        final media =
            isApiItem ? mediaFromApiItem(node) : mediaFromGraphNode(node);
        if (media.isNotEmpty) return (media, code != null && nodeCode == code);
      }
      // Don't descend into a mismatched media node — its children are that
      // other post's frames.
      if ((isApiItem || isGraphNode) && mismatched) return null;
      (List<MediaItem>, bool)? fallback;
      for (final value in node.values) {
        final r = _findMediaNode(value, code, depth + 1);
        if (r == null) continue;
        if (r.$2) return r;
        fallback ??= r;
      }
      return fallback;
    }
    if (node is List) {
      (List<MediaItem>, bool)? fallback;
      for (final value in node) {
        final r = _findMediaNode(value, code, depth + 1);
        if (r == null) continue;
        if (r.$2) return r;
        fallback ??= r;
      }
      return fallback;
    }
    if (node is String &&
        node.length > 2 &&
        node.startsWith('{') &&
        (node.contains('video_url') ||
            node.contains('display_url') ||
            node.contains('video_versions') ||
            node.contains('image_versions2'))) {
      return _findMediaNode(_tryJson(node), code, depth + 1);
    }
    return null;
  }

  /// The `{...}` starting at [start], honouring strings and escapes, or null
  /// if it never closes.
  static String? _balancedObject(String text, int start) {
    var depth = 0;
    var inString = false;
    for (var i = start; i < text.length; i++) {
      final c = text.codeUnitAt(i);
      if (inString) {
        if (c == 0x5C) {
          i++; // skip escaped char
        } else if (c == 0x22) {
          inString = false;
        }
        continue;
      }
      if (c == 0x22) {
        inString = true;
      } else if (c == 0x7B) {
        depth++;
      } else if (c == 0x7D) {
        depth--;
        if (depth == 0) return text.substring(start, i + 1);
      }
    }
    return null;
  }

  static Object? _tryJson(String text) {
    final t = text.trim();
    if (!(t.startsWith('{') || t.startsWith('['))) return null;
    try {
      return jsonDecode(t);
    } on FormatException {
      return null;
    }
  }

  /// `<meta property|name="..." content="...">` pairs, first value per key,
  /// with HTML entities in the content decoded.
  static Map<String, String> _metaTags(String html) {
    final out = <String, String>{};
    final tag = RegExp(r'<meta\b[^>]*>', caseSensitive: false);
    final attr = RegExp(r'''([a-zA-Z:-]+)\s*=\s*("([^"]*)"|'([^']*)')''');
    for (final m in tag.allMatches(html)) {
      final attrs = <String, String>{};
      for (final a in attr.allMatches(m.group(0)!)) {
        attrs[a.group(1)!.toLowerCase()] = a.group(3) ?? a.group(4) ?? '';
      }
      final key = attrs['property'] ?? attrs['name'];
      final content = attrs['content'];
      if (key == null || content == null) continue;
      out.putIfAbsent(key.toLowerCase(), () => _decodeEntities(content));
    }
    return out;
  }

  static String _decodeEntities(String s) => s
      .replaceAll('&amp;', '&')
      .replaceAll('&#38;', '&')
      .replaceAll('&quot;', '"')
      .replaceAll('&#039;', "'")
      .replaceAll('&#39;', "'")
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>');

  /// Undoes the JSON-in-HTML escaping URLs pick up when lifted from script
  /// text rather than decoded JSON.
  static String _unescape(String s) => _decodeEntities(s
      .replaceAll(r'\/', '/')
      .replaceAll(r'\u0026', '&')
      .replaceAll(r'\u003d', '=')
      .replaceAll(r'\u003D', '='));

  static int? _int(Object? v) => v is num ? v.toInt() : null;
  static double? _double(Object? v) => v is num ? v.toDouble() : null;
}

/// One browser's Instagram cookies, ready to send as a `Cookie:` header.
class _CookieSource {
  final String browser;
  final String header;
  const _CookieSource(this.browser, this.header);
}

/// Exception thrown when image extraction from Instagram fails.
class InstagramExtractionException implements Exception {
  final String message;
  const InstagramExtractionException(this.message);
  @override
  String toString() => 'InstagramExtractionException: $message';
}
