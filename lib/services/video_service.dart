import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'image_service.dart';

/// Downloads and saves videos.
///
/// Videos are handled as opaque files: streamed from the CDN straight to
/// disk and copied verbatim on export. Nothing here decodes or re-encodes
/// them, which keeps the app free of native video plugins on Linux.
class VideoService {
  static const _userAgent =
      'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36';

  /// Streams the video at [url] to [dest] and returns the number of bytes
  /// written. [onProgress] is called as chunks arrive; `total` is null when
  /// the server sends no Content-Length.
  ///
  /// Writes to `<dest>.part` and renames on success, so a failed or
  /// interrupted download never leaves a truncated file under the real name.
  /// Throws [VideoDownloadException] on any failure.
  static Future<int> downloadVideo(
    String url,
    File dest, {
    void Function(int received, int? total)? onProgress,
  }) async {
    final part = File('${dest.path}.part');
    final client = http.Client();
    try {
      final request = http.Request('GET', Uri.parse(url))
        ..headers.addAll({
          'User-Agent': _userAgent,
          'Accept': 'video/mp4,video/*;q=0.9,*/*;q=0.8',
          'Referer': 'https://www.instagram.com/',
        });
      final response =
          await client.send(request).timeout(const Duration(seconds: 30));
      if (response.statusCode != 200) {
        throw VideoDownloadException(
          'Download failed with status ${response.statusCode}',
        );
      }

      await dest.parent.create(recursive: true);
      final sink = part.openWrite();
      final head = <int>[];
      var received = 0;
      try {
        // Per-chunk timeout: a stalled connection fails instead of hanging,
        // without capping how long a large file may take overall.
        await for (final chunk
            in response.stream.timeout(const Duration(seconds: 60))) {
          if (head.length < 12) head.addAll(chunk.take(12 - head.length));
          sink.add(chunk);
          received += chunk.length;
          onProgress?.call(received, response.contentLength);
        }
      } finally {
        await sink.close();
      }

      if (received == 0) {
        throw const VideoDownloadException('Downloaded video is empty');
      }
      if (!looksLikeMp4(head)) {
        throw const VideoDownloadException(
          'The server did not return an MP4 file (expired or blocked link?)',
        );
      }
      await part.rename(dest.path);
      return received;
    } catch (e) {
      if (await part.exists()) await part.delete();
      if (e is VideoDownloadException) rethrow;
      throw VideoDownloadException('Failed to download video: $e');
    } finally {
      client.close();
    }
  }

  /// Whether [head] (the first bytes of a file) is an ISO-BMFF / MP4
  /// container: bytes 4–7 are the `ftyp` box type.
  static bool looksLikeMp4(List<int> head) =>
      head.length >= 8 &&
      head[4] == 0x66 && // f
      head[5] == 0x74 && // t
      head[6] == 0x79 && // y
      head[7] == 0x70; // p

  /// Copies [source] verbatim into [directory] (or the platform output
  /// directory when null) as [filename], and returns the new path.
  static Future<String> saveVideo(
    File source, {
    required String filename,
    String? directory,
  }) async {
    final Directory dir;
    if (directory != null) {
      dir = Directory(directory);
      if (!await dir.exists()) await dir.create(recursive: true);
    } else {
      dir = await ImageService.getOutputDirectory();
    }
    final target = p.join(dir.path, filename);
    if (p.equals(p.absolute(source.path), p.absolute(target))) return target;
    await source.copy(target);
    return target;
  }

  /// Extracts every [every]th frame of [video] (frames 0, every, 2*every,
  /// ...) as lossless PNGs into [outDir], named `<stem>_f<NNNNNN>.png` by
  /// their frame number in the source. Returns the written files in order.
  ///
  /// This is the one place a video is decoded, and it is done by the system
  /// `ffmpeg` binary rather than a plugin — the app still ships no native
  /// video code. Throws [FrameSplitException] if ffmpeg is missing or fails.
  static Future<List<File>> splitFrames(
    File video,
    Directory outDir, {
    int every = 4,
  }) async {
    if (every < 1) throw ArgumentError.value(every, 'every', 'must be >= 1');
    await outDir.create(recursive: true);
    final stem = p.basenameWithoutExtension(video.path);
    // ffmpeg numbers its outputs 0, 1, 2...; they are renamed afterwards to
    // the source frame number so a frame can be traced back to the video.
    final tmpPattern = p.join(outDir.path, '.split_%06d.png');
    final ProcessResult result;
    try {
      result = await Process.run('ffmpeg', splitFramesArgs(
        video.path,
        tmpPattern,
        every: every,
      ));
    } on ProcessException {
      throw const FrameSplitException(
        'ffmpeg is not installed (sudo dnf install ffmpeg)',
      );
    }

    final tmp = <File>[];
    for (var i = 0;; i++) {
      final f = File(p.join(outDir.path, '.split_${_pad(i)}.png'));
      if (!await f.exists()) break;
      tmp.add(f);
    }
    if (result.exitCode != 0 || tmp.isEmpty) {
      for (final f in tmp) {
        await f.delete();
      }
      final err = (result.stderr as String).trim();
      throw FrameSplitException(
        err.isEmpty ? 'ffmpeg exited with code ${result.exitCode}' : err,
      );
    }

    final out = <File>[];
    for (var i = 0; i < tmp.length; i++) {
      final name = '${stem}_f${_pad(i * every)}.png';
      out.add(await tmp[i].rename(p.join(outDir.path, name)));
    }
    return out;
  }

  /// ffmpeg arguments for [splitFrames]: keep frames whose index is a
  /// multiple of [every], pass their timestamps through untouched (no
  /// duplicated or dropped frames), and write RGB PNGs.
  static List<String> splitFramesArgs(
    String input,
    String outputPattern, {
    required int every,
  }) =>
      [
        '-hide_banner',
        '-loglevel', 'error',
        '-y',
        '-i', input,
        '-vf', 'select=not(mod(n\\,$every))',
        '-fps_mode', 'passthrough',
        '-start_number', '0',
        outputPattern,
      ];

  static String _pad(int n) => n.toString().padLeft(6, '0');

  /// Filename for frame [index] of the post [shortcode]: `<shortcode>_<i>.mp4`,
  /// matching the `<shortcode>_<i>.<ext>` names grabbed images get, so one
  /// post's files sort together. Characters that are unsafe in filenames are
  /// replaced (shortcodes never contain any, but this is fed from parsed
  /// input).
  static String videoFilename(String shortcode, int index) {
    final safe = shortcode.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    return '${safe.isEmpty ? 'video' : safe}_$index.mp4';
  }

  /// Formats a duration in seconds as `m:ss` (or `h:mm:ss`).
  static String formatDuration(double seconds) {
    final total = seconds.round();
    final h = total ~/ 3600;
    final m = (total % 3600) ~/ 60;
    final s = total % 60;
    String two(int n) => n.toString().padLeft(2, '0');
    return h > 0 ? '$h:${two(m)}:${two(s)}' : '$m:${two(s)}';
  }
}

/// Exception thrown when a video download fails.
class VideoDownloadException implements Exception {
  final String message;
  const VideoDownloadException(this.message);
  @override
  String toString() => 'VideoDownloadException: $message';
}

/// Exception thrown when extracting frames from a video fails.
class FrameSplitException implements Exception {
  final String message;
  const FrameSplitException(this.message);
  @override
  String toString() => 'FrameSplitException: $message';
}
