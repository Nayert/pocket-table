import 'dart:math';

import 'player.dart';
import 'screen.dart';

/// What a player did, already checked by the platform against the screen
/// they were shown: right actionId, option ids that were on it, number in range.
class PlayerAction {
  const PlayerAction({required this.actionId, this.choice = const [], this.value});
  final String actionId;
  final List<String> choice;

  /// Number (or text) typed in, if the screen or option asked for one.
  final Object? value;

  String? get first => choice.isEmpty ? null : choice.first;
  int? get intValue => value is num ? (value as num).round() : null;
}

class ActionResult {
  const ActionResult.ok() : error = null;
  const ActionResult.error(String this.error);
  final String? error;
  bool get ok => error == null;
}

/// Services the platform gives a running game.
abstract class GameContext {
  /// Call after the game changes state by itself (e.g. a timer ran out),
  /// so the platform sends everyone their updated screen.
  void requestUpdate();

  /// Cryptographically secure random source. Use it for shuffling and roles.
  Random get random;
}

/// A host-adjustable setting shown in the lobby.
class GameSetting {
  const GameSetting.integer(this.key, this.label, {required int defaultValue, required this.min, required this.max, this.step = 1})
      : defaultValue = defaultValue,
        isBool = false;
  const GameSetting.toggle(this.key, this.label, {required bool defaultValue})
      : defaultValue = defaultValue,
        isBool = true,
        min = 0,
        max = 1,
        step = 1;

  final String key;
  final String label;
  final Object defaultValue;
  final bool isBool;
  final int min;
  final int max;
  final int step;
}

/// Every game implements this. The platform only ever talks to games
/// through it, so adding a game never means changing the core.
///
/// publicState() is drawn on the host's table/TV view by the host app.
/// Use these keys (all optional):
///   'title':       String  big heading, e.g. "Night 2" or "Flop"
///   'subtitle':    String
///   'banner':      String  very large text, e.g. "Town wins!"
///   'secondsLeft': int     countdown
///   'cards':       List<String>  face-up cards ("As", "Td"; "??" = face down)
///   'rows':        List<Map> each {'label', 'value', 'highlight': bool, 'dim': bool}
///   'log':         List<String>  most recent last
/// It must NEVER contain private information (roles, hole cards) until the
/// game reveals it to everyone.
abstract class Game {
  String get id;
  String get displayName;
  String get description;
  int get minPlayers;
  int get maxPlayers;
  List<GameSetting> get settings => const [];

  void start(GameContext ctx, List<Player> players, Map<String, Object> settings);

  /// Check the move is legal for this game state, then apply it.
  ActionResult handleAction(String playerId, PlayerAction action);

  Map<String, dynamic> publicState();

  /// What this one player should see right now. Only ever sent to them.
  Screen privateState(String playerId);

  bool get isOver;

  void onPlayerConnectionChanged(String playerId, bool connected) {}

  /// Cancel timers etc. Called when the game ends or the host quits.
  void dispose() {}
}

typedef GameFactory = Game Function();

/// Seconds left until [deadline], or null if there is none.
int? secondsUntil(DateTime? deadline) {
  if (deadline == null) return null;
  final s = (deadline.difference(DateTime.now()).inMilliseconds / 1000).ceil();
  return s < 0 ? 0 : s;
}
