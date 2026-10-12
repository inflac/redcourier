// lib/utils/app_logger.dart
import 'package:flutter/foundation.dart';

/// Simple centralized logger for your app.
///
/// Usage:
///   AppLogger.init(isEnabled: !kReleaseMode); // Enable only in debug
///   AppLogger.debug('Something happened');
///   AppLogger.error('Something failed', e);
///   AppLogger.info('Process complete');
///
/// Safe for production: logs are suppressed when disabled.
class AppLogger {
  static bool _enabled = !kReleaseMode;
  static const String _tag = '[RedCourier]';

  /// Initialize the logger (e.g. at app startup).
  static void init({required bool isEnabled}) {
    _enabled = isEnabled;
  }

  /// Print a debug message (only if enabled).
  static void debug(String message, [Object? data]) {
    if (!_enabled) return;
    final ts = DateTime.now().toIso8601String();
    final extra = data != null ? ' | $data' : '';
    debugPrint('$_tag [DEBUG][$ts] $message$extra');
  }

  /// Print an info message.
  static void info(String message, [Object? data]) {
    if (!_enabled) return;
    final ts = DateTime.now().toIso8601String();
    debugPrint('$_tag [INFO][$ts] $message${data != null ? ' | $data' : ''}');
  }

  /// Print a warning.
  static void warn(String message, [Object? data]) {
    if (!_enabled) return;
    final ts = DateTime.now().toIso8601String();
    debugPrint('$_tag [WARN][$ts] $message${data != null ? ' | $data' : ''}');
  }

  /// Print an error message (always prints stack if provided).
  static void error(String message, [Object? error, StackTrace? stack]) {
    if (!_enabled) return;
    final ts = DateTime.now().toIso8601String();
    debugPrint('$_tag [ERROR][$ts] $message');
    if (error != null) debugPrint('  ↳ Error: $error');
    if (stack != null) debugPrint('  ↳ Stack: $stack');
  }
}
