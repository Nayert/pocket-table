import 'dart:async';
import 'dart:math';

import 'package:transport/transport.dart';

import 'game.dart';
import 'player.dart';
import 'screen.dart';

/// Ties a transport, the lobby and the active game together.
/// The host UI reads its fields and listens to [changes].
class Platform implements GameContext {
  Platform({required List<GameFactory> games, this.maxPlayers = 20, Random? random})
      : _random = random ?? Random.secure(),
        _factories = games {
    for (final f in games) {
      final g = f();
      catalog.add(g);
      gameSettings[g.id] = {for (final s in g.settings) s.key: s.defaultValue};
    }
    selectedGameId = catalog.isEmpty ? null : catalog.first.id;
  }

  final int maxPlayers;
  final Random _random;
  final List<GameFactory> _factories;

  /// One instance of each game, used for names/settings in the lobby.
  final List<Game> catalog = [];
  final Map<String, Map<String, Object>> gameSettings = {};
  String? selectedGameId;

  /// Seats, in join order.
  final List<Player> players = [];
  final Map<String, String> _connToPlayer = {};

  Transport? _transport;
  final _subs = <StreamSubscription<dynamic>>[];
  JoinInfo? joinInfo;
  TransportStatus transportStatus = TransportStatus.stopped;

  Game? activeGame;
  final Set<String> _gamePlayerIds = {};
  final Map<String, Screen> _lastScreen = {};
  final Map<String, String> _lastSignature = {};
  Timer? _ticker;

  final _changes = StreamController<void>.broadcast();

  /// Fires whenever something the host UI shows may have changed.
  Stream<void> get changes => _changes.stream;
  void _notify() => _changes.add(null);

  Game? get selectedGame => catalog.where((g) => g.id == selectedGameId).firstOrNull;
  bool get inGame => activeGame != null;
  List<Player> get connectedPlayers => players.where((p) => p.connected).toList();

  @override
  Random get random => _random;

  // ---------------------------------------------------------------- hosting

  Future<void> host(Transport transport) async {
    await shutdown();
    _transport = transport;
    _subs
      ..add(transport.onJoin.listen((_) {})) // nothing to do until they send "join"
      ..add(transport.onLeave.listen(_onLeave))
      ..add(transport.onMessage.listen(_onMessage))
      ..add(transport.onStatus.listen((s) {
        transportStatus = s;
        _notify();
      }));
    joinInfo = await transport.start();
    transportStatus = transport.status;
    _notify();
  }

  Future<void> shutdown() async {
    _endActiveGame(notifyPlayers: false);
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    if (_transport != null) {
      _transport!.broadcast(_msg('room.closed', {'reason': 'host_left'}));
      await _transport!.stop();
    }
    _transport = null;
    joinInfo = null;
    players.clear();
    _connToPlayer.clear();
    transportStatus = TransportStatus.stopped;
    _notify();
  }

  // ---------------------------------------------------------------- lobby

  void selectGame(String id) {
    if (inGame || !catalog.any((g) => g.id == id)) return;
    selectedGameId = id;
    _broadcastLobby();
    _notify();
  }

  void setSetting(String key, Object value) {
    final id = selectedGameId;
    if (id == null || inGame) return;
    gameSettings[id]![key] = value;
    _notify();
  }

  /// Why the selected game can't start right now, or null if it can.
  /// The host UI shows this under a disabled Start button.
  String? get startProblem {
    final template = selectedGame;
    if (template == null) return 'Pick a game first.';
    if (inGame) return 'A game is already running.';
    final n = connectedPlayers.length;
    if (n < template.minPlayers) {
      final more = template.minPlayers - n;
      return '${template.displayName} needs at least ${template.minPlayers} players '
          '($more more to join).';
    }
    if (n > template.maxPlayers) {
      return '${template.displayName} allows at most ${template.maxPlayers} players. '
          'Remove ${n - template.maxPlayers}.';
    }
    return null;
  }

  /// Starts the selected game. Returns an error message, or null on success.
  String? startGame() {
    final problem = startProblem;
    if (problem != null) return problem;
    final template = selectedGame!;
    final seated = connectedPlayers;
    // Drop anyone who left the lobby before we started.
    players.removeWhere((p) => !p.connected);

    final game = _factories.firstWhere((f) => f().id == template.id)();
    activeGame = game;
    _gamePlayerIds
      ..clear()
      ..addAll(seated.map((p) => p.id));
    _lastScreen.clear();
    _lastSignature.clear();

    _broadcast(_msg('game.started', {'game': game.id, 'name': game.displayName}));
    game.start(this, List.unmodifiable(seated), Map.of(gameSettings[template.id]!));
    // Refresh countdowns on the host view once a second.
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _notify());
    _pushScreens();
    return null;
  }

  /// Ends the current game (or returns from the game-over screen) to the lobby.
  void endGame() => _endActiveGame(notifyPlayers: true);

  void _endActiveGame({required bool notifyPlayers}) {
    final game = activeGame;
    if (game == null) return;
    game.dispose();
    activeGame = null;
    _ticker?.cancel();
    _ticker = null;
    _gamePlayerIds.clear();
    _lastScreen.clear();
    _lastSignature.clear();
    players.removeWhere((p) => !p.connected);
    if (notifyPlayers) {
      _broadcast(_msg('game.ended', {}));
      _broadcastLobby();
    }
    _notify();
  }

  void kick(String playerId) {
    final p = _playerById(playerId);
    if (p == null) return;
    if (p.connId != null) {
      _transport?.sendTo(p.connId!, _msg('room.closed', {'reason': 'kicked'}));
      _connToPlayer.remove(p.connId);
      _transport?.disconnect(p.connId!);
    }
    _removeFromGame(p);
    players.remove(p);
    _broadcastLobby();
    _pushScreens();
    _notify();
  }

  /// The host pressed one of the active game's [Game.hostControls].
  /// Returns an error message, or null when it worked.
  String? hostAction(String controlId, {List<String> choice = const [], Object? value}) {
    final game = activeGame;
    if (game == null) return 'No game is running.';
    final control = game.hostControls().where((c) => c.id == controlId).firstOrNull;
    if (control == null) return 'That button is out of date.';
    if (control.options.isNotEmpty) {
      final ids = {for (final o in control.options) o.id: o};
      if (choice.isEmpty || (!control.multi && choice.length > 1) || choice.toSet().length != choice.length) {
        return control.multi ? 'Pick at least one.' : 'Pick one.';
      }
      for (final c in choice) {
        final opt = ids[c];
        if (opt == null) return 'That choice isn\'t available.';
        if (opt.input != null && !_inRange(value, opt.input!.min, opt.input!.max, opt.input!.step)) {
          return 'Pick an amount from ${opt.input!.min} to ${opt.input!.max}.';
        }
      }
    } else if (choice.isNotEmpty) {
      return 'That button takes no choice.';
    }
    final input = control.input;
    if (input != null && !_inRange(value, input.min, input.max, input.step)) {
      return 'Pick an amount from ${input.min} to ${input.max}.';
    }
    final result = game.handleHostAction(PlayerAction(actionId: controlId, choice: choice, value: value));
    if (!result.ok) return result.error;
    requestUpdate();
    return null;
  }

  // ---------------------------------------------------------------- GameContext

  @override
  void requestUpdate() {
    _pushScreens();
    _notify();
  }

  // ---------------------------------------------------------------- messages in

  void _onMessage(IncomingMessage m) {
    switch (m.type) {
      case 'join':
        _onJoin(m.connId, m.payload);
      case 'action':
        _onAction(m.connId, m.payload);
      case 'leave':
        _onPlayerQuit(m.connId);
      default:
        break; // unknown types are ignored, never trusted
    }
  }

  void _onJoin(String connId, Map<String, dynamic> p) {
    void reject(String reason) {
      _transport?.sendTo(connId, _msg('join.error', {'reason': reason}));
      _transport?.disconnect(connId);
    }

    if (p['v'] != protocolVersion) return reject('version_mismatch');

    // Returning player?
    final token = p['reconnectToken'];
    if (token is String) {
      final existing = players.where((pl) => pl.reconnectToken == token).firstOrNull;
      if (existing != null) {
        final old = existing.connId;
        if (old != null && old != connId) {
          _connToPlayer.remove(old);
          _transport?.disconnect(old);
        }
        existing.connId = connId;
        _connToPlayer[connId] = existing.id;
        _sendJoinOk(existing);
        activeGame?.onPlayerConnectionChanged(existing.id, true);
        _broadcastLobby();
        _pushScreens(force: {existing.id});
        _notify();
        return;
      }
    }

    final name = _cleanName(p['name']);
    if (name == null) return reject('bad_name');
    if (inGame) return reject('game_in_progress');
    if (players.length >= maxPlayers) return reject('room_full');
    if (players.any((pl) => pl.name.toLowerCase() == name.toLowerCase())) return reject('name_taken');

    final player = Player(
      id: randomId(_random, 'p_'),
      name: name,
      reconnectToken: randomId(_random, 't_') + randomId(_random, ''),
    )..connId = connId;
    players.add(player);
    _connToPlayer[connId] = player.id;
    _sendJoinOk(player);
    _broadcastLobby();
    _notify();
  }

  void _sendJoinOk(Player p) {
    _transport?.sendTo(p.connId!, _msg('join.ok', {
      'playerId': p.id,
      'reconnectToken': p.reconnectToken,
      'protocolVersion': protocolVersion,
    }));
    _transport?.sendTo(p.connId!, _msg('lobby.update', _lobbyPayload()));
    if (inGame && _gamePlayerIds.contains(p.id)) {
      _transport?.sendTo(p.connId!, _msg('game.started', {'game': activeGame!.id, 'name': activeGame!.displayName}));
    }
  }

  static String? _cleanName(Object? raw) {
    if (raw is! String) return null;
    // Control characters and invisible formatting characters (zero-width,
    // direction overrides) would let one player look like another.
    final name = raw
        .replaceAll(RegExp(r'[\x00-\x1F\x7F\u00AD\u200B-\u200F\u202A-\u202E\u2060-\u2069\uFEFF]'), '')
        .trim();
    if (name.isEmpty || name.length > 16) return null;
    return name;
  }

  void _onAction(String connId, Map<String, dynamic> p) {
    final playerId = _connToPlayer[connId];
    final game = activeGame;
    if (playerId == null || game == null || !_gamePlayerIds.contains(playerId)) return;

    final screen = _lastScreen[playerId];
    final error = _validate(screen, p);
    if (error != null) {
      _transport?.sendTo(connId, _msg('action.error', {'message': error}));
      _pushScreens(force: {playerId});
      return;
    }

    final rawChoice = p['choice'];
    final choice = rawChoice is List ? rawChoice.map((e) => e.toString()).toList() : <String>[];
    final action = PlayerAction(actionId: p['actionId'] as String, choice: choice, value: p['value']);
    final result = game.handleAction(playerId, action);
    if (!result.ok) {
      _transport?.sendTo(connId, _msg('action.error', {'message': result.error}));
      _pushScreens(force: {playerId});
      return;
    }
    _pushScreens();
    _notify();
  }

  /// Never trust the client: the action must match the screen we sent.
  static String? _validate(Screen? screen, Map<String, dynamic> p) {
    if (screen == null || !screen.acceptsAction || p['actionId'] != screen.actionId) {
      return 'That screen is out of date.';
    }
    final rawChoice = p['choice'];
    final choice = rawChoice is List ? rawChoice.map((e) => e.toString()).toList() : <String>[];
    final value = p['value'];

    if (screen.kind == ScreenKind.input) {
      if (screen.textInput) {
        if (value is! String || value.trim().isEmpty || value.length > (screen.inputMax ?? 60)) {
          return 'Check your answer.';
        }
      } else if (!_inRange(value, screen.inputMin, screen.inputMax, 1)) {
        return 'Pick a number from ${screen.inputMin} to ${screen.inputMax}.';
      }
      return null;
    }

    final ids = {for (final o in screen.options) o.id: o};
    final minPick = screen.kind == ScreenKind.choice ? screen.min : 1;
    final maxPick = screen.kind == ScreenKind.choice ? screen.max : 1;
    if (choice.length < minPick || choice.length > maxPick || choice.toSet().length != choice.length) {
      return 'Pick ${minPick == maxPick ? minPick : '$minPick–$maxPick'} option(s).';
    }
    for (final c in choice) {
      final opt = ids[c];
      if (opt == null) return 'That option isn\'t available.';
      if (opt.input != null && !_inRange(value, opt.input!.min, opt.input!.max, opt.input!.step)) {
        return 'Pick an amount from ${opt.input!.min} to ${opt.input!.max}.';
      }
    }
    return null;
  }

  /// A whole number in [min]..[max], on a multiple of [step] counted from
  /// [min]. The top of the range (e.g. all in) is always allowed.
  static bool _inRange(Object? v, int? min, int? max, int step) {
    if (v is! num || !v.isFinite || v != v.roundToDouble()) return false;
    if (min != null && v < min) return false;
    if (max != null && v > max) return false;
    if (step > 1 && min != null && v != max && (v.toInt() - min) % step != 0) return false;
    return true;
  }

  void _onLeave(String connId) {
    final playerId = _connToPlayer.remove(connId);
    if (playerId == null) return;
    final p = _playerById(playerId);
    if (p == null) return;
    p.connId = null;
    if (!inGame) {
      // Keep the seat a little while in the lobby too, in case it's just a locked screen.
      Timer(const Duration(seconds: 30), () {
        if (!p.connected && !inGame && players.remove(p)) {
          _broadcastLobby();
          _notify();
        }
      });
    } else {
      activeGame?.onPlayerConnectionChanged(p.id, false);
    }
    _broadcastLobby();
    _notify();
  }

  /// Player pressed "Leave": free their seat now.
  void _onPlayerQuit(String connId) {
    final playerId = _connToPlayer[connId];
    if (playerId == null) return;
    _connToPlayer.remove(connId);
    final p = _playerById(playerId);
    if (p != null) {
      p.connId = null;
      _removeFromGame(p); // their token is gone, so the seat can't come back
      players.remove(p);
    }
    _broadcastLobby();
    _pushScreens();
    _notify();
  }

  /// Take a player out of the running game for good and let the game react.
  void _removeFromGame(Player p) {
    if (!_gamePlayerIds.remove(p.id)) return;
    _lastScreen.remove(p.id);
    _lastSignature.remove(p.id);
    // Only onPlayerRemoved: a separate "disconnected" call first could let a
    // game finish the phase with the leaver's last choice still counted.
    activeGame?.onPlayerRemoved(p.id);
  }

  // ---------------------------------------------------------------- messages out

  /// Send each player in the game their current screen, if it changed.
  void _pushScreens({Set<String> force = const {}}) {
    final game = activeGame;
    if (game == null) return;
    for (final p in players) {
      if (!_gamePlayerIds.contains(p.id)) continue;
      final screen = game.privateState(p.id);
      final sig = screen.signature;
      _lastScreen[p.id] = screen;
      if (p.connId == null) continue;
      if (_lastSignature[p.id] == sig && !force.contains(p.id)) continue;
      _lastSignature[p.id] = sig;
      _transport?.sendTo(p.connId!, {'v': protocolVersion, ...screen.toMessage()});
    }
  }

  Map<String, dynamic> _lobbyPayload() => {
        'players': [for (final p in players) p.toLobbyJson()],
        'selectedGame': selectedGame?.displayName,
        'maxPlayers': maxPlayers,
      };

  void _broadcastLobby() => _broadcast(_msg('lobby.update', _lobbyPayload()));

  void _broadcast(Map<String, dynamic> m) => _transport?.broadcast(m);

  Player? _playerById(String id) => players.where((p) => p.id == id).firstOrNull;

  Map<String, dynamic> _msg(String type, Map<String, dynamic> payload) =>
      {'v': protocolVersion, 'type': type, 'payload': payload};
}
