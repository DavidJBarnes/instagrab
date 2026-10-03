import 'package:flutter_test/flutter_test.dart';
import 'package:insta_grab/services/video_service.dart';

void main() {
  group('VideoService.videoFilename', () {
    test('is <shortcode>_<index>.mp4, matching grabbed image names', () {
      expect(VideoService.videoFilename('Cx1y2Z3aBcD', 0), 'Cx1y2Z3aBcD_0.mp4');
      expect(VideoService.videoFilename('DcjCb9PEYMR', 2), 'DcjCb9PEYMR_2.mp4');
    });

    test('keeps - and _ which are valid shortcode characters', () {
      expect(VideoService.videoFilename('a-b_c', 1), 'a-b_c_1.mp4');
    });

    test('replaces path separators and other unsafe characters', () {
      expect(VideoService.videoFilename('../x/y', 0), '___x_y_0.mp4');
      expect(VideoService.videoFilename('', 3), 'video_3.mp4');
    });
  });

  group('VideoService.looksLikeMp4', () {
    test('accepts an ftyp box header', () {
      expect(
        VideoService.looksLikeMp4(
          [0, 0, 0, 0x20, 0x66, 0x74, 0x79, 0x70, 0x69, 0x73, 0x6F, 0x6D],
        ),
        isTrue,
      );
    });

    test('rejects HTML error pages and short input', () {
      expect(VideoService.looksLikeMp4('<!DOCTYPE html>'.codeUnits), isFalse);
      expect(VideoService.looksLikeMp4([0, 0, 0]), isFalse);
    });
  });

  group('VideoService.formatDuration', () {
    test('formats m:ss and h:mm:ss', () {
      expect(VideoService.formatDuration(0), '0:00');
      expect(VideoService.formatDuration(9.8), '0:10');
      expect(VideoService.formatDuration(65), '1:05');
      expect(VideoService.formatDuration(3725), '1:02:05');
    });
  });
}
