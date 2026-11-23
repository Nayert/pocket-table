import 'dart:convert';
import 'dart:math';

/// Must match PROTOCOL_VERSION in the relay and the player page.
const int protocolVersion = 1;

/// Biggest message accepted from a player, in bytes.
const int maxMessageBytes = 16 * 1024;

/// A message from one player connection.
class IncomingMessage {
  IncomingMessage(this.connId, this.message);

  /// Transport-level connection id. The platform core maps this to a player.
  final String connId;
  final Map<String, dynamic> message;

  String? get type => message['type'] as String?;
  Map<String, dynamic> get payload =>
      (message['payload'] as Map?)?.cast<String, dynamic>() ?? const {};
}

/// What the host UI shows so people can join.
class JoinInfo {
  const JoinInfo({required this.url, required this.roomCode, required this.mode, this.warning});

  /// Link for the QR code.
  final String url;

  /// Short code players can type in.
  final String roomCode;

  /// "Local" or "Online".
  final String mode;

  /// Something the host should know, e.g. "No Wi-Fi network found".
  final String? warning;
}

enum TransportStatus { stopped, connecting, connected, reconnecting, failed }

abstract class Transport {
  /// Open the server / connect to the relay. Throws if it can't.
  Future<JoinInfo> start();
  Future<void> stop();

  /// Send to one connection. Use this for anything private (roles, cards).
  void sendTo(String connId, Map<String, dynamic> message);

  /// Send to every connection. Never use this for private information.
  void broadcast(Map<String, dynamic> message);

  /// Drop a connection (kicked player, wrong protocol version).
  void disconnect(String connId);

  Stream<IncomingMessage> get onMessage;
  Stream<String> get onJoin;
  Stream<String> get onLeave;
  Stream<TransportStatus> get onStatus;

  JoinInfo? get joinInfo;
  TransportStatus get status;
}

// ---- helpers shared by the implementations ----

const _codeAlphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';

String randomCode(Random rng, [int length = 4]) =>
    List.generate(length, (_) => _codeAlphabet[rng.nextInt(_codeAlphabet.length)]).join();

String randomId(Random rng, String prefix) =>
    prefix + List.generate(8, (_) => rng.nextInt(16).toRadixString(16)).join();

/// Parse a socket frame into a JSON object, or null if it isn't one.
Map<String, dynamic>? decodeFrame(dynamic data) {
  if (data is! String || data.length > maxMessageBytes) return null;
  try {
    final decoded = jsonDecode(data);
    return decoded is Map ? decoded.cast<String, dynamic>() : null;
  } catch (_) {
    return null;
  }
}
