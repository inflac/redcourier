import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:file_selector/file_selector.dart';

/// Asks the user for a folder to save received files to (for example a
/// mounted VeraCrypt volume). Returns null if cancelled. Tests replace it.
Future<String?> Function(String confirmLabel) pickFolder = _systemPicker;

// coverage:ignore-start
// System dialogs cannot run in tests.
Future<String?> _systemPicker(String confirmLabel) async {
  if (Platform.isAndroid) return FilePicker.getDirectoryPath();
  return getDirectoryPath(confirmButtonText: confirmLabel, canCreateDirectories: true);
}
// coverage:ignore-end
