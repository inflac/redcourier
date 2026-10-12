import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Where RedCourier keeps its data.
///
/// `REDCOURIER_DATA_DIR` overrides the default. The Tails installer sets it
/// to a folder in ~/Persistent, because the normal data folder is wiped on
/// every reboot there.
Future<Directory> resolveDataDir() async {
  final override = Platform.environment['REDCOURIER_DATA_DIR'];
  if (override != null && override.trim().isNotEmpty) {
    return Directory(override.trim()).create(recursive: true);
  }
  final support = await getApplicationSupportDirectory();
  return Directory(p.join(support.path, 'redcourier')).create(recursive: true);
}

/// Small non-secret settings (language, theme, Tor port, default group),
/// stored as JSON next to the groups. Written atomically.
class Prefs {
  static File? _file;
  static Map<String, dynamic> _data = {};

  static Future<void> init(Directory dataDir) async {
    _file = File(p.join(dataDir.path, 'settings.json'));
    try {
      if (await _file!.exists()) {
        _data = jsonDecode(await _file!.readAsString()) as Map<String, dynamic>;
      }
    } catch (_) {
      _data = {};
    }
  }

  static String? getString(String key) => _data[key] as String?;
  static int? getInt(String key) => _data[key] as int?;
  static bool? getBool(String key) => _data[key] as bool?;

  static Future<void> set(String key, Object? value) async {
    if (value == null) {
      _data.remove(key);
    } else {
      _data[key] = value;
    }
    final file = _file;
    if (file == null) return;
    // One write at a time: parallel writes would share the .tmp file, and on
    // Windows the second rename fails while the first holds it.
    final previous = _writing;
    final write = () async {
      if (previous != null) {
        try {
          await previous;
        } catch (_) {}
      }
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsString(const JsonEncoder.withIndent('  ').convert(_data), flush: true);
      await tmp.rename(file.path);
    }();
    _writing = write;
    try {
      await write;
    } finally {
      if (identical(_writing, write)) _writing = null;
    }
  }

  static Future<void>? _writing;
}
