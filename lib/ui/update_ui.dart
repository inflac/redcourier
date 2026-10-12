import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;

import '../core/crypto_util.dart';
import '../core/tor.dart';
import '../core/updater.dart';
import '../i18n.dart';
import '../prefs.dart';
import '../theme.dart';

/// Update preferences, stored like CalSec's: off by default.
class UpdatePrefs {
  static const _enabledKey = 'updates_enabled';
  static const _modeKey = 'update_mode'; // "auto" | "notify"
  static const _channelKey = 'update_channel'; // "official" | URL

  static bool get enabled => Prefs.getBool(_enabledKey) ?? false;
  static String get mode => Prefs.getString(_modeKey) ?? 'notify';
  static String get channel => Prefs.getString(_channelKey) ?? 'official';

  static Future<void> setEnabled(bool v) => Prefs.set(_enabledKey, v);
  static Future<void> setMode(String v) => Prefs.set(_modeKey, v);
  static Future<void> setChannel(String v) => Prefs.set(_channelKey, v.trim().isEmpty ? 'official' : v.trim());
}

/// Self-update is only possible for versions installed by our installers
/// (Tails installer, Windows setup) and for APKs from GitHub.
/// (Not final so tests can point it at a folder.)
String? updateInstallDir = installedDir();

/// Android's package installer, reached through MainActivity.kt.
class AndroidInstaller {
  static const _channel = MethodChannel('redcourier/updates');
  const AndroidInstaller();

  Future<String?> installerPackage() => _channel.invokeMethod<String>('installerPackage');
  Future<bool> canInstall() async => await _channel.invokeMethod<bool>('canInstall') ?? false;
  Future<void> openInstallSettings() => _channel.invokeMethod<void>('openInstallSettings');
  Future<void> install(File apk) => _channel.invokeMethod<void>('installApk', {'path': apk.path});
}

/// Replaced in tests.
AndroidInstaller androidInstaller = const AndroidInstaller();

/// Android: updates are offered only for APKs from GitHub, not for F-Droid
/// or store installs. Called once before the app starts.
Future<void> initUpdates() async {
  if (!Platform.isAndroid) return;
  try {
    final installer = await androidInstaller.installerPackage();
    final info = await PackageInfo.fromPlatform();
    updateInstallDir = selfUpdateAllowed(installer, info.packageName) ? Directory.systemTemp.path : null;
  } catch (_) {
    updateInstallDir = null;
  }
}
bool get updatesAvailable => updateInstallDir != null;

/// An update found in "notify" mode, shown as a banner.
final pendingUpdate = ValueNotifier<UpdateInfo?>(null);

/// Creates the updater; tests replace it to talk to a local server.
Future<Updater> Function() updaterFactory = _updater;

Future<Updater> _updater() async {
  final info = await PackageInfo.fromPlatform();
  return Updater(
    currentVersion: info.version,
    channel: UpdatePrefs.channel,
    clientFactory: () => TorNetwork.createHttpClient(isolation: 'updates'),
  );
}

/// Called once after start, like CalSec's startup check.
Future<void> runStartupUpdateCheck(NavigatorState? navigator) async {
  if (!updatesAvailable) return;
  await Updater.cleanupPrevious(updateInstallDir!);
  if (!UpdatePrefs.enabled) return;
  if (UpdatePrefs.mode == 'auto') {
    final context = navigator?.context;
    if (context != null && context.mounted) {
      await showUpdateDialog(context, automatic: true);
    }
    return;
  }
  try {
    pendingUpdate.value = await (await updaterFactory()).check();
  } catch (_) {
    // Notify mode stays silent on network errors.
  }
}

Future<void> showUpdateDialog(BuildContext context, {UpdateInfo? info, bool automatic = false}) =>
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => UpdateDialog(info: info, automatic: automatic),
    );

/// Checks (if [info] is null), downloads, verifies, installs and restarts.
class UpdateDialog extends StatefulWidget {
  final UpdateInfo? info;
  final bool automatic;
  const UpdateDialog({super.key, this.info, this.automatic = false});

  @override
  State<UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<UpdateDialog> {
  String _status = tr('Checking for updates…');
  double? _progress;
  bool _done = false;
  bool _working = true;
  UpdateInfo? _info;

  @override
  void initState() {
    super.initState();
    _info = widget.info;
    _run();
  }

  void _set(String status, {double? progress}) {
    if (!mounted) return;
    setState(() {
      _status = status;
      _progress = progress;
    });
  }

  Future<void> _run() async {
    final installDir = updateInstallDir;
    Directory? work;
    try {
      if (installDir == null) throw UpdateException('Updates are only available for installed versions.');
      final updater = await updaterFactory();
      var info = _info;
      if (info == null) {
        info = await updater.check();
        if (info == null) {
          _set(tr('RedCourier is up to date.'));
          if (mounted) {
            setState(() {
              _working = false;
              _done = true;
            });
          }
          if (widget.automatic) {
            await Future<void>.delayed(const Duration(seconds: 1));
            if (mounted) Navigator.pop(context);
          }
          return;
        }
        _info = info;
      }
      final version = info.version;
      if (updater.platform == UpdatePlatform.android && !await androidInstaller.canInstall()) {
        await androidInstaller.openInstallSettings();
        throw UpdateException('Allow RedCourier to install apps (the settings page just opened), then try again.');
      }
      work = Directory(p.join(Directory.systemTemp.path, 'redcourier-update-${randomHex(6)}'));
      _set(tr('Downloading update {version}…', {'version': version}), progress: 0);
      final file = await updater.download(info, work,
          onProgress: (v) => _set(tr('Downloading update {version}…', {'version': version}), progress: v));
      _set(tr('Signature valid. Installing…'));
      if (updater.platform == UpdatePlatform.android) {
        // Android asks the user; the app keeps running until then.
        await androidInstaller.install(file);
        _set(tr('Confirm the installation in the Android dialog, then open RedCourier again.'));
        if (mounted) {
          setState(() {
            _working = false;
            _done = true;
          });
        }
        return;
      }
      if (updater.platform == UpdatePlatform.windows) {
        // The installer replaces the program and starts it again.
        await Future<void>.delayed(const Duration(milliseconds: 800));
        await Updater.runWindowsSetup(file);
      }
      await Updater.install(installDir, file);
      _set(tr('Update installed. Restarting…'));
      await Future<void>.delayed(const Duration(milliseconds: 800));
      await Updater.restart(installDir);
    } catch (e) {
      _set(tr('Update failed: {reason}', {'reason': errorMessage(e)}));
      if (mounted) setState(() => _working = false);
    } finally {
      if (work != null && await work.exists()) {
        try {
          await work.delete(recursive: true);
        } catch (_) {}
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_working,
      child: AlertDialog(
        title: Text(_info == null ? tr('Updates') : tr('Update {version}', {'version': _info!.version})),
        content: SizedBox(
          width: 380,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(_status),
            if (_working) ...[
              const SizedBox(height: 16),
              LinearProgressIndicator(value: _progress),
            ],
          ]),
        ),
        actions: [
          if (!_working)
            FilledButton(
              onPressed: () => Navigator.pop(context),
              child: Text(_done ? tr('OK') : tr('Close')),
            ),
        ],
      ),
    );
  }
}

/// Banner for an update found in notify mode (CalSec: toolbar button).
class UpdateBanner extends StatelessWidget {
  const UpdateBanner({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<UpdateInfo?>(
      valueListenable: pendingUpdate,
      builder: (context, info, _) {
        if (info == null) return const SizedBox.shrink();
        final palette = AppPalette.of(context);
        return MaterialBanner(
          backgroundColor: palette.bgPanel,
          leading: Icon(Icons.system_update_alt, color: palette.accent),
          content: Text(tr('Update {version} is available.', {'version': info.version})),
          actions: [
            TextButton(onPressed: () => pendingUpdate.value = null, child: Text(tr('Later'))),
            FilledButton(
              onPressed: () => showUpdateDialog(context, info: info),
              child: Text(tr('Install now')),
            ),
          ],
        );
      },
    );
  }
}

/// Settings section (only shown for installed versions).
class UpdateSettingsCard extends StatefulWidget {
  final Widget Function({required String title, required IconData icon, required List<Widget> children}) card;
  const UpdateSettingsCard({super.key, required this.card});

  @override
  State<UpdateSettingsCard> createState() => _UpdateSettingsCardState();
}

class _UpdateSettingsCardState extends State<UpdateSettingsCard> {
  late final _custom =
      TextEditingController(text: UpdatePrefs.channel == 'official' ? '' : UpdatePrefs.channel);

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final enabled = UpdatePrefs.enabled;
    final official = UpdatePrefs.channel == 'official';
    return widget.card(title: tr('Updates'), icon: Icons.system_update_alt, children: [
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(tr('Check for updates at start')),
        subtitle: Text(tr('Downloads go through Tor and are only installed with a valid release signature.'),
            style: TextStyle(color: palette.fgDim)),
        value: enabled,
        onChanged: (v) async {
          await UpdatePrefs.setEnabled(v);
          setState(() {});
        },
      ),
      if (enabled) ...[
        const SizedBox(height: 8),
        SegmentedButton<String>(
          segments: [
            ButtonSegment(value: 'auto', label: Text(tr('Install automatically'))),
            ButtonSegment(value: 'notify', label: Text(tr('Only notify'))),
          ],
          selected: {UpdatePrefs.mode},
          onSelectionChanged: (v) async {
            await UpdatePrefs.setMode(v.first);
            setState(() {});
          },
        ),
        const SizedBox(height: 12),
        RadioGroup<bool>(
          groupValue: official,
          onChanged: (v) async {
            // An empty URL would count as "official" again, so start with https://.
            if (v != true && _custom.text.trim().isEmpty) _custom.text = 'https://';
            await UpdatePrefs.setChannel(v == true ? 'official' : _custom.text);
            setState(() {});
          },
          child: Column(children: [
            RadioListTile<bool>(
              contentPadding: EdgeInsets.zero,
              value: true,
              title: Text(tr('Official releases (GitHub)')),
            ),
            RadioListTile<bool>(
              contentPadding: EdgeInsets.zero,
              value: false,
              title: Text(tr('Custom channel')),
            ),
          ]),
        ),
        if (!official)
          TextField(
            controller: _custom,
            decoration: InputDecoration(
              labelText: tr('Channel URL (GitHub-compatible release JSON)'),
              hintText: 'https://…/releases/latest',
            ),
            onChanged: (v) => UpdatePrefs.setChannel(v.trim().isEmpty ? 'https://' : v),
          ),
      ],
      const SizedBox(height: 8),
      OutlinedButton.icon(
        onPressed: () => showUpdateDialog(context),
        icon: const Icon(Icons.refresh),
        label: Text(tr('Check now')),
      ),
    ]);
  }
}
