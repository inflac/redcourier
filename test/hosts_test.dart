import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:redcourier/core/crypto_util.dart';
import 'package:redcourier/core/hosts.dart';

/// Collects data until nothing arrives for [idle], like fiche's receive timeout.
Future<List<int>> readUntilIdle(Socket c, {Duration idle = const Duration(milliseconds: 300)}) async {
  final input = <int>[];
  final done = Completer<List<int>>();
  Timer? timer;
  void arm() {
    timer?.cancel();
    timer = Timer(idle, () {
      if (!done.isCompleted) done.complete(input);
    });
  }

  arm();
  c.listen((d) {
    input.addAll(d);
    arm();
  }, onDone: () {
    if (!done.isCompleted) done.complete(input);
  });
  return done.future;
}

/// Parses a multipart/form-data body into fields and one file.
(Map<String, String>, String?, Uint8List?) parseMultipart(HttpRequest r, List<int> body) {
  final boundary = r.headers.contentType!.parameters['boundary']!;
  final text = latin1.decode(body);
  final fields = <String, String>{};
  String? fileName;
  Uint8List? file;
  for (final part in text.split('--$boundary')) {
    final sep = part.indexOf('\r\n\r\n');
    if (sep < 0) continue;
    final head = part.substring(0, sep);
    var content = part.substring(sep + 4);
    if (content.endsWith('\r\n')) content = content.substring(0, content.length - 2);
    final name = RegExp(r'name="([^"]+)"').firstMatch(head)?.group(1);
    final fn = RegExp(r'filename="([^"]+)"').firstMatch(head)?.group(1);
    if (name == null) continue;
    if (fn != null) {
      fileName = fn;
      file = Uint8List.fromList(latin1.encode(content));
    } else {
      fields[name] = content;
    }
  }
  return (fields, fileName, file);
}

void main() {
  late HttpServer server;
  late Directory tmp;
  late File part;
  late Uint8List partBytes;
  final stored = <String, Uint8List>{};
  final requests = <String>[];
  String? lastTime;
  String base() => 'http://127.0.0.1:${server.port}';

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('rc_hosts_');
    partBytes = randomBytes(300000);
    part = File(p.join(tmp.path, 'abc.zip'))..writeAsBytesSync(partBytes);
    stored.clear();
    requests.clear();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((r) async {
      final body = <int>[];
      await for (final c in r) {
        body.addAll(c);
      }
      requests.add('${r.method} ${r.uri.path}');
      final path = r.uri.path;
      // ── filebin ──
      if (path.startsWith('/fb/')) {
        final segs = r.uri.pathSegments.sublist(1);
        if (r.method == 'POST' && segs.length == 2) {
          expect(r.headers.value('Content-SHA256'), sha256Hex(body));
          stored['/fb/${segs.join('/')}'] = Uint8List.fromList(body);
          r.response.statusCode = 201;
          r.response.write(jsonEncode({
            'bin': {'id': segs[0], 'expired_at': '2030-01-08T12:00:00Z'},
            'file': {'filename': segs[1]},
          }));
        } else if (r.method == 'GET' && stored.containsKey(path)) {
          expect(r.headers.value('cookie'), contains('verified='));
          r.response.add(stored[path]!);
        } else if (r.method == 'DELETE' && segs.length == 1) {
          stored.removeWhere((k, _) => k.startsWith('/fb/${segs[0]}/'));
        } else {
          r.response.statusCode = 404;
        }
      // ── temp.sh ──
      } else if (path == '/ts/upload' && r.method == 'POST') {
        final (_, name, file) = parseMultipart(r, body);
        stored['/ts/x1/$name'] = file!;
        r.response.write('${base()}/ts/x1/$name\n');
      } else if (path.startsWith('/ts/') && stored.containsKey(path)) {
        if (r.method == 'GET') {
          r.response.headers.contentType = ContentType.html;
          r.response.write('<html>click to download</html>');
        } else {
          r.response.add(stored[path]!);
        }
      // ── litterbox ──
      } else if (path == '/lb/api.php' && r.method == 'POST') {
        final (fields, name, file) = parseMultipart(r, body);
        expect(fields['reqtype'], 'fileupload');
        expect(['1h', '12h', '24h', '72h'], contains(fields['time']));
        lastTime = fields['time'];
        stored['/lb/f/$name'] = file!;
        r.response.write('${base()}/lb/f/$name');
      } else if (path.startsWith('/lb/f/') && stored.containsKey(path)) {
        r.response.add(stored[path]!);
      } else {
        r.response.statusCode = 404;
      }
      await r.response.close();
    });
  });

  tearDown(() async {
    await server.close(force: true);
    await tmp.delete(recursive: true);
  });

  Future<void> roundTrip(FileHost host, {Duration lifetime = const Duration(days: 2)}) async {
    final c = HttpClient();
    final hosted = await host.upload(c, part, 'abc.zip', lifetime);
    expect(hosted.host, host.id);
    expect(hosted.size, partBytes.length);
    expect(hosted.sha256, sha256Hex(partBytes));
    final out = File(p.join(tmp.path, 'out_${host.id}'));
    await host.download(c, HostedPart.fromJson(hosted.toJson()), out);
    expect(await out.readAsBytes(), partBytes);
    c.close();
  }

  test('filebin: raw upload with checksum, expiry from the reply, delete', () async {
    final host = FilebinHost(base: Uri.parse('${base()}/fb/'));
    await roundTrip(host);
    final c = HttpClient();
    final hosted = await host.upload(c, part, 'abc.zip', const Duration(days: 1));
    expect(hosted.expires, DateTime.parse('2030-01-08T12:00:00Z'));
    final count = stored.length;
    await host.delete(c, hosted);
    expect(stored.length, count - 1);
    c.close();
  });

  test('temp.sh: multipart upload, download via POST behind the HTML page', () async {
    final host = TempShHost(base: Uri.parse('${base()}/ts/'));
    await roundTrip(host);
    expect(requests.where((r) => r.startsWith('POST /ts/x1/')), isNotEmpty);
  });

  test('litterbox: multipart upload with time field', () async {
    final host = LitterboxHost(api: Uri.parse('${base()}/lb/api.php'), linkHosts: ['127.0.0.1']);
    await roundTrip(host);
    expect(lastTime, '72h', reason: 'two days need the 72h option');
  });

  test('a failing upload is reported with the host name', () async {
    final host = FilebinHost(base: Uri.parse('${base()}/nope/'));
    final c = HttpClient();
    await expectLater(host.upload(c, part, 'abc.zip', const Duration(days: 1)),
        throwsA(isA<HostException>().having((e) => e.args['host'], 'host', 'filebin.net')));
    c.close();
  });

  test('a link reply pointing to another domain is refused', () async {
    final host = LitterboxHost(api: Uri.parse('${base()}/lb/api.php'), linkHosts: ['files.catbox.moe']);
    final c = HttpClient();
    await expectLater(host.upload(c, part, 'abc.zip', const Duration(days: 1)), throwsA(isA<HostException>()));
    c.close();
  });

  group('termbin', () {
    late ServerSocket tcp;
    late HttpServer web;
    final pastes = <String, String>{};

    Future<List<int>> plainExchange(String host, int port, List<int> data) async {
      final s = await Socket.connect(host, port);
      final reply = <int>[];
      final done = s.listen(reply.addAll).asFuture<void>();
      s.add(data);
      await s.flush(); // no half-close: the server answers after an idle pause
      await done;
      s.destroy();
      return reply;
    }

    setUp(() async {
      pastes.clear();
      web = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      web.listen((r) async {
        final text = pastes[r.uri.path.substring(1)];
        if (text == null) {
          r.response.statusCode = 404;
        } else {
          r.response.write(text);
        }
        await r.response.close();
      });
      tcp = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      tcp.listen((c) async {
        // Like fiche: read until the client is idle (fiche waits 5 s, here 300 ms).
        final input = await readUntilIdle(c);
        final text = utf8.decode(input);
        expect(text.length, lessThan(32768), reason: 'termbin buffer');
        final slug = randomHex(3);
        pastes[slug] = text;
        c.write('http://127.0.0.1:${web.port}/$slug\n');
        await c.close();
      });
    });

    tearDown(() async {
      await tcp.close();
      await web.close(force: true);
    });

    TermbinHost host() => TermbinHost(
        tcp: plainExchange,
        server: '127.0.0.1',
        port: tcp.port,
        linkHosts: ['127.0.0.1'],
        allowHttpForTests: true);

    test('upload as base64 text and download back', () async {
      final small = File(p.join(tmp.path, 'small.zip'))..writeAsBytesSync(randomBytes(20000));
      final h = host();
      final c = HttpClient();
      final hosted = await h.upload(c, small, 'small.zip', const Duration(days: 1));
      expect(hosted.size, 20000);
      expect(pastes.values.single.trim(), base64.encode(small.readAsBytesSync()));
      final out = File(p.join(tmp.path, 'back'));
      await h.download(c, hosted, out);
      expect(out.readAsBytesSync(), small.readAsBytesSync());
      c.close();
    });

    test('parts above the limit are refused before sending', () async {
      final big = File(p.join(tmp.path, 'big.zip'))..writeAsBytesSync(randomBytes(30000));
      await expectLater(host().upload(HttpClient(), big, 'big.zip', const Duration(days: 1)),
          throwsA(isA<HostException>()));
      expect(pastes, isEmpty);
    });
  });

  test('real hosts are configured with https and sensible limits', () {
    for (final h in defaultHosts()) {
      expect(h.maxBytes, greaterThanOrEqualTo(256 * 1024 * 1024), reason: h.id);
      expect(h.maxRetention, greaterThanOrEqualTo(const Duration(days: 3)), reason: h.id);
      expect(() => h.checkLink('http://${h.linkHosts.first}/x'), throwsA(isA<HostException>()));
    }
  });
}
