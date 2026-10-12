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

// coverage:ignore-start
// Needs a camera; scanning only exists on Android devices.
class _QrScanPage extends StatefulWidget {
  final String title;
  const _QrScanPage({required this.title});

  @override
  State<_QrScanPage> createState() => _QrScanPageState();
}

class _QrScanPageState extends State<_QrScanPage> {
  bool _done = false;
  String? _error;

  /// Why the last frame could not be read, if the scanner says so (for
  /// example an unsupported camera image format). Shown under the preview.
  String? _lastFailure;

  void _onScan(Code code) {
    final text = code.text;
    if (_done || !code.isValid || text == null || text.isEmpty) return;
    _done = true;
    Navigator.pop(context, text);
  }

  void _onFailure(Code code) {
    final reason = code.error;
    if (reason == null || reason.isEmpty || reason == _lastFailure || !mounted) return;
    setState(() => _lastFailure = reason);
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(_error!, textAlign: TextAlign.center, style: TextStyle(color: palette.red)),
              ),
            )
          : Column(children: [
              Expanded(
                child: ReaderWidget(
                  codeFormat: Format.qrCode,
                  onScan: _onScan,
                  onScanFailure: _onFailure,
                  showGallery: false,
                  showToggleCamera: false,
                  // Codes photographed from a screen are often small, blurred
                  // or shown with inverted colours: search the whole frame,
                  // also scaled down and inverted.
                  cropPercent: 0.9,
                  tryHarder: true,
                  tryDownscale: true,
                  tryInverted: true,
                  scanDelay: const Duration(milliseconds: 300),
                  onControllerCreated: (_, error) {
                    if (error != null && mounted) {
                      setState(() => _error = tr('The camera is not available. Allow camera access in the '
                          'system settings or enter the code by hand.'));
                    }
                  },
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  _lastFailure == null
                      ? tr('Hold the QR code inside the frame, about 20 cm from the camera.')
                      : tr('Not recognized yet: {reason}', {'reason': _lastFailure}),
                  textAlign: TextAlign.center,
                  style: TextStyle(color: palette.fgDim),
                ),
              ),
            ]),
    );
  }
}
// coverage:ignore-end
