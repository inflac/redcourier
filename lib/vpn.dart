// vpn_detector.dart
import 'dart:io';
import 'package:flutter/services.dart';

class VpnDetector {
  static const _channel = MethodChannel("vpn_detector");

  /// Returns true when a VPN connection is active.
  static Future<bool> isVpnActive() async {
    if (Platform.isAndroid || Platform.isIOS || Platform.isMacOS) {
      try {
        final result = await _channel.invokeMethod<bool>("isVpnActive");
        return result ?? false;
      } catch (_) {
        return false;
      }
    }

    // Unsupported platforms fallback
    return false;
  }
}