import 'dart:io';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

/// Service for downloading, resizing, and saving images.
///
/// All image manipulation uses the `image` package for cross-platform
/// compatibility (no native dependencies).
class ImageService {
  /// Downloads an image from a URL and returns the raw bytes.
  ///
  /// Uses appropriate headers to avoid being blocked by CDNs; [headers] are
  /// added to (and override) them. Throws [ImageDownloadException] on failure.
  static Future<Uint8List> downloadImage(
    String url, {
    Map<String, String>? headers,
  }) async {
    try {
      final response = await http.get(
        Uri.parse(url),
        headers: {
          'User-Agent': 'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 '
              '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36',
          'Accept': 'image/*,*/*;q=0.8',
          'Referer': 'https://www.instagram.com/',
          ...?headers,
        },
      ).timeout(const Duration(seconds: 30));

      if (response.statusCode != 200) {
        throw ImageDownloadException(
          'Download failed with status ${response.statusCode}',
        );
      }

      if (response.bodyBytes.isEmpty) {
        throw const ImageDownloadException('Downloaded image is empty');
      }

      return response.bodyBytes;
    } catch (e) {
      if (e is ImageDownloadException) rethrow;
      throw ImageDownloadException('Failed to download image: $e');
    }
  }

  /// Decodes image bytes into an [img.Image] for manipulation.
  ///
  /// Supports JPEG, PNG, WebP, and other formats handled by the `image` package.
  static img.Image? decodeImage(Uint8List bytes) {
    return img.decodeImage(bytes);
  }

  /// Resizes an image to the specified dimensions.
  ///
  /// If [maintainAspect] is true, the image is resized to fit within
  /// the target dimensions while preserving aspect ratio.
  /// Uses Lanczos3 interpolation for high-quality downscaling.
  static img.Image resize(
    img.Image image, {
    required int width,
    required int height,
    bool maintainAspect = true,
  }) {
    if (maintainAspect) {
      final aspectRatio = image.width / image.height;
      final targetRatio = width / height;

      if (aspectRatio > targetRatio) {
        // Width-constrained
        height = (width / aspectRatio).round();
      } else {
        // Height-constrained
        width = (height * aspectRatio).round();
      }
    }

    return img.copyResize(
      image,
      width: width,
      height: height,
      interpolation: img.Interpolation.cubic,
    );
  }

  /// Crops an image to the specified rectangle.
  ///
  /// Coordinates are in pixel space relative to the source image.
  static img.Image crop(
    img.Image image, {
    required int x,
    required int y,
    required int width,
    required int height,
  }) {
    return img.copyCrop(
      image,
      x: x,
      y: y,
      width: width,
      height: height,
    );
  }

  /// Encodes an image to PNG bytes.
  static Uint8List encodePng(img.Image image) {
    return Uint8List.fromList(img.encodePng(image));
  }

  /// Encodes an image to JPEG bytes with the specified quality (0-100).
  static Uint8List encodeJpeg(img.Image image, {int quality = 90}) {
    return Uint8List.fromList(img.encodeJpg(image, quality: quality));
  }

  /// Returns the platform-appropriate downloads/output directory.
  static Future<Directory> getOutputDirectory() async {
    if (Platform.isAndroid) {
      // Use external storage downloads folder
      final dir = Directory('/storage/emulated/0/Download/InstaGrab');
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      return dir;
    } else if (Platform.isLinux) {
      final home = Platform.environment['HOME'] ?? '/home';
      final dir = Directory(p.join(home, 'Pictures', 'InstaGrab'));
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      return dir;
    } else {
      final appDir = await getApplicationDocumentsDirectory();
      final dir = Directory(p.join(appDir.path, 'InstaGrab'));
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      return dir;
    }
  }

  /// Saves image bytes to a file and returns the file path.
  ///
  /// [filename] should include the extension (.png, .jpg). If
  /// [directory] is provided, it's used (and created if missing);
  /// otherwise the platform-default path is used.
  static Future<String> saveImage(
    Uint8List bytes, {
    required String filename,
    String? directory,
  }) async {
    final Directory dir;
    if (directory != null) {
      dir = Directory(directory);
      if (!await dir.exists()) await dir.create(recursive: true);
    } else {
      dir = await getOutputDirectory();
    }
    final file = File(p.join(dir.path, filename));
    await file.writeAsBytes(bytes);
    return file.path;
  }

  /// Returns the file extension matching the actual bytes of an image.
  ///
  /// Sniffs magic bytes rather than trusting a URL or a caller-supplied
  /// name, so grabbed originals can be written to disk verbatim (no
  /// re-encode) under a name that matches their real format. Falls back
  /// to `jpg`, which is what the Instagram CDN serves in practice.
  static String extensionForBytes(Uint8List bytes) {
    if (bytes.length >= 3 &&
        bytes[0] == 0xFF &&
        bytes[1] == 0xD8 &&
        bytes[2] == 0xFF) {
      return 'jpg';
    }
    if (bytes.length >= 8 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47) {
      return 'png';
    }
    if (bytes.length >= 12 &&
        bytes[0] == 0x52 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x46 &&
        bytes[8] == 0x57 &&
        bytes[9] == 0x45 &&
        bytes[10] == 0x42 &&
        bytes[11] == 0x50) {
      return 'webp';
    }
    if (bytes.length >= 4 &&
        bytes[0] == 0x47 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46) {
      return 'gif';
    }
    return 'jpg';
  }

  /// Generates a timestamped filename for saving.
  static String generateFilename(
      {String prefix = 'insta', String ext = 'png'}) {
    final now = DateTime.now();
    final stamp = '${now.year}${_pad(now.month)}${_pad(now.day)}'
        '_${_pad(now.hour)}${_pad(now.minute)}${_pad(now.second)}';
    return '${prefix}_$stamp.$ext';
  }

  static String _pad(int n) => n.toString().padLeft(2, '0');
}

/// Exception thrown when image download fails.
class ImageDownloadException implements Exception {
  /// Human-readable error message.
  final String message;

  const ImageDownloadException(this.message);

  @override
  String toString() => 'ImageDownloadException: $message';
}
