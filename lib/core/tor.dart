import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'crypto_util.dart';
import 'remote.dart';

class TorException extends RemoteException {
  TorException(super.template, [super.args]);
}

/// All network traffic of RedCourier goes through Tor, in one of two ways
/// (like CalSec):
///
/// * **SOCKS proxy (default).** Every connection is opened through Tor's
///   SOCKS5 port, like `socks5h://127.0.0.1:9050`: host names are sent to Tor
///   unresolved (no DNS leaks, .onion works). HTTPS is set up on top of the
///   SOCKS connection, so Tor only sees encrypted data. There is no local
///   listening port. Each local group sends its own SOCKS credentials, which
///   makes Tor use separate circuits per group.
/// * **torsocks.** If the app was started with `torsocks`, every connect()
///   is already redirected into Tor and DNS is resolved by Tor. torsocks
///   rejects connections to 127.0.0.1, including Tor's own SOCKS port, so
///   the app then connects normally and lets torsocks do the work. Before
///   the first connection it checks once that traffic really arrives through
///   Tor. torsocks cannot separate circuits per group.
///
/// Tor is found on 127.0.0.1:9050 (Tails, tor service, Orbot) or :9150
/// (Tor Browser) unless a port is configured. Without Tor nothing connects.
class TorNetwork {
  static const host = '127.0.0.1';
  static const autoPorts = [9050, 9150];

  /// null = try [autoPorts].
  static int? configuredPort;

  /// Separates Tor circuits between the groups on this device.
  static String isolationKey = 'default';

  /// Sent as User-Agent on every HTTP request: the one Tor Browser sends,
  /// so servers do not see "RedCourier" or Dart's default.
  static const userAgent = 'Mozilla/5.0 (Windows NT 10.0; rv:140.0) Gecko/20100101 Firefox/140.0';

  /// Answers whether a request arrived through Tor (tests use a local server).
  static String checkUrl = 'https://check.torproject.org/api/ip';

  /// True if the app runs under torsocks (LD_PRELOAD).
  static bool underTorsocks = _detectTorsocks();

  /// TLS trust for connections through the SOCKS proxy. null = the system's
  /// root certificates; tests set a context with their own certificate.
  static SecurityContext? securityContext;

  static int? _activePort;
  static Future<String>? _torsocksCheck;

  static int? get activePort => _activePort;

  /// Makes direct connections impossible for all Dart code of the app.
  /// Called first thing in main():
  ///
  /// * every `HttpClient()` that any code creates (also code in packages)
  ///   connects through Tor, and proxy settings from the environment are
  ///   ignored;
  /// * every `Socket.connect` / `Socket.startConnect` to anything other than
  ///   Tor's SOCKS port on 127.0.0.1 fails with a [TorException].
  ///
  /// Under torsocks sockets are not restricted: torsocks routes every
  /// connection into Tor and itself refuses connections to 127.0.0.1.
  /// Native code in plugins is not covered; none of the plugins used
  /// connects to the network (see test/network_guard_test.dart).
  static void installGuard() {
    HttpOverrides.global = TorHttpOverrides();
    IOOverrides.global = TorIOOverrides();
  }

  /// Whether a raw socket to [target]:[port] may be opened.
  static bool isAllowedSocket(Object target, int port) {
    if (underTorsocks) return true;
    final ports = {...autoPorts, if (configuredPort != null) configuredPort!};
    if (!ports.contains(port)) return false;
    final address = target is InternetAddress ? target.address : '$target';
    return address == host || address == '::1';
  }

  static bool _detectTorsocks() {
    if (!Platform.isLinux) return false;
    final preload = Platform.environment['LD_PRELOAD'] ?? '';
    return preload.split(RegExp(r'[:\s]')).any((p) => p.toLowerCase().contains('torsocks'));
  }

  static String _isolation(String? isolation) =>
      sha256Hex(utf8.encode(isolation ?? isolationKey)).substring(0, 32);

  /// Creates an HttpClient whose traffic goes through Tor.
  /// Clients with different [isolation] keys (default: [isolationKey]) use
  /// separate Tor circuits. Throws [TorException] if Tor is not reachable.
  static Future<HttpClient> createHttpClient({String? isolation}) async {
    // Never take a proxy from the environment (http_proxy and friends).
    final client = HttpClient()
      ..findProxy = ((_) => 'DIRECT')
      ..userAgent = userAgent
      ..idleTimeout = const Duration(seconds: 10);
    if (underTorsocks) {
      await _verifyTorsocks();
      return client;
    }
    final socksPort = await findSocksPort();
    final iso = _isolation(isolation);
    client.connectionFactory = (uri, proxyHost, proxyPort) => _connectionTask(uri, socksPort, iso);
    return client;
  }

  static Future<ConnectionTask<Socket>> _connectionTask(Uri uri, int socksPort, String iso) async {
    final secure = uri.scheme == 'https';
    final port = uri.hasPort ? uri.port : (secure ? 443 : 80);
    _SocksConnection? conn;
    var cancelled = false;
    Future<Socket> connect() async {
      final c = conn = await _socksConnect(uri.host, port, iso, socksPort);
      if (cancelled) {
        c.socket.destroy();
        throw const SocketException('Connection cancelled');
      }
      // TLS runs end to end on top of the Tor connection. The server only
      // speaks after the client hello, so no data is left in the handshake.
      if (secure) return SecureSocket.secure(c.socket, host: uri.host, context: securityContext);
      return _SocksSocket(c);
    }

    return ConnectionTask.fromSocket(connect(), () {
      cancelled = true;
      conn?.socket.destroy();
    });
  }

  /// Returns a working SOCKS port or throws [TorException].
  static Future<int> findSocksPort() async {
    final candidates = configuredPort != null ? [configuredPort!] : autoPorts;
    final ordered = [
      if (_activePort != null && candidates.contains(_activePort)) _activePort!,
      ...candidates.where((p) => p != _activePort),
    ];
    for (final port in ordered) {
      if (await _probe(port)) {
        _activePort = port;
        return port;
      }
    }
    _activePort = null;
    throw TorException(
        'Tor is not reachable on {ports}. Start Tor first: Tails does this automatically, '
        'on Windows start Tor Browser or the Tor service, on Android start Orbot.',
        {'ports': candidates.map((p) => '$host:$p').join(', ')});
  }

  static Future<bool> _probe(int port) async {
    Socket? s;
    try {
      s = await Socket.connect(host, port, timeout: const Duration(seconds: 3));
      final reply = Completer<List<int>>();
      final buf = <int>[];
      final sub = s.listen(
          (d) {
            buf.addAll(d);
            if (buf.length >= 2 && !reply.isCompleted) reply.complete(buf);
          },
          onError: (_) {},
          onDone: () {
            if (!reply.isCompleted) reply.complete(buf);
          });
      s.add([5, 1, 0]);
      final r = await reply.future.timeout(const Duration(seconds: 3), onTimeout: () => const []);
      await sub.cancel();
      return r.length >= 2 && r[0] == 5;
    } catch (_) {
      return false;
    } finally {
      s?.destroy();
    }
  }

  /// Opens a raw TCP connection through Tor, sends [data] and returns what
  /// the peer answers before it closes the connection. The connection stays
  /// open for writing: termbin's server answers after a few idle seconds,
  /// and half-closed connections are not reliable through Tor.
  /// Used for services without HTTP (termbin.com).
  static Future<Uint8List> tcpExchange(String targetHost, int port, List<int> data,
      {String? isolation, int maxReply = 64 * 1024}) async {
    final _SocksConnection conn;
    try {
      if (underTorsocks) {
        await _verifyTorsocks();
        final s = await Socket.connect(targetHost, port, timeout: const Duration(seconds: 60));
        conn = _SocksConnection.listen(s);
      } else {
        final socksPort = await findSocksPort();
        conn = await _socksConnect(targetHost, port, _isolation(isolation), socksPort);
      }
    } on TorException {
      rethrow;
    } catch (e) {
      throw TorException('Tor could not connect to {host}: {reason}', {'host': targetHost, 'reason': e});
    }
    try {
      final reply = conn.readAll(maxReply);
      conn.socket.add(data);
      await conn.socket.flush();
      return await reply.timeout(const Duration(seconds: 120));
    } finally {
      conn.socket.destroy();
    }
  }

  /// Asks the Tor Project whether our traffic arrives through Tor.
  /// Returns the exit IP address.
  static Future<String> check() async {
    if (underTorsocks) {
      _torsocksCheck = null; // check again on request
      return _verifyTorsocks();
    }
    return _checkIsTor(await createHttpClient());
  }

  /// Under torsocks the app cannot see where its connections go, so it asks
  /// once per run before anything else is sent.
  static Future<String> _verifyTorsocks() {
    final running = _torsocksCheck ??= _checkIsTor(HttpClient()..findProxy = ((_) => 'DIRECT'));
    return running.catchError((Object e) {
      _torsocksCheck = null;
      throw e;
    });
  }

  static Future<String> _checkIsTor(HttpClient client) async {
    try {
      final req = await client.getUrl(Uri.parse(checkUrl));
      final res = await req.close().timeout(const Duration(seconds: 60));
      final body = await utf8.decodeStream(res);
      final json = jsonDecode(body) as Map<String, dynamic>;
      if (json['IsTor'] != true) {
        throw TorException('The connection does not go through Tor.');
      }
      return json['IP'] as String? ?? '?';
    } on TorException {
      rethrow;
    } catch (e) {
      throw TorException('Tor check failed: {reason}', {'reason': e});
    } finally {
      client.close(force: true);
    }
  }
}

/// Routes every HttpClient of the process through Tor (see
/// [TorNetwork.installGuard]). Clients from [TorNetwork.createHttpClient]
/// replace the connection factory with one that adds their isolation key.
class TorHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context)
      ..findProxy = ((_) => 'DIRECT')
      ..userAgent = TorNetwork.userAgent;
    if (!TorNetwork.underTorsocks) {
      client.connectionFactory = (uri, proxyHost, proxyPort) async =>
          TorNetwork._connectionTask(uri, await TorNetwork.findSocksPort(), TorNetwork._isolation(null));
    }
    return client;
  }

  @override
  String findProxyFromEnvironment(Uri url, Map<String, String>? environment) => 'DIRECT';
}

/// Refuses every socket that does not go to Tor (see [TorNetwork.installGuard]).
final class TorIOOverrides extends IOOverrides {
  Never _blocked(Object host, int port) => throw TorException(
      'Blocked a direct connection to {target}. RedCourier only connects through Tor.',
      {'target': '$host:$port'});

  @override
  Future<Socket> socketConnect(host, int port, {sourceAddress, int sourcePort = 0, Duration? timeout}) {
    if (!TorNetwork.isAllowedSocket(host as Object, port)) return Future.sync(() => _blocked(host, port));
    return super
        .socketConnect(host, port, sourceAddress: sourceAddress, sourcePort: sourcePort, timeout: timeout);
  }

  @override
  Future<ConnectionTask<Socket>> socketStartConnect(host, int port, {sourceAddress, int sourcePort = 0}) {
    if (!TorNetwork.isAllowedSocket(host as Object, port)) return Future.sync(() => _blocked(host, port));
    return super.socketStartConnect(host, port, sourceAddress: sourceAddress, sourcePort: sourcePort);
  }
}

/// Opens a SOCKS5 connection with remote DNS (like socks5h), past the
/// handshake. [isolation] is sent as SOCKS password; Tor builds separate
/// circuits for different credentials.
Future<_SocksConnection> _socksConnect(String host, int port, String isolation, int socksPort) async {
  final s = await Socket.connect(TorNetwork.host, socksPort, timeout: const Duration(seconds: 10));
  final conn = _SocksConnection.listen(s);
  try {
    s.add([5, 2, 0, 2]); // no auth, username/password
    final m = await conn.read(2);
    if (m[0] != 5) throw const SocketException('Not a SOCKS5 server');
    if (m[1] == 2) {
      final user = utf8.encode('redcourier');
      final pass = utf8.encode(isolation);
      s.add([1, user.length, ...user, pass.length, ...pass]);
      final a = await conn.read(2);
      if (a[1] != 0) throw const SocketException('SOCKS authentication failed');
    } else if (m[1] != 0) {
      throw const SocketException('No acceptable SOCKS method');
    }
    final hostBytes = utf8.encode(host);
    if (hostBytes.isEmpty || hostBytes.length > 255) throw const SocketException('Invalid host name');
    s.add([5, 1, 0, 3, hostBytes.length, ...hostBytes, port >> 8, port & 0xff]);
    final r = await conn.read(4);
    if (r[1] != 0) {
      throw SocketException('Tor could not reach $host:$port (SOCKS error ${r[1]})');
    }
    final addrLen = switch (r[3]) { 1 => 4, 4 => 16, 3 => (await conn.read(1))[0], _ => 0 };
    await conn.read(addrLen + 2);
  } catch (e) {
    await conn.cancel();
    s.destroy();
    rethrow;
  }
  return conn;
}

/// A socket with its single subscription, used for the SOCKS handshake and
/// afterwards handed on.
class _SocksConnection {
  final Socket socket;
  final StreamSubscription<Uint8List> sub;
  final List<int> buffer = [];
  Completer<void>? _waiting;
  Object? _error;
  bool _done = false;

  _SocksConnection._(this.socket, this.sub);

  factory _SocksConnection.listen(Socket s) {
    late _SocksConnection c;
    final sub = s.listen((d) {
      c.buffer.addAll(d);
      c._wake();
    }, onError: (Object e) {
      c._error = e;
      c._wake();
    }, onDone: () {
      c._done = true;
      c._wake();
    });
    return c = _SocksConnection._(s, sub);
  }

  void _wake() {
    final w = _waiting;
    _waiting = null;
    if (w != null && !w.isCompleted) w.complete();
  }

  Future<List<int>> read(int n) async {
    while (buffer.length < n) {
      if (_error != null) throw _error!;
      if (_done) throw const SocketException('Tor closed the connection');
      await (_waiting = Completer<void>()).future.timeout(const Duration(seconds: 90));
    }
    final out = buffer.sublist(0, n);
    buffer.removeRange(0, n);
    return out;
  }

  Future<void> cancel() => sub.cancel();

  /// Collects everything the peer sends until it closes (at most [max] bytes).
  Future<Uint8List> readAll(int max) {
    final out = BytesBuilder()..add(buffer);
    buffer.clear();
    final done = Completer<Uint8List>();
    sub
      ..onData((d) {
        out.add(d);
        if (out.length > max && !done.isCompleted) {
          done.completeError(const SocketException('Reply too large'));
          socket.destroy();
        }
      })
      ..onError((Object e) {
        if (!done.isCompleted) done.completeError(e);
      })
      ..onDone(() {
        if (!done.isCompleted) done.complete(out.takeBytes());
      });
    return done.future;
  }
}

/// Plain (non-TLS) connection through Tor, for http:// URLs such as .onion
/// WebDAV servers. The socket's stream was already used for the SOCKS
/// handshake, so reading continues through that subscription.
class _SocksSocket extends Stream<Uint8List> implements Socket {
  final Socket _inner;
  final StreamController<Uint8List> _in;

  _SocksSocket(_SocksConnection c)
      : _inner = c.socket,
        _in = StreamController<Uint8List>() {
    c.sub.pause();
    _in
      ..onListen = c.sub.resume
      ..onPause = c.sub.pause
      ..onResume = c.sub.resume
      ..onCancel = c.sub.cancel;
    if (c.buffer.isNotEmpty) _in.add(Uint8List.fromList(c.buffer));
    c.buffer.clear();
    c.sub
      ..onData(_in.add)
      ..onError(_in.addError)
      ..onDone(_in.close);
  }

  @override
  StreamSubscription<Uint8List> listen(void Function(Uint8List event)? onData,
          {Function? onError, void Function()? onDone, bool? cancelOnError}) =>
      _in.stream.listen(onData, onError: onError, onDone: onDone, cancelOnError: cancelOnError);

  @override
  Encoding get encoding => _inner.encoding;
  @override
  set encoding(Encoding value) => _inner.encoding = value;
  @override
  void add(List<int> data) => _inner.add(data);
  @override
  void addError(Object error, [StackTrace? stackTrace]) => _inner.addError(error, stackTrace);
  @override
  Future addStream(Stream<List<int>> stream) => _inner.addStream(stream);
  @override
  Future close() => _inner.close();
  @override
  Future get done => _inner.done;
  @override
  Future flush() => _inner.flush();
  @override
  void write(Object? object) => _inner.write(object);
  @override
  void writeAll(Iterable objects, [String separator = '']) => _inner.writeAll(objects, separator);
  @override
  void writeln([Object? object = '']) => _inner.writeln(object);
  @override
  void writeCharCode(int charCode) => _inner.writeCharCode(charCode);
  @override
  InternetAddress get address => _inner.address;
  @override
  int get port => _inner.port;
  @override
  InternetAddress get remoteAddress => _inner.remoteAddress;
  @override
  int get remotePort => _inner.remotePort;
  @override
  bool setOption(SocketOption option, bool enabled) => _inner.setOption(option, enabled);
  @override
  Uint8List getRawOption(RawSocketOption option) => _inner.getRawOption(option);
  @override
  void setRawOption(RawSocketOption option) => _inner.setRawOption(option);
  @override
  void destroy() => _inner.destroy();
}
