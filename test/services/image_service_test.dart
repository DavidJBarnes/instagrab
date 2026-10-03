import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
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

  group('ImageService.extensionForBytes', () {
    test('recognises JPEG, PNG, WebP and GIF magic bytes', () {
      expect(
        ImageService.extensionForBytes(
            Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0])),
        'jpg',
      );
      expect(
        ImageService.extensionForBytes(
          Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]),
        ),
        'png',
      );
      expect(
        ImageService.extensionForBytes(
          Uint8List.fromList([
            0x52, 0x49, 0x46, 0x46, // RIFF
            0x00, 0x00, 0x00, 0x00, // size
            0x57, 0x45, 0x42, 0x50, // WEBP
          ]),
        ),
        'webp',
      );
      expect(
        ImageService.extensionForBytes(
          Uint8List.fromList([0x47, 0x49, 0x46, 0x38, 0x39, 0x61]),
        ),
        'gif',
      );
    });

    test('falls back to jpg for unrecognised or truncated data', () {
      expect(ImageService.extensionForBytes(Uint8List.fromList([])), 'jpg');
      expect(ImageService.extensionForBytes(Uint8List.fromList([0x00, 0x01])),
          'jpg');
      // RIFF container that is not WebP (e.g. a wav) must not claim webp.
      expect(
        ImageService.extensionForBytes(
          Uint8List.fromList([
            0x52, 0x49, 0x46, 0x46,
            0x00, 0x00, 0x00, 0x00,
            0x57, 0x41, 0x56, 0x45, // WAVE
          ]),
        ),
        'jpg',
      );
    });
  });
}
