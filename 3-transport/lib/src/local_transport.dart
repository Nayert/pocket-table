import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'transport_base.dart';

/// Loads a file of the player web page, e.g. "index.html" or "app.js".
/// Returns null if it doesn't exist. In Flutter this reads from app assets.
typedef AssetLoader = Future<List<int>?> Function(String path);

/// Runs an HTTP + WebSocket server on the host phone. Players on the same
/// Wi-Fi open http://<phone-ip>:<port>/ and the page connects back here.
class LocalTransport implements Transport {
  LocalTransport({required this.loadAsset, this.port = 8080, Random? random})
      : _rng = random ?? Random.secure();

  final AssetLoader loadAsset;
  final int port;
  final Random _rng;

  HttpServer? _server;
  final _sockets = <String, WebSocket>{};
  final _messages = StreamController<IncomingMessage>.broadcast();
  final _joins = StreamController<String>.broadcast();
  final _leaves = StreamController<String>.broadcast();
  final _statusCtl = StreamController<TransportStatus>.broadcast();

  JoinInfo? _joinInfo;
  TransportStatus _status = TransportStatus.stopped;

  @override
  JoinInfo? get joinInfo => _joinInfo;
  @override
  TransportStatus get status => _status;
  @override
  Stream<IncomingMessage> get onMessage => _messages.stream;
  @override
  Stream<String> get onJoin => _joins.stream;
  @override
  Stream<String> get onLeave => _leaves.stream;
  @override
  Stream<TransportStatus> get onStatus => _statusCtl.stream;

  void _setStatus(TransportStatus s) {
    _status = s;
    _statusCtl.add(s);
  }

  @override
  Future<JoinInfo> start() async {
    _setStatus(TransportStatus.connecting);
    try {
      _server = await HttpServer.bind(InternetAddress.anyIPv4, port);
    } on SocketException {
      _server = await HttpServer.bind(InternetAddress.anyIPv4, 0); // port in use: pick any
    }
    _server!.listen(_handleRequest, onError: (_) {});

    final ip = await findLocalIp();
    final code = randomCode(_rng);
    _joinInfo = JoinInfo(
      url: 'http://${ip ?? '127.0.0.1'}:${_server!.port}/?room=$code',
      roomCode: code,
      mode: 'Local',
      warning: ip == null ? 'No Wi-Fi network found. Connect to Wi-Fi or turn on your hotspot.' : null,
    );
    _setStatus(TransportStatus.connected);
    return _joinInfo!;
  }

  @override
  Future<void> stop() async {
    for (final ws in _sockets.values.toList()) {
      await ws.close();
    }
    _sockets.clear();
    await _server?.close(force: true);
    _server = null;
    _setStatus(TransportStatus.stopped);
  }

  @override
  void sendTo(String connId, Map<String, dynamic> message) {
    _sockets[connId]?.add(jsonEncode({...message, 'to': connId}));
  }

  @override
  void broadcast(Map<String, dynamic> message) {
    final text = jsonEncode({...message, 'to': 'all'});
    for (final ws in _sockets.values) {
      ws.add(text);
    }
  }

  @override
  void disconnect(String connId) {
    final ws = _sockets.remove(connId);
    if (ws != null) {
      ws.close();
      _leaves.add(connId);
    }
  }

  Future<void> _handleRequest(HttpRequest req) async {
    try {
      if (req.uri.path == '/ws/player' && WebSocketTransformer.isUpgradeRequest(req)) {
        final ws = await WebSocketTransformer.upgrade(req);
        _addSocket(ws);
        return;
      }
      if (req.method != 'GET') {
        req.response.statusCode = HttpStatus.methodNotAllowed;
        await req.response.close();
        return;
      }
      await _serveFile(req);
    } catch (_) {
      try {
        req.response.statusCode = HttpStatus.internalServerError;
        await req.response.close();
      } catch (_) {}
    }
  }

  void _addSocket(WebSocket ws) {
    ws.pingInterval = const Duration(seconds: 15);
    final id = randomId(_rng, 'c_');
    _sockets[id] = ws;
    _joins.add(id);
    ws.listen(
      (data) {
        final msg = decodeFrame(data);
        if (msg == null) return;
        msg['from'] = id; // players can't pretend to be someone else
        _messages.add(IncomingMessage(id, msg));
      },
      onDone: () {
        if (identical(_sockets[id], ws)) {
          _sockets.remove(id);
          _leaves.add(id);
        }
      },
      onError: (_) {},
    );
  }

  static const _types = {
    'html': 'text/html; charset=utf-8',
    'js': 'text/javascript; charset=utf-8',
    'css': 'text/css; charset=utf-8',
    'json': 'application/json',
    'png': 'image/png',
    'svg': 'image/svg+xml',
    'ico': 'image/x-icon',
  };

  Future<void> _serveFile(HttpRequest req) async {
    var path = req.uri.path;
    if (path == '/' || path.isEmpty) path = '/index.html';
    path = path.substring(1);
    final bytes = path.contains('..') ? null : await loadAsset(path);
    final res = req.response;
    if (bytes == null) {
      res.statusCode = HttpStatus.notFound;
      res.write('Not found');
    } else {
      final ext = path.split('.').last.toLowerCase();
      res.headers.set(HttpHeaders.contentTypeHeader, _types[ext] ?? 'application/octet-stream');
      res.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');
      res.add(bytes);
    }
    await res.close();
  }

  /// The phone's address on the local network, preferring Wi-Fi/hotspot.
  static Future<String?> findLocalIp() async {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
    );
    int score(NetworkInterface i, InternetAddress a) {
      final n = i.name.toLowerCase();
      var s = 0;
      if (n.startsWith('wlan') || n.startsWith('en') || n.startsWith('ap') || n.contains('wifi')) s += 2;
      if (n.contains('rmnet') || n.contains('pdp') || n.contains('tun') || n.contains('utun')) s -= 3;
      final ip = a.address;
      if (ip.startsWith('192.168.') || ip.startsWith('10.') ||
          RegExp(r'^172\.(1[6-9]|2\d|3[01])\.').hasMatch(ip)) {
        s += 1;
      }
      return s;
    }

    String? best;
    var bestScore = -1 << 30;
    for (final i in interfaces) {
      for (final a in i.addresses) {
        final s = score(i, a);
        if (s > bestScore) {
          bestScore = s;
          best = a.address;
        }
      }
    }
    return best;
  }
}
