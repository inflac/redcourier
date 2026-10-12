import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../app_controller.dart';
import '../app_notifier.dart';
import '../core/tor.dart';
import '../i18n.dart';
import '../notifications.dart';
import '../prefs.dart';
import '../theme.dart';
import 'update_ui.dart';
import 'webdav_dialog.dart';
import 'widgets.dart';

const themePrefKey = 'theme_mode';
const torPortPrefKey = 'tor_port';

Future<ThemeMode> loadThemeMode() async {
  return ThemeMode.values
      .firstWhere((m) => m.name == Prefs.getString(themePrefKey), orElse: () => ThemeMode.system);
}

Future<void> loadTorSettings() async {
  TorNetwork.configuredPort = Prefs.getInt(torPortPrefKey);
}

class SettingsScreen extends StatefulWidget {
  final AppController app;
  final ValueNotifier<ThemeMode> themeMode;
  const SettingsScreen({super.key, required this.app, required this.themeMode});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  String _version = '';
  late final _torPort = TextEditingController(text: TorNetwork.configuredPort?.toString() ?? '');
  String? _torStatus;
  bool _torChecking = false;

  @override
  void initState() {
    super.initState();
    PackageInfo.fromPlatform().then((i) {
      if (mounted) setState(() => _version = '${i.version}+${i.buildNumber}');
    });
  }

  Future<void> _setTheme(ThemeMode mode) async {
    widget.themeMode.value = mode;
    await Prefs.set(themePrefKey, mode.name);
    setState(() {});
  }

  Future<void> _setLanguage(String code) async {
    await I18n.set(code);
    if (mounted) setState(() {});
  }

  Future<void> _setTorPort(bool auto) async {
    if (auto) {
      TorNetwork.configuredPort = null;
      await Prefs.set(torPortPrefKey, null);
    } else {
      final port = int.tryParse(_torPort.text.trim());
      if (port == null || port <= 0 || port > 65535) {
        AppNotifier.showError(tr('Please enter a port between 1 and 65535.'));
        return;
      }
      TorNetwork.configuredPort = port;
      await Prefs.set(torPortPrefKey, port);
    }
    setState(() => _torStatus = null);
  }

  Future<void> _checkTor() async {
    setState(() {
      _torChecking = true;
      _torStatus = null;
    });
    try {
      final ip = await TorNetwork.check();
      _torStatus = TorNetwork.underTorsocks
          ? tr('Connected through Tor via torsocks (exit {ip}).', {'ip': ip})
          : tr('Connected through Tor (port {port}, exit {ip}).', {'port': TorNetwork.activePort, 'ip': ip});
    } catch (e) {
      _torStatus = errorMessage(e);
    } finally {
      if (mounted) setState(() => _torChecking = false);
    }
  }

  Future<void> _changeWebDav() async {
    if (await showWebDavAccessDialog(context, widget.app)) {
      AppNotifier.showSuccess(tr('WebDAV access checked and saved.'));
      if (mounted) setState(() {});
    }
  }

  Future<void> _clearDownloads() async {
    final ok = await confirm(
        context,
        tr('Delete downloaded deliveries?'),
        tr('This deletes the encrypted copies of all downloaded deliveries of this group from this device. '
            'Files you saved to a folder are not touched.'),
        action: tr('Delete'),
        danger: true);
    if (!ok) return;
    await widget.app.run((s) => s.deleteAllDownloads());
    AppNotifier.showInfo(tr('Downloads deleted.'));
  }

  Future<void> _deleteGroup() async {
    final ok = await confirm(
        context,
        tr('Delete group "{name}" from this device?', {'name': widget.app.groupName}),
        tr('This deletes your identity, keys and the local data of this group from this device. '
            'Nothing on the server changes. To use the group again you need a new join request. '
            'Downloaded files are not deleted.'),
        action: tr('Delete'),
        danger: true);
    if (!ok) return;
    if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
    await widget.app.deleteGroup();
  }

  void _switchGroup() {
    Navigator.of(context).popUntil((r) => r.isFirst);
    widget.app.lock();
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final s = widget.app.session;
    final autoPort = TorNetwork.configuredPort == null;

    return Scaffold(
      appBar: AppBar(title: Text(tr('Settings'))),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: ListView(padding: const EdgeInsets.all(16), children: [
            SectionCard(title: tr('Appearance'), icon: Icons.palette_outlined, children: [
              SegmentedButton<ThemeMode>(
                segments: [
                  ButtonSegment(value: ThemeMode.system, label: Text(tr('System'))),
                  ButtonSegment(value: ThemeMode.light, label: Text(tr('Light'))),
                  ButtonSegment(value: ThemeMode.dark, label: Text(tr('Dark'))),
                ],
                selected: {widget.themeMode.value},
                onSelectionChanged: (v) => _setTheme(v.first),
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                initialValue: I18n.language.value,
                decoration: InputDecoration(labelText: tr('Language')),
                items: [
                  for (final e in I18n.supported.entries)
                    DropdownMenuItem(value: e.key, child: Text(e.value)),
                ],
                onChanged: (v) {
                  if (v != null) _setLanguage(v);
                },
              ),
            ]),
            const SizedBox(height: 16),
            SectionCard(title: tr('Notifications'), icon: Icons.notifications_outlined, children: [
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(tr('Notify about new deliveries')),
                subtitle: Text(
                    tr(
                        'While a group is unlocked, RedCourier syncs every {n} minutes and shows a '
                        'notification without sender or group name. When the app is closed or locked, '
                        'nothing is checked.',
                        {'n': syncIntervalMinutes}),
                    style: TextStyle(color: palette.fgDim)),
                value: Notifications.enabled,
                onChanged: (v) async {
                  await Notifications.setEnabled(v);
                  if (mounted) setState(() {});
                },
              ),
            ]),
            const SizedBox(height: 16),
            if (updatesAvailable) ...[
              UpdateSettingsCard(
                card: ({required title, required icon, required children}) =>
                    SectionCard(title: title, icon: icon, children: children),
              ),
              const SizedBox(height: 16),
            ],
            SectionCard(title: tr('Tor'), icon: Icons.security, children: [
              Text(
                tr('All connections go through Tor. Without Tor, RedCourier does not connect at all. '
                    'Tails starts Tor automatically. On Windows, start Tor Browser or the Tor '
                    'service; on Android, start Orbot.'),
                style: TextStyle(color: palette.fgDim),
              ),
              const SizedBox(height: 8),
              if (TorNetwork.underTorsocks)
                Text(
                    tr('Started with torsocks: torsocks routes all connections into Tor. All groups '
                        'share its circuits. Start RedCourier without torsocks to get separate '
                        'circuits per group.'),
                    style: TextStyle(color: palette.fgDim))
              else
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(tr('Find Tor automatically')),
                  subtitle: Text(tr('Tries port 9050 (Tails, Tor service, Orbot) and 9150 (Tor Browser).'),
                      style: TextStyle(color: palette.fgDim)),
                  value: autoPort,
                  onChanged: (v) {
                    if (v) {
                      _setTorPort(true);
                    } else {
                      _torPort.text = '9050';
                      _setTorPort(false);
                    }
                  },
                ),
              if (!autoPort && !TorNetwork.underTorsocks) ...[
                TextField(
                  controller: _torPort,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(labelText: tr('Tor SOCKS port on 127.0.0.1')),
                  onSubmitted: (_) => _setTorPort(false),
                  onEditingComplete: () => _setTorPort(false),
                ),
                const SizedBox(height: 8),
              ],
              OutlinedButton.icon(
                onPressed: _torChecking ? null : _checkTor,
                icon: _torChecking
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.verified_user_outlined),
                label: Text(tr('Test Tor connection')),
              ),
              if (_torStatus != null) ...[
                const SizedBox(height: 8),
                Text(_torStatus!),
              ],
            ]),
            const SizedBox(height: 16),
            SectionCard(
                title: tr('Group {name}', {'name': widget.app.groupName}),
                icon: Icons.group_outlined,
                children: [
                  Wrap(spacing: 8, runSpacing: 8, children: [
                    OutlinedButton.icon(
                      onPressed: _switchGroup,
                      icon: const Icon(Icons.swap_horiz),
                      label: Text(tr('Switch group')),
                    ),
                    OutlinedButton.icon(
                      onPressed: () {
                        widget.app.lock();
                        Navigator.of(context).popUntil((r) => r.isFirst);
                      },
                      icon: const Icon(Icons.lock),
                      label: Text(tr('Lock now')),
                    ),
                  ]),
                  if (s != null) ...[
                    const SizedBox(height: 16),
                    Text(tr('WebDAV folder'), style: TextStyle(color: palette.fgDim)),
                    SelectableText(s.local.webdav.url),
                    const SizedBox(height: 4),
                    Text(tr('Username: {name}', {'name': s.local.webdav.username}),
                        style: TextStyle(color: palette.fgDim)),
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      onPressed: _changeWebDav,
                      icon: const Icon(Icons.key),
                      label: Text(tr('Change WebDAV access')),
                    ),
                    const SizedBox(height: 8),
                  ],
                  OutlinedButton.icon(
                    onPressed: _clearDownloads,
                    icon: const Icon(Icons.folder_delete_outlined),
                    label: Text(tr('Delete downloaded deliveries')),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(foregroundColor: palette.red),
                    onPressed: _deleteGroup,
                    icon: const Icon(Icons.delete_forever),
                    label: Text(tr('Delete this group from this device')),
                  ),
                ]),
            const SizedBox(height: 24),
            Center(
              child: Text(tr('RedCourier {version}', {'version': _version}),
                  style: TextStyle(color: palette.fgDim)),
            ),
          ]),
        ),
      ),
    );
  }
}
