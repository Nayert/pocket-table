import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'transport_base.dart';

/// Connects to the relay server as the host of a room.
/// If the connection drops it keeps retrying with room.resume, so players
/// keep their seats as long as the relay's grace period hasn't run out.
class OnlineTransport implements Transport {
  OnlineTransport({required String relayUrl, this.maxPlayers = 20})
      : _wsUrl = _toWsUrl(relayUrl);

  final String _wsUrl;
  final int maxPlayers;

  WebSocket? _ws;
  bool _stopped = false;
  bool _reconnecting = false;
  String? _room;
  String? _hostToken;
  final _connIds = <String>{};

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

  static String _toWsUrl(String url) {
    var u = url.trim();
    if (u.endsWith('/')) u = u.substring(0, u.length - 1);
    if (u.startsWith('https://')) {
      u = 'wss://${u.substring(8)}';
    } else if (u.startsWith('http://')) {
      u = 'ws://${u.substring(7)}';
    } else if (!u.startsWith('ws://') && !u.startsWith('wss://')) {
      u = 'wss://$u';
    }
    return '$u/ws/host';
  }

  void _setStatus(TransportStatus s) {
    _status = s;
    _statusCtl.add(s);
  }

  @override
  Future<JoinInfo> start() async {
    _stopped = false;
    _setStatus(TransportStatus.connecting);
    final reply = await _open({
      'v': protocolVersion,
      'type': 'room.create',
      'payload': {'v': protocolVersion, 'maxPlayers': maxPlayers},
    });
    final p = (reply['payload'] as Map?)?.cast<String, dynamic>() ?? {};
    if (reply['type'] != 'room.created') {
      _setStatus(TransportStatus.failed);
      throw StateError(_reason(p['reason']));
    }
    _room = p['room'] as String;
    _hostToken = p['hostToken'] as String;
    _joinInfo = JoinInfo(url: p['joinUrl'] as String, roomCode: _room!, mode: 'Online');
    _setStatus(TransportStatus.connected);
    return _joinInfo!;
  }

  String _reason(Object? r) => switch (r) {
        'version_mismatch' => 'The relay server runs a different protocol version. Update the app or the server.',
        'server_full' => 'The relay server is full. Try again later.',
        'room_not_found' => 'The room has expired.',
        _ => 'The relay server refused the room ($r).',
      };

  /// Connect, send [first], and return the relay's first reply.
  /// Later messages go to [_onRelayMessage].
  Future<Map<String, dynamic>> _open(Map<String, dynamic> first) async {
    final ws = await WebSocket.connect(_wsUrl).timeout(const Duration(seconds: 10));
    ws.pingInterval = const Duration(seconds: 15);
    _ws = ws;
    final reply = Completer<Map<String, dynamic>>();
    ws.listen(
      (data) {
        final msg = decodeFrame(data);
        if (msg == null) return;
        if (!reply.isCompleted) {
          reply.complete(msg);
        } else {
          _onRelayMessage(msg);
        }
      },
      onDone: () {
        if (!reply.isCompleted) reply.completeError(const SocketException('Relay closed the connection'));
        if (identical(_ws, ws)) _onDisconnected();
      },
      onError: (_) {},
    );
    ws.add(jsonEncode(first));
    try {
      return await reply.future.timeout(const Duration(seconds: 10));
    } catch (_) {
      if (identical(_ws, ws)) _ws = null;
      await ws.close();
      rethrow;
    }
  }

  void _onRelayMessage(Map<String, dynamic> msg) {
    final type = msg['type'];
    final p = (msg['payload'] as Map?)?.cast<String, dynamic>() ?? const {};
    switch (type) {
      case 'player.joined':
        final joined = p['connId'] as String;
        _connIds.add(joined);
        _joins.add(joined);
      case 'player.left':
        final left = p['connId'] as String;
        if (_connIds.remove(left)) _leaves.add(left);
      case 'room.closed':
        _stopped = true;
        _setStatus(TransportStatus.failed);
      default:
        final from = msg['from'];
        if (from is String && _connIds.contains(from)) {
          _messages.add(IncomingMessage(from, msg));
        }
    }
  }

  void _onDisconnected() {
    _ws = null;
    if (_stopped || _room == null || _reconnecting) return;
    _setStatus(TransportStatus.reconnecting);
    _reconnect();
  }

  Future<void> _reconnect() async {
    _reconnecting = true;
    try {
      await _tryResume();
    } finally {
      _reconnecting = false;
    }
  }

  Future<void> _tryResume() async {
    var delay = const Duration(seconds: 1);
    final giveUpAt = DateTime.now().add(const Duration(minutes: 2)); // relay grace period
    while (!_stopped && DateTime.now().isBefore(giveUpAt)) {
      try {
        final reply = await _open({
          'v': protocolVersion,
          'type': 'room.resume',
          'payload': {'room': _room, 'hostToken': _hostToken},
        });
        if (reply['type'] != 'room.resumed') break;
        final p = (reply['payload'] as Map).cast<String, dynamic>();
        final now = ((p['players'] as List?) ?? const []).cast<String>().toSet();
        // Players who left or joined while we were away.
        for (final gone in _connIds.difference(now).toList()) {
          _connIds.remove(gone);
          _leaves.add(gone);
        }
        for (final fresh in now.difference(_connIds)) {
          _connIds.add(fresh);
          _joins.add(fresh);
        }
        _setStatus(TransportStatus.connected);
        return;
      } catch (_) {
        await Future<void>.delayed(delay);
        delay = Duration(seconds: min(delay.inSeconds * 2, 10));
      }
    }
    if (!_stopped) _setStatus(TransportStatus.failed);
  }

  @override
  Future<void> stop() async {
    _stopped = true;
    await _ws?.close();
    _ws = null;
    _connIds.clear();
    _setStatus(TransportStatus.stopped);
  }

  void _send(Map<String, dynamic> message) => _ws?.add(jsonEncode(message));

  @override
  void sendTo(String connId, Map<String, dynamic> message) =>
      _send({...message, 'from': 'host', 'to': connId});

  @override
  void broadcast(Map<String, dynamic> message) =>
      _send({...message, 'from': 'host', 'to': 'all'});

  @override
  void disconnect(String connId) {
    _send({'v': protocolVersion, 'type': 'player.close', 'payload': {'connId': connId}});
    if (_connIds.remove(connId)) _leaves.add(connId);
  }
}
