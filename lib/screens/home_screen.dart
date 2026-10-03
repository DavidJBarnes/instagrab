import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/media_item.dart';
import '../services/instagram_service.dart';
import '../services/image_service.dart';
import '../services/library_service.dart';
import '../services/settings_service.dart';
import '../services/video_service.dart';
import 'editor_screen.dart';
import 'settings_screen.dart';

/// Home screen: paste an Instagram URL, download into the library, or
/// open the library directly to re-edit previously grabbed images.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _urlController = TextEditingController();
  final _focusNode = FocusNode();
  bool _loading = false;
  String? _error;
  String? _status;

  @override
  void dispose() {
    _urlController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data?.text != null && data!.text!.isNotEmpty) {
      _urlController.text = data.text!;
      _urlController.selection = TextSelection.fromPosition(
        TextPosition(offset: _urlController.text.length),
      );
    }
  }

  Future<void> _processUrl() async {
    final input = _urlController.text.trim();
    if (input.isEmpty) {
      setState(() => _error = 'Please enter an Instagram URL');
      return;
    }
    final canonical = InstagramService.normalizeUrl(input);
    if (canonical == null) {
      setState(() => _error = 'Not a valid Instagram post URL');
      return;
    }
    final shortcode = RegExp(r'/p/([^/]+)/').firstMatch(canonical)!.group(1)!;

    setState(() {
      _loading = true;
      _error = null;
      _status = 'Finding media...';
    });

    try {
      final media = await InstagramService.extractMedia(input);
      if (media.isEmpty) {
        setState(() {
          _loading = false;
          _error = 'No images or videos found in this post';
        });
        return;
      }

      final settings = await SettingsService.load();
      final added = <LibraryImage>[];
      var exported = 0;
      for (var i = 0; i < media.length; i++) {
        final item = media[i];
        final label = item.isVideo ? 'video' : 'image';
        setState(() {
          _status = 'Downloading $label (${i + 1}/${media.length})...';
        });
        try {
          final LibraryImage entry;
          if (item.isVideo) {
            entry =
                await _grabVideo(item, canonical, shortcode, i, media.length);
          } else {
            final bytes = await ImageService.downloadImage(item.url);
            entry = await LibraryService.add(
              bytes: bytes,
              sourceUrl: canonical,
              shortcode: shortcode,
              carouselIndex: i,
            );
          }
          added.add(entry);

          // Also drop the untouched original into the user's save path, so a
          // grab alone produces files where they expect them. Written
          // verbatim (no decode/re-encode) to keep the CDN original intact —
          // the export format setting applies to editor image exports only.
          try {
            if (entry.isVideo) {
              await VideoService.saveVideo(
                LibraryService.fileFor(entry),
                filename: entry.filename,
                directory: settings.savePath,
              );
            } else {
              final bytes = await LibraryService.readBytes(entry);
              final ext = ImageService.extensionForBytes(bytes);
              await ImageService.saveImage(
                bytes,
                filename: '${shortcode}_$i.$ext',
                directory: settings.savePath,
              );
            }
            exported++;
          } catch (e) {
            // A read-only or missing save path must not lose the grab —
            // the library copy above is already safe on disk.
            debugPrint('Failed to export $label ${i + 1} to save path: $e');
          }
        } catch (e) {
          // Skip failures on individual carousel frames
          debugPrint('Failed to grab $label ${i + 1}: $e');
        }
      }

      if (added.isEmpty) {
        setState(() {
          _loading = false;
          _error = 'Failed to download any media from this post';
        });
        return;
      }

      setState(() {
        _loading = false;
        _error = exported == 0
            ? 'Grabbed ${added.length} item(s) to the library, but could not '
                'write to ${settings.savePath} — check the save path in Settings.'
            : null;
      });

      if (mounted) {
        await Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => EditorScreen(initialImageId: added.first.id),
          ),
        );
      }
    } on InstagramExtractionException catch (e) {
      setState(() {
        _loading = false;
        _error = e.message;
      });
    } catch (e) {
      setState(() {
        _loading = false;
        _error = 'Unexpected error: $e';
      });
    }
  }

  /// Streams one video into the library (with its cover frame, when there
  /// is one) and registers it, reporting progress in the button label.
  Future<LibraryImage> _grabVideo(
    MediaItem item,
    String canonical,
    String shortcode,
    int index,
    int count,
  ) async {
    final dest = await LibraryService.videoFileFor(shortcode, index);
    var lastPercent = -1;
    await VideoService.downloadVideo(
      item.url,
      dest,
      onProgress: (received, total) {
        if (!mounted) return;
        final mb = (received / (1024 * 1024)).toStringAsFixed(1);
        final percent =
            total == null || total == 0 ? null : received * 100 ~/ total;
        // Repaint on whole-percent steps, not on every network chunk.
        if (percent != null && percent == lastPercent) return;
        lastPercent = percent ?? lastPercent;
        setState(() {
          _status = 'Downloading video (${index + 1}/$count) '
              '${percent != null ? '$percent%' : '$mb MB'}...';
        });
      },
    );

    // The cover is only for display; a video without one is still a grab.
    Uint8List? thumb;
    final thumbUrl = item.thumbnailUrl;
    if (thumbUrl != null) {
      try {
        thumb = await ImageService.downloadImage(thumbUrl);
      } catch (e) {
        debugPrint('Failed to fetch cover for video ${index + 1}: $e');
      }
    }

    return LibraryService.addVideo(
      sourceUrl: canonical,
      shortcode: shortcode,
      carouselIndex: index,
      thumbnailBytes: thumb,
      width: item.width,
      height: item.height,
      durationSeconds: item.durationSeconds,
    );
  }

  Future<void> _openLibrary() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const EditorScreen()),
    );
  }

  Future<void> _openSettings() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const SettingsScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('InstaGrab'),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Settings',
            onPressed: _openSettings,
          ),
        ],
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 500),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Icon(
                  Icons.photo_library_outlined,
                  size: 64,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(height: 16),
                Text(
                  'Grab Instagram Media',
                  style: theme.textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  'Paste an Instagram post or reel URL to add its images and '
                  'videos to your library, '
                  'or open the library to re-edit past grabs.',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 32),
                TextField(
                  controller: _urlController,
                  focusNode: _focusNode,
                  enabled: !_loading,
                  decoration: InputDecoration(
                    hintText: 'https://www.instagram.com/p/...',
                    labelText: 'Instagram URL',
                    prefixIcon: const Icon(Icons.link),
                    suffixIcon: IconButton(
                      icon: const Icon(Icons.paste),
                      tooltip: 'Paste from clipboard',
                      onPressed: _loading ? null : _pasteFromClipboard,
                    ),
                    errorText: _error,
                  ),
                  keyboardType: TextInputType.url,
                  textInputAction: TextInputAction.go,
                  onSubmitted: (_) => _processUrl(),
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: _loading ? null : _processUrl,
                  icon: _loading
                      ? SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: theme.colorScheme.onPrimary,
                          ),
                        )
                      : const Icon(Icons.download),
                  label: Text(
                    _loading ? (_status ?? 'Processing...') : 'Grab',
                  ),
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    textStyle: theme.textTheme.titleMedium,
                  ),
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: _loading ? null : _openLibrary,
                  icon: const Icon(Icons.collections_outlined),
                  label: const Text('Open Library'),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
