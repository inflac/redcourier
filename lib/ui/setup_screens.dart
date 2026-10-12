import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../core/crypto_util.dart';
import '../core/group.dart';
import '../core/identity.dart';
import '../core/vault.dart';
import '../i18n.dart';
import '../theme.dart';
import 'qr_scan.dart';
import 'settings_screen.dart';
import 'update_ui.dart';
import 'widgets.dart';

/// Centered, width-limited page used by all setup screens.
class _SetupPage extends StatelessWidget {
  final AppController app;
  final String title;
  final List<Widget> children;
  final List<Widget> actions;
  final Widget? leading;
  const _SetupPage(
      {required this.app,
      required this.title,
      required this.children,
      this.actions = const [],
      this.leading});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        leading: leading,
        actions: [
          ...actions,
          // App settings (language, Tor, updates) work without a group, so the
          // app can be updated before joining one.
          IconButton(
            tooltip: tr('Settings'),
            icon: const Icon(Icons.settings),
            onPressed: () => Navigator.of(context)
                .push(MaterialPageRoute(builder: (_) => SettingsScreen(app: app, themeMode: appThemeMode))),
          ),
          const LanguageButton(),
        ],
      ),
      body: SafeArea(
        child: Column(children: [
          const UpdateBanner(),
          Expanded(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: ListView(padding: const EdgeInsets.all(16), children: children),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}

class _Intro extends StatelessWidget {
  final String text;
  const _Intro(this.text);
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: Text(text, style: TextStyle(color: AppPalette.of(context).fgDim, height: 1.4)),
      );
}

class _ErrorText extends StatelessWidget {
  final String? text;
  const _ErrorText(this.text);
  @override
  Widget build(BuildContext context) => text == null
      ? const SizedBox.shrink()
      : Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Text(text!, style: TextStyle(color: AppPalette.of(context).red)),
        );
}

Widget _busyIcon(bool busy, IconData icon) => busy
    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
    : Icon(icon);

// ── Add a group with a new identity ──────────────────────────────────────────

class WelcomeScreen extends StatefulWidget {
  final AppController app;
  const WelcomeScreen({super.key, required this.app});
  @override
  State<WelcomeScreen> createState() => _WelcomeScreenState();
}

enum _Start { join, create }

class _WelcomeScreenState extends State<WelcomeScreen> {
  final _name = TextEditingController();
  final _identifier = TextEditingController();
  final _pw = TextEditingController();
  final _pw2 = TextEditingController();
  final _url = TextEditingController();
  final _user = TextEditingController();
  final _pass = TextEditingController();
  _Start? _start;
  String? _error;
  bool _busy = false;

  bool get _isAdditional => widget.app.addingGroup && widget.app.groups.isNotEmpty;

  String? _validate() {
    final name = widget.app.validateGroupName(_name.text) ?? validateIdentifier(_identifier.text);
    if (name != null) return tr(name);
    if (_pw.text.length < Vault.minPasswordLength) {
      return tr('The password needs at least {n} characters.', {'n': Vault.minPasswordLength});
    }
    if (_pw.text != _pw2.text) return tr('The passwords do not match.');
    if (_start == _Start.create) {
      final url = WebDavConfig.validateUrl(_url.text);
      if (url != null) return tr(url);
      if (_user.text.trim().isEmpty) return tr('Please enter the WebDAV username.');
    }
    return null;
  }

  Future<void> _submit() async {
    final error = _validate();
    setState(() => _error = error);
    if (error != null) return;
    setState(() => _busy = true);
    final app = widget.app;
    final create = _start == _Start.create;
    final cfg = create ? WebDavConfig(_url.text, _user.text.trim(), _pass.text) : null;
    try {
      await app.addGroup(_name.text, _identifier.text, _pw.text);
    } catch (e) {
      if (mounted) setState(() => _error = errorMessage(e));
      if (mounted) setState(() => _busy = false);
      return;
    }
    // The group exists locally now; the app shows the next screen. Creating
    // the shared sync.json happens right away, errors are shown there.
    if (cfg != null) {
      try {
        await app.createGroup(cfg);
      } catch (_) {
        // Shown on the group setup screen, which keeps the entered data.
      }
    }
  }

  Widget _choice(IconData icon, String title, String text, _Start start) {
    final palette = AppPalette.of(context);
    return Card(
      elevation: 0,
      color: palette.bgAlt,
      shape: RoundedRectangleBorder(
        side: BorderSide(color: palette.border),
        borderRadius: BorderRadius.circular(12),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => setState(() {
          _start = start;
          _error = null;
        }),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(children: [
            Icon(icon, size: 32, color: palette.accent),
            const SizedBox(width: 16),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                Text(text, style: TextStyle(color: palette.fgDim)),
              ]),
            ),
            Icon(Icons.chevron_right, color: palette.fgDim),
          ]),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final title = _isAdditional ? tr('Add group') : tr('Welcome to RedCourier');
    final leading = _isAdditional
        ? IconButton(
            tooltip: tr('Cancel'),
            icon: const Icon(Icons.close),
            onPressed: _busy ? null : widget.app.cancelAddingGroup)
        : null;

    if (_start == null) {
      return _SetupPage(app: widget.app, title: title, leading: leading, children: [
        _Intro(_isAdditional
            ? tr('Every group on this device has its own identity, password and sync file. '
                'Members of one group never see your other groups.')
            : tr('RedCourier sends end-to-end encrypted files to the members of your group. '
                'The files are stored encrypted at file sharing services, the group itself in a '
                'shared WebDAV folder, for example on Nextcloud. All traffic goes through Tor.')),
        _choice(Icons.login, tr('Join a group'),
            tr('An admin adds you. You send them your join request and get an invite back.'), _Start.join),
        const SizedBox(height: 12),
        _choice(
            Icons.add_circle_outline,
            tr('Start a new group'),
            tr('You become the admin. You need an empty WebDAV folder, for example on Nextcloud.'),
            _Start.create),
      ]);
    }

    final create = _start == _Start.create;
    return _SetupPage(
      app: widget.app,
      title: create ? tr('Start a new group') : tr('Join a group'),
      leading: IconButton(
        tooltip: tr('Back'),
        icon: const Icon(Icons.arrow_back),
        onPressed: _busy ? null : () => setState(() => _start = null),
      ),
      children: [
        _Intro(tr('Your identifier is how other members find you when they send files. Your '
            'private keys never leave this device and are protected by the password below. '
            'The group name is only shown on this device.')),
        SecureTextField(
            controller: _name,
            label: tr('Group name (only on this device)'),
            hint: tr('e.g. Work or Family')),
        Padding(
          padding: const EdgeInsets.only(top: 4, left: 12),
          child: Text(
              tr('Stored unencrypted on this device (folder name, group list). Choose a name that '
                  'reveals nothing sensitive.'),
              style: TextStyle(color: AppPalette.of(context).fgDim, fontSize: 12)),
        ),
        const SizedBox(height: 12),
        SecureTextField(controller: _identifier, label: tr('Identifier (name or handle)')),
        const SizedBox(height: 12),
        SecureTextField(controller: _pw, label: tr('Password for this group'), obscure: true),
        const SizedBox(height: 12),
        SecureTextField(
            controller: _pw2,
            label: tr('Repeat password'),
            obscure: true,
            onSubmitted: create ? null : (_) => _submit()),
        if (create) ...[
          const SizedBox(height: 20),
          _Intro(tr('Use a WebDAV folder, for example a Nextcloud folder. Use an app password, '
              'not your main password.\nExample URL: https://cloud.example.com/remote.php/dav/files/USER/redcourier/')),
          SecureTextField(controller: _url, label: tr('WebDAV folder URL')),
          const SizedBox(height: 12),
          SecureTextField(controller: _user, label: tr('WebDAV username')),
          const SizedBox(height: 12),
          SecureTextField(
              controller: _pass,
              label: tr('WebDAV app password'),
              obscure: true,
              onSubmitted: (_) => _submit()),
        ],
        _ErrorText(_error),
        const SizedBox(height: 20),
        ElevatedButton.icon(
          onPressed: _busy ? null : _submit,
          icon: _busyIcon(_busy, create ? Icons.cloud_upload_outlined : Icons.key),
          label: Text(_busy ? tr('Creating keys…') : (create ? tr('Create group') : tr('Continue'))),
        ),
      ],
    );
  }
}

// ── Unlock a group ───────────────────────────────────────────────────────────

class UnlockScreen extends StatefulWidget {
  final AppController app;
  const UnlockScreen({super.key, required this.app});
  @override
  State<UnlockScreen> createState() => _UnlockScreenState();
}

class _UnlockScreenState extends State<UnlockScreen> {
  final _pw = TextEditingController();
  String? _error;
  bool _busy = false;

  AppController get _app => widget.app;

  Future<void> _unlock() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _app.unlock(_pw.text);
    } on WrongPasswordException {
      if (mounted) {
        setState(() => _error = tr('Wrong password.'));
        _pw.clear();
      }
    } catch (e) {
      if (mounted) setState(() => _error = errorMessage(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete() async {
    final ok = await confirm(
      context,
      tr('Delete group "{name}" from this device?', {'name': _app.groupName}),
      tr('This deletes your identity, keys and the local data of this group from this device. '
          'Nothing on the server changes. To use the group again you need a new join request. '
          'Files you saved to a folder are not deleted.'),
      action: tr('Delete'),
      danger: true,
    );
    if (ok) await _app.deleteGroup();
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final current = _app.groupName;
    return _SetupPage(app: _app, title: 'RedCourier', children: [
      const SizedBox(height: 16),
      Icon(Icons.lock_outline, size: 56, color: palette.accent),
      const SizedBox(height: 24),
      Row(children: [
        Expanded(
          child: DropdownButtonFormField<String>(
            key: ValueKey(current),
            initialValue: current,
            decoration: InputDecoration(labelText: tr('Group')),
            items: [for (final g in _app.groups) DropdownMenuItem(value: g, child: Text(g))],
            onChanged: _busy
                ? null
                : (v) {
                    if (v != null && v != current) {
                      _pw.clear();
                      setState(() => _error = null);
                      _app.selectGroup(v);
                    }
                  },
          ),
        ),
        const SizedBox(width: 8),
        IconButton(
          tooltip: tr('Add group'),
          icon: const Icon(Icons.group_add),
          onPressed: _busy ? null : _app.startAddingGroup,
        ),
      ]),
      CheckboxListTile(
        contentPadding: EdgeInsets.zero,
        controlAffinity: ListTileControlAffinity.leading,
        title: Text(tr('Open this group at start')),
        value: current != null && _app.defaultGroup == current,
        onChanged: (v) => _app.setDefaultGroup(v ?? false),
      ),
      const SizedBox(height: 8),
      SecureTextField(
          controller: _pw,
          label: tr('Password'),
          obscure: true,
          autofocus: true,
          onSubmitted: (_) => _unlock()),
      _ErrorText(_error),
      const SizedBox(height: 20),
      ElevatedButton.icon(
        onPressed: _busy ? null : _unlock,
        icon: _busyIcon(_busy, Icons.lock_open),
        label: Text(tr('Unlock')),
      ),
      const SizedBox(height: 32),
      TextButton(
        onPressed: _busy ? null : _delete,
        child: Text(tr('Forgot password? Delete this group from this device')),
      ),
    ]);
  }
}

// ── Join or create a group ───────────────────────────────────────────────────

class GroupSetupScreen extends StatefulWidget {
  final AppController app;
  const GroupSetupScreen({super.key, required this.app});
  @override
  State<GroupSetupScreen> createState() => _GroupSetupScreenState();
}

class _GroupSetupScreenState extends State<GroupSetupScreen> {
  final _invite = TextEditingController();
  final _fingerprint = TextEditingController();
  final _url = TextEditingController();
  final _user = TextEditingController();
  final _pass = TextEditingController();
  String? _joinError;
  String? _createError;
  bool _busy = false;

  Identity get _me => widget.app.identity!;

  /// Creating may have been started on the welcome screen and still run.
  bool get _creating => widget.app.creatingGroup;

  @override
  void initState() {
    super.initState();
    _showAttempt();
    // The welcome screen starts creating right after this screen appears.
    widget.app.addListener(_showAttempt);
    // After a failed attempt (for example a timeout) keep what was entered.
    final failure = widget.app.lastCreateFailure;
    if (widget.app.lastCreateAttempt != null && failure != null) {
      _createError = '${errorMessage(failure)}\n${tr('You can simply try again. If the group was already '
          'stored on the server, this device recognizes it as its own and takes it over.')}';
    }
  }

  @override
  void dispose() {
    widget.app.removeListener(_showAttempt);
    super.dispose();
  }

  /// Shows the WebDAV data of the running or last attempt.
  void _showAttempt() {
    final last = widget.app.lastCreateAttempt;
    if (last == null || _url.text.isNotEmpty) return;
    _url.text = last.url;
    _user.text = last.username;
    _pass.text = last.password;
  }

  Future<void> _join() async {
    final Invite invite;
    try {
      invite = Invite.parse(_invite.text);
    } on FormatException catch (e) {
      setState(() => _joinError = errorMessage(e));
      return;
    }
    final fingerprint = parseFingerprint(_fingerprint.text);
    if (fingerprint == null) {
      setState(() => _joinError = _fingerprint.text.trim().isEmpty
          ? tr('Enter the group fingerprint your admin sent you over a second channel.')
          : tr('This is not a complete group fingerprint (64 characters 0-9 and A-F).'));
      return;
    }
    setState(() {
      _busy = true;
      _joinError = null;
    });
    try {
      await widget.app.joinGroup(invite, fingerprint);
    } on TrustException catch (e) {
      if (mounted) {
        setState(() => _joinError = tr(
            'The group does not match the fingerprint you entered. Do not join. Someone may have '
            'changed the invite or the server. Contact your admin over another channel.\n'
            'Found: {fp}',
            {'fp': formatFingerprint(e.fingerprint)}));
      }
    } catch (e) {
      if (mounted) setState(() => _joinError = errorMessage(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _create() async {
    final urlError = WebDavConfig.validateUrl(_url.text);
    if (urlError != null || _user.text.trim().isEmpty) {
      setState(
          () => _createError = urlError != null ? tr(urlError) : tr('Please enter the WebDAV username.'));
      return;
    }
    final ok = await confirm(
      context,
      tr('Create a new group?'),
      tr(
          'RedCourier will create sync.json in\n{url}\n\n'
          'Use an empty folder that only your group can access. You become the admin.',
          {'url': _url.text.trim()}),
      action: tr('Create'),
    );
    if (!ok) return;
    setState(() {
      _busy = true;
      _createError = null;
    });
    try {
      await widget.app.createGroup(WebDavConfig(_url.text, _user.text.trim(), _pass.text));
    } catch (e) {
      if (mounted) setState(() => _createError = errorMessage(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// The group was created on this device but never joined or set up.
  Future<void> _delete() async {
    final ok = await confirm(
      context,
      tr('Delete group "{name}" from this device?', {'name': widget.app.groupName}),
      tr('This deletes your identity, keys and the local data of this group from this device. '
          'Nothing on the server changes. To use the group again you need a new join request. '
          'Files you saved to a folder are not deleted.'),
      action: tr('Delete'),
      danger: true,
    );
    if (ok) await widget.app.deleteGroup();
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return _SetupPage(
      app: widget.app,
      title: tr('Group {name}', {'name': widget.app.groupName}),
      actions: [
        IconButton(tooltip: tr('Lock'), icon: const Icon(Icons.lock), onPressed: widget.app.lock),
      ],
      children: [
        SectionCard(title: tr('Join an existing group'), icon: Icons.group_add, children: [
          Text(tr('1. Send your join request to an admin of the group.'),
              style: TextStyle(color: palette.fgDim)),
          const SizedBox(height: 8),
          Text(tr('Your identifier: {name}', {'name': _me.identifier})),
          Text(tr('Your user id: {id}', {'id': shortId(_me.userId)}), style: TextStyle(color: palette.fgDim)),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            icon: const Icon(Icons.qr_code),
            label: Text(tr('Show join request')),
            onPressed: () => showCodeDialog(
              context,
              title: tr('Your join request'),
              code: _me.joinRequest.encode(),
              showQr: false,
              explanation: tr(
                  'It contains only your identifier and public keys. The admin should '
                  'compare your user id ({id}) with you.',
                  {'id': shortId(_me.userId)}),
            ),
          ),
          const SizedBox(height: 16),
          Text(tr('2. When the admin has added you, paste the invite you received.'),
              style: TextStyle(color: palette.fgDim)),
          const SizedBox(height: 8),
          SecureTextField(
            controller: _invite,
            label: tr('Invite (RCINVITE2:…)'),
            maxLines: 3,
            suffix: canScanQr ? ScanQrButton(controller: _invite, title: tr('Scan invite')) : null,
          ),
          const SizedBox(height: 16),
          Text(
              tr('3. Enter the group fingerprint. Your admin sends it over a second channel: by e-mail, '
                  'or you scan the QR code on their screen.'),
              style: TextStyle(color: palette.fgDim)),
          const SizedBox(height: 8),
          SecureTextField(
            controller: _fingerprint,
            label: tr('Group fingerprint'),
            maxLines: 3,
            suffix: canScanQr
                ? ScanQrButton(controller: _fingerprint, title: tr('Scan group fingerprint'))
                : null,
          ),
          _ErrorText(_joinError),
          const SizedBox(height: 12),
          ElevatedButton.icon(
            onPressed: _busy || _creating ? null : _join,
            icon: _busyIcon(_busy && !_creating, Icons.login),
            label: Text(_busy && !_creating ? tr('Connecting through Tor…') : tr('Join group')),
          ),
        ]),
        const SizedBox(height: 16),
        SectionCard(title: tr('Start a new group as admin'), icon: Icons.add_circle_outline, children: [
          Text(
              tr('Use a WebDAV folder, for example a Nextcloud folder. Use an app password, '
                  'not your main password.\n'
                  'Example URL: https://cloud.example.com/remote.php/dav/files/USER/redcourier/'),
              style: TextStyle(color: palette.fgDim)),
          const SizedBox(height: 12),
          SecureTextField(controller: _url, label: tr('WebDAV folder URL')),
          const SizedBox(height: 12),
          SecureTextField(controller: _user, label: tr('WebDAV username')),
          const SizedBox(height: 12),
          SecureTextField(controller: _pass, label: tr('WebDAV app password'), obscure: true),
          if (!_creating) _ErrorText(_createError),
          const SizedBox(height: 12),
          if (_creating) ...[
            Text(tr('Creating the group on the server through Tor. This can take a minute.'),
                style: TextStyle(color: palette.fgDim)),
            const SizedBox(height: 8),
            const LinearProgressIndicator(),
            const SizedBox(height: 12),
          ],
          ElevatedButton.icon(
            onPressed: _busy || _creating ? null : _create,
            icon: _busyIcon(_creating, Icons.cloud_upload_outlined),
            label: Text(_creating ? tr('Creating group…') : tr('Create group')),
          ),
        ]),
        const SizedBox(height: 24),
        Center(
          child: TextButton.icon(
            style: TextButton.styleFrom(foregroundColor: palette.red),
            onPressed: _busy || _creating ? null : _delete,
            icon: const Icon(Icons.delete_outline),
            label: Text(tr('Delete this group from this device')),
          ),
        ),
      ],
    );
  }
}
