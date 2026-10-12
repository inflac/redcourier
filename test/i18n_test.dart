import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:redcourier/i18n_de.dart';

/// Reads the Dart string literal(s) starting at [i] (adjacent literals are
/// concatenated). Returns null if there is no plain single-quoted literal.
String? readLiterals(String src, int i) {
  final out = StringBuffer();
  var found = false;
  while (true) {
    while (i < src.length && ' \t\r\n'.contains(src[i])) {
      i++;
    }
    if (i >= src.length || src[i] != "'") break;
    if (src.startsWith("'''", i)) return null;
    i++;
    while (i < src.length && src[i] != "'") {
      if (src[i] == r'\') {
        final n = src[i + 1];
        out.write(switch (n) { 'n' => '\n', 't' => '\t', _ => n });
        i += 2;
      } else {
        out.write(src[i]);
        i++;
      }
    }
    i++; // closing quote
    found = true;
  }
  return found ? out.toString() : null;
}

/// All texts that reach the user: tr(...) calls, error templates and lines
/// marked with `// i18n`.
Map<String, String> collectTexts() {
  final texts = <String, String>{};
  final calls = RegExp(
      r"(?:\btr\(|(?<!Socket)Exception\(|\bsuper\(|onProgress\?\.call\(|_fail\(res\.statusCode,)");
  for (final f in Directory('lib').listSync(recursive: true).whereType<File>()) {
    if (!f.path.endsWith('.dart') || f.path.endsWith('i18n_de.dart')) continue;
    final src = f.readAsStringSync();
    for (final m in calls.allMatches(src)) {
      final t = readLiterals(src, m.end);
      if (t != null) texts[t] = '${f.path}:${m.start}';
    }
    for (final line in src.split('\n').where((l) => l.contains('// i18n'))) {
      final m = RegExp(r"(?:return|\?|:)\s+'").firstMatch(line);
      if (m == null) continue;
      final t = readLiterals(line, m.end - 1);
      if (t != null) texts[t] = f.path;
    }
  }
  return texts;
}

Set<String> placeholders(String s) =>
    RegExp(r'\{(\w+)\}').allMatches(s).map((m) => m.group(1)!).toSet();

void main() {
  test('every user-visible text has a German translation', () {
    final texts = collectTexts();
    expect(texts.length, greaterThan(150));
    final missing = texts.keys.where((t) => !germanTexts.containsKey(t)).toList()..sort();
    if (missing.isNotEmpty) {
      // Printed so the missing entries can be added to lib/i18n_de.dart.
      for (final m in missing) {
        // ignore: avoid_print
        print('MISSING: ${m.replaceAll('\n', r'\n')}');
      }
    }
    expect(missing, isEmpty);
  });

  test('translations keep the placeholders and have no interpolation', () {
    for (final e in germanTexts.entries) {
      expect(placeholders(e.value), placeholders(e.key), reason: e.key);
      expect(e.key.contains(r'$'), isFalse, reason: e.key);
    }
  });

  test('no unused translations', () {
    final texts = collectTexts();
    final unused = germanTexts.keys.where((k) => !texts.containsKey(k)).toList();
    expect(unused, isEmpty);
  });
}
