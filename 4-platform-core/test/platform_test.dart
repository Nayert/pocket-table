// Run with:  dart test   (from 4-platform-core/)
import 'package:platform_core/platform_core.dart';
import 'package:test/test.dart';
import 'package:transport/transport.dart';

/// Tiny game: each player presses A or B once; game ends when all have.
class _PressGame extends Game {
  final pressed = <String, String>{};
  final removed = <String>[];
  final values = <Object?>[];
  late List<Player> players;

  @override
  String get id => 'press';
  @override
  String get displayName => 'Press';
  @override
  String get description => 'Test game';
  @override
  int get minPlayers => 2;
  @override
  int get maxPlayers => 4;

  @override
  void start(GameContext ctx, List<Player> players, Map<String, Object> settings) => this.players = players;

  @override
  ActionResult handleAction(String playerId, PlayerAction action) {
    pressed[playerId] = action.first!;
    values.add(action.value);
    return const ActionResult.ok();
  }

  @override
  void onPlayerRemoved(String playerId) => removed.add(playerId);

  @override
  Screen privateState(String playerId) => pressed.containsKey(playerId)
      ? Screen.waiting('Done')
      : Screen.choice(actionId: 'press', secret: true, body: 'shh', options: const [
          Option('a', 'A'),
          Option('b', 'B'),
          Option('r', 'Raise', input: OptionInput(min: 10, max: 52, step: 5)),
        ]);

  @override
  Map<String, dynamic> publicState() => {'title': 'Press', 'rows': []};

  @override
  bool get isOver => pressed.length == players.length;
}

void main() {
  late FakeTransport t;
  late Platform platform;

  setUp(() async {
    t = FakeTransport();
    platform = Platform(games: [_PressGame.new]);
    await platform.host(t);
  });

  String join(String conn, String name, {String? token, int v = protocolVersion}) {
    t.simulateJoin(conn);
    t.simulateMessage(conn, 'join', {'v': v, 'name': name, if (token != null) 'reconnectToken': token});
    return t.lastTo(conn, type: 'join.ok')?['payload']?['reconnectToken'] as String? ?? '';
  }

  test('players join and see the lobby', () {
    join('c1', 'Ana');
    join('c2', 'Ben');
    expect(platform.players.map((p) => p.name), ['Ana', 'Ben']);
    final lobby = t.lastTo('c1', type: 'lobby.update')!['payload'] as Map;
    expect((lobby['players'] as List).length, 2);
  });

  test('bad joins are rejected', () {
    join('c1', 'Ana');
    join('c2', 'ana');
    expect(t.lastTo('c2', type: 'join.error')!['payload']['reason'], 'name_taken');
    join('c3', 'Old', v: 0);
    expect(t.lastTo('c3', type: 'join.error')!['payload']['reason'], 'version_mismatch');
    join('c4', '   ');
    expect(t.lastTo('c4', type: 'join.error')!['payload']['reason'], 'bad_name');
  });

  test('min players enforced, then the game sends private screens', () {
    join('c1', 'Ana');
    expect(platform.startGame(), isNotNull);
    join('c2', 'Ben');
    expect(platform.startGame(), isNull);
    expect(t.lastTo('c1')!['type'], 'screen.choice');
  });

  test('invalid actions are refused before reaching the game', () {
    join('c1', 'Ana');
    join('c2', 'Ben');
    platform.startGame();
    t.simulateMessage('c1', 'action', {'actionId': 'press', 'choice': ['zzz']});
    expect(t.lastTo('c1', type: 'action.error'), isNotNull);
    t.simulateMessage('c1', 'action', {'actionId': 'old', 'choice': ['a']});
    expect((platform.activeGame as _PressGame).pressed, isEmpty);
    t.simulateMessage('c1', 'action', {'actionId': 'press', 'choice': ['a']});
    expect((platform.activeGame as _PressGame).pressed, {platform.players.first.id: 'a'});
    expect(t.lastTo('c1')!['type'], 'screen.waiting');
  });

  test('reconnecting with the token gets the same seat and current screen', () {
    final token = join('c1', 'Ana');
    join('c2', 'Ben');
    platform.startGame();
    t.simulateLeave('c1');
    expect(platform.players.first.connected, isFalse);
    join('c9', 'whatever', token: token);
    expect(platform.players.first.connId, 'c9');
    expect(t.lastTo('c9')!['type'], 'screen.choice');
  });

  test('new players cannot join mid-game', () {
    join('c1', 'Ana');
    join('c2', 'Ben');
    platform.startGame();
    join('c3', 'Cal');
    expect(t.lastTo('c3', type: 'join.error')!['payload']['reason'], 'game_in_progress');
  });

  test('amounts must be whole numbers on the step (or the maximum)', () {
    join('c1', 'Ana');
    join('c2', 'Ben');
    platform.startGame();
    final game = platform.activeGame as _PressGame;
    for (final bad in [12, 15.5, 9, 55, '20', null]) {
      t.simulateMessage('c1', 'action', {'actionId': 'press', 'choice': ['r'], 'value': bad});
    }
    expect(game.pressed, isEmpty);
    t.simulateMessage('c1', 'action', {'actionId': 'press', 'choice': ['r'], 'value': 52}); // all in: max
    t.simulateMessage('c2', 'action', {'actionId': 'press', 'choice': ['r'], 'value': 20.0});
    expect(game.pressed.length, 2);
  });

  test('screens marked secret say so on the wire', () {
    join('c1', 'Ana');
    join('c2', 'Ben');
    platform.startGame();
    expect(t.lastTo('c1')!['payload']['secret'], isTrue);
  });

  test('invisible characters are stripped from names', () {
    join('c1', 'Bob');
    join('c2', 'Bo\u200Bb\u202E');
    expect(t.lastTo('c2', type: 'join.error')!['payload']['reason'], 'name_taken');
  });

  test('pressing Leave mid-game removes the player from the game', () {
    join('c1', 'Ana');
    join('c2', 'Ben');
    join('c3', 'Cal');
    platform.startGame();
    final game = platform.activeGame as _PressGame;
    final ben = platform.players[1].id;
    t.simulateMessage('c2', 'leave');
    expect(game.removed, [ben]);
    expect(platform.players.map((p) => p.name), ['Ana', 'Cal']);
    t.simulateMessage('c2', 'action', {'actionId': 'press', 'choice': ['a']});
    expect(game.pressed, isEmpty);
  });

  test('kicking mid-game removes the player from the game', () {
    join('c1', 'Ana');
    join('c2', 'Ben');
    join('c3', 'Cal');
    platform.startGame();
    final game = platform.activeGame as _PressGame;
    final cal = platform.players[2].id;
    platform.kick(cal);
    expect(game.removed, [cal]);
    expect(t.lastTo('c3', type: 'room.closed')!['payload']['reason'], 'kicked');
  });
}
