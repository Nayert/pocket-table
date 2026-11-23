// Run with:  dart test   (from 5-games/)
import 'dart:math';

import 'package:games/games.dart';
import 'package:platform_core/platform_core.dart';
import 'package:test/test.dart';

class _Ctx implements GameContext {
  int updates = 0;
  @override
  final Random random = Random(7);
  @override
  void requestUpdate() => updates++;
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
    final bodies = players.map((p) => game.privateState(p.id).body!).toList();
    expect(bodies.where((b) => b.contains('You are in the Mafia')).length, 1);
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
    final mafiaId = game.rolesForTesting.entries.firstWhere((e) => e.value == 'mafia').key;
    everyoneActs((p, s) => s.options.any((o) => o.id == mafiaId) ? mafiaId : 'nobody');
    expect(game.isOver, isTrue);
    expect(game.publicState()['banner'], 'Town wins!');
  });

  // ---- same scenarios as prototype/test_prototypes.py (MafiaRules) ----

  MafiaGame fresh(int n, Map<String, Object> settings) {
    players = [for (var i = 0; i < n; i++) Player(id: 'p$i', name: 'P$i', reconnectToken: 't$i')];
    game.dispose();
    return game = MafiaGame()..start(_Ctx(), players, settings);
  }

  void act(String pid, String choice) {
    final s = game.privateState(pid);
    final r = game.handleAction(pid, PlayerAction(actionId: s.actionId ?? 'none', choice: [choice]));
    if (!r.ok) throw StateError(r.error!);
  }

  String roleOf(String pid) => game.rolesForTesting[pid]!;
  String withRole(String role) => game.rolesForTesting.entries.firstWhere((e) => e.value == role).key;

  test('night picks: not-on-the-list and repeats are rejected, role-specific ones are not', () {
    fresh(6, {'doctor': true, 'detective': true});
    for (final p in players) {
      act(p.id, 'ready');
    }
    final m = withRole('mafia');
    final s = game.privateState(m);
    expect(game.handleAction(m, PlayerAction(actionId: s.actionId!, choice: ['nobody'])).ok, isFalse);
    expect(game.handleAction(m, PlayerAction(actionId: s.actionId!, choice: ['zz'])).ok, isFalse);
    expect(game.handleAction(m, PlayerAction(actionId: 'wrong', choice: [withRole('villager')])).ok, isFalse);
    final v = players.map((p) => p.id).firstWhere((id) => roleOf(id) == 'villager');
    expect(game.handleAction(m, PlayerAction(actionId: s.actionId!, choice: [v])).ok, isTrue);
    expect(game.handleAction(m, PlayerAction(actionId: s.actionId!, choice: [v])).ok, isFalse);
  });

  test('night options are identical for every role', () {
    fresh(8, {'doctor': true, 'detective': true});
    for (final p in players) {
      act(p.id, 'ready');
    }
    final lists = {
      for (final p in players) roleOf(p.id): game.privateState(p.id).options.map((o) => o.id).toList(),
    };
    expect(lists.keys, containsAll(['mafia', 'doctor', 'detective', 'villager']));
    expect({for (final l in lists.values) l.join(',')}.length, 1);
    expect(lists['mafia']!, [for (final p in players) p.id]);
  });

  test('mafia picking self or a teammate kills nobody', () {
    fresh(8, {'doctor': false, 'detective': false});
    final mafia = [for (final p in players) if (roleOf(p.id) == 'mafia') p.id];
    expect(mafia.length, 2);
    for (final p in players) {
      act(p.id, 'ready');
    }
    act(mafia[0], mafia[0]);
    act(mafia[1], mafia[0]);
    for (final p in players) {
      if (!mafia.contains(p.id)) act(p.id, p.id);
    }
    expect(title(), startsWith('Morning'));
    expect(game.publicState()['log'], contains(contains('nobody died')));
    expect(game.publicState()['subtitle'], contains('/8 ready'));
    expect((game.publicState()['rows'] as List).where((r) => r['value'] == 'alive').length, 8);
  });

  test('a target who left during the night is not reported killed', () {
    fresh(6, {'doctor': true, 'detective': true});
    for (final p in players) {
      act(p.id, 'ready');
    }
    final victim = players.map((p) => p.id).firstWhere((id) => roleOf(id) == 'villager');
    act(withRole('mafia'), victim);
    game.onPlayerRemoved(victim);
    for (final p in players) {
      if (p.id != victim && game.privateState(p.id).options.isNotEmpty) act(p.id, p.id);
    }
    expect(game.publicState()['log'], contains(contains('nobody died')));
    expect(game.publicState()['log'], isNot(contains(contains('was killed'))));
  });

  test("a mafia member's night screen does not change when a teammate acts", () {
    fresh(8, {'doctor': false, 'detective': false});
    final mafia = [for (final p in players) if (roleOf(p.id) == 'mafia') p.id];
    for (final p in players) {
      act(p.id, 'ready');
    }
    final before = game.privateState(mafia[0]).signature;
    act(mafia[1], players.first.id);
    expect(game.privateState(mafia[0]).signature, before);
    // After acting, the waiting screen is static too.
    act(mafia[0], players.first.id);
    final waiting = game.privateState(mafia[0]).signature;
    final other = players.map((p) => p.id).firstWhere((id) => !mafia.contains(id));
    act(other, other);
    expect(game.privateState(mafia[0]).signature, waiting);
  });

  test('mafia count is capped so mafia start outnumbered', () {
    fresh(5, {'mafiaCount': 4});
    expect(game.rolesForTesting.values.where((r) => r == 'mafia').length, 2);
  });

  test('minimum game: four players', () {
    fresh(4, {'doctor': true, 'detective': true});
    expect(game.rolesForTesting.values.toList()..sort(), ['detective', 'doctor', 'mafia', 'villager']);
    final m = withRole('mafia'), doc = withRole('doctor'), det = withRole('detective'), vil = withRole('villager');
    for (final p in players) {
      act(p.id, 'ready');
    }
    act(m, vil);
    act(doc, doc);
    act(det, m);
    act(vil, m);
    expect(title(), startsWith('Morning'));
    expect(game.privateState(det).body, 'Your investigation: ${players.firstWhere((p) => p.id == m).name} is Mafia.');
    expect(game.privateState(vil).title, 'Dead');
    final living = [for (final p in players) if (p.id != vil) p.id]..sort();
    for (var i = 0; i < 2; i++) {
      for (final p in living) {
        act(p, 'ready');
      }
    }
    for (final p in living) {
      act(p, p != m ? m : doc);
    }
    expect(game.isOver, isTrue);
    expect(game.publicState()['banner'], 'Town wins!');
  });

  test('a vote tie means nobody is out', () {
    fresh(4, {'doctor': false, 'detective': false});
    game.forcePhaseForTesting('vote');
    act('p0', 'p1');
    act('p1', 'p0');
    act('p2', 'p0');
    act('p3', 'p1');
    final rows = (game.publicState()['rows'] as List).cast<Map>();
    expect(rows.where((r) => r['value'] == 'alive').length, 4);
    expect((game.publicState()['log'] as List).last, contains('no one was voted out'));
  });

  test('majority rule: most votes is not enough', () {
    fresh(6, {'majorityVote': true});
    game.forcePhaseForTesting('vote');
    final target = [for (final p in players) if (roleOf(p.id) != 'mafia') p.id].first;
    final v = [for (final p in players) if (p.id != target) p.id];
    final votes = {v[0]: target, v[1]: target, target: v[0], v[2]: v[3], v[3]: v[4], v[4]: 'nobody'};
    for (final p in players) {
      act(p.id, votes[p.id]!); // target has 2 of 6 votes: the most, but not a majority
    }
    final rows = (game.publicState()['rows'] as List).cast<Map>();
    expect(rows.where((r) => r['value'] == 'alive').length, 6);
    expect((game.publicState()['log'] as List).last, contains('majority'));
  });

  test('a phase ends without waiting for disconnected players', () {
    fresh(4, {});
    game.onPlayerConnectionChanged('p3', false);
    for (final p in ['p0', 'p1', 'p2']) {
      act(p, 'ready');
    }
    expect(title(), startsWith('Night')); // did not wait for p3
  });

  test('disconnecting the last holdout ends the phase', () {
    final ctx = _Ctx();
    players = [for (var i = 0; i < 4; i++) Player(id: 'p$i', name: 'P$i', reconnectToken: 't$i')];
    game.dispose();
    game = MafiaGame()..start(ctx, players, {});
    for (final p in ['p0', 'p1', 'p2']) {
      act(p, 'ready');
    }
    expect(title(), 'Check your role');
    game.onPlayerConnectionChanged('p3', false);
    expect(title(), startsWith('Night'));
    expect(ctx.updates, 1);
  });

  test('leaving kills the player and can end the game', () {
    fresh(4, {'doctor': false, 'detective': false});
    game.onPlayerRemoved(withRole('mafia'));
    expect(game.isOver, isTrue);
    expect(game.publicState()['banner'], 'Town wins!');
    expect((game.publicState()['log'] as List).last, contains('left the game. They were Mafia.'));
  });

  test('leaving mid-phase can end the phase', () {
    fresh(6, {});
    final leaver = players.firstWhere((p) => roleOf(p.id) != 'mafia').id;
    for (final p in players) {
      if (p.id != leaver) act(p.id, 'ready');
    }
    expect(title(), 'Check your role');
    game.onPlayerRemoved(leaver);
    expect(title(), startsWith('Night'));
  });

  group('privacy: nothing private in title or lines', () {
    const roleWords = ['Mafia', 'Doctor', 'Detective', 'Villager'];

    void checkPhase(String label) {
      final screens = [
        for (final p in players) game.privateState(p.id),
      ];
      expect(screens.map((s) => s.title).toSet().length, 1, reason: '$label: titles differ');
      for (final s in screens) {
        expect(s.secret, isTrue, reason: label);
        final visible = '${s.title} ${(s.lines ?? []).join(' ')}';
        for (final w in roleWords) {
          expect(visible, isNot(contains(w)), reason: '$label: $visible');
        }
      }
    }

    test('reveal, night, dawn, day and vote screens', () {
      checkPhase('reveal');
      everyoneActs();
      checkPhase('night');
      everyoneActs();
      // dawn: dead players get another screen; only check the living
      for (final s in [for (final p in players) game.privateState(p.id)].where((s) => s.title != 'Dead')) {
        expect(s.title, 'Morning');
        expect(s.secret, isTrue);
        expect((s.lines ?? []).join(' '), isNot(anyOf(contains('Mafia'), contains('Doctor'), contains('Detective'))));
      }
      everyoneActs();
      for (final s in [for (final p in players) game.privateState(p.id)].where((s) => s.title != 'Dead')) {
        expect(s.title, startsWith('Day'));
        expect(s.secret, isTrue);
        expect('${s.title} ${(s.lines ?? []).join(' ')}', isNot(contains('Your role')));
      }
      everyoneActs();
      for (final s in [for (final p in players) game.privateState(p.id)].where((s) => s.title != 'Dead')) {
        expect(s.title, 'Vote someone out');
        expect(s.secret, isTrue);
        expect(s.lines, isNull);
      }
    });

    test('the reveal body holds the role, and teammates only for the Mafia', () {
      for (final p in players) {
        final s = game.privateState(p.id);
        expect(s.body, contains(roleOf(p.id) == 'mafia' ? 'You are in the Mafia.' : 'You are the'));
      }
    });

    test('public state has no roles until the game ends', () {
      final text = game.publicState().toString();
      for (final w in ['Doctor', 'Detective', 'Villager', 'Mafia', 'mafia', 'doctor']) {
        expect(text, isNot(contains(w)), reason: w);
      }
    });
  });
}
