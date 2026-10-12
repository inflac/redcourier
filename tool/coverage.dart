// Prints line coverage per file from coverage/lcov.info and fails below a
// minimum:
//
//   flutter test --coverage
//   dart run tool/coverage.dart [--min 80]
//
// test/coverage_all_test.dart imports every library, so files no test uses
// still count (with 0 %). Files without executable lines (only constants)
// do not appear in lcov.info and are not counted.
import 'dart:io';

void main(List<String> args) {
  final i = args.indexOf('--min');
  final min = i >= 0 && i + 1 < args.length ? double.parse(args[i + 1]) : 80.0;
  final lcov = File('coverage/lcov.info');
  if (!lcov.existsSync()) {
    stderr.writeln('coverage/lcov.info not found. Run: flutter test --coverage');
    exit(2);
  }

  final hits = <String, Map<int, int>>{};
  Map<int, int>? current;
  for (final line in lcov.readAsLinesSync()) {
    if (line.startsWith('SF:')) {
      final path = line.substring(3).replaceAll('\\', '/');
      current = hits.putIfAbsent(path.substring(path.indexOf('lib/')), () => {});
    } else if (line.startsWith('DA:') && current != null) {
      final parts = line.substring(3).split(',');
      final n = int.parse(parts[0]);
      current[n] = (current[n] ?? 0) + int.parse(parts[1]);
    }
  }

  var covered = 0, total = 0;
  final rows = <(double, String)>[];
  for (final e in hits.entries) {
    final c = e.value.values.where((h) => h > 0).length;
    final t = e.value.length;
    if (t == 0) continue;
    covered += c;
    total += t;
    rows.add((100 * c / t, '${(100 * c / t).toStringAsFixed(1).padLeft(5)} %  ${'$c/$t'.padLeft(9)}  ${e.key}'));
  }
  rows.sort((a, b) => a.$1.compareTo(b.$1));
  for (final r in rows) {
    stdout.writeln(r.$2);
  }
  final pct = total == 0 ? 0.0 : 100 * covered / total;
  stdout.writeln('Total: ${pct.toStringAsFixed(1)} % ($covered/$total lines), minimum $min %');
  if (pct < min) {
    stderr.writeln('Coverage is below $min %.');
    exit(1);
  }
}
