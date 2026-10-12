import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../app_notifier.dart';
import '../core/crypto_util.dart';
import '../core/group.dart';
import '../core/identity.dart';
import '../i18n.dart';
import '../theme.dart';
import 'widgets.dart';

class MembersScreen extends StatefulWidget {
  final AppController app;
  const MembersScreen({super.key, required this.app});

  @override
  State<MembersScreen> createState() => _MembersScreenState();
}

class _MembersScreenState extends State<MembersScreen> {
  GroupSession get _s => widget.app.session!;

  String get _inviteCode => Invite(_s.local.webdav).encode();

  void _showInvite() => showCodeDialog(
        context,
        title: tr('Invite'),
        code: _inviteCode,
        explanation: tr('Step 1 of 2: send this invite to the new member, for example over a messenger. '
            'It contains the WebDAV access data.\n'
            'Step 2: send the group fingerprint over a different channel (e-mail, or the QR code for '
            'the Android app). Someone who reads only one channel cannot lead the new member into '
            'a fake group.'),
        extraAction: (tr('Group fingerprint'), _showFingerprint),
      );

  Future<void> _add() async {
    final controller = TextEditingController();
    final request = await showDialog<JoinRequest>(
      context: context,
      builder: (ctx) => _AddMemberDialog(controller: controller),
    );
    if (request == null || !mounted) return;
    final admin = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('Add {name}?', {'name': request.identifier})),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(tr('Compare this user id with the new member before adding them:')),
          const SizedBox(height: 8),
          CodeBox(shortId(request.userId)),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('Cancel'))),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('Add as admin'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('Add as member'))),
        ],
      ),
    );
    if (admin == null || !mounted) return;
    try {
      await withProgress(
          context, tr('Adding member…'), () => widget.app.run((s) => s.addMember(request, admin: admin)));
      if (!mounted) return;
      setState(() {});
      AppNotifier.showSuccess(tr('{name} was added', {'name': request.identifier}));
      _showInvite();
    } catch (e) {
      AppNotifier.showError(errorMessage(e));
    }
  }

  Future<void> _remove(Member m) async {
    final ok = await confirm(
      context,
      tr('Remove {name}?', {'name': m.identifier}),
      [
        tr('All shared group keys are replaced, so {name} can no longer read the member list '
            'or sign changes. Files already sent to {name} stay readable for them.',
            {'name': m.identifier}),
        if (m.isAdmin)
          tr('Because {name} is an admin, the group fingerprint changes and every member has to '
              'confirm the new one.', {'name': m.identifier}),
        tr('Afterwards, create a new app password on the server and revoke the old one. Send the new '
            'password to the remaining members; they enter it under Settings → Change WebDAV access.'),
      ].join('\n\n'),
      action: tr('Remove'),
      danger: true,
    );
    if (!ok || !mounted) return;
    try {
      await withProgress(context, tr('Removing member and rotating keys…'),
          () => widget.app.run((s) => s.removeMember(m.id)));
      if (mounted) setState(() {});
      AppNotifier.showInfo(tr('{name} was removed', {'name': m.identifier}));
      if (m.isAdmin && mounted) _showFingerprint(changed: true);
    } catch (e) {
      AppNotifier.showError(errorMessage(e));
    }
  }

  Future<void> _setAdmin(Member m, bool admin) async {
    final ok = admin
        ? await confirm(
            context,
            tr('Make {name} an admin?', {'name': m.identifier}),
            tr('Admins can add and remove members, make others admins and take admin rights away, '
                'also from you. The group fingerprint stays the same.'),
            action: tr('Make admin'))
        : await confirm(
            context,
            tr('Remove admin rights from {name}?', {'name': m.identifier}),
            tr('The admin key is replaced. The group fingerprint changes and every member has to '
                'confirm the new one.'),
            action: tr('Continue'));
    if (!ok || !mounted) return;
    try {
      await withProgress(context, tr('Updating role…'), () => widget.app.run((s) => s.setAdmin(m.id, admin)));
      if (!mounted) return;
      setState(() {});
      if (admin) {
        AppNotifier.showSuccess(tr('{name} is now an admin', {'name': m.identifier}));
      } else {
        _showFingerprint(changed: true);
      }
    } catch (e) {
      AppNotifier.showError(errorMessage(e));
    }
  }

  void _showFingerprint({bool changed = false}) {
    final fp = formatFingerprint(_s.fingerprint);
    showCodeDialog(
      context,
      title: changed ? tr('New group fingerprint') : tr('Group fingerprint'),
      code: fp,
      qrData: fingerprintQr(_s.fingerprint),
      copyText: tr('RedCourier group fingerprint:\n{fp}', {'fp': fp}),
      explanation: changed
          ? tr('Send this fingerprint to every member over a trusted channel: by e-mail (copy the '
              'text), or let them scan the QR code with the Android app. They need it to accept '
              'the change.')
          : tr('Send this fingerprint over a different channel than the invite: by e-mail (copy the '
              'text), or let the new member scan the QR code with the Android app. Members can also '
              'compare it at any time to make sure nobody swapped the group keys.'),
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final me = widget.app.identity!;
    final members = _s.activeMembers;

    return Scaffold(
      appBar: AppBar(title: Text(tr('Members'))),
      floatingActionButton: _s.isAdmin
          ? FloatingActionButton.extended(
              onPressed: _add, icon: const Icon(Icons.person_add), label: Text(tr('Add member')))
          : null,
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 96), children: [
            SectionCard(title: tr('You'), icon: Icons.person, children: [
              Text(me.identifier, style: const TextStyle(fontSize: 16)),
              Text(
                  tr('User id {id} · {role}',
                      {'id': shortId(me.userId), 'role': _s.isAdmin ? tr('admin') : tr('member')}),
                  style: TextStyle(color: palette.fgDim)),
              const SizedBox(height: 12),
              Wrap(spacing: 8, runSpacing: 8, children: [
                OutlinedButton.icon(
                  icon: const Icon(Icons.fingerprint),
                  label: Text(tr('Group fingerprint')),
                  onPressed: _showFingerprint,
                ),
                if (_s.isAdmin)
                  OutlinedButton.icon(
                    icon: const Icon(Icons.mail_lock_outlined),
                    label: Text(tr('Invite')),
                    onPressed: _showInvite,
                  ),
              ]),
            ]),
            if (_s.isAdmin && members.where((m) => m.isAdmin).length == 1 && members.length > 1) ...[
              const SizedBox(height: 16),
              SectionCard(title: tr('Only one admin'), icon: Icons.info_outline, children: [
                Text(
                    tr('You are the only admin. If you lose this device or forget its password, nobody '
                        'can manage the group any more. Make a second member admin (menu next to the '
                        'member).'),
                    style: TextStyle(color: palette.fgDim)),
              ]),
            ],
            const SizedBox(height: 16),
            Text(tr('Members: {n}', {'n': members.length}), style: TextStyle(color: palette.fgDim)),
            const SizedBox(height: 8),
            for (final m in members)
              Card(
                elevation: 0,
                color: palette.bgAlt,
                margin: const EdgeInsets.only(bottom: 8),
                shape: RoundedRectangleBorder(
                  side: BorderSide(color: palette.border),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: ListTile(
                  title: Row(children: [
                    Flexible(child: Text(m.identifier, overflow: TextOverflow.ellipsis)),
                    const SizedBox(width: 8),
                    if (m.isAdmin) Tag(tr('admin')),
                    if (m.id == _s.myId) ...[const SizedBox(width: 6), Tag(tr('you'), color: palette.fgDim)],
                  ]),
                  subtitle: Text(shortId(m.id), style: TextStyle(color: palette.fgDim)),
                  trailing: _s.isAdmin && m.id != _s.myId
                      ? PopupMenuButton<String>(
                          onSelected: (v) {
                            if (v == 'remove') _remove(m);
                            if (v == 'admin') _setAdmin(m, true);
                            if (v == 'member') _setAdmin(m, false);
                          },
                          itemBuilder: (_) => [
                            if (!m.isAdmin) PopupMenuItem(value: 'admin', child: Text(tr('Make admin'))),
                            if (m.isAdmin)
                              PopupMenuItem(value: 'member', child: Text(tr('Remove admin rights'))),
                            PopupMenuItem(value: 'remove', child: Text(tr('Remove from group'))),
                          ],
                        )
                      : null,
                ),
              ),
          ]),
        ),
      ),
    );
  }
}

class _AddMemberDialog extends StatefulWidget {
  final TextEditingController controller;
  const _AddMemberDialog({required this.controller});

  @override
  State<_AddMemberDialog> createState() => _AddMemberDialogState();
}

class _AddMemberDialogState extends State<_AddMemberDialog> {
  String? _error;

  void _submit() {
    try {
      Navigator.pop(context, JoinRequest.parse(widget.controller.text));
    } on FormatException catch (e) {
      setState(() => _error = errorMessage(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(tr('Add member')),
      content: SizedBox(
        width: 420,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(tr('Paste the join request the new member sent you.')),
          const SizedBox(height: 12),
          SecureTextField(
              controller: widget.controller,
              label: tr('Join request (RCJOIN2:…)'),
              maxLines: 3,
              errorText: _error),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('Cancel'))),
        FilledButton(onPressed: _submit, child: Text(tr('Continue'))),
      ],
    );
  }
}
