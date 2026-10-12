import 'dart:async';

import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../app_notifier.dart';
import '../core/crypto_util.dart';
import '../core/group.dart';
import '../core/messages.dart';
import '../i18n.dart';
import '../notifications.dart';
import '../theme.dart';
import 'members_screen.dart';
import 'qr_scan.dart';
import 'send_screen.dart';
import 'settings_screen.dart';
import 'update_ui.dart';
import 'widgets.dart';

class HomeScreen extends StatefulWidget {
  final AppController app;
  final ValueNotifier<ThemeMode> themeMode;
  const HomeScreen({super.key, required this.app, required this.themeMode});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  bool _syncing = false;
  String? _problem;
  bool _notMember = false;

  /// Running downloads: entry id -> (status, progress).
  final Map<String, (String, double?)> _downloads = {};
  final Map<String, CancelToken> _cancels = {};
  Timer? _timer;
  bool _inForeground = true;

  GroupSession get _s => widget.app.session!;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _sync();
      if (Notifications.enabled) await Notifications.requestPermission(onlyOnce: true);
    });
    _timer = Timer.periodic(const Duration(minutes: syncIntervalMinutes), (_) => _sync(quiet: true));
  }

  @override
  void dispose() {
    _timer?.cancel();
    for (final t in _cancels.values) {
      t.cancel();
    }
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _inForeground = state == AppLifecycleState.resumed;
    if (state == AppLifecycleState.resumed) _sync(quiet: true);
  }

  Future<void> _sync({bool quiet = false, String? fingerprint}) async {
    if (_syncing || widget.app.session == null) return;
    setState(() => _syncing = true);
    try {
      final r = await widget.app.sync(confirmedFingerprint: fingerprint);
      if (!mounted) return;
      setState(() {
        _problem = null;
        _notMember = false;
      });
      if (r.newEntries > 0 && !_inForeground) {
        await Notifications.newDeliveries(r.newEntries);
      } else if (r.newEntries > 0) {
        AppNotifier.showSuccess(
            r.newEntries == 1 ? tr('1 new delivery') : tr('{n} new deliveries', {'n': r.newEntries}));
      } else if (!quiet) {
        AppNotifier.showInfo(tr('Up to date'));
      }
      if (r.credentialsUpdated) AppNotifier.showInfo(tr('The admin updated the WebDAV credentials.'));
      unawaited(_s.cleanupExpired().catchError((_) => 0));
    } on TrustException catch (e) {
      if (!mounted) return;
      setState(() => _problem = errorMessage(e));
      await _askFingerprint(e);
    } on NotMemberException catch (e) {
      if (mounted) {
        setState(() {
          _problem = errorMessage(e);
          _notMember = true;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _problem = tr('Sync failed: {reason}', {'reason': errorMessage(e)}));
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  Future<void> _askFingerprint(TrustException e) async {
    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('Group key changed')),
        content: SizedBox(
          width: 420,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(tr('The admin signing key of this group has changed. This happens when an admin '
                'is removed or demoted, but it can also mean someone tampered with the server.\n\n'
                'Ask your admin for the new fingerprint over a trusted channel (e-mail, or scan the QR '
                'code on their screen) and enter it here.')),
            const SizedBox(height: 12),
            SecureTextField(
              controller: controller,
              label: tr('Fingerprint from your admin'),
              maxLines: 3,
              suffix: canScanQr
                  ? ScanQrButton(controller: controller, title: tr('Scan group fingerprint'))
                  : null,
            ),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('Cancel'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, controller.text), child: Text(tr('Verify'))),
        ],
      ),
    );
    if (result == null || result.trim().isEmpty) return;
    final fp = parseFingerprint(result);
    if (fp == null) {
      AppNotifier.showError(tr('This is not a complete group fingerprint (64 characters 0-9 and A-F).'));
      return;
    }
    if (fp != e.fingerprint) {
      AppNotifier.showError(tr('The fingerprint does not match. The update was not accepted.'));
      return;
    }
    await _sync(fingerprint: fp);
  }

  Future<void> _download(Entry entry) async {
    final token = CancelToken();
    setState(() {
      _downloads[entry.id] = (tr('Preparing…'), null);
      _cancels[entry.id] = token;
    });
    try {
      final dir = await widget.app.downloadDir();
      final path = await widget.app
          .run((s) => s.download(entry, dir, cancel: token, onProgress: (template, args, progress) {
                if (mounted) setState(() => _downloads[entry.id] = (tr(template, args), progress));
              }));
      AppNotifier.showSuccess(tr('Saved to {path}', {'path': path}));
    } on CancelledException {
      AppNotifier.showInfo(tr('Download paused. Finished parts are kept, you can resume later.'));
    } catch (e) {
      final resumable = _s.partialParts(entry) != null;
      AppNotifier.showError(tr('Download failed: {reason}', {'reason': errorMessage(e)}) +
          (resumable ? '\n${tr('Finished parts are kept, you can resume later.')}' : ''));
    } finally {
      if (mounted) {
        setState(() {
          _downloads.remove(entry.id);
          _cancels.remove(entry.id);
        });
      }
    }
  }

  void _cancelDownload(Entry entry) => _cancels[entry.id]?.cancel();

  Future<void> _delete(Entry entry) async {
    final ok = await confirm(
        context,
        tr('Delete delivery?'),
        tr('The delivery is removed for all recipients. Where the hosting service allows '
            'it, the uploaded files are deleted too.'),
        action: tr('Delete'),
        danger: true);
    if (!ok || !mounted) return;
    try {
      await withProgress(context, tr('Deleting…'), () => widget.app.run((s) => s.deleteEntry(entry.id)));
      AppNotifier.showInfo(tr('Deleted'));
    } catch (e) {
      AppNotifier.showError(errorMessage(e));
    }
  }

  Future<void> _hide(Entry entry) async {
    await widget.app.run((s) => s.hide(entry));
    AppNotifier.showInfo(tr('Removed from your inbox'));
  }

  void _open(Widget page) => Navigator.of(context).push(MaterialPageRoute(builder: (_) => page)).then((_) {
        if (mounted) setState(() {});
      });

  @override
  Widget build(BuildContext context) {
    final s = widget.app.session;
    if (s == null) return const SizedBox.shrink();
    final palette = AppPalette.of(context);
    final inbox = s.isLoaded ? s.inbox : <Entry>[];
    final sent = s.isLoaded ? s.sent : <Entry>[];
    final newCount = inbox.where(s.isNew).length;

    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('RedCourier'),
            Text(widget.app.groupName ?? '',
                style: TextStyle(fontSize: 13, color: palette.fgDim, fontWeight: FontWeight.normal)),
          ]),
          actions: [
            IconButton(
              tooltip: tr('Sync'),
              onPressed: _syncing ? null : () => _sync(),
              icon: _syncing
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.sync),
            ),
            IconButton(
              tooltip: tr('Members'),
              icon: const Icon(Icons.group),
              onPressed: s.isLoaded ? () => _open(MembersScreen(app: widget.app)) : null,
            ),
            IconButton(
              tooltip: tr('Settings'),
              icon: const Icon(Icons.settings),
              onPressed: () => _open(SettingsScreen(app: widget.app, themeMode: widget.themeMode)),
            ),
          ],
          bottom: TabBar(tabs: [
            Tab(
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Text(tr('Inbox')),
                if (newCount > 0) ...[
                  const SizedBox(width: 6),
                  Tag(tr('{n} new', {'n': newCount}))
                ],
              ]),
            ),
            Tab(text: tr('Sent')),
          ]),
        ),
        floatingActionButton: s.isLoaded && !_notMember
            ? FloatingActionButton.extended(
                onPressed: () => _open(SendScreen(app: widget.app)),
                icon: const Icon(Icons.send),
                label: Text(tr('Send')),
              )
            : null,
        body: Column(children: [
          const UpdateBanner(),
          if (_problem != null)
            MaterialBanner(
              backgroundColor: palette.bgPanel,
              leading: Icon(Icons.warning_amber, color: palette.red),
              content: Text(_problem!),
              actions: [
                if (_notMember)
                  TextButton(
                    onPressed: () async {
                      final ok = await confirm(
                          context,
                          tr('Delete group "{name}" from this device?', {'name': widget.app.groupName}),
                          tr('This deletes your identity, keys and the local data of this group from '
                              'this device. Nothing on the server changes. To use the group again you '
                              'need a new join request. Downloaded files are not deleted.'),
                          action: tr('Delete'),
                          danger: true);
                      if (ok) await widget.app.deleteGroup();
                    },
                    child: Text(tr('Delete from this device')),
                  ),
                TextButton(onPressed: () => _sync(), child: Text(tr('Retry'))),
              ],
            ),
          if (s.isLoaded && s.rejectedEntries > 0)
            MaterialBanner(
              backgroundColor: palette.bgPanel,
              leading: Icon(Icons.gpp_maybe, color: palette.red),
              content:
                  Text(tr('Entries with an invalid signature were hidden: {n}', {'n': s.rejectedEntries})),
              actions: const [SizedBox.shrink()],
            ),
          Expanded(
            child: TabBarView(children: [
              _list(inbox,
                  empty: s.isLoaded ? tr('No deliveries for you yet.') : tr('Loading…'), sent: false),
              _list(sent, empty: tr('You have not sent anything yet.'), sent: true),
            ]),
          ),
        ]),
      ),
    );
  }

  Widget _list(List<Entry> entries, {required String empty, required bool sent}) {
    return RefreshIndicator(
      onRefresh: () => _sync(),
      child: entries.isEmpty
          ? ListView(children: [
              const SizedBox(height: 80),
              Center(child: Text(empty, style: TextStyle(color: AppPalette.of(context).fgDim))),
            ])
          : ListView.builder(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 96),
              itemCount: entries.length,
              itemBuilder: (_, i) => _EntryCard(
                entry: entries[i],
                session: _s,
                sentView: sent,
                downloads: _downloads,
                onDownload: _download,
                onCancel: _cancelDownload,
                onDelete: _delete,
                onHide: _hide,
              ),
            ),
    );
  }
}

class _EntryCard extends StatelessWidget {
  final Entry entry;
  final GroupSession session;
  final bool sentView;
  final Map<String, (String, double?)> downloads;
  final Future<void> Function(Entry) onDownload;
  final void Function(Entry) onCancel;
  final Future<void> Function(Entry) onDelete;
  final Future<void> Function(Entry) onHide;

  const _EntryCard({
    required this.entry,
    required this.session,
    required this.sentView,
    required this.downloads,
    required this.onDownload,
    required this.onCancel,
    required this.onDelete,
    required this.onHide,
  });

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final canDelete = entry.sentByMe || session.isAdmin;
    final title = sentView
        ? tr('To {names}', {'names': entry.to.map(session.nameOf).join(', ')})
        : tr('From {name}', {'name': entry.senderName});

    return Card(
      elevation: 0,
      color: palette.bgAlt,
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(
        side: BorderSide(color: !sentView && session.isNew(entry) ? palette.accent : palette.border),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
              child: Text(title,
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                  overflow: TextOverflow.ellipsis),
            ),
            if (!sentView && session.isNew(entry)) Tag(tr('new')),
            PopupMenuButton<String>(
              onSelected: (v) {
                if (v == 'delete') onDelete(entry);
                if (v == 'hide') onHide(entry);
              },
              itemBuilder: (_) => [
                if (!sentView) PopupMenuItem(value: 'hide', child: Text(tr('Remove from my inbox'))),
                if (canDelete) PopupMenuItem(value: 'delete', child: Text(tr('Delete for everyone'))),
              ],
            ),
          ]),
          Text(
            '${formatDateTime(entry.created)} · ${formatSize(entry.totalSize)} · ${formatRemaining(entry.expires)}',
            style: TextStyle(color: palette.fgDim, fontSize: 13),
          ),
          if (entry.note.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(entry.note),
          ],
          const SizedBox(height: 8),
          for (final f in entry.files)
            Padding(
              padding: const EdgeInsets.only(right: 8, bottom: 4),
              child: Row(children: [
                Icon(Icons.insert_drive_file_outlined, size: 20, color: palette.fgDim),
                const SizedBox(width: 8),
                Expanded(child: Text(f.name, overflow: TextOverflow.ellipsis)),
                const SizedBox(width: 8),
                Text(formatSize(f.size), style: TextStyle(color: palette.fgDim, fontSize: 13)),
              ]),
            ),
          if (downloads[entry.id] case final (String, double?) state) ...[
            const SizedBox(height: 8),
            Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(state.$1, style: TextStyle(color: palette.fgDim, fontSize: 13)),
                  const SizedBox(height: 4),
                  LinearProgressIndicator(value: state.$2),
                ]),
              ),
              IconButton(
                tooltip: tr('Stop download'),
                icon: const Icon(Icons.stop_circle_outlined),
                onPressed: () => onCancel(entry),
              ),
            ]),
          ] else if (!sentView) ...[
            const SizedBox(height: 8),
            if (session.partialParts(entry) case final int done)
              FilledButton.tonalIcon(
                onPressed: () => onDownload(entry),
                icon: const Icon(Icons.play_arrow),
                label: Text(tr(
                    'Resume download ({done}/{n} parts)', {'done': done, 'n': entry.payload.parts.length})),
              )
            else
              FilledButton.tonalIcon(
                onPressed: () => onDownload(entry),
                icon: const Icon(Icons.download),
                label: Text(entry.files.length == 1
                    ? tr('Download')
                    : tr('Download {n} files', {'n': entry.files.length})),
              ),
          ],
        ]),
      ),
    );
  }
}
