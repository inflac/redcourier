import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../app_controller.dart';
import '../app_notifier.dart';
import '../core/group.dart';
import '../core/messages.dart';
import '../i18n.dart';
import '../theme.dart';
import 'widgets.dart';

class SendScreen extends StatefulWidget {
  final AppController app;
  const SendScreen({super.key, required this.app});

  @override
  State<SendScreen> createState() => _SendScreenState();
}

class _SendScreenState extends State<SendScreen> {
  /// Limited by how long the file hosts keep uploads (filebin about a week).
  static const _allLifetimes = [1, 3, 6];

  final Set<String> _recipients = {};
  final List<String> _paths = [];
  final _note = TextEditingController();
  final _filter = TextEditingController();
  int _lifetime = 3;

  List<int> get _lifetimes => _allLifetimes.where((d) => Duration(days: d) <= _s.maxLifetime).toList();
  bool _busy = false;
  String _status = '';
  double? _progress;
  CancelToken? _cancel;

  GroupSession get _s => widget.app.session!;

  Future<void> _pickFiles() async {
    List<String> picked;
    if (Platform.isAndroid || Platform.isIOS) {
      // Returns an empty list when the user cancels.
      final files = await FilePicker.pickFiles();
      picked = files.map((f) => f.path).whereType<String>().toList();
    } else {
      final files = await openFiles();
      picked = files.map((f) => f.path).toList();
    }
    setState(() {
      for (final path in picked) {
        if (!_paths.contains(path)) _paths.add(path);
      }
    });
  }

  Future<void> _send() async {
    if (_recipients.isEmpty) {
      AppNotifier.showError(tr('Choose at least one recipient.'));
      return;
    }
    if (_paths.isEmpty) {
      AppNotifier.showError(tr('Choose at least one file.'));
      return;
    }
    final token = CancelToken();
    setState(() {
      _busy = true;
      _status = tr('Preparing…');
      _progress = null;
      _cancel = token;
    });
    try {
      await widget.app.run((s) => s.send(
            recipientIds: _recipients.toList(),
            paths: List.of(_paths),
            note: _note.text.trim(),
            lifetime: Duration(days: _lifetime),
            cancel: token,
            onProgress: (template, args, progress) {
              if (mounted) {
                setState(() {
                  _status = tr(template, args);
                  _progress = progress;
                });
              }
            },
          ));
      AppNotifier.showSuccess(tr('Sent'));
      if (mounted) Navigator.pop(context);
    } on CancelledException {
      AppNotifier.showInfo(tr('Sending cancelled. Nothing was published.'));
      if (mounted) setState(() => _busy = false);
    } catch (e) {
      AppNotifier.showError(tr('Sending failed: {reason}', {'reason': errorMessage(e)}));
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    // If the screen goes away anyway (for example the app locks), the upload
    // stops and already uploaded parts are deleted.
    _cancel?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final query = _filter.text.trim().toLowerCase();
    final candidates = _s.activeMembers
        .where((m) => m.id != _s.myId)
        .where((m) => query.isEmpty || m.identifier.toLowerCase().contains(query))
        .toList();

    return PopScope(
      // While sending, leave only through "Cancel sending".
      canPop: !_busy,
      child: Scaffold(
        appBar: AppBar(title: Text(tr('Send files'))),
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640),
              child: ListView(padding: const EdgeInsets.all(16), children: [
                AbsorbPointer(
                  absorbing: _busy,
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    SectionCard(title: tr('Recipients'), icon: Icons.people_outline, children: [
                      if (_s.activeMembers.length > 8) ...[
                        TextField(
                          controller: _filter,
                          decoration: InputDecoration(
                              labelText: tr('Search identifier'), prefixIcon: const Icon(Icons.search)),
                          onChanged: (_) => setState(() {}),
                        ),
                        const SizedBox(height: 12),
                      ],
                      if (candidates.isEmpty)
                        Text(tr('No other members yet. Ask an admin to add people.'),
                            style: TextStyle(color: palette.fgDim)),
                      Wrap(spacing: 8, runSpacing: 8, children: [
                        for (final m in candidates)
                          FilterChip(
                            label: Text(m.identifier),
                            selected: _recipients.contains(m.id),
                            onSelected: (v) =>
                                setState(() => v ? _recipients.add(m.id) : _recipients.remove(m.id)),
                          ),
                      ]),
                    ]),
                    const SizedBox(height: 16),
                    SectionCard(title: tr('Files'), icon: Icons.attach_file, children: [
                      for (final path in _paths)
                        Row(children: [
                          Icon(Icons.insert_drive_file_outlined, size: 20, color: palette.fgDim),
                          const SizedBox(width: 8),
                          Expanded(child: Text(p.basename(path), overflow: TextOverflow.ellipsis)),
                          Text(formatSize(File(path).lengthSync()),
                              style: TextStyle(color: palette.fgDim, fontSize: 13)),
                          IconButton(
                            tooltip: tr('Remove'),
                            icon: const Icon(Icons.close, size: 18),
                            onPressed: () => setState(() => _paths.remove(path)),
                          ),
                        ]),
                      const SizedBox(height: 8),
                      OutlinedButton.icon(
                        onPressed: _pickFiles,
                        icon: const Icon(Icons.add),
                        label: Text(_paths.isEmpty ? tr('Choose files') : tr('Add more files')),
                      ),
                    ]),
                    const SizedBox(height: 16),
                    SectionCard(title: tr('Details'), icon: Icons.notes, children: [
                      SecureTextField(
                          controller: _note, label: tr('Note (optional, encrypted)'), maxLines: 4),
                      const SizedBox(height: 12),
                      DropdownButtonFormField<int>(
                        initialValue: _lifetime,
                        decoration: InputDecoration(labelText: tr('Delete automatically after')),
                        items: [
                          for (final d in _lifetimes)
                            DropdownMenuItem(
                                value: d, child: Text(d == 1 ? tr('1 day') : tr('{n} days', {'n': d}))),
                        ],
                        onChanged: (v) => setState(() => _lifetime = v ?? _lifetime),
                      ),
                    ]),
                  ]),
                ),
                const SizedBox(height: 20),
                if (_busy) ...[
                  Text(_status, textAlign: TextAlign.center),
                  const SizedBox(height: 8),
                  LinearProgressIndicator(
                      value: _progress, minHeight: 8, borderRadius: BorderRadius.circular(4)),
                  const SizedBox(height: 20),
                ],
                if (_busy)
                  OutlinedButton.icon(
                    onPressed: _cancel!.isCancelled ? null : () => setState(() => _cancel!.cancel()),
                    icon: const Icon(Icons.stop_circle_outlined),
                    label: Text(tr('Cancel sending')),
                  )
                else
                  ElevatedButton.icon(
                    onPressed: _send,
                    icon: const Icon(Icons.send),
                    label: Text(_recipients.isEmpty
                        ? tr('Send')
                        : tr('Send to {n} recipient(s)', {'n': _recipients.length})),
                  ),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}
