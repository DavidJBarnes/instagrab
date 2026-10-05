import 'package:flutter_test/flutter_test.dart';
import 'package:insta_grab/services/instagram_service.dart';

void main() {
  group('InstagramService.normalizeUrl', () {
    test('canonicalises a plain post URL', () {
      expect(
        InstagramService.normalizeUrl(
            'https://www.instagram.com/p/DcjCb9PEYMR/'),
        'https://www.instagram.com/p/DcjCb9PEYMR/',
      );
    });

    test('accepts reel, reels and tv URLs, and a missing www', () {
      expect(
        InstagramService.normalizeUrl(
            'https://instagram.com/reel/Cx1y2Z3aBcD/'),
        'https://www.instagram.com/p/Cx1y2Z3aBcD/',
      );
      expect(
        InstagramService.normalizeUrl(
            'https://www.instagram.com/reels/DdJqVKrCrvc/'),
        'https://www.instagram.com/p/DdJqVKrCrvc/',
      );
      expect(
        InstagramService.normalizeUrl(
            'https://www.instagram.com/tv/Bw9QrStUvWx/'),
        'https://www.instagram.com/p/Bw9QrStUvWx/',
      );
    });

    test('drops a query-string share token', () {
      expect(
        InstagramService.normalizeUrl(
            'https://www.instagram.com/p/DcjCb9PEYMR/?igsh=abc123'),
        'https://www.instagram.com/p/DcjCb9PEYMR/',
      );
    });

    // Regression: share links append a token drawn from the shortcode
    // alphabet and with no delimiter, so a greedy capture used to swallow it
    // and decode to a 70-digit media id that Instagram answered with a 400.
    test('stops at 11 chars when a share token is appended without a slash',
        () {
      expect(
        InstagramService.normalizeUrl(
            'https://www.instagram.com/p/DcjCb9PEYMRf-m3CWWkZaZ1C9ry0LTMKk_pod40'),
        'https://www.instagram.com/p/DcjCb9PEYMR/',
      );
    });

    test('returns null for non-post URLs', () {
      expect(InstagramService.normalizeUrl('https://www.instagram.com/nasa/'),
          isNull);
      expect(
          InstagramService.normalizeUrl('https://example.com/p/DcjCb9PEYMR/'),
          isNull);
      expect(InstagramService.normalizeUrl('not a url'), isNull);
    });
  });

  group('InstagramService.shortcodeToMediaId', () {
    test('decodes a shortcode to its numeric media id', () {
      expect(InstagramService.shortcodeToMediaId('DcjCb9PEYMR'),
          '3973030013540860689');
    });

    test('produces a media id of realistic magnitude', () {
      expect(InstagramService.shortcodeToMediaId('DcjCb9PEYMR').length, 19);
    });

    test('rejects characters outside the shortcode alphabet', () {
      expect(
        () => InstagramService.shortcodeToMediaId('Dcj!b9PEYMR'),
        throwsA(isA<InstagramExtractionException>()),
      );
    });
  });
}
