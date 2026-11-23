/// A seat in the room. Survives disconnects: the player gets the same seat
/// back by sending their reconnect token.
class Player {
  Player({required this.id, required this.name, required this.reconnectToken});

  final String id;
  final String name;
  final String reconnectToken;

  /// Current transport connection, or null while disconnected.
  String? connId;

  bool get connected => connId != null;

  Map<String, dynamic> toLobbyJson() => {'id': id, 'name': name, 'connected': connected};
}
