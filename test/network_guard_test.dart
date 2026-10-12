import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Every network connection must go through lib/core/tor.dart. This test
/// fails as soon as other code opens connections itself, so a direct
/// connection cannot slip in unnoticed. The runtime guard
/// (TorNetwork.installGuard) catches what a pattern cannot.
void main() {
  const torFile = 'lib/core/tor.dart';

  // Pattern -> what it would do.
  final forbidden = <RegExp, String>{
    RegExp(r'\bHttpClient\s*\('): 'creates an HTTP client',
    RegExp(r'\b(Secure)?Socket\s*\.\s*(connect|startConnect)\b'): 'opens a socket',
    RegExp(r'\bRaw(Secure)?Socket\b'): 'uses raw sockets',
    RegExp(r'\bRaw(Secure)?ServerSocket\b|\bServerSocket\b|\bHttpServer\b'): 'listens on a port',
    RegExp(r'\bRawDatagramSocket\b'): 'sends UDP',
    RegExp(r'\bWebSocket\b'): 'opens a WebSocket',
    RegExp(r'\bInternetAddress\s*\.\s*lookup\b'): 'resolves DNS itself',
    RegExp(r'\b(Http|IO)Overrides\b'): 'changes the network overrides',
    RegExp(r'''['"]package:(http|dio|web_socket_channel)/'''): 'uses a network package',
  };
  // Starting other programs could also open connections.
  final process = RegExp(r'\bProcess\s*\.\s*(run|start|runSync)\b');
  // The updater unpacks the verified update and restarts the app; both local.
  const processAllowed = {'lib/core/updater.dart'};

  test('only tor.dart opens network connections', () {
    final problems = <String>[];
    final files = Directory('lib').listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart'));
    for (final f in files) {
      final path = p.posix.joinAll(p.split(f.path));
      final lines = f.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i];
        if (path != torFile) {
          forbidden.forEach((re, what) {
            if (re.hasMatch(line)) problems.add('$path:${i + 1} $what: ${line.trim()}');
          });
        }
        if (process.hasMatch(line) && !processAllowed.contains(path)) {
          problems.add('$path:${i + 1} starts a program: ${line.trim()}');
        }
      }
    }
    expect(problems, isEmpty,
        reason: 'Network access belongs into $torFile (TorNetwork.createHttpClient / tcpExchange).');
  });

  test('main() installs the Tor guard before anything else', () {
    final main = File('lib/main.dart').readAsStringSync();
    final start = main.indexOf('void main()');
    final guard = main.indexOf('TorNetwork.installGuard()');
    expect(guard, greaterThan(start));
    // Only the Flutter binding comes before it.
    final between = main.substring(start, guard);
    expect(between.contains('await'), isFalse, reason: 'nothing may run before the guard');
  });

  test('no network packages are dependencies', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    for (final pkg in ['http', 'dio', 'web_socket_channel', 'firebase_core', 'google_fonts', 'sentry_flutter']) {
      expect(RegExp('^\\s+$pkg:', multiLine: true).hasMatch(pubspec), isFalse, reason: pkg);
    }
  });
}
