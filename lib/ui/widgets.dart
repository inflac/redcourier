import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../app_notifier.dart';
import '../core/crypto_util.dart';
import '../i18n.dart';
import '../keyboard.dart';
import '../theme.dart';

bool get isMobile => !kIsWeb && (Platform.isAndroid || Platform.isIOS);

/// Text field that never uses the system keyboard on phones.
///
/// Third-party keyboards can log or upload what is typed. On Android and iOS
/// the field opens RedCourier's own keyboard instead; on desktop it is a
/// normal text field.
class SecureTextField extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final String? hint;
  final bool obscure;
  final int maxLines;
  final String? errorText;
  final ValueChanged<String>? onSubmitted;
  final bool autofocus;
  final Widget? suffix;

  const SecureTextField({
    super.key,
    required this.controller,
    required this.label,
    this.hint,
    this.obscure = false,
    this.maxLines = 1,
    this.errorText,
    this.onSubmitted,
    this.autofocus = false,
    this.suffix,
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      obscureText: obscure,
      maxLines: obscure ? 1 : maxLines,
      minLines: 1,
      readOnly: isMobile,
      autofocus: autofocus && !isMobile,
      autocorrect: false,
      enableSuggestions: false,
      enableIMEPersonalizedLearning: false,
      onTap: isMobile ? () => showSecureKeyboard(context, controller, label, obscure) : null,
      onSubmitted: onSubmitted,
      decoration: InputDecoration(labelText: label, hintText: hint, errorText: errorText, suffixIcon: suffix),
    );
  }
}

Future<void> showSecureKeyboard(
    BuildContext context, TextEditingController controller, String label, bool obscure) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppPalette.of(context).bgPanel,
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 12, 8, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: ValueListenableBuilder<TextEditingValue>(
                    valueListenable: controller,
                    builder: (_, v, __) => Text(
                      v.text.isEmpty
                          ? label
                          : obscure
                              ? '•' * v.text.length
                              : v.text,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: v.text.isEmpty ? AppPalette.of(ctx).fgDim : AppPalette.of(ctx).fg),
                    ),
                  ),
                ),
                TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('Done'))),
              ],
            ),
            const SizedBox(height: 8),
            CustomKeyboard(
              onKeyPress: (k) => controller.text += k,
              onBackspace: () {
                if (controller.text.isNotEmpty) {
                  controller.text = controller.text.substring(0, controller.text.length - 1);
                }
              },
              onClear: controller.clear,
            ),
          ],
        ),
      ),
    ),
  );
}

String formatSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const units = ['KB', 'MB', 'GB', 'TB'];
  var v = bytes / 1024;
  var i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return '${v.toStringAsFixed(v < 10 ? 1 : 0)} ${units[i]}';
}

String _two(int v) => v.toString().padLeft(2, '0');

String formatDateTime(DateTime t) =>
    '${_two(t.day)}.${_two(t.month)}.${t.year} ${_two(t.hour)}:${_two(t.minute)}';

String formatRemaining(DateTime until) {
  final d = until.difference(DateTime.now());
  if (d.isNegative) return tr('expired');
  if (d.inDays == 1) return tr('expires in 1 day');
  if (d.inDays > 1) return tr('expires in {n} days', {'n': d.inDays});
  if (d.inHours >= 1) return tr('expires in {n} h', {'n': d.inHours});
  return tr('expires in {n} min', {'n': d.inMinutes.clamp(1, 59)});
}

String shortId(String id) => formatFingerprint(id.substring(0, 16));

Future<bool> confirm(BuildContext context, String title, String message,
    {String? action, bool danger = false}) async {
  final palette = AppPalette.of(context);
  final result = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('Cancel'))),
        FilledButton(
          style: danger ? FilledButton.styleFrom(backgroundColor: palette.red) : null,
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(action ?? tr('OK')),
        ),
      ],
    ),
  );
  return result ?? false;
}

/// Shows a code (join request, invite) with copy button and QR code.
Future<void> showCodeDialog(BuildContext context,
    {required String title,
    required String code,
    String? explanation,
    bool showQr = true,
    String? qrData,
    String? copyText,
    (String, VoidCallback)? extraAction}) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (explanation != null) ...[
                Text(explanation, style: TextStyle(color: AppPalette.of(ctx).fgDim)),
                const SizedBox(height: 12),
              ],
              if (showQr)
                Center(
                  child: Container(
                    color: Colors.white,
                    padding: const EdgeInsets.all(8),
                    child: QrImageView(data: qrData ?? code, size: 220, backgroundColor: Colors.white),
                  ),
                ),
              const SizedBox(height: 12),
              CodeBox(code),
            ],
          ),
        ),
      ),
      actions: [
        if (extraAction != null)
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              extraAction.$2();
            },
            child: Text(extraAction.$1),
          ),
        TextButton(
          onPressed: () {
            Clipboard.setData(ClipboardData(text: copyText ?? code));
            AppNotifier.showInfo(tr('Copied to clipboard'));
          },
          child: Text(tr('Copy')),
        ),
        FilledButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('Close'))),
      ],
    ),
  );
}

class CodeBox extends StatelessWidget {
  final String text;
  final bool copyable;
  const CodeBox(this.text, {super.key, this.copyable = false});

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: palette.bgAlt,
        border: Border.all(color: palette.border),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Expanded(
            child: SelectableText(text,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 13)),
          ),
          if (copyable)
            IconButton(
              tooltip: tr('Copy'),
              icon: const Icon(Icons.copy, size: 18),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: text));
                AppNotifier.showInfo(tr('Copied to clipboard'));
              },
            ),
        ],
      ),
    );
  }
}

/// Small rounded label, e.g. for roles or "new".
class Tag extends StatelessWidget {
  final String text;
  final Color? color;
  const Tag(this.text, {super.key, this.color});

  @override
  Widget build(BuildContext context) {
    final c = color ?? AppPalette.of(context).accent;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: c.withValues(alpha: 0.6)),
      ),
      child: Text(text, style: TextStyle(fontSize: 12, color: c, fontWeight: FontWeight.w600)),
    );
  }
}

/// Section card with a title used on setup and settings pages.
class SectionCard extends StatelessWidget {
  final String title;
  final List<Widget> children;
  final IconData? icon;
  const SectionCard({super.key, required this.title, required this.children, this.icon});

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return Card(
      elevation: 0,
      color: palette.bgAlt,
      shape: RoundedRectangleBorder(
        side: BorderSide(color: palette.border),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              if (icon != null) ...[Icon(icon, color: palette.accent), const SizedBox(width: 8)],
              Expanded(
                child: Text(title,
                    style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
              ),
            ]),
            const SizedBox(height: 12),
            ...children,
          ],
        ),
      ),
    );
  }
}

/// Runs [action] while showing a blocking progress dialog.
Future<T?> withProgress<T>(BuildContext context, String message, Future<T> Function() action) async {
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => PopScope(
      canPop: false,
      child: AlertDialog(
        content: Row(children: [
          const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 3)),
          const SizedBox(width: 16),
          Expanded(child: Text(message)),
        ]),
      ),
    ),
  );
  try {
    return await action();
  } finally {
    if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
  }
}

/// App bar button to switch the language (used where Settings are not reachable).
class LanguageButton extends StatelessWidget {
  const LanguageButton({super.key});

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: tr('Language'),
      icon: const Icon(Icons.translate),
      onSelected: I18n.set,
      itemBuilder: (_) => [
        for (final e in I18n.supported.entries)
          CheckedPopupMenuItem(value: e.key, checked: I18n.language.value == e.key, child: Text(e.value)),
      ],
    );
  }
}
