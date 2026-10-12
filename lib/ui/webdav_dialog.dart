import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../core/crypto_util.dart';
import '../core/group.dart';
import '../core/identity.dart';
import '../i18n.dart';
import '../theme.dart';
import 'qr_scan.dart';
import 'widgets.dart';

/// Changes the WebDAV access of the unlocked group on this device. The new
/// data is only saved after the app reached the folder and found this very
/// group there, so a typo cannot lock the group out. Returns true if saved.
Future<bool> showWebDavAccessDialog(BuildContext context, AppController app) async {
  final saved = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _WebDavAccessDialog(app: app),
  );
  return saved ?? false;
}

class _WebDavAccessDialog extends StatefulWidget {
  final AppController app;
  const _WebDavAccessDialog({required this.app});

  @override
  State<_WebDavAccessDialog> createState() => _WebDavAccessDialogState();
}

class _WebDavAccessDialogState extends State<_WebDavAccessDialog> {
  late final WebDavConfig _current = widget.app.session!.local.webdav;
  late final _url = TextEditingController(text: _current.url);
  late final _user = TextEditingController(text: _current.username);
  final _pass = TextEditingController();
  final _invite = TextEditingController();
  final _fingerprint = TextEditingController();
  bool _askFingerprint = false;
  bool _busy = false;
  String? _error;

  /// The entered data; an invite, if pasted, replaces the fields.
  WebDavConfig? _config() {
    if (_invite.text.trim().isNotEmpty) return Invite.parse(_invite.text).webdav;
    final urlError = WebDavConfig.validateUrl(_url.text);
    if (urlError != null) throw FormatException(urlError);
    if (_user.text.trim().isEmpty) throw const FormatException('Please enter the WebDAV username.');
    // An empty password field keeps the current password.
    final pass = _pass.text.isEmpty ? _current.password : _pass.text;
    return WebDavConfig(_url.text, _user.text.trim(), pass);
  }

  Future<void> _save() async {
    final WebDavConfig? cfg;
    try {
      cfg = _config();
    } on FormatException catch (e) {
      setState(() => _error = errorMessage(e));
      return;
    }
    if (cfg == null) return;
    final fp = _askFingerprint ? parseFingerprint(_fingerprint.text) : null;
    if (_askFingerprint && fp == null) {
      setState(() => _error = tr('This is not a complete group fingerprint (64 characters 0-9 and A-F).'));
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.app.updateWebDav(cfg, confirmedFingerprint: fp);
      if (mounted) Navigator.pop(context, true);
    } on TrustException catch (e) {
      if (mounted) {
        setState(() {
          _askFingerprint = true;
          _error = tr('The group in this folder has a different admin key than this device knows (an admin '
              'was changed, or this is another group). Enter the current group fingerprint from your admin. '
              'Found: {fp}', {'fp': formatFingerprint(e.fingerprint)});
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = errorMessage(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return AlertDialog(
      title: Text(tr('WebDAV access')),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(
                tr('Used only on this device. Enter new access data here when your admin changed the app '
                    'password or moved the folder. It is checked before it is saved.'),
                style: TextStyle(color: palette.fgDim)),
            const SizedBox(height: 12),
            SecureTextField(controller: _url, label: tr('WebDAV folder URL')),
            const SizedBox(height: 12),
            SecureTextField(controller: _user, label: tr('WebDAV username')),
            const SizedBox(height: 12),
            SecureTextField(
                controller: _pass,
                label: tr('WebDAV app password'),
                hint: tr('Leave empty to keep the current one'),
                obscure: true),
            const SizedBox(height: 16),
            Text(tr('Or paste a new invite from your admin:'), style: TextStyle(color: palette.fgDim)),
            const SizedBox(height: 8),
            SecureTextField(
              controller: _invite,
              label: tr('Invite (RCINVITE2:…)'),
              maxLines: 2,
              suffix: canScanQr ? ScanQrButton(controller: _invite, title: tr('Scan invite')) : null,
            ),
            if (_askFingerprint) ...[
              const SizedBox(height: 12),
              SecureTextField(
                controller: _fingerprint,
                label: tr('Group fingerprint'),
                maxLines: 2,
                suffix: canScanQr
                    ? ScanQrButton(controller: _fingerprint, title: tr('Scan group fingerprint'))
                    : null,
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: TextStyle(color: palette.red)),
            ],
            if (_busy) ...[
              const SizedBox(height: 12),
              Text(tr('Checking the folder through Tor…'), style: TextStyle(color: palette.fgDim)),
              const SizedBox(height: 8),
              const LinearProgressIndicator(),
            ],
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: _busy ? null : () => Navigator.pop(context, false), child: Text(tr('Cancel'))),
        FilledButton(onPressed: _busy ? null : _save, child: Text(tr('Check and save'))),
      ],
    );
  }
}
