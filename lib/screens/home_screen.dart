import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/instagram_service.dart';
import '../services/image_service.dart';
import '../services/library_service.dart';
import '../services/settings_service.dart';
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
      _status = 'Extracting image URLs...';
    });

    try {
      final imageUrls = await InstagramService.extractImageUrls(input);
      if (imageUrls.isEmpty) {
        setState(() {
          _loading = false;
          _error = 'No images found in this post';
        });
        return;
      }

      final settings = await SettingsService.load();
      final added = <LibraryImage>[];
      var exported = 0;
      for (var i = 0; i < imageUrls.length; i++) {
        setState(() {
          _status = 'Downloading image (${i + 1}/${imageUrls.length})...';
        });
        try {
          final bytes = await ImageService.downloadImage(imageUrls[i]);
          final entry = await LibraryService.add(
            bytes: bytes,
            sourceUrl: canonical,
            shortcode: shortcode,
            carouselIndex: i,
          );
          added.add(entry);

          // Also drop the untouched original into the user's save path, so a
          // grab alone produces files where they expect them. Written
          // verbatim (no decode/re-encode) to keep the CDN original intact —
          // the export format setting applies to editor exports only.
          try {
            final ext = ImageService.extensionForBytes(bytes);
            await ImageService.saveImage(
              bytes,
              filename: '${shortcode}_$i.$ext',
              directory: settings.savePath,
            );
            exported++;
          } catch (e) {
            // A read-only or missing save path must not lose the grab —
            // the library copy above is already safe on disk.
            debugPrint('Failed to export image ${i + 1} to save path: $e');
          }
        } catch (e) {
          // Skip failures on individual carousel frames
          debugPrint('Failed to grab image ${i + 1}: $e');
        }
      }

      if (added.isEmpty) {
        setState(() {
          _loading = false;
          _error = 'Failed to download any images from this post';
        });
        return;
      }

      setState(() {
        _loading = false;
        _error = exported == 0
            ? 'Grabbed ${added.length} image(s) to the library, but could not '
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
                  'Grab Instagram Images',
                  style: theme.textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  'Paste an Instagram share URL to add it to your library, '
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
                    _loading ? (_status ?? 'Processing...') : 'Grab Images',
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
