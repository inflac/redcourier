import 'package:flutter/foundation.dart';

import 'core/messages.dart';
import 'i18n_de.dart';
import 'prefs.dart';

/// Minimal translation layer: English source text is the key.
///
/// [tr] returns the German text when German is selected, otherwise the
/// English text, with {placeholders} filled in from the arguments.
class I18n {
  static const supported = {'en': 'English', 'de': 'Deutsch'};
  static const _prefKey = 'language';

  static final language = ValueNotifier<String>('en');

  /// English unless the user chose another language in the settings.
  static Future<void> load() async {
    final saved = Prefs.getString(_prefKey);
    language.value = supported.containsKey(saved) ? saved! : 'en';
  }

  static Future<void> set(String code) async {
    if (!supported.containsKey(code)) return;
    language.value = code;
    await Prefs.set(_prefKey, code);
  }
}

String _lookup(String en) => I18n.language.value == 'de' ? (germanTexts[en] ?? en) : en;

String tr(String en, [Map<String, Object?> args = const {}]) {
  final translated = <String, Object?>{
    for (final e in args.entries) e.key: e.value is String ? _lookup(e.value as String) : e.value,
  };
  return fillTemplate(_lookup(en), translated);
}

/// Translated message for an error shown to the user.
String errorMessage(Object e) {
  if (e is AppException) return tr(e.template, e.args);
  if (e is FormatException) return tr(e.message);
  final s = e.toString();
  return s.startsWith('Exception: ') ? s.substring(11) : s;
}
