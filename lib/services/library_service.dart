import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import '../models/media_item.dart';
import 'video_service.dart';

/// One entry in the on-disk library — an image or a video.
///
/// Represents media we grabbed from Instagram, persisted to disk with
/// enough metadata to show in the strip and info pane. The name predates
/// video support; [kind] says which this is.
class LibraryImage {
  /// Stable identifier used as the on-disk filename stem.
  final String id;

  /// Instagram post URL this image was extracted from.
  final String sourceUrl;

  /// Instagram shortcode (the `DXfEDOzDZjz` in /p/DXfEDOzDZjz/).
  final String shortcode;

  /// Position within a carousel (0-based); 0 for single-image posts.
  final int carouselIndex;

  /// When this image was downloaded into the library.
  final DateTime grabbedAt;

  final int width;
  final int height;

  /// Size of the original bytes on disk (for display only).
  final int fileSize;

  /// On-disk filename within the library directory.
  final String filename;

  /// Image or video. Entries written before video support have no `kind`
  /// in the index and load as images.
  final MediaKind kind;

  /// Cover-frame image within the library directory, for videos. Null for
  /// images, and for videos whose cover could not be downloaded.
  final String? thumbnailFilename;

  /// Video length in seconds, when Instagram reported it.
  final double? durationSeconds;

  const LibraryImage({
    required this.id,
    required this.sourceUrl,
    required this.shortcode,
    required this.carouselIndex,
    required this.grabbedAt,
    required this.width,
    required this.height,
    required this.fileSize,
    required this.filename,
    this.kind = MediaKind.image,
    this.thumbnailFilename,
    this.durationSeconds,
  });

  bool get isVideo => kind == MediaKind.video;

  Map<String, dynamic> toJson() => {
        'id': id,
        'sourceUrl': sourceUrl,
        'shortcode': shortcode,
        'carouselIndex': carouselIndex,
        'grabbedAt': grabbedAt.toIso8601String(),
        'width': width,
        'height': height,
        'fileSize': fileSize,
        'filename': filename,
        'kind': kind.name,
        if (thumbnailFilename != null) 'thumbnailFilename': thumbnailFilename,
        if (durationSeconds != null) 'durationSeconds': durationSeconds,
      };

  factory LibraryImage.fromJson(Map<String, dynamic> j) => LibraryImage(
        id: j['id'] as String,
        sourceUrl: j['sourceUrl'] as String,
        shortcode: j['shortcode'] as String,
        carouselIndex: j['carouselIndex'] as int,
        grabbedAt: DateTime.parse(j['grabbedAt'] as String),
        width: j['width'] as int,
        height: j['height'] as int,
        fileSize: j['fileSize'] as int,
        filename: j['filename'] as String,
        kind: MediaKind.values.firstWhere(
          (k) => k.name == j['kind'],
          orElse: () => MediaKind.image,
        ),
        thumbnailFilename: j['thumbnailFilename'] as String?,
        durationSeconds: (j['durationSeconds'] as num?)?.toDouble(),
      );
}

/// Persistent library of grabbed images and videos.
///
/// Storage layout:
///   ~/.local/share/InstaGrab/library/
///     index.json              — list of [LibraryImage]
///     <shortcode>_<i>.<ext>   — raw bytes for each entry (`.mp4` for videos)
///     <shortcode>_<i>_thumb.jpg — cover frame for a video entry
///
/// Edits to a library image are exported elsewhere (see settings save path);
/// the library itself holds only originals and is never mutated after an
/// image is added (aside from delete).
class LibraryService {
  static Directory get _libraryDir {
    final home = Platform.environment['HOME'] ?? '/tmp';
    return Directory(p.join(home, '.local', 'share', 'InstaGrab', 'library'));
  }

  static File get _indexFile => File(p.join(_libraryDir.path, 'index.json'));

  /// Absolute path of [filename] inside the library directory.
  static String pathFor(String filename) => p.join(_libraryDir.path, filename);

  /// The library's copy of [entry]'s media (the image, or the `.mp4`).
  static File fileFor(LibraryImage entry) => File(pathFor(entry.filename));

  /// [entry]'s cover-frame file, or null if it has none. Images are their
  /// own thumbnail, so this returns the image file for them.
  static File? thumbnailFileFor(LibraryImage entry) {
    if (!entry.isVideo) return fileFor(entry);
    final thumb = entry.thumbnailFilename;
    return thumb == null ? null : File(pathFor(thumb));
  }

  /// Where the video for frame [carouselIndex] of [shortcode] lives in the
  /// library. Download into this, then register it with [addVideo].
  static Future<File> videoFileFor(String shortcode, int carouselIndex) async {
    await _libraryDir.create(recursive: true);
    return File(pathFor(_videoFilename(shortcode, carouselIndex)));
  }

  static String _videoFilename(String shortcode, int i) =>
      VideoService.videoFilename(shortcode, i);

  /// Returns all library entries, newest-first.
  static Future<List<LibraryImage>> list() async {
    if (!await _indexFile.exists()) return const [];
    final raw = await _indexFile.readAsString();
    if (raw.isEmpty) return const [];
    final decoded = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
    final items = decoded.map(LibraryImage.fromJson).toList();
    items.sort((a, b) => b.grabbedAt.compareTo(a.grabbedAt));
    return items;
  }

  /// Adds one image to the library and returns the new [LibraryImage].
  static Future<LibraryImage> add({
    required Uint8List bytes,
    required String sourceUrl,
    required String shortcode,
    required int carouselIndex,
  }) async {
    await _libraryDir.create(recursive: true);

    final decoded = img.decodeImage(bytes);
    final width = decoded?.width ?? 0;
    final height = decoded?.height ?? 0;

    // Filename is deterministic per (shortcode, index) so re-grabbing the
    // same post idempotently overwrites. The library index is deduped below.
    final filename = '${shortcode}_$carouselIndex.jpg';
    final file = File(p.join(_libraryDir.path, filename));
    await file.writeAsBytes(bytes);

    final entry = LibraryImage(
      id: '${shortcode}_$carouselIndex',
      sourceUrl: sourceUrl,
      shortcode: shortcode,
      carouselIndex: carouselIndex,
      grabbedAt: DateTime.now(),
      width: width,
      height: height,
      fileSize: bytes.length,
      filename: filename,
    );

    final existing = await list();
    final deduped = existing.where((e) => e.id != entry.id).toList();
    // A frame that used to be a video leaves its .mp4 and cover behind.
    for (final old in existing.where((e) => e.id == entry.id)) {
      await _deleteFiles(old, keep: {filename});
    }
    deduped.insert(0, entry);
    await _writeIndex(deduped);
    return entry;
  }

  /// Registers an already-downloaded video (at [videoFileFor]) in the
  /// library, storing [thumbnailBytes] as its cover when given. [width] and
  /// [height] fall back to the cover's dimensions when Instagram didn't
  /// report them.
  static Future<LibraryImage> addVideo({
    required String sourceUrl,
    required String shortcode,
    required int carouselIndex,
    Uint8List? thumbnailBytes,
    int? width,
    int? height,
    double? durationSeconds,
  }) async {
    await _libraryDir.create(recursive: true);
    final filename = _videoFilename(shortcode, carouselIndex);
    final video = File(pathFor(filename));
    final fileSize = await video.length();

    String? thumbName;
    if (thumbnailBytes != null && thumbnailBytes.isNotEmpty) {
      thumbName = '${shortcode}_${carouselIndex}_thumb.jpg';
      await File(pathFor(thumbName)).writeAsBytes(thumbnailBytes);
      if (width == null || height == null) {
        final decoded = img.decodeImage(thumbnailBytes);
        width ??= decoded?.width;
        height ??= decoded?.height;
      }
    }

    final entry = LibraryImage(
      id: '${shortcode}_$carouselIndex',
      sourceUrl: sourceUrl,
      shortcode: shortcode,
      carouselIndex: carouselIndex,
      grabbedAt: DateTime.now(),
      width: width ?? 0,
      height: height ?? 0,
      fileSize: fileSize,
      filename: filename,
      kind: MediaKind.video,
      thumbnailFilename: thumbName,
      durationSeconds: durationSeconds,
    );

    final existing = await list();
    final deduped = existing.where((e) => e.id != entry.id).toList();
    // Re-grabbing a post whose frame used to be an image (or vice versa)
    // leaves the old file behind under a different extension.
    for (final old in existing.where((e) => e.id == entry.id)) {
      await _deleteFiles(old, keep: {filename, thumbName});
    }
    deduped.insert(0, entry);
    await _writeIndex(deduped);
    return entry;
  }

  /// Reads the original bytes for a library image.
  static Future<Uint8List> readBytes(LibraryImage entry) async {
    final file = File(p.join(_libraryDir.path, entry.filename));
    return file.readAsBytes();
  }

  /// Overwrites a library entry's image bytes and updates its metadata.
  ///
  /// Keeps the same filename/id so the entry stays in place in the strip.
  static Future<LibraryImage> update({
    required LibraryImage entry,
    required Uint8List bytes,
  }) async {
    final file = File(p.join(_libraryDir.path, entry.filename));
    await file.writeAsBytes(bytes);

    final decoded = img.decodeImage(bytes);
    final updated = LibraryImage(
      id: entry.id,
      sourceUrl: entry.sourceUrl,
      shortcode: entry.shortcode,
      carouselIndex: entry.carouselIndex,
      grabbedAt: entry.grabbedAt,
      width: decoded?.width ?? entry.width,
      height: decoded?.height ?? entry.height,
      fileSize: bytes.length,
      filename: entry.filename,
      kind: entry.kind,
      thumbnailFilename: entry.thumbnailFilename,
      durationSeconds: entry.durationSeconds,
    );

    final items = await list();
    final replaced = items.map((e) => e.id == entry.id ? updated : e).toList();
    await _writeIndex(replaced);
    return updated;
  }

  /// Removes an entry from the index and deletes its on-disk files.
  static Future<void> delete(LibraryImage entry) async {
    await _deleteFiles(entry);
    final items = await list();
    items.removeWhere((e) => e.id == entry.id);
    await _writeIndex(items);
  }

  /// Empties the library: every file in the library directory (media,
  /// covers, the index, and any leftover `.part` downloads) is deleted.
  /// Exports in the save path are not touched. Returns how many entries
  /// the index held.
  static Future<int> clear() async {
    final count = (await list()).length;
    if (await _libraryDir.exists()) {
      await for (final f in _libraryDir.list()) {
        if (f is File) await f.delete();
      }
    }
    return count;
  }

  static Future<void> _deleteFiles(
    LibraryImage entry, {
    Set<String?> keep = const {},
  }) async {
    for (final name in [entry.filename, entry.thumbnailFilename]) {
      if (name == null || keep.contains(name)) continue;
      final file = File(pathFor(name));
      if (await file.exists()) await file.delete();
    }
  }

  static Future<void> _writeIndex(List<LibraryImage> items) async {
    final tmp = File('${_indexFile.path}.tmp');
    await tmp.writeAsString(
      jsonEncode(items.map((e) => e.toJson()).toList()),
    );
    await tmp.rename(_indexFile.path);
  }
}
