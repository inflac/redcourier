import 'dart:io' show Platform;
import 'package:fluttertoast/fluttertoast.dart';
import 'package:flutter/material.dart';

import 'main.dart' show scaffoldMessengerKey;
import 'theme.dart';

class AppNotifier {
  static void showError(dynamic error, {String? fallbackMessage, BuildContext? context}) {
    final message = error.toString().isNotEmpty
        ? error.toString()
        : fallbackMessage ?? 'An unknown error occurred';
    _showToast(message, _palette(context).red, context: context);
  }

  static void showInfo(String message, {BuildContext? context}) {
    _showToast(message, _palette(context).accent, context: context);
  }

  static void showSuccess(String message, {BuildContext? context}) {
    _showToast(message, _palette(context).accentHover, context: context);
  }

  /// Palette of the running app. Falls back to the dark palette before the
  /// app has built its first frame.
  static AppPalette _palette(BuildContext? context) {
    final ctx = context ?? scaffoldMessengerKey.currentContext;
    return ctx != null ? AppPalette.of(ctx) : AppPalette.dark;
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
            style: const TextStyle(color: Colors.white),
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
