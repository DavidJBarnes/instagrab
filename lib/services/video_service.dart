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
