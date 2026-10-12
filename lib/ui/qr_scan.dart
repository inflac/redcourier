import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_zxing/flutter_zxing.dart';

import '../i18n.dart';
import '../theme.dart';

/// Scanning needs a camera; on desktops codes are pasted as text instead.
bool get canScanQr => Platform.isAndroid;

/// Opens the camera and returns the text of the first QR code, or null.
/// zxing runs on the device; no image leaves it.
Future<String?> scanQrCode(BuildContext context, {required String title}) =>
    Navigator.of(context).push<String>(MaterialPageRoute(builder: (_) => _QrScanPage(title: title)));

/// Icon button that scans a QR code into [controller].
class ScanQrButton extends StatelessWidget {
  final TextEditingController controller;
  final String title;
  final VoidCallback? onScanned;
  const ScanQrButton({super.key, required this.controller, required this.title, this.onScanned});

  @override
  Widget build(BuildContext context) => IconButton(
        tooltip: tr('Scan QR code'),
        icon: const Icon(Icons.qr_code_scanner),
        onPressed: () async {
          final text = await scanQrCode(context, title: title);
          if (text == null) return;
          controller.text = text;
          onScanned?.call();
        },
      );
}

class _QrScanPage extends StatefulWidget {
  final String title;
  const _QrScanPage({required this.title});

  @override
  State<_QrScanPage> createState() => _QrScanPageState();
}

class _QrScanPageState extends State<_QrScanPage> {
  bool _done = false;
  String? _error;

  void _onScan(Code code) {
    final text = code.text;
    if (_done || !code.isValid || text == null || text.isEmpty) return;
    _done = true;
    Navigator.pop(context, text);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(_error!,
                    textAlign: TextAlign.center, style: TextStyle(color: AppPalette.of(context).red)),
              ),
            )
          : ReaderWidget(
              codeFormat: Format.qrCode,
              onScan: _onScan,
              showGallery: false,
              showToggleCamera: false,
              tryHarder: true,
              onControllerCreated: (_, error) {
                if (error != null && mounted) {
                  setState(() => _error = tr('The camera is not available. Allow camera access in the '
                      'system settings or enter the code by hand.'));
                }
              },
            ),
    );
  }
}
