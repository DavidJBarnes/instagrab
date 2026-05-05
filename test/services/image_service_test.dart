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

  group('ImageService.crop', () {
    test('center crop returns requested dimensions', () {
      final image = img.Image(width: 800, height: 600);

      final cropped = ImageService.crop(
        image,
        x: 200,
        y: 100,
        width: 400,
        height: 400,
      );

      expect(cropped.width, 400);
      expect(cropped.height, 400);
    });

    test('top-left edge crop returns requested dimensions', () {
      final image = img.Image(width: 800, height: 600);

      final cropped = ImageService.crop(
        image,
        x: 0,
        y: 0,
        width: 200,
        height: 200,
      );

      expect(cropped.width, 200);
      expect(cropped.height, 200);
    });
  });
}
