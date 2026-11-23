// Run with:  dart test   (from 5-games/)
import 'dart:math';

import 'package:games/games.dart';
import 'package:platform_core/platform_core.dart';
import 'package:test/test.dart';

List<String> h(String s) => s.split(' ');

class _Ctx implements GameContext {
  int updates = 0;
  @override
  final Random random = Random(42);
  @override
  void requestUpdate() => updates++;
}

void main() {
  group('hand evaluator (same cases as prototype/test_prototypes.py)', () {
    test('categories', () {
      const cases = {
        'As Ks Qs Js Ts': 'Straight flush',
        '9c 9d 9h 9s 2c': 'Four of a kind',
        '3c 3d 3h 7s 7c': 'Full house',
        '2h 7h 9h Jh Kh': 'Flush',
        '5c 6d 7h 8s 9c': 'Straight',
        'Ac 2d 3h 4s 5c': 'Straight',
        'Qc Qd Qh 7s 2c': 'Three of a kind',
        'Jc Jd 4h 4s Ac': 'Two pair',
        'Tc Td 4h 8s Ac': 'Pair',
        '2c 5d 9h Js Kc': 'High card',
      };
      cases.forEach((cards, name) => expect(describeScore(evaluate5(h(cards))), name, reason: cards));
    });

    test('ordering', () {
      const better = [
        ['As Ks Qs Js Ts', '9s 8s 7s 6s 5s'],
        ['2c 3c 4c 5c 6c', 'Ac 2d 3h 4s 5c'],
        ['6c 7d 8h 9s Tc', 'Ac 2d 3h 4s 5c'],
        ['Kc Kd 2h 2s 3c', 'Qc Qd Jh Js Ac'],
        ['Ac Ad 9h 5s 3c', 'Ac Ad 9h 5s 2c'],
        ['3c 3d 3h 2s 2c', '2c 2d 2h As Ac'],
      ];
      for (final [a, b] in better) {
        expect(compareScores(evaluate5(h(a)), evaluate5(h(b))), greaterThan(0), reason: '$a vs $b');
      }
    });

    test('best of seven and split', () {
      expect(describeScore(bestHand(h('Ah Kh 2h 7h 9c 9d 3h'))), 'Flush');
      expect(describeScore(bestHand(h('9c 9d 9h 4s 4c 4d 2c'))), 'Full house');
      final board = h('As Ks Qd Jc Th');
      expect(compareScores(bestHand([...board, ...h('2c 3d')]), bestHand([...board, ...h('4h 5h')])), 0);
    });
  });

  group('pots', () {
    test('side pot with a folded player', () {
      final pots = buildPots({'a': 20, 'b': 100, 'c': 100, 'd': 30}, {'d'});
      expect(pots.map((p) => p.amount), [80, 170]);
      expect(pots[0].eligible, ['a', 'b', 'c']);
      expect(pots[1].eligible, ['b', 'c']);
    });

    test('split with odd chip goes to first in order', () {
      final won = awardPots([Pot(101, ['a', 'b'])], {'a': [5, 1], 'b': [5, 1]}, ['b', 'a']);
      expect(won, {'b': 51, 'a': 50});
    });

    test('short stack only wins the main pot', () {
      final pots = buildPots({'a': 20, 'b': 100, 'c': 100}, {});
      final won = awardPots(pots, {'a': [9], 'b': [5], 'c': [1]}, ['a', 'b', 'c']);
      expect(won, {'a': 60, 'b': 160});
    });
  });

  group('poker game', () {
    late PokerGame game;
    late List<Player> players;

    setUp(() {
      players = [
        for (final n in ['Ana', 'Ben', 'Cal'])
          Player(id: n.toLowerCase(), name: n, reconnectToken: 't')
      ];
      game = PokerGame()..start(_Ctx(), players, {'startingChips': 1000, 'bigBlind': 20, 'turnSeconds': 0});
    });
    tearDown(() => game.dispose());

    int totalChips() {
      final rows = (game.publicState()['rows'] as List).cast<Map>();
      final pot = int.parse(RegExp(r'Pot: (\d+)').firstMatch(game.publicState()['subtitle'] as String)!.group(1)!);
      return pot + rows.map((r) => int.parse(RegExp(r'^(\d+) chips').firstMatch(r['value'] as String)!.group(1)!)).reduce((a, b) => a + b);
    }

    String whoseTurn() => players.firstWhere((p) => game.privateState(p.id).kind == ScreenKind.choice).id;

    test('blinds are posted and exactly one player is asked to act', () {
      expect(totalChips(), 3000);
      expect(players.where((p) => game.privateState(p.id).kind == ScreenKind.choice).length, 1);
    });

    test('everyone folds to one player, chips are conserved', () {
      final first = whoseTurn();
      expect(game.handleAction(first, PlayerAction(actionId: game.privateState(first).actionId!, choice: ['fold'])).ok, isTrue);
      final second = whoseTurn();
      expect(game.handleAction(second, PlayerAction(actionId: game.privateState(second).actionId!, choice: ['fold'])).ok, isTrue);
      expect(game.privateState(first).kind, ScreenKind.results);
      expect(totalChips(), 3000);
    });

    test('acting out of turn is rejected', () {
      final turn = whoseTurn();
      final other = players.firstWhere((p) => p.id != turn).id;
      final r = game.handleAction(other, PlayerAction(actionId: game.privateState(turn).actionId!, choice: ['fold']));
      expect(r.ok, isFalse);
    });

    test('a raise below the minimum is rejected', () {
      final turn = whoseTurn();
      final id = game.privateState(turn).actionId!;
      expect(game.handleAction(turn, PlayerAction(actionId: id, choice: ['raise'], value: 25)).ok, isFalse);
      expect(game.handleAction(turn, PlayerAction(actionId: id, choice: ['raise'], value: 40)).ok, isTrue);
    });

    test('checking/calling every street reaches a showdown and conserves chips', () {
      for (var i = 0; i < 40 && game.privateState(players.first.id).kind != ScreenKind.results; i++) {
        final turn = whoseTurn();
        final screen = game.privateState(turn);
        final canCheck = screen.options.any((o) => o.id == 'check');
        game.handleAction(turn, PlayerAction(actionId: screen.actionId!, choice: [canCheck ? 'check' : 'call']));
      }
      expect(game.privateState(players.first.id).kind, ScreenKind.results);
      expect(totalChips(), 3000);
      expect((game.publicState()['cards'] as List).length, 5);
    });
  });
}
