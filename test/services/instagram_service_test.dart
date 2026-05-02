import 'package:flutter_test/flutter_test.dart';
import 'package:insta_grab/services/instagram_service.dart';

void main() {
  group('InstagramService.normalizeUrl', () {
    test('1. Debería retornar la URL canónica estándar', () {
      expect(InstagramService.normalizeUrl('https://www.instagram.com/p/ABC123/'), 
             'https://www.instagram.com/p/ABC123/');
    });

    test('2. Debería añadir "www" si falta', () {
      expect(InstagramService.normalizeUrl('https://instagram.com/p/ABC123/'), 
             'https://www.instagram.com/p/ABC123/');
    });

    test('3. Debería convertir /reel/ a /p/', () {
      expect(InstagramService.normalizeUrl('https://www.instagram.com/reel/ABC123/'), 
             'https://www.instagram.com/p/ABC123/');
    });

    test('4. Debería convertir /tv/ a /p/', () {
      expect(InstagramService.normalizeUrl('https://www.instagram.com/tv/ABC123/'), 
             'https://www.instagram.com/p/ABC123/');
    });

    test('5. Debería limpiar parámetros de consulta (query params)', () {
      expect(InstagramService.normalizeUrl('https://www.instagram.com/p/ABC123/?utm_source=share'), 
             'https://www.instagram.com/p/ABC123/');
    });

    test('6. Debería limpiar fragmentos (#)', () {
      expect(InstagramService.normalizeUrl('https://www.instagram.com/p/ABC123/#fragment'), 
             'https://www.instagram.com/p/ABC123/');
    });

    test('7. Debería retornar null para URLs que no son de Instagram', () {
      expect(InstagramService.normalizeUrl('https://twitter.com/user/status/123'), isNull);
    });

    test('8. Debería retornar null para strings vacíos', () {
      expect(InstagramService.normalizeUrl(''), isNull);
    });

    group('shortcodeToMediaId', () {
      test('should return "1" when shortcode is "B"', () {
        final result = InstagramService.shortcodeToMediaId('B');
        expect(result, equals('1'));
      });

      test('should correctly decode a known real shortcode', () {
        // Real example: /p/Ct_7366MA_u/ -> media_id: 3134487193241784302
        final result = InstagramService.shortcodeToMediaId('Ct_7366MA_u');
        expect(result, equals('3134487193241784302'));
      });

      test('should throw InstagramExtractionException when shortcode is empty', () {
        expect(
          () => InstagramService.shortcodeToMediaId(''),
          throwsA(isA<InstagramExtractionException>()),
        );
      });

      test('should throw InstagramExtractionException when shortcode is invalid', () {
        expect(
          () => InstagramService.shortcodeToMediaId('!!!invalid'),
          throwsA(isA<InstagramExtractionException>()),
        );
      });
    });
  });
}
