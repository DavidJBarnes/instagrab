import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
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

  group('VideoService.splitFrames', () {
    final hasFfmpeg = Process.runSync('which', ['ffmpeg']).exitCode == 0;
    late Directory tmp;

    setUp(() => tmp = Directory.systemTemp.createTempSync('split_frames'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('writes every 4th frame as a full-size PNG named by source frame',
        () async {
      // 25 frames at 25 fps: frames 0, 4, ..., 24 are kept.
      final video = File(p.join(tmp.path, 'Abc_0.mp4'));
      final made = Process.runSync('ffmpeg', [
        '-hide_banner', '-loglevel', 'error', '-y',
        '-f', 'lavfi', '-i', 'testsrc=size=320x240:rate=25:duration=1',
        '-pix_fmt', 'yuv420p', video.path,
      ]);
      expect(made.exitCode, 0, reason: made.stderr as String);

      final out = Directory(p.join(tmp.path, 'Abc_0_frames'));
      final frames = await VideoService.splitFrames(video, out);

      expect(
        frames.map((f) => p.basename(f.path)),
        [0, 4, 8, 12, 16, 20, 24]
            .map((n) => 'Abc_0_f${n.toString().padLeft(6, '0')}.png'),
      );
      // Nothing else (no leftover temp names) in the folder.
      expect(out.listSync().length, frames.length);
      final first = img.decodePng(frames.first.readAsBytesSync())!;
      expect([first.width, first.height], [320, 240]);
    }, skip: hasFfmpeg ? false : 'ffmpeg not installed');

    test('throws FrameSplitException for a file that is not a video',
        () async {
      final bogus = File(p.join(tmp.path, 'bogus.mp4'))
        ..writeAsStringSync('<html>nope</html>');
      await expectLater(
        VideoService.splitFrames(bogus, Directory(p.join(tmp.path, 'out'))),
        throwsA(isA<FrameSplitException>()),
      );
    }, skip: hasFfmpeg ? false : 'ffmpeg not installed');
  });
}
