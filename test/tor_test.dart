import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:redcourier/core/tor.dart';

/// Self-signed certificate for "localhost" (test only).
const testCert = '''-----BEGIN CERTIFICATE-----
MIIBlDCCATugAwIBAgIUYp8TI+T0lwJCp1QSQr8IpHAXZ3cwCgYIKoZIzj0EAwIw
FDESMBAGA1UEAwwJbG9jYWxob3N0MCAXDTI2MTAxMTE2NDkzMFoYDzIxMjYwOTE3
MTY0OTMwWjAUMRIwEAYDVQQDDAlsb2NhbGhvc3QwWTATBgcqhkjOPQIBBggqhkjO
PQMBBwNCAATBUu2P/n3gMMxcmKjB6WZcDZAgiYMgx0hRg5ub1iOdxayhFNQbPKqQ
uPGExxci4jnrpMOp2hlQCLvNzQOchCXvo2kwZzAdBgNVHQ4EFgQU+hSEJskkbGVc
Yh2spDkZglI1vFgwHwYDVR0jBBgwFoAU+hSEJskkbGVcYh2spDkZglI1vFgwDwYD
VR0TAQH/BAUwAwEB/zAUBgNVHREEDTALgglsb2NhbGhvc3QwCgYIKoZIzj0EAwID
RwAwRAIgJuvGgQWOEmpgXDuma0aCPXX5hIm4r+QYDbUtvE8bVaACIDKmK+Vpc7XV
xlp9SiWzrlvzRCvp0Xo5URCgcoBkZYJP
-----END CERTIFICATE-----
''';

const testKey = '''-----BEGIN PRIVATE KEY-----
MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgjObGJGDSpS3lC9H8
MRPtlT+6nKvr6cJeNnCOe84AnXyhRANCAATBUu2P/n3gMMxcmKjB6WZcDZAgiYMg
x0hRg5ub1iOdxayhFNQbPKqQuPGExxci4jnrpMOp2hlQCLvNzQOchCXv
-----END PRIVATE KEY-----
''';

/// Minimal SOCKS5 server that resolves "localhost" itself and records what
/// clients asked for.
class FakeSocks {
  final ServerSocket server;
  final requests = <String>[];
  final users = <String>[];
  FakeSocks(this.server) {
    server.listen(_handle);
  }
  int get port => server.port;

  void _handle(Socket c) {
    final buf = <int>[];
    var stage = 0;
    Socket? target;
    c.listen((d) async {
      if (target != null) {
        target!.add(d);
        return;
      }
      buf.addAll(d);
      if (stage == 0 && buf.length >= 2 && buf.length >= 2 + buf[1]) {
        buf.removeRange(0, 2 + buf[1]);
        c.add([5, 2]);
        stage = 1;
      }
      if (stage == 1 && buf.length >= 2) {
        final ulen = buf[1];
        if (buf.length < 3 + ulen) return;
        final plen = buf[2 + ulen];
        if (buf.length < 3 + ulen + plen) return;
        users.add('${utf8.decode(buf.sublist(2, 2 + ulen))}:${utf8.decode(buf.sublist(3 + ulen, 3 + ulen + plen))}');
        buf.removeRange(0, 3 + ulen + plen);
        c.add([1, 0]);
        stage = 2;
      }
      if (stage == 2 && buf.length >= 5) {
        expect(buf[3], 3, reason: 'host names must be sent to the SOCKS server (remote DNS)');
        final len = buf[4];
        if (buf.length < 7 + len) return;
        final host = utf8.decode(buf.sublist(5, 5 + len));
        final port = (buf[5 + len] << 8) | buf[6 + len];
        buf.removeRange(0, 7 + len);
        requests.add('$host:$port');
        stage = 3;
        if (host != 'localhost') {
          c.add([5, 4, 0, 1, 0, 0, 0, 0, 0, 0]);
          await c.close();
          return;
        }
        final t = await Socket.connect('127.0.0.1', port);
        target = t;
        c.add([5, 0, 0, 1, 127, 0, 0, 1, 0, 0]);
        if (buf.isNotEmpty) t.add(List.of(buf));
        t.listen(c.add, onDone: () => c.destroy(), onError: (_) => c.destroy());
      }
    }, onDone: () => target?.destroy(), onError: (_) => target?.destroy());
  }
}

void main() {
  late FakeSocks socks;
  late HttpServer web;
  String? lastUserAgent;

  setUp(() async {
    socks = FakeSocks(await ServerSocket.bind(InternetAddress.loopbackIPv4, 0));
    web = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    web.listen((r) async {
      final body = await utf8.decodeStream(r);
      lastUserAgent = r.headers.value(HttpHeaders.userAgentHeader);
      r.response.write('${r.method} ${r.uri.path} $body');
      await r.response.close();
    });
    TorNetwork.configuredPort = socks.port;
    TorNetwork.isolationKey = 'work';
  });

  tearDown(() async {
    await web.close(force: true);
    await socks.server.close();
  });

  test('plain HTTP goes through SOCKS with remote DNS and per-group isolation', () async {
    final client = await TorNetwork.createHttpClient();
    final req = await client.postUrl(Uri.parse('http://localhost:${web.port}/x'));
    req.write('payload');
    final res = await req.close();
    expect(await utf8.decodeStream(res), 'POST /x payload');
    expect(lastUserAgent, TorNetwork.userAgent, reason: 'looks like Tor Browser, not like the app');
    client.close();
    expect(socks.requests, ['localhost:${web.port}']);
    expect(socks.users.single, startsWith('redcourier:'));

    TorNetwork.isolationKey = 'private';
    final c2 = await TorNetwork.createHttpClient();
    await (await (await c2.getUrl(Uri.parse('http://localhost:${web.port}/'))).close()).drain<void>();
    c2.close();
    expect(socks.users[1], isNot(socks.users[0]), reason: 'groups use different circuits');
  });

  test('HTTPS runs end to end on top of the SOCKS connection', () async {
    final serverCtx = SecurityContext()
      ..useCertificateChainBytes(utf8.encode(testCert))
      ..usePrivateKeyBytes(utf8.encode(testKey));
    final tls = await HttpServer.bindSecure(InternetAddress.loopbackIPv4, 0, serverCtx);
    tls.listen((r) async {
      r.response.write('secure ${r.uri.path}');
      await r.response.close();
    });
    TorNetwork.securityContext = SecurityContext(withTrustedRoots: false)
      ..setTrustedCertificatesBytes(utf8.encode(testCert));
    try {
      final client = await TorNetwork.createHttpClient();
      final res = await (await client.getUrl(Uri.parse('https://localhost:${tls.port}/x'))).close();
      expect(await utf8.decodeStream(res), 'secure /x');
      client.close();
      expect(socks.requests, ['localhost:${tls.port}'], reason: 'the host name goes to Tor unresolved');

      // A certificate that does not match is still refused.
      TorNetwork.securityContext = SecurityContext(withTrustedRoots: false);
      final c2 = await TorNetwork.createHttpClient();
      await expectLater(() async => (await c2.getUrl(Uri.parse('https://localhost:${tls.port}/'))).close(),
          throwsA(isA<HandshakeException>()));
      c2.close(force: true);
    } finally {
      TorNetwork.securityContext = null;
      await tls.close(force: true);
    }
  });

  test('a failed Tor connection becomes an error, never a direct connection', () async {
    final client = await TorNetwork.createHttpClient();
    await expectLater(
        () async => (await client.getUrl(Uri.parse('http://unreachable.example:81/'))).close(),
        throwsA(isA<SocketException>()));
    client.close();
    expect(socks.requests, ['unreachable.example:81']);
  });

  test('raw TCP exchange (termbin) goes through SOCKS with remote DNS', () async {
    final echo = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    echo.listen((c) {
      // Like termbin: answer after the client has been idle for a moment.
      final input = <int>[];
      Timer? idle;
      c.listen((d) {
        input.addAll(d);
        idle?.cancel();
        idle = Timer(const Duration(milliseconds: 300), () async {
          c.write('got ${input.length} bytes');
          await c.close();
        });
      });
    });
    final reply = await TorNetwork.tcpExchange('localhost', echo.port, List.filled(5000, 65));
    expect(utf8.decode(reply), 'got 5000 bytes');
    expect(socks.requests.last, 'localhost:${echo.port}');
    await echo.close();
  });

  test('the guard routes every HttpClient through Tor and blocks direct sockets', () async {
    // Zones instead of the global overrides, so the fake Tor and web servers
    // of this test (set up outside the zone) can still connect.
    await HttpOverrides.runWithHttpOverrides(() async {
      await IOOverrides.runWithIOOverrides(() async {
        // A plain HttpClient, as a careless package would create it.
        final client = HttpClient();
        final res = await (await client.getUrl(Uri.parse('http://localhost:${web.port}/plain'))).close();
        expect(await utf8.decodeStream(res), 'GET /plain ');
        client.close();
        expect(socks.requests, ['localhost:${web.port}'], reason: 'it went through Tor');

        // Direct sockets are refused, by name and by address.
        await expectLater(Socket.connect('127.0.0.1', web.port), throwsA(isA<TorException>()));
        await expectLater(Socket.connect('example.org', 443), throwsA(isA<TorException>()));
        await expectLater(Socket.startConnect(InternetAddress('93.184.215.14'), 80),
            throwsA(isA<TorException>()));
        expect(socks.requests, hasLength(1), reason: 'nothing else left the device');

        // The Tor SOCKS port itself stays reachable.
        final s = await Socket.connect('127.0.0.1', socks.port);
        s.destroy();
      }, TorIOOverrides());
    }, TorHttpOverrides());
  });

  test('missing Tor is reported clearly', () async {
    final unused = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = unused.port;
    await unused.close();
    TorNetwork.configuredPort = port;
    await expectLater(TorNetwork.createHttpClient(), throwsA(isA<TorException>()));
  });
}
