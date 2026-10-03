import 'dart:convert';
import 'package:http/http.dart' as http;
import 'chrome_cookies.dart';
import 'instagram_cookies.dart';

/// Extracts image URLs from Instagram posts.
///
/// Instagram no longer exposes any useful image information to
/// unauthenticated clients (the post page is a JS-only shell, the embed
/// endpoint returns the same shell, public APIs return 302/404/403). We
/// authenticate by borrowing session cookies from the user's browser — see
/// [FirefoxCookieJar] and [ChromeCookieJar].
///
/// Desktop-only (Linux). On Android the cookie source doesn't exist.
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
  /// if the input isn't an IG post/reel/TV URL.
  ///
  /// Shortcodes are exactly 11 characters. Share links often append a
  /// token built from the same alphabet (`/p/<shortcode><token>`), so the
  /// match is length-bounded — a greedy capture swallows the token and
  /// decodes to a media id that Instagram rejects with a 400.
  static String? normalizeUrl(String input) {
    final match = RegExp(
      r'https?://(?:www\.)?instagram\.com/(?:p|reel|tv)/([A-Za-z0-9_-]{11})',
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

  /// Fetches image URLs for the post at [url].
  ///
  /// Returns one URL for a single-image post, multiple for a carousel.
  /// Videos are skipped (carousel_media entries with media_type != 1).
  ///
  /// Throws [InstagramExtractionException] with an actionable message
  /// for every failure mode: invalid URL, not logged in, expired
  /// session, post not found, post is video-only.
  static Future<List<String>> extractImageUrls(String url) async {
    final canonical = normalizeUrl(url);
    if (canonical == null) {
      throw const InstagramExtractionException(
        'Invalid Instagram URL. Expected a post, reel, or TV URL.',
      );
    }
    final shortcode = RegExp(r'/p/([^/]+)/').firstMatch(canonical)!.group(1)!;
    final mediaId = shortcodeToMediaId(shortcode);

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

    final urls = _collectImageUrls(items.first as Map<String, dynamic>);
    if (urls.isEmpty) {
      throw const InstagramExtractionException(
        'This post contains no still images (likely a video-only post).',
      );
    }
    return urls;
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

  /// Walks the media item and returns the highest-resolution image URL
  /// for each image — a single entry for images, one per image frame for
  /// carousels. Video items are skipped.
  static List<String> _collectImageUrls(Map<String, dynamic> item) {
    final mediaType = item['media_type'] as int?;
    if (mediaType == 8) {
      final carousel = item['carousel_media'] as List? ?? const [];
      return [
        for (final child in carousel.cast<Map<String, dynamic>>())
          if (child['media_type'] == 1)
            if (_bestCandidate(child) case final url?) url,
      ];
    }
    if (mediaType == 1) {
      final url = _bestCandidate(item);
      return [if (url != null) url];
    }
    return const [];
  }

  /// Picks the largest candidate from `image_versions2.candidates` and
  /// returns its URL, or null if none are available.
  static String? _bestCandidate(Map<String, dynamic> item) {
    final versions = item['image_versions2'] as Map<String, dynamic>?;
    final candidates = versions?['candidates'] as List?;
    if (candidates == null || candidates.isEmpty) return null;
    Map<String, dynamic>? best;
    var bestArea = -1;
    for (final c in candidates.cast<Map<String, dynamic>>()) {
      final w = (c['width'] as num?)?.toInt() ?? 0;
      final h = (c['height'] as num?)?.toInt() ?? 0;
      final area = w * h;
      if (area > bestArea) {
        bestArea = area;
        best = c;
      }
    }
    return best?['url'] as String?;
  }
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
