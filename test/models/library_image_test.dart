import 'package:flutter_test/flutter_test.dart';
import 'package:insta_grab/services/library_service.dart';

void main() {
  group('LibraryImage JSON', () {
    test('roundtrips all fields', () {
      final original = LibraryImage(
        id: 'DXfEDOzDZjz_2',
        sourceUrl: 'https://www.instagram.com/p/DXfEDOzDZjz/',
        shortcode: 'DXfEDOzDZjz',
        carouselIndex: 2,
        grabbedAt: DateTime.utc(2026, 5, 5, 10, 30, 15, 123),
        width: 1080,
        height: 1350,
        fileSize: 345678,
        filename: 'DXfEDOzDZjz_2.jpg',
      );

      final roundtripped = LibraryImage.fromJson(original.toJson());

      expect(roundtripped.id, original.id);
      expect(roundtripped.sourceUrl, original.sourceUrl);
      expect(roundtripped.shortcode, original.shortcode);
      expect(roundtripped.carouselIndex, original.carouselIndex);
      expect(roundtripped.grabbedAt, original.grabbedAt);
      expect(roundtripped.width, original.width);
      expect(roundtripped.height, original.height);
      expect(roundtripped.fileSize, original.fileSize);
      expect(roundtripped.filename, original.filename);
    });

    test('roundtrips null-like edge values', () {
      final original = LibraryImage(
        id: 'empty_0',
        sourceUrl: '',
        shortcode: 'empty',
        carouselIndex: 0,
        grabbedAt: DateTime.utc(2026),
        width: 0,
        height: 0,
        fileSize: 0,
        filename: '',
      );

      final roundtripped = LibraryImage.fromJson(original.toJson());

      expect(roundtripped.id, 'empty_0');
      expect(roundtripped.sourceUrl, '');
      expect(roundtripped.shortcode, 'empty');
      expect(roundtripped.carouselIndex, 0);
      expect(roundtripped.grabbedAt, DateTime.utc(2026));
      expect(roundtripped.width, 0);
      expect(roundtripped.height, 0);
      expect(roundtripped.fileSize, 0);
      expect(roundtripped.filename, '');
    });

    test('preserves grabbedAt millisecond precision', () {
      final original = LibraryImage(
        id: 'timestamp_0',
        sourceUrl: 'https://www.instagram.com/p/timestamp/',
        shortcode: 'timestamp',
        carouselIndex: 0,
        grabbedAt: DateTime.utc(2026, 5, 5, 10, 30, 15, 987),
        width: 640,
        height: 480,
        fileSize: 1024,
        filename: 'timestamp_0.jpg',
      );

      final json = original.toJson();
      final roundtripped = LibraryImage.fromJson(json);

      expect(json['grabbedAt'], '2026-05-05T10:30:15.987Z');
      expect(roundtripped.grabbedAt, original.grabbedAt);
      expect(roundtripped.grabbedAt.millisecond, 987);
    });
  });
}
