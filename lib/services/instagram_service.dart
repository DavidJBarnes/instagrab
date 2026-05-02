import 'dart:convert';
import 'package:http/http.dart' as http;
import 'instagram_cookies.dart';

/// Extracts image URLs from Instagram posts.
///
/// Instagram no longer exposes any useful image information to
/// unauthenticated clients (the post page is a JS-only shell, public
/// APIs return 302/404/403). We authenticate by borrowing session
/// cookies from the user's Firefox profile — see [FirefoxCookieJar].
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
  static String? normalizeUrl(String input) {
    final match = RegExp(
      r'https?://(?:www\.)?instagram\.com/(?:p|reel|tv)/([A-Za-z0-9_-]+)',
    ).firstMatch(input.trim());
    if (match == null) return null;
    return 'https://www.instagram.com/p/${match.group(1)}/';
  }

  /// Decodes an Instagram shortcode to its numeric `media_id`.
  ///
  /// The result exceeds 2^53 so a `BigInt` is used throughout; the
  /// stringified form is what the `/api/v1/` endpoint expects.
  static String shortcodeToMediaId(String shortcode) {
    if (shortcode.isEmpty) {
      throw const InstagramExtractionException('Shortcode cannot be empty.');
    }
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

    final cookieHeader = await FirefoxCookieJar.readInstagramCookieHeader();
    if (cookieHeader == null) {
      throw const InstagramExtractionException(
        'Not logged into Instagram in Firefox. Open Firefox, log into '
        'instagram.com, then try again.',
      );
    }

    final response = await http.get(
      Uri.parse('https://www.instagram.com/api/v1/media/$mediaId/info/'),
      headers: {
        'User-Agent': _userAgent,
        'X-IG-App-ID': _appId,
        'Cookie': cookieHeader,
        'Accept': 'application/json',
      },
    ).timeout(const Duration(seconds: 20));

    if (response.statusCode == 401 || response.statusCode == 403) {
      throw const InstagramExtractionException(
        'Instagram session expired or invalid. Log into instagram.com '
        'in Firefox again, then retry.',
      );
    }
    if (response.statusCode == 404) {
      throw const InstagramExtractionException(
        'Post not found. It may be deleted or from a private account you '
        "don't follow.",
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

/// Exception thrown when image extraction from Instagram fails.
class InstagramExtractionException implements Exception {
  final String message;
  const InstagramExtractionException(this.message);
  @override
  String toString() => 'InstagramExtractionException: $message';
}
