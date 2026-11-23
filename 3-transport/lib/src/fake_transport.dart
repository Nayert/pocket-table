import 'dart:async';

import 'transport_base.dart';

/// In-memory transport for tests: no sockets. Call [simulateJoin] etc. to
/// pretend to be players, and read [sent] to see what the host sent.
class FakeTransport implements Transport {
  final _messages = StreamController<IncomingMessage>.broadcast(sync: true);
  final _joins = StreamController<String>.broadcast(sync: true);
  final _leaves = StreamController<String>.broadcast(sync: true);
  final _statusCtl = StreamController<TransportStatus>.broadcast(sync: true);

  /// Every message sent, as (connId or "all", message).
  final sent = <(String, Map<String, dynamic>)>[];
  final connected = <String>{};
  TransportStatus _status = TransportStatus.stopped;

  @override
  JoinInfo? joinInfo;
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

  @override
  Future<JoinInfo> start() async {
    _status = TransportStatus.connected;
    return joinInfo = const JoinInfo(url: 'http://test/?room=TEST', roomCode: 'TEST', mode: 'Fake');
  }

  @override
  Future<void> stop() async {
    _status = TransportStatus.stopped;
  }

  @override
  void sendTo(String connId, Map<String, dynamic> message) => sent.add((connId, message));

  @override
  void broadcast(Map<String, dynamic> message) => sent.add(('all', message));

  @override
  void disconnect(String connId) {
    if (connected.remove(connId)) _leaves.add(connId);
  }

  void simulateJoin(String connId) {
    connected.add(connId);
    _joins.add(connId);
  }

  void simulateLeave(String connId) {
    if (connected.remove(connId)) _leaves.add(connId);
  }

  void simulateMessage(String connId, String type, [Map<String, dynamic> payload = const {}]) =>
      _messages.add(IncomingMessage(connId, {'v': protocolVersion, 'type': type, 'from': connId, 'payload': payload}));

  /// Messages a connection would have received (direct + broadcasts).
  List<Map<String, dynamic>> receivedBy(String connId) =>
      [for (final (to, m) in sent) if (to == connId || to == 'all') m];

  Map<String, dynamic>? lastTo(String connId, {String? type}) {
    final msgs = receivedBy(connId).where((m) => type == null || m['type'] == type).toList();
    return msgs.isEmpty ? null : msgs.last;
  }
}
