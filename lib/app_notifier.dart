import 'dart:io' show Platform;
import 'package:fluttertoast/fluttertoast.dart';
import 'package:flutter/material.dart';

import 'main.dart' show scaffoldMessengerKey;

class AppNotifier {
  static void showError(dynamic error, {String? fallbackMessage, BuildContext? context}) {
    final message = error.toString().isNotEmpty
        ? error.toString()
        : fallbackMessage ?? 'An unknown error occurred';
    _showToast(message, Colors.redAccent, context: context);
  }

  static void showInfo(String message, {BuildContext? context}) {
    _showToast(message, Colors.blueAccent, context: context);
  }

  static void showSuccess(String message, {BuildContext? context}) {
    _showToast(message, Colors.green, context: context);
  }

  static void _showToast(String message, Color color, {BuildContext? context}) {
    bool isMobile = false;
    try {
      isMobile = Platform.isAndroid || Platform.isIOS;
    } catch (_) {
      // Fallback, falls Platform nicht funktioniert (z. B. in AppImage)
      isMobile = false;
    }

    if (isMobile) {
      try {
        Fluttertoast.showToast(
          msg: message,
          toastLength: Toast.LENGTH_LONG,
          gravity: ToastGravity.TOP,
          backgroundColor: color,
          textColor: Colors.white,
          fontSize: 16.0,
        );
        return;
      } catch (e) {
        // Falls Plugin trotzdem fehlt
        debugPrint("Fluttertoast not available: $e");
      }
    }

    // Fallback für alles andere (Linux, macOS, Windows, AppImage, Tails)
    final messenger = scaffoldMessengerKey.currentState;
    if (messenger != null) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(message,
            style: TextStyle(color: Colors.white),
          ),
          backgroundColor: color,
          behavior: SnackBarBehavior.floating,
        ),
      );
    } else {
      debugPrint('[AppNotifier] $message');
    }
  }
}
