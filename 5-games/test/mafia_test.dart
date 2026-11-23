// Run with:  dart test   (from 5-games/)
import 'dart:math';

import 'package:games/games.dart';
import 'package:platform_core/platform_core.dart';
import 'package:test/test.dart';

class _Ctx implements GameContext {
  @override
  final Random random = Random(7);
  @override
  void requestUpdate() {}
}

void main() {
  late MafiaGame game;
  late List<Player> players;

  setUp(() {
    players = [for (var i = 0; i < 6; i++) Player(id: 'p$i', name: 'P$i', reconnectToken: 't$i')];
    game = MafiaGame()..start(_Ctx(), players, {'doctor': true, 'detective': true});
  });
  tearDown(() => game.dispose());

  /// Everyone who has buttons presses the first one (or [pick] if it returns an id).
  void everyoneActs([String? Function(Player p, Screen s)? pick]) {
    for (final p in players) {
      final s = game.privateState(p.id);
      if (s.actionId == null || s.options.isEmpty) continue;
      final choice = pick?.call(p, s) ?? s.options.first.id;
      game.handleAction(p.id, PlayerAction(actionId: s.actionId!, choice: [choice]));
    }
  }

  String title() => game.publicState()['title'] as String;

  test('roles are private and there is one mafia among 6', () {
    final titles = players.map((p) => game.privateState(p.id).title!).toList();
    expect(titles.where((t) => t.contains('Mafia')).length, 1);
    expect(game.publicState().toString(), isNot(contains('Mafia')));
  });

  test('phases advance once everyone has acted', () {
    expect(title(), 'Check your role');
    everyoneActs();
    expect(title(), startsWith('Night'));
    everyoneActs();
    expect(title(), startsWith('Morning'));
    everyoneActs();
    expect(title(), startsWith('Day'));
    everyoneActs();
    expect(title(), startsWith('Voting'));
  });

  test('cannot act twice or pick an illegal option', () {
    final p = players.first;
    final s = game.privateState(p.id);
    expect(game.handleAction(p.id, PlayerAction(actionId: s.actionId!, choice: ['ready'])).ok, isTrue);
    expect(game.handleAction(p.id, PlayerAction(actionId: s.actionId!, choice: ['ready'])).ok, isFalse);
    expect(game.handleAction(players[1].id, PlayerAction(actionId: s.actionId!, choice: ['p0'])).ok, isFalse);
  });

  test('town wins by voting out the mafia', () {
    everyoneActs(); // reveal
    everyoneActs(); // night: at most one villager dies, so the town still outnumbers the mafia
    everyoneActs(); // dawn
    everyoneActs(); // day
    final mafiaId = players.firstWhere((p) => game.privateState(p.id).lines!.first.contains('Mafia')).id;
    everyoneActs((p, s) => s.options.any((o) => o.id == mafiaId) ? mafiaId : 'nobody');
    expect(game.isOver, isTrue);
    expect(game.publicState()['banner'], 'Town wins!');
  });
}
