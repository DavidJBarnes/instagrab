import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:insta_grab/services/image_service.dart';

void main() {
  group('ImageService.generateFilename', () {
    test('default prefix and extension produce expected format', () {
      final filename = ImageService.generateFilename();
      expect(filename, matches(RegExp(r'^insta_\d{8}_\d{6}\.png$')));
    });

    test('custom prefix and extension are respected', () {
      final filename =
          ImageService.generateFilename(prefix: 'test', ext: 'jpg');
      expect(filename, matches(RegExp(r'^test_\d{8}_\d{6}\.jpg$')));
    });
  });

  group('ImageService decode/encode', () {
    test('PNG roundtrip preserves dimensions', () {
      final image = img.Image(width: 100, height: 100);
      final encoded = ImageService.encodePng(image);

      final decoded = ImageService.decodeImage(encoded);

      expect(decoded, isNotNull);
      expect(decoded!.width, 100);
      expect(decoded.height, 100);
    });

    test('JPEG roundtrip preserves dimensions', () {
      final image = img.Image(width: 100, height: 100);
      final encoded = ImageService.encodeJpeg(image);

      final decoded = ImageService.decodeImage(encoded);

      expect(decoded, isNotNull);
      expect(decoded!.width, 100);
      expect(decoded.height, 100);
    });

    test('decodeImage returns null for invalid bytes', () {
      final decoded = ImageService.decodeImage(Uint8List(8));

      expect(decoded, isNull);
    });
  });
}
