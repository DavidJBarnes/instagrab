import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import '../services/settings_service.dart';

/// Settings screen: save path + default image format.
///
/// Any change here is the single source of truth for save operations —
/// the editor's save button uses these values and never prompts.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  SettingsSnapshot? _current;
  final _pathController = TextEditingController();
  final _apiKeyController = TextEditingController();
  final _apiUrlController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void dispose() {
    _pathController.dispose();
    _apiKeyController.dispose();
    _apiUrlController.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    final snap = await SettingsService.load();
    if (!mounted) return;
    setState(() {
      _current = snap;
      _pathController.text = snap.savePath;
      _apiKeyController.text = snap.wanlyApiKey;
      _apiUrlController.text = snap.wanlyApiUrl;
    });
  }

  Future<void> _pickDirectory() async {
    final path = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Choose save folder',
      initialDirectory: _current?.savePath,
    );
    if (path == null) return;
    await SettingsService.update(savePath: path);
    await _reload();
  }

  Future<void> _savePathFromField() async {
    final text = _pathController.text.trim();
    if (text.isEmpty) return;
    await SettingsService.update(savePath: text);
    await _reload();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Save path updated'),
          duration: Duration(seconds: 1),
        ),
      );
    }
  }

  Future<void> _setFormat(ImageFormat format) async {
    await SettingsService.update(format: format);
    await _reload();
  }

  Future<void> _saveApiKey() async {
    await SettingsService.update(wanlyApiKey: _apiKeyController.text.trim());
    await _reload();
  }

  Future<void> _saveApiUrl() async {
    await SettingsService.update(wanlyApiUrl: _apiUrlController.text.trim());
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final current = _current;

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: current == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(24),
              children: [
                Text('Save location', style: theme.textTheme.titleMedium),
                const SizedBox(height: 4),
                Text(
                  'Images are saved here with no prompt when you hit Save.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _pathController,
                        decoration: const InputDecoration(
                          labelText: 'Folder',
                          isDense: true,
                        ),
                        onSubmitted: (_) => _savePathFromField(),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      icon: const Icon(Icons.folder_open),
                      tooltip: 'Browse',
                      onPressed: _pickDirectory,
                    ),
                    IconButton(
                      icon: const Icon(Icons.check),
                      tooltip: 'Save path',
                      onPressed: _savePathFromField,
                    ),
                  ],
                ),
                const SizedBox(height: 32),
                Text('Default format', style: theme.textTheme.titleMedium),
                const SizedBox(height: 4),
                Text(
                  'Every image save uses this format — no format picker on save. '
                  'Videos are always saved as the original .mp4.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 12),
                RadioGroup<ImageFormat>(
                  groupValue: current.format,
                  onChanged: (v) => v == null ? null : _setFormat(v),
                  child: Column(
                    children: [
                      for (final f in ImageFormat.values)
                        RadioListTile<ImageFormat>(
                          title: Text(f.label),
                          subtitle: Text('.${f.extension}'),
                          value: f,
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 32),
                Text('Wanly API', style: theme.textTheme.titleMedium),
                const SizedBox(height: 4),
                Text(
                  'Configure the Wanly API integration.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _apiKeyController,
                        decoration: const InputDecoration(
                          labelText: 'API Key',
                          isDense: true,
                        ),
                        onSubmitted: (_) => _saveApiKey(),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.check),
                      tooltip: 'Save API key',
                      onPressed: _saveApiKey,
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _apiUrlController,
                        decoration: const InputDecoration(
                          labelText: 'API URL',
                          isDense: true,
                        ),
                        onSubmitted: (_) => _saveApiUrl(),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.check),
                      tooltip: 'Save API URL',
                      onPressed: _saveApiUrl,
                    ),
                  ],
                ),
              ],
            ),
    );
  }
}
