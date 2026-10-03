import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:crop_your_image/crop_your_image.dart' hide ImageFormat;
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import '../services/image_service.dart';
import '../services/library_service.dart';
import '../services/settings_service.dart';
import '../services/video_service.dart';
import 'settings_screen.dart';

/// Editor screen: crop + resize the selected library image.
///
/// Left rail is the full persistent library, newest-first, videos marked
/// with a play badge. Center is the crop/resize editor for images, or a
/// cover-frame preview with a Save video button for videos (which are never
/// edited or re-encoded). Right side is a collapsible metadata pane.
/// Save writes to the user's settings-configured path/format with no
/// prompts — every decision is pre-declared in Settings.
class EditorScreen extends StatefulWidget {
  /// If provided, the editor starts with this library entry selected.
  /// Otherwise the newest entry is selected.
  final String? initialImageId;

  const EditorScreen({super.key, this.initialImageId});

  @override
  State<EditorScreen> createState() => _EditorScreenState();
}

class _EditorScreenState extends State<EditorScreen> {
  List<LibraryImage> _library = const [];
  LibraryImage? _selected;
  Uint8List? _originalBytes;
  Uint8List? _editedBytes;
  bool _loading = true;
  bool _isCropping = false;
  bool _isSaving = false;
  bool _infoVisible = true;

  _EditorMode _mode = _EditorMode.crop;
  final _cropController = CropController();
  double? _cropAspectRatio;
  bool _cropActive = false;

  final _widthController = TextEditingController();
  final _heightController = TextEditingController();
  bool _maintainAspect = true;
  double? _originalAspect;

  Uint8List? get _activeBytes => _editedBytes ?? _originalBytes;

  @override
  void initState() {
    super.initState();
    _loadLibrary();
  }

  @override
  void dispose() {
    _widthController.dispose();
    _heightController.dispose();
    super.dispose();
  }

  Future<void> _loadLibrary() async {
    final items = await LibraryService.list();
    LibraryImage? initial;
    if (widget.initialImageId != null) {
      initial = items.firstWhere(
        (e) => e.id == widget.initialImageId,
        orElse: () => items.isNotEmpty ? items.first : _nullEntry(),
      );
      if (initial.id.isEmpty) initial = null;
    } else if (items.isNotEmpty) {
      initial = items.first;
    }
    if (!mounted) return;
    setState(() {
      _library = items;
      _loading = false;
    });
    if (initial != null) await _selectImage(initial);
  }

  Future<void> _selectImage(LibraryImage entry) async {
    if (_selected?.id == entry.id) return;
    if (entry.isVideo) {
      // A video's only pixels are its cover frame, kept for display. Crop
      // and resize never see it, so the dimension fields are left alone.
      final thumb = LibraryService.thumbnailFileFor(entry);
      final bytes = thumb != null && await thumb.exists()
          ? await thumb.readAsBytes()
          : null;
      if (!mounted) return;
      setState(() {
        _selected = entry;
        _originalBytes = bytes;
        _editedBytes = null;
        _cropActive = false;
      });
      return;
    }
    final bytes = await LibraryService.readBytes(entry);
    if (!mounted) return;
    final decoded = img.decodeImage(bytes);
    setState(() {
      _selected = entry;
      _originalBytes = bytes;
      _editedBytes = null;
      _mode = _EditorMode.crop;
      _cropAspectRatio = null;
      _cropActive = false;
      if (decoded != null) {
        _widthController.text = decoded.width.toString();
        _heightController.text = decoded.height.toString();
        _originalAspect = decoded.width / decoded.height;
      }
    });
  }

  void _performCrop() {
    setState(() => _isCropping = true);
    _cropController.crop();
  }

  void _onCropped(Uint8List cropped) {
    final decoded = img.decodeImage(cropped);
    setState(() {
      _editedBytes = cropped;
      _isCropping = false;
      if (decoded != null) {
        _widthController.text = decoded.width.toString();
        _heightController.text = decoded.height.toString();
      }
    });
    _toast('Image cropped');
  }

  void _resetEdits() {
    setState(() {
      _editedBytes = null;
      _cropActive = false;
      final decoded = img.decodeImage(_originalBytes!);
      if (decoded != null) {
        _widthController.text = decoded.width.toString();
        _heightController.text = decoded.height.toString();
      }
    });
  }

  void _performResize() {
    final w = int.tryParse(_widthController.text);
    final h = int.tryParse(_heightController.text);
    if (w == null || h == null || w <= 0 || h <= 0) {
      _toast('Enter valid width and height');
      return;
    }
    if (w > 10000 || h > 10000) {
      _toast('Maximum dimension is 10000px');
      return;
    }
    final decoded = img.decodeImage(_activeBytes!);
    if (decoded == null) return;
    final resized = ImageService.resize(
      decoded,
      width: w,
      height: h,
      maintainAspect: _maintainAspect,
    );
    setState(() {
      _editedBytes = ImageService.encodePng(resized);
      _widthController.text = resized.width.toString();
      _heightController.text = resized.height.toString();
    });
    _toast('Resized to ${resized.width}×${resized.height}');
  }

  void _onWidthChanged(String value) {
    if (!_maintainAspect || _originalAspect == null) return;
    final w = int.tryParse(value);
    if (w != null && w > 0) {
      _heightController.text = (w / _originalAspect!).round().toString();
    }
  }

  void _onHeightChanged(String value) {
    if (!_maintainAspect || _originalAspect == null) return;
    final h = int.tryParse(value);
    if (h != null && h > 0) {
      _widthController.text = (h * _originalAspect!).round().toString();
    }
  }

  Future<void> _save() async {
    final bytes = _activeBytes;
    final entry = _selected;
    if (bytes == null || entry == null) return;
    // An unedited image is still worth exporting — "grab it and keep the
    // original" is a normal thing to want. Only the library write below is
    // skipped in that case, since there is nothing new to store.
    final hasEdits = _editedBytes != null;
    setState(() => _isSaving = true);
    try {
      final settings = await SettingsService.load();
      final decoded = img.decodeImage(bytes);
      if (decoded == null) throw Exception('Failed to decode image');
      final encoded = settings.format == ImageFormat.jpeg
          ? ImageService.encodeJpeg(decoded, quality: 95)
          : ImageService.encodePng(decoded);
      final filename = ImageService.generateFilename(
        prefix: entry.shortcode,
        ext: settings.format.extension,
      );
      final path = await ImageService.saveImage(
        encoded,
        filename: filename,
        directory: settings.savePath,
      );

      // Update the library entry so the rail shows the edited version.
      // Skipped when nothing was edited: re-encoding an untouched original
      // would only degrade the library copy.
      if (hasEdits) {
        final libraryBytes = ImageService.encodeJpeg(decoded, quality: 95);
        final updatedEntry = await LibraryService.update(
          entry: entry,
          bytes: libraryBytes,
        );
        final items = await LibraryService.list();
        if (mounted) {
          setState(() {
            _library = items;
            _selected = updatedEntry;
            _originalBytes = libraryBytes;
            _editedBytes = null;
            _originalAspect = updatedEntry.width / updatedEntry.height;
            _widthController.text = updatedEntry.width.toString();
            _heightController.text = updatedEntry.height.toString();
          });
        }
      }

      _toast('Saved → $path', duration: const Duration(seconds: 3));
    } catch (e) {
      _toast('Save failed: $e');
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  /// Copies the selected video verbatim into the save path. Re-saving just
  /// overwrites the same `<shortcode>_<i>.mp4`, so it is safe to repeat
  /// (e.g. after changing the save path in Settings).
  Future<void> _saveVideo() async {
    final entry = _selected;
    if (entry == null || !entry.isVideo) return;
    setState(() => _isSaving = true);
    try {
      final source = LibraryService.fileFor(entry);
      if (!await source.exists()) {
        throw Exception('the library copy is missing — grab the post again');
      }
      final settings = await SettingsService.load();
      final path = await VideoService.saveVideo(
        source,
        filename: entry.filename,
        directory: settings.savePath,
      );
      _toast('Saved → $path', duration: const Duration(seconds: 3));
    } catch (e) {
      _toast('Save failed: $e');
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  /// Hands the video to the desktop's default player. Linux only — it is a
  /// plain `xdg-open`, not a plugin, so there is nothing to build per
  /// platform.
  Future<void> _openInPlayer() async {
    final entry = _selected;
    if (entry == null) return;
    try {
      await Process.start(
        'xdg-open',
        [LibraryService.fileFor(entry).path],
        mode: ProcessStartMode.detached,
      );
    } catch (e) {
      _toast('Could not open a video player: $e');
    }
  }

  Future<void> _openSettings() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const SettingsScreen()),
    );
  }

  Future<void> _deleteSelected() async {
    final entry = _selected;
    if (entry == null) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove from library?'),
        content: const Text(
          'This deletes the original image file from the library. Your '
          'saved exports are not affected.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    await LibraryService.delete(entry);
    await _loadLibrary();
  }

  void _toast(String msg, {Duration duration = const Duration(seconds: 1)}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: duration),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_selected == null ? 'Library' : 'Editor'),
        actions: [
          if (_editedBytes != null)
            IconButton(
              icon: const Icon(Icons.undo),
              tooltip: 'Reset edits',
              onPressed: _resetEdits,
            ),
          IconButton(
            icon: Icon(_infoVisible ? Icons.info : Icons.info_outline),
            tooltip: _infoVisible ? 'Hide info' : 'Show info',
            onPressed: () => setState(() => _infoVisible = !_infoVisible),
          ),
          if (_selected != null)
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: 'Remove from library',
              onPressed: _deleteSelected,
            ),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Settings',
            onPressed: _openSettings,
          ),
          IconButton(
            icon: _isSaving
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.save),
            tooltip: _selected?.isVideo == true ? 'Save video' : 'Save',
            onPressed: _isSaving || _selected == null
                ? null
                : (_selected!.isVideo ? _saveVideo : _save),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _LibraryRail(
                  library: _library,
                  selectedId: _selected?.id,
                  selectedBytes: _originalBytes,
                  onSelect: _selectImage,
                ),
                Expanded(
                  child: _selected == null
                      ? const _EmptyEditorHint()
                      : _selected!.isVideo
                          ? _buildVideoView()
                          : _buildEditor(),
                ),
                if (_infoVisible && _selected != null)
                  _InfoPane(
                    entry: _selected!,
                    currentBytes: _activeBytes,
                    edited: _editedBytes != null,
                  ),
              ],
            ),
    );
  }

  /// Video pane: cover frame with a play badge, the facts we know, and Save
  /// video. Crop and resize are image-only and are not offered here.
  Widget _buildVideoView() {
    final theme = Theme.of(context);
    final entry = _selected!;
    final facts = [
      if (entry.width > 0 && entry.height > 0)
        '${entry.width} × ${entry.height}',
      if (entry.durationSeconds != null)
        VideoService.formatDuration(entry.durationSeconds!),
      _humanBytes(entry.fileSize),
    ].join('  ·  ');
    return Column(
      children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Stack(
              alignment: Alignment.center,
              children: [
                Positioned.fill(
                  child: _originalBytes != null
                      ? Image.memory(_originalBytes!, fit: BoxFit.contain)
                      : Container(
                          color: theme.colorScheme.surfaceContainerHighest,
                          child: Icon(
                            Icons.movie_outlined,
                            size: 64,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                ),
                const _PlayBadge(size: 72),
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                facts,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: 4),
              Text(
                'Videos are saved exactly as downloaded. Crop and resize '
                'are for images only.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: _isSaving ? null : _saveVideo,
                icon: _isSaving
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.save_alt),
                label: Text(_isSaving ? 'Saving...' : 'Save video'),
                style: FilledButton.styleFrom(
                  minimumSize: const Size(double.infinity, 48),
                ),
              ),
              if (Platform.isLinux) ...[
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: _openInPlayer,
                  icon: const Icon(Icons.play_circle_outline),
                  label: const Text('Open in video player'),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(double.infinity, 44),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildEditor() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: SegmentedButton<_EditorMode>(
            segments: const [
              ButtonSegment(
                value: _EditorMode.crop,
                icon: Icon(Icons.crop),
                label: Text('Crop'),
              ),
              ButtonSegment(
                value: _EditorMode.resize,
                icon: Icon(Icons.photo_size_select_large),
                label: Text('Resize'),
              ),
            ],
            selected: {_mode},
            onSelectionChanged: (modes) {
              setState(() => _mode = modes.first);
            },
          ),
        ),
        Expanded(
          child:
              _mode == _EditorMode.crop ? _buildCropView() : _buildResizeView(),
        ),
      ],
    );
  }

  Widget _buildCropView() {
    final theme = Theme.of(context);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _aspectChip('Free', null),
                _aspectChip('1:1', 1.0),
                _aspectChip('4:5', 4 / 5),
                _aspectChip('16:9', 16 / 9),
                _aspectChip('9:16', 9 / 16),
                _aspectChip('4:3', 4 / 3),
                _aspectChip('3:2', 3 / 2),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: _cropActive
                ? Crop(
                    key: ValueKey(
                      '${_selected?.id}-$_cropAspectRatio-${_editedBytes?.length}',
                    ),
                    controller: _cropController,
                    image: _activeBytes!,
                    aspectRatio: _cropAspectRatio,
                    withCircleUi: false,
                    onCropped: _onCropped,
                    initialSize: 0.8,
                    maskColor: Colors.black.withAlpha(180),
                    baseColor: theme.colorScheme.surface,
                    cornerDotBuilder: (size, edgeAlignment) => DotControl(
                      color: theme.colorScheme.primary,
                    ),
                  )
                : GestureDetector(
                    onTapDown: (_) => setState(() => _cropActive = true),
                    onPanStart: (_) => setState(() => _cropActive = true),
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        Image.memory(_activeBytes!, fit: BoxFit.contain),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.black54,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: const Text(
                            'Tap to select crop area',
                            style: TextStyle(color: Colors.white, fontSize: 13),
                          ),
                        ),
                      ],
                    ),
                  ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: FilledButton.icon(
            onPressed: _isCropping || !_cropActive ? null : _performCrop,
            icon: _isCropping
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.crop),
            label: Text(_isCropping ? 'Cropping...' : 'Apply Crop'),
            style: FilledButton.styleFrom(
              minimumSize: const Size(double.infinity, 48),
            ),
          ),
        ),
      ],
    );
  }

  Widget _aspectChip(String label, double? ratio) {
    final isSelected = _cropAspectRatio == ratio;
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: ChoiceChip(
        label: Text(label),
        selected: isSelected,
        onSelected: (_) => setState(() => _cropAspectRatio = ratio),
      ),
    );
  }

  Widget _buildResizeView() {
    final theme = Theme.of(context);
    return Column(
      children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Center(
              child: Image.memory(_activeBytes!, fit: BoxFit.contain),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _widthController,
                          decoration: const InputDecoration(
                            labelText: 'Width',
                            suffixText: 'px',
                            isDense: true,
                          ),
                          keyboardType: TextInputType.number,
                          onChanged: _onWidthChanged,
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        child: IconButton(
                          icon: Icon(
                            _maintainAspect ? Icons.link : Icons.link_off,
                            color: _maintainAspect
                                ? theme.colorScheme.primary
                                : theme.colorScheme.onSurfaceVariant,
                          ),
                          tooltip: _maintainAspect
                              ? 'Unlock aspect ratio'
                              : 'Lock aspect ratio',
                          onPressed: () => setState(
                            () => _maintainAspect = !_maintainAspect,
                          ),
                        ),
                      ),
                      Expanded(
                        child: TextField(
                          controller: _heightController,
                          decoration: const InputDecoration(
                            labelText: 'Height',
                            suffixText: 'px',
                            isDense: true,
                          ),
                          keyboardType: TextInputType.number,
                          onChanged: _onHeightChanged,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        _resizePresetChip('240×320', 240, 320),
                        _resizePresetChip('480×640 (Feature Phone)', 480, 640),
                        _resizePresetChip('600×800', 600, 800),
                        _resizePresetChip(
                            '750×1000 (iPhone 6 to 8)', 750, 1000),
                        _resizePresetChip('768×1024 (Old Android)', 768, 1024),
                        _resizePresetChip('960×1280', 960, 1280),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    onPressed: _performResize,
                    icon: const Icon(Icons.photo_size_select_large),
                    label: const Text('Apply Resize'),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(double.infinity, 48),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _resizePresetChip(String label, int w, int h) {
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: ActionChip(
        label: Text(label),
        onPressed: () {
          _widthController.text = w.toString();
          _heightController.text = h.toString();
          _maintainAspect = false;
          _performResize();
        },
      ),
    );
  }

  static LibraryImage _nullEntry() => LibraryImage(
        id: '',
        sourceUrl: '',
        shortcode: '',
        carouselIndex: 0,
        grabbedAt: DateTime.fromMillisecondsSinceEpoch(0),
        width: 0,
        height: 0,
        fileSize: 0,
        filename: '',
      );
}

enum _EditorMode { crop, resize }

String _humanBytes(int n) {
  if (n < 1024) return '$n B';
  if (n < 1024 * 1024) return '${(n / 1024).toStringAsFixed(1)} KB';
  return '${(n / (1024 * 1024)).toStringAsFixed(1)} MB';
}

/// Vertical scrollable thumbnail strip on the left edge. Newest-first.
class _LibraryRail extends StatelessWidget {
  final List<LibraryImage> library;
  final String? selectedId;
  final Uint8List? selectedBytes;
  final Future<void> Function(LibraryImage) onSelect;

  const _LibraryRail({
    required this.library,
    required this.selectedId,
    required this.selectedBytes,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: 96,
      decoration: BoxDecoration(
        border: Border(right: BorderSide(color: theme.dividerColor)),
      ),
      child: Column(
        children: [
          Expanded(
            child: library.isEmpty
                ? const _EmptyLibraryHint()
                : ListView.builder(
                    padding: const EdgeInsets.all(8),
                    itemCount: library.length,
                    itemBuilder: (_, i) {
                      final entry = library[i];
                      final active = entry.id == selectedId;
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: GestureDetector(
                          onTap: () => onSelect(entry),
                          child: Container(
                            height: 80,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: active
                                    ? theme.colorScheme.primary
                                    : theme.colorScheme.outline.withAlpha(80),
                                width: active ? 2 : 1,
                              ),
                            ),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(6),
                              child: Stack(
                                fit: StackFit.expand,
                                alignment: Alignment.center,
                                children: [
                                  _thumbnail(context, entry, active),
                                  if (entry.isVideo)
                                    const Center(child: _PlayBadge(size: 28)),
                                ],
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _thumbnail(BuildContext context, LibraryImage entry, bool active) {
    if (active && selectedBytes != null) {
      return Image.memory(
        selectedBytes!,
        fit: BoxFit.cover,
        gaplessPlayback: true,
      );
    }
    final file = LibraryService.thumbnailFileFor(entry);
    if (file == null) {
      // A video whose cover could not be fetched.
      return ColoredBox(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
      );
    }
    return Image.file(
      file,
      fit: BoxFit.cover,
      gaplessPlayback: true,
      errorBuilder: (_, __, ___) => ColoredBox(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
      ),
    );
  }
}

/// Round translucent play symbol drawn over video thumbnails. Purely a
/// marker — there is no in-app player.
class _PlayBadge extends StatelessWidget {
  final double size;
  const _PlayBadge({required this.size});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: const BoxDecoration(
        color: Colors.black54,
        shape: BoxShape.circle,
      ),
      child: Icon(Icons.play_arrow, color: Colors.white, size: size * 0.7),
    );
  }
}

/// Right-side metadata panel describing the selected image.
class _InfoPane extends StatefulWidget {
  final LibraryImage entry;
  final Uint8List? currentBytes;
  final bool edited;

  const _InfoPane({
    required this.entry,
    required this.currentBytes,
    required this.edited,
  });

  @override
  State<_InfoPane> createState() => _InfoPaneState();
}

class _InfoPaneState extends State<_InfoPane> {
  List<String> _folderNames = [];
  String? _selectedFolder;
  bool _loadingFolders = false;
  String? _folderError;
  bool _uploading = false;

  Uint8List? get _bytes => widget.currentBytes;

  @override
  void initState() {
    super.initState();
    _loadFolders();
  }

  @override
  void didUpdateWidget(covariant _InfoPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.entry.id != widget.entry.id) {
      _loadFolders();
    }
  }

  Future<void> _loadFolders() async {
    // Wanly's endpoints are /images/...; videos aren't offered for upload.
    if (widget.entry.isVideo) return;
    final settings = await SettingsService.load();
    if (settings.wanlyApiUrl.isEmpty) return;
    setState(() {
      _loadingFolders = true;
      _folderError = null;
    });
    try {
      final uri = Uri.parse('${settings.wanlyApiUrl}/images/folders');
      final response = await http.get(uri, headers: {
        if (settings.wanlyApiKey.isNotEmpty) 'X-API-Key': settings.wanlyApiKey,
      }).timeout(const Duration(seconds: 10));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as List<dynamic>;
        setState(() {
          _folderNames = data
              .map((e) => (e as Map<String, dynamic>)['name']?.toString() ?? '')
              .where((n) => n.isNotEmpty)
              .toList();
        });
      } else {
        setState(() => _folderError = 'HTTP ${response.statusCode}');
      }
    } catch (e) {
      if (mounted) setState(() => _folderError = e.toString());
    }
    if (mounted) setState(() => _loadingFolders = false);
  }

  Future<void> _upload() async {
    final bytes = _bytes;
    if (_selectedFolder == null || bytes == null) return;
    final settings = await SettingsService.load();
    if (settings.wanlyApiUrl.isEmpty) return;
    setState(() => _uploading = true);
    try {
      final uri = Uri.parse('${settings.wanlyApiUrl}/images/upload');
      final request = http.MultipartRequest('POST', uri);
      if (settings.wanlyApiKey.isNotEmpty) {
        request.headers['X-API-Key'] = settings.wanlyApiKey;
      }
      request.fields['folder'] = _selectedFolder!;
      request.files.add(http.MultipartFile.fromBytes(
        'file',
        bytes,
        filename: '${widget.entry.shortcode}.jpg',
      ));
      final streamed =
          await request.send().timeout(const Duration(seconds: 30));
      final response = await http.Response.fromStream(streamed);
      if (response.statusCode == 200) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Uploaded to Wanly'),
              duration: Duration(seconds: 2),
            ),
          );
        }
      } else {
        if (mounted) _showError('Upload failed: HTTP ${response.statusCode}');
      }
    } catch (e) {
      if (mounted) _showError('Upload failed: $e');
    }
    if (mounted) setState(() => _uploading = false);
  }

  void _showError(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 3)),
    );
  }

  Widget _buildFolderDropdown(ThemeData theme) {
    if (_loadingFolders) {
      return const Padding(
        padding: EdgeInsets.only(top: 8),
        child: SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    if (_folderError != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              _folderError!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ),
          TextButton.icon(
            onPressed: _loadFolders,
            icon: const Icon(Icons.refresh, size: 16),
            label: const Text('Retry'),
          ),
        ],
      );
    }
    if (_folderNames.isEmpty) {
      return Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Text(
          'No folders found',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Folder',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 4),
          DropdownButton<String>(
            value:
                _folderNames.contains(_selectedFolder) ? _selectedFolder : null,
            isExpanded: true,
            hint: const Text('Select folder'),
            items: _folderNames.map((n) {
              return DropdownMenuItem(value: n, child: Text(n));
            }).toList(),
            onChanged: (v) => setState(() => _selectedFolder = v),
          ),
        ],
      ),
    );
  }

  Widget _buildVideoInfo(BuildContext context) {
    final theme = Theme.of(context);
    final e = widget.entry;
    return Container(
      width: 260,
      decoration: BoxDecoration(
        border: Border(left: BorderSide(color: theme.dividerColor)),
      ),
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Video info', style: theme.textTheme.titleMedium),
          const SizedBox(height: 12),
          _row(
            context,
            'Dimensions',
            e.width > 0 && e.height > 0
                ? '${e.width} × ${e.height}'
                : 'Unknown',
          ),
          _row(
            context,
            'Duration',
            e.durationSeconds != null
                ? VideoService.formatDuration(e.durationSeconds!)
                : 'Unknown',
          ),
          _row(context, 'Size on disk', _humanBytes(e.fileSize)),
          _row(context, 'File', e.filename),
          _row(context, 'Shortcode', e.shortcode),
          _row(context, 'Carousel index', '${e.carouselIndex}'),
          _row(context, 'Grabbed', _formatDate(e.grabbedAt)),
          const SizedBox(height: 12),
          Text('Source', style: theme.textTheme.titleSmall),
          const SizedBox(height: 4),
          SelectableText(
            e.sourceUrl,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.primary,
            ),
          ),
          const Divider(height: 32),
          Text('Wanly', style: theme.textTheme.titleSmall),
          const SizedBox(height: 4),
          Text(
            'Upload to Wanly is for images only.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.entry.isVideo) return _buildVideoInfo(context);
    final theme = Theme.of(context);
    final decoded = _bytes != null ? img.decodeImage(_bytes!) : null;
    final curW = decoded?.width ?? widget.entry.width;
    final curH = decoded?.height ?? widget.entry.height;

    return Container(
      width: 260,
      decoration: BoxDecoration(
        border: Border(left: BorderSide(color: theme.dividerColor)),
      ),
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Image info', style: theme.textTheme.titleMedium),
          const SizedBox(height: 12),
          _row(context, 'Original',
              '${widget.entry.width} × ${widget.entry.height}'),
          _row(
            context,
            'Current',
            '$curW × $curH${widget.edited ? '  (edited)' : ''}',
          ),
          _row(context, 'Size on disk', _humanBytes(widget.entry.fileSize)),
          _row(context, 'Shortcode', widget.entry.shortcode),
          _row(context, 'Carousel index', '${widget.entry.carouselIndex}'),
          _row(context, 'Grabbed', _formatDate(widget.entry.grabbedAt)),
          const SizedBox(height: 12),
          Text('Source', style: theme.textTheme.titleSmall),
          const SizedBox(height: 4),
          SelectableText(
            widget.entry.sourceUrl,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.primary,
            ),
          ),
          const Divider(height: 32),
          Text('Wanly', style: theme.textTheme.titleSmall),
          _buildFolderDropdown(theme),
          const SizedBox(height: 8),
          FilledButton.tonalIcon(
            onPressed: _uploading || _selectedFolder == null || _bytes == null
                ? null
                : _upload,
            icon: _uploading
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.cloud_upload_outlined),
            label: Text(_uploading ? 'Uploading...' : 'Upload to Wanly'),
          ),
        ],
      ),
    );
  }

  Widget _row(BuildContext context, String k, String v) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 92,
            child: Text(
              k,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(child: Text(v, style: theme.textTheme.bodySmall)),
        ],
      ),
    );
  }

  String _formatDate(DateTime d) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
  }
}

class _EmptyEditorHint extends StatelessWidget {
  const _EmptyEditorHint();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.photo_library_outlined,
              size: 64,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 16),
            Text(
              'Library is empty',
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            Text(
              'Go back and grab an Instagram post to add images.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyLibraryHint extends StatelessWidget {
  const _EmptyLibraryHint();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(8),
        child: Text(
          'Empty',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 11),
        ),
      ),
    );
  }
}
