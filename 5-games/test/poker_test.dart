// Run with:  dart test   (from 5-games/)
import 'dart:math';

import 'package:games/games.dart';
import 'package:platform_core/platform_core.dart';
import 'package:test/test.dart';

List<String> h(String s) => s.split(' ');

class _Ctx implements GameContext {
  _Ctx([int seed = 42]) : random = Random(seed);
  int updates = 0;
  @override
  final Random random;
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

  // ---- same scenarios as prototype/test_prototypes.py (PokerBetting) ----
  group('poker betting (mirrors PokerBetting in test_prototypes.py)', () {
    late PokerGame g;
    late _Ctx ctx;
    late List<Player> ps;

    /// Deck that deals these hole cards (seat order) and this board.
    List<String> stackedDeck(List<List<String>> holes, List<String> board) {
      final deal = [
        for (final hc in holes) hc[0],
        for (final hc in holes) hc[1],
        'Xx', ...board.sublist(0, 3), 'Xx', board[3], 'Xx', board[4],
      ];
      return deal.reversed.toList();
    }

    void newGame(List<String> ids,
        {int chips = 1000, int bb = 20, int? dealer, List<String>? deck, Map<String, int>? stacks, int seed = 1, int turnSeconds = 0}) {
      ps = [for (final i in ids) Player(id: i, name: i, reconnectToken: 't$i')];
      ctx = _Ctx(seed);
      g = PokerGame(deckForTesting: deck, dealerForTesting: dealer, chipsForTesting: stacks)
        ..start(ctx, ps, {'startingChips': chips, 'bigBlind': bb, 'turnSeconds': turnSeconds});
    }

    tearDown(() => g.dispose());

    Screen? turnScreen() {
      for (final p in ps) {
        final sc = g.privateState(p.id);
        if (sc.kind == ScreenKind.choice) return sc;
      }
      return null;
    }

    String? toAct() {
      for (final p in ps) {
        if (g.privateState(p.id).kind == ScreenKind.choice) return p.id;
      }
      return null;
    }

    ActionResult tryAct(String pid, String move, [Object? amount]) =>
        g.handleAction(pid, PlayerAction(actionId: turnScreen()?.actionId ?? 'none', choice: [move], value: amount));

    void act(String pid, String move, [Object? amount]) {
      final r = tryAct(pid, move, amount);
      if (!r.ok) throw StateError('$pid $move: ${r.error}');
    }

    void ready(String pid) {
      final r = g.handleAction(pid, PlayerAction(actionId: g.privateState(pid).actionId ?? 'none', choice: ['next']));
      if (!r.ok) throw StateError('$pid ready: ${r.error}');
    }

    Map<String, dynamic> row(String id) =>
        (g.publicState()['rows'] as List).cast<Map<String, dynamic>>()[ps.indexWhere((p) => p.id == id)];

    int chipsOf(String id) => int.parse(RegExp(r'^(\d+) chips').firstMatch(row(id)['value'] as String)!.group(1)!);
    int betOf(String id) => int.tryParse(RegExp(r'bet (\d+)').firstMatch(row(id)['value'] as String)?.group(1) ?? '') ?? 0;
    bool folded(String id) => (row(id)['value'] as String).contains('folded');
    int total() {
      final pot = int.parse(RegExp(r'Pot: (\d+)').firstMatch(g.publicState()['subtitle'] as String)!.group(1)!);
      return pot + [for (final p in ps) chipsOf(p.id)].reduce((a, b) => a + b);
    }

    Option? option(String pid, String id) => g.privateState(pid).options.where((o) => o.id == id).firstOrNull;
    bool canRaise(String pid) => option(pid, 'raise') != null;
    int minTo(String pid) => option(pid, 'raise')!.input!.min;
    String dealerId() => ps[(g.publicState()['rows'] as List).indexWhere((r) => (r as Map)['label'].toString().endsWith('(D)'))].id;
    String street() => g.publicState()['title'] as String;
    String phase() {
      if (g.isOver) return 'over';
      if (g.publicState()['title'] == 'Waiting for players to reconnect') return 'waiting';
      if (ps.any((p) => g.privateState(p.id).kind == ScreenKind.choice)) return 'betting';
      return 'hand_over';
    }

    bool dealtIn(String id) => g.privateState(id).cards?.isNotEmpty ?? false;

    test('heads-up blinds and order', () {
      newGame(['a', 'b'], dealer: 0);
      expect([betOf('a'), betOf('b')], [10, 20]); // dealer posts the small blind
      expect(toAct(), 'a'); // and acts first pre-flop
      act('a', 'call');
      expect(toAct(), 'b'); // big blind gets the option
      expect(canRaise('b'), isTrue);
      act('b', 'check');
      expect(street(), contains('Flop'));
      expect(toAct(), 'b'); // big blind acts first after the flop
    });

    test('three-handed blinds rotate', () {
      newGame(['a', 'b', 'c'], dealer: 0);
      expect([for (final p in ps) betOf(p.id)], [0, 10, 20]);
      expect(toAct(), 'a');
      act('a', 'fold');
      act('b', 'fold');
      expect(phase(), 'hand_over');
      for (final p in 'abc'.split('')) {
        ready(p);
      }
      expect(dealerId(), 'b');
      expect([for (final p in ps) betOf(p.id)], [20, 0, 10]);
    });

    test('min raise', () {
      newGame(['a', 'b', 'c'], dealer: 0);
      expect(minTo('a'), 40);
      expect(tryAct('a', 'raise', 30).ok, isFalse);
      act('a', 'raise', 60); // raise by 40
      expect(minTo('b'), 100); // next raise must be 40 more
      expect(tryAct('b', 'raise', 99).ok, isFalse);
      act('b', 'raise', 100);
    });

    test('illegal moves', () {
      newGame(['a', 'b', 'c'], dealer: 0);
      expect(tryAct('b', 'call').ok, isFalse); // not b's turn
      expect(tryAct('a', 'check').ok, isFalse); // facing the big blind
      expect(tryAct('a', 'raise', 40.5).ok, isFalse); // not a whole number
      expect(tryAct('a', 'raise', 5000).ok, isFalse); // more than they have
      expect(tryAct('a', 'raise', 'lots').ok, isFalse);
      expect(tryAct('a', 'raise').ok, isFalse); // no amount
      expect(tryAct('zz', 'fold').ok, isFalse); // not in the game
    });

    test('a short all-in does not reopen betting', () {
      newGame(['a', 'b', 'c'], dealer: 0, stacks: {'c': 170}); // c has 150 behind after the big blind
      act('a', 'call');
      act('b', 'call');
      act('c', 'check'); // flop, b acts first
      expect(street(), contains('Flop'));
      act('b', 'raise', 100); // b bets 100
      act('c', 'raise', 150); // c all in for 150: only 50 more, not a full raise
      act('a', 'call'); // a hadn't acted: a could have raised
      expect(toAct(), 'b');
      expect(canRaise('b'), isFalse); // b already acted: call or fold only
      expect(tryAct('b', 'raise', 400).ok, isFalse);
      act('b', 'call');
      expect(street(), contains('Turn'));
    });

    test('a full raise reopens betting', () {
      newGame(['a', 'b', 'c'], dealer: 0);
      act('a', 'call');
      act('b', 'call');
      act('c', 'check');
      act('b', 'raise', 100);
      act('c', 'raise', 200); // full raise
      act('a', 'fold');
      expect(canRaise('b'), isTrue);
    });

    test('everyone all in runs the board with side pots', () {
      final holes = [['As', 'Ad'], ['Ks', 'Kd'], ['Qs', 'Qd']];
      final board = ['2c', '7h', '9d', '3s', '4h'];
      // c deals, a posts the small blind, b the big blind; stacks 100 / 300 / 600
      newGame(['a', 'b', 'c'], dealer: 2, deck: stackedDeck(holes, board), stacks: {'a': 100, 'b': 300, 'c': 600});
      act('c', 'raise', 600);
      act('a', 'call');
      act('b', 'call');
      expect(phase(), 'hand_over');
      expect((g.publicState()['cards'] as List).length, 5);
      expect(chipsOf('a'), 300); // main pot 3 x 100
      expect(chipsOf('b'), 400); // side pot 2 x 200
      expect(chipsOf('c'), 300); // uncalled 300 comes back
      expect(total(), 1000);
    });

    test('split pot', () {
      final holes = [['2c', '3d'], ['2d', '3c']];
      final board = ['As', 'Ks', 'Qd', 'Jc', 'Th']; // board plays
      newGame(['a', 'b'], chips: 500, dealer: 0, deck: stackedDeck(holes, board));
      act('a', 'raise', 500);
      act('b', 'call');
      expect([chipsOf('a'), chipsOf('b')], [500, 500]);
      expect(phase(), 'hand_over');
    });

    test('odd chip goes left of the dealer', () {
      final holes = [['2c', '3d'], ['2d', '3c'], ['4c', '5c']];
      final board = ['As', 'Ks', 'Qd', 'Jc', 'Th'];
      newGame(['a', 'b', 'c'], dealer: 0, deck: stackedDeck(holes, board));
      act('a', 'call');
      act('b', 'fold'); // b's small blind (10) stays in: pot 50
      act('c', 'check');
      for (var i = 0; i < 3; i++) {
        act('c', 'check');
        act('a', 'check');
      }
      // pot 50 split between c and a; odd chip to the first winner left of dealer (b folded -> c)
      expect(chipsOf('c'), 1005);
      expect(chipsOf('a'), 1005);
      expect(chipsOf('b'), 990);
    });

    test('bust out and game over', () {
      final holes = [['As', 'Ad'], ['7c', '2d']];
      final board = ['Ac', 'Kd', '9h', '5s', '3c'];
      newGame(['a', 'b'], chips: 500, dealer: 0, deck: stackedDeck(holes, board));
      act('a', 'raise', 500);
      act('b', 'call');
      expect(phase(), 'over');
      expect(g.publicState()['banner'], 'a wins the game!');
      expect((g.publicState()['log'] as List), contains('b is out of chips.'));
      expect(chipsOf('a'), 1000);
      expect(tryAct('a', 'check').ok, isFalse);
    });

    test('a player leaving mid-hand', () {
      newGame(['a', 'b', 'c'], dealer: 0);
      final before = total();
      g.onPlayerRemoved('b'); // b (small blind) leaves out of turn
      expect(folded('b'), isTrue);
      act('a', 'fold'); // only c left: wins uncontested
      expect(phase(), 'hand_over');
      expect(total(), before);
      ready('a');
      ready('c');
      expect(phase(), 'betting');
      expect(dealtIn('b'), isFalse); // never dealt in again
      expect(ctx.updates, greaterThan(0));
    });

    test('leaving on your turn folds', () {
      newGame(['a', 'b'], dealer: 0);
      g.onPlayerRemoved('a');
      expect(phase(), 'over'); // only b has chips and hasn't left
      expect(g.publicState()['banner'], 'b wins the game!');
    });

    test('disconnected players sit out', () {
      newGame(['a', 'b', 'c'], dealer: 0);
      act('a', 'fold');
      act('b', 'fold');
      g.onPlayerConnectionChanged('b', false);
      ready('a');
      ready('c');
      expect(dealtIn('b'), isFalse);
      expect(ps.where((p) => dealtIn(p.id)).length, 2);
      act(toAct()!, 'fold');
      g.onPlayerConnectionChanged('c', false);
      ready('a');
      expect(phase(), 'waiting'); // only a is here
      expect(g.privateState('a').title, 'Waiting for players to reconnect');
      g.onPlayerConnectionChanged('b', true);
      expect(phase(), 'betting');
    });

    test('a disconnect can start the next hand when everyone else is ready', () {
      newGame(['a', 'b', 'c'], dealer: 0);
      act('a', 'fold');
      act('b', 'fold');
      ready('a');
      ready('b');
      expect(phase(), 'hand_over'); // still waiting for c
      g.onPlayerConnectionChanged('c', false);
      expect(phase(), 'betting');
      expect(dealtIn('c'), isFalse);
    });

    test('timeout checks or folds', () {
      newGame(['a', 'b', 'c'], dealer: 0);
      g.timeoutForTesting(); // a faces the big blind: fold
      expect(folded('a'), isTrue);
      act('b', 'call');
      g.timeoutForTesting(); // c can check
      expect(folded('c'), isFalse);
      expect(street(), contains('Flop'));
    });

    test('a disconnected player to act gets a grace timer of at most 20s', () {
      newGame(['a', 'b', 'c'], dealer: 0, turnSeconds: 60);
      expect(g.publicState()['secondsLeft'], inInclusiveRange(59, 60));
      g.onPlayerConnectionChanged('a', false); // a is to act
      expect(g.publicState()['secondsLeft'], inInclusiveRange(19, 20));
      g.onPlayerConnectionChanged('a', true);
      expect(g.publicState()['secondsLeft'], inInclusiveRange(19, 20)); // reconnecting never extends it

      newGame(['a', 'b', 'c'], dealer: 0, turnSeconds: 10);
      g.onPlayerConnectionChanged('a', false);
      expect(g.publicState()['secondsLeft'], inInclusiveRange(9, 10));

      newGame(['a', 'b', 'c'], dealer: 0, turnSeconds: 0);
      expect(g.publicState()['secondsLeft'], isNull);
      g.onPlayerConnectionChanged('a', false);
      expect(g.publicState()['secondsLeft'], inInclusiveRange(19, 20));
    });

    test('disconnect/reconnect cannot push the turn deadline later', () {
      newGame(['a', 'b', 'c'], dealer: 0, turnSeconds: 60);
      g.onPlayerConnectionChanged('a', false);
      final shortened = g.publicState()['secondsLeft'] as int;
      expect(shortened, inInclusiveRange(19, 20));
      for (var i = 0; i < 5; i++) {
        g.onPlayerConnectionChanged('a', true);
        g.onPlayerConnectionChanged('a', false);
      }
      g.onPlayerConnectionChanged('a', true);
      expect(g.publicState()['secondsLeft'] as int, lessThanOrEqualTo(shortened));

      // No turn limit: the grace deadline set on disconnect also survives reconnecting.
      newGame(['a', 'b', 'c'], dealer: 0, turnSeconds: 0);
      g.onPlayerConnectionChanged('a', false);
      g.onPlayerConnectionChanged('a', true);
      g.onPlayerConnectionChanged('a', false);
      g.onPlayerConnectionChanged('a', true);
      expect(g.publicState()['secondsLeft'], inInclusiveRange(19, 20));

      // A short turn limit is not extended up to the grace period either.
      newGame(['a', 'b', 'c'], dealer: 0, turnSeconds: 10);
      g.onPlayerConnectionChanged('a', false);
      g.onPlayerConnectionChanged('a', true);
      expect(g.publicState()['secondsLeft'] as int, lessThanOrEqualTo(10));
    });

    test('random games conserve chips', () {
      for (var seed = 0; seed < 40; seed++) {
        final rng = Random(seed);
        newGame(['a', 'b', 'c', 'd'], chips: 200, bb: 20, seed: seed);
        for (var i = 0; i < 2000; i++) {
          if (g.isOver) break;
          final pid = toAct();
          if (pid == null) {
            g.timeoutForTesting(); // hand over: deal the next one
            continue;
          }
          final sc = g.privateState(pid);
          final ids = sc.options.map((o) => o.id).toList();
          final move = [
            'fold',
            ids.contains('check') ? 'check' : 'call',
            if (ids.contains('raise')) 'raise',
          ][rng.nextInt(2 + (ids.contains('raise') ? 1 : 0))];
          final input = option(pid, 'raise')?.input;
          act(pid, move, move == 'raise' ? input!.min + rng.nextInt(input.max - input.min + 1) : null);
          expect(total(), 800, reason: 'seed $seed');
        }
        for (final p in ps) {
          expect(chipsOf(p.id), greaterThanOrEqualTo(0));
        }
        g.dispose();
      }
    });

    test('privacy: hole cards are only in the owner\'s secret screen', () {
      newGame(['a', 'b', 'c'], dealer: 0);
      expect(g.publicState().toString(), isNot(matches(RegExp('[♠♥♦♣]'))));
      final holes = {for (final p in ps) p.id: g.privateState(p.id).cards!};
      expect(g.publicState()['cards'], isEmpty);
      for (final p in ps) {
        final sc = g.privateState(p.id);
        expect(sc.cards, hasLength(2));
        expect(sc.secret, isTrue);
        final visible = '${sc.title} ${(sc.lines ?? []).join(' ')}';
        for (final c in sc.cards!) {
          expect(visible, isNot(contains(c)));
          expect(visible, isNot(contains(prettyCard(c))));
        }
        expect((sc.lines ?? []).join(' '), contains('Pot:'));
      }
      // still hidden after a street is dealt, while two players remain
      act('a', 'call');
      act('b', 'call');
      act('c', 'check');
      final pub = g.publicState().toString();
      for (final c in holes.values.expand((x) => x)) {
        expect(pub, isNot(contains(prettyCard(c))));
        expect(g.publicState()['cards'], isNot(contains(c)));
      }
    });
  });
}
