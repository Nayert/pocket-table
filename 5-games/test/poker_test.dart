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


  // ---- the chip tracker: cards are dealt at the table, the app keeps the chips ----
  group('poker chip tracker', () {
    late PokerGame g;
    late _Ctx ctx;
    late List<Player> ps;

    ActionResult tryHost(String id, {List<String> choice = const [], Object? value}) =>
        g.handleHostAction(PlayerAction(actionId: id, choice: choice, value: value));

    void host(String id, {List<String> choice = const [], Object? value}) {
      final r = tryHost(id, choice: choice, value: value);
      if (!r.ok) throw StateError('host $id: ${r.error}');
    }

    void newGame(List<String> ids,
        {int buyIn = 1000, int bb = 20, int? dealer = 0, Map<String, int>? stacks, int seed = 1, int turnSeconds = 0, bool autoRebuy = false, bool deal = true}) {
      ps = [for (final i in ids) Player(id: i, name: i, reconnectToken: 't$i')];
      ctx = _Ctx(seed);
      g = PokerGame(dealerForTesting: dealer, chipsForTesting: stacks)
        ..start(ctx, ps, {'buyIn': buyIn, 'bigBlind': bb, 'turnSeconds': turnSeconds, 'autoRebuy': autoRebuy});
      if (deal) host('next');
    }

    tearDown(() => g.dispose());

    HostControl? control(String id) => g.hostControls().where((c) => c.id == id).firstOrNull;

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
    String status(String id) => row(id)['value'] as String;
    int chipsOf(String id) => int.parse(RegExp(r'^(\d+) chips').firstMatch(status(id))!.group(1)!);
    int betOf(String id) => int.tryParse(RegExp(r'bet (\d+)').firstMatch(status(id))?.group(1) ?? '') ?? 0;
    bool folded(String id) => status(id).contains('folded');
    int pot() => int.parse(RegExp(r'Pot: (\d+)').firstMatch(g.publicState()['subtitle'] as String)!.group(1)!);
    int total() => pot() + [for (final p in ps) chipsOf(p.id)].reduce((a, b) => a + b);
    String title() => g.publicState()['title'] as String;
    String phase() {
      if (title().contains('Showdown')) return 'showdown';
      if (ps.any((p) => g.privateState(p.id).kind == ScreenKind.choice)) return 'betting';
      return 'between';
    }

    Option? option(String pid, String id) => g.privateState(pid).options.where((o) => o.id == id).firstOrNull;
    bool canRaise(String pid) => option(pid, 'allin') != null;
    int minTo(String pid) => option(pid, 'raise')!.input!.min;
    String dealerId() => ps[(g.publicState()['rows'] as List).indexWhere((r) => RegExp(r'\(D\b').hasMatch((r as Map)['label'] as String))].id;

    test('starts between hands with everyone bought in, and the host deals', () {
      newGame(['a', 'b', 'c'], deal: false, dealer: 1);
      expect(phase(), 'between');
      expect(title(), contains('b deals first'));
      expect([for (final p in ps) chipsOf(p.id)], [1000, 1000, 1000]);
      expect(control('next')!.label, 'Start first hand');
      expect(g.privateState('a').options.single.label, 'Ready');
      host('next');
      expect(phase(), 'betting');
      expect(dealerId(), 'b');
    });

    test('everyone pressing Ready also deals', () {
      newGame(['a', 'b'], deal: false);
      ready('a');
      expect(phase(), 'between');
      ready('b');
      expect(phase(), 'betting');
    });

    test('heads-up blinds and order', () {
      newGame(['a', 'b']);
      expect([betOf('a'), betOf('b')], [10, 20]); // dealer posts the small blind
      expect(row('a')['label'], 'a (D, SB)');
      expect(row('b')['label'], 'b (BB)');
      expect(toAct(), 'a'); // and acts first pre-flop
      act('a', 'call');
      expect(toAct(), 'b'); // big blind gets the option
      expect(canRaise('b'), isTrue);
      act('b', 'check');
      expect(title(), contains('Flop'));
      expect(g.publicState()['banner'], 'Deal the flop');
      expect(toAct(), 'b'); // big blind acts first after the flop
    });

    test('shows each bet this round and who still has to act', () {
      newGame(['a', 'b', 'c']);
      expect([for (final p in ps) betOf(p.id)], [0, 10, 20]);
      expect(g.publicState()['subtitle'], contains('Still to act: a, b, c'));
      expect(status('a'), contains('to act'));
      expect(row('a')['highlight'], isTrue);
      act('a', 'raise', 60);
      expect(betOf('a'), 60);
      expect(status('a'), contains('done'));
      expect(g.publicState()['subtitle'], contains('Still to act: b, c'));
      expect(g.publicState()['subtitle'], contains('This round: 90'));
      act('b', 'call');
      act('c', 'call');
      // New round: bets reset, the round's summary goes in the log.
      expect(title(), contains('Flop'));
      expect([for (final p in ps) betOf(p.id)], [0, 0, 0]);
      expect(pot(), 180);
      expect(g.publicState()['log'], contains('Pre-flop · pot 180: a 60, b 60, c 60'));
      expect(g.privateState('b').lines, contains('Your bet this round: 0'));
    });

    test('three-handed: the dealer moves on each hand', () {
      newGame(['a', 'b', 'c']);
      expect(toAct(), 'a');
      act('a', 'fold');
      act('b', 'fold');
      expect(phase(), 'between');
      expect(g.publicState()['log'], contains('c wins 30 (everyone else folded).'));
      expect(dealerId(), 'b'); // shown as next dealer
      host('next');
      expect(dealerId(), 'b');
      expect([for (final p in ps) betOf(p.id)], [20, 0, 10]);
    });

    test('the host can choose the dealer between hands', () {
      newGame(['a', 'b', 'c']);
      expect(control('dealer'), isNull); // not mid-hand
      act('a', 'fold');
      act('b', 'fold');
      host('dealer', choice: ['a']);
      expect(dealerId(), 'a');
      host('next');
      expect(dealerId(), 'a');
      expect([for (final p in ps) betOf(p.id)], [0, 10, 20]);
    });

    test('min raise, all in, and illegal moves', () {
      newGame(['a', 'b', 'c']);
      expect(minTo('a'), 40);
      expect(tryAct('b', 'call').ok, isFalse); // not b's turn
      expect(tryAct('a', 'check').ok, isFalse); // facing the big blind
      expect(tryAct('a', 'raise', 30).ok, isFalse);
      expect(tryAct('a', 'raise', 40.5).ok, isFalse);
      expect(tryAct('a', 'raise', 5000).ok, isFalse);
      expect(tryAct('zz', 'fold').ok, isFalse);
      act('a', 'raise', 60);
      expect(minTo('b'), 100);
      act('b', 'allin');
      expect(betOf('b'), 1000);
      expect(status('b'), contains('ALL IN'));
    });

    test('a short all-in does not reopen betting', () {
      newGame(['a', 'b', 'c'], stacks: {'c': 170});
      act('a', 'call');
      act('b', 'call');
      act('c', 'check');
      act('b', 'raise', 100);
      act('c', 'allin'); // 150: only 50 more, not a full raise
      act('a', 'call');
      expect(toAct(), 'b');
      expect(canRaise('b'), isFalse);
      act('b', 'call');
      expect(title(), contains('Turn'));
    });

    test('checking down goes to a showdown where the host picks the winner', () {
      newGame(['a', 'b', 'c']);
      act('a', 'call');
      act('b', 'call');
      act('c', 'check');
      for (var i = 0; i < 3; i++) {
        act('b', 'check');
        act('c', 'check');
        act('a', 'check');
      }
      expect(phase(), 'showdown');
      expect(g.publicState()['banner'], 'Who won the main pot?');
      expect(tryAct('a', 'check').ok, isFalse);
      final award = control('award')!;
      expect(award.primary, isTrue);
      expect(award.options.map((o) => o.id), ['b', 'c', 'a']); // from the dealer's left
      expect(tryHost('award', choice: ['zz']).ok, isFalse);
      host('award', choice: ['c']);
      expect(phase(), 'between');
      expect(chipsOf('c'), 1040);
      expect(total(), 3000);
      expect((g.publicState()['log'] as List).where((l) => (l as String).contains(' · pot ')).length, 4);
    });

    test('side pots are paid one at a time and uncalled chips come back', () {
      // c deals, a posts the small blind, b the big blind; stacks 100 / 300 / 600
      newGame(['a', 'b', 'c'], dealer: 2, stacks: {'a': 100, 'b': 300, 'c': 600});
      act('c', 'allin');
      act('a', 'call');
      act('b', 'call');
      expect(phase(), 'showdown');
      expect(chipsOf('c'), 300); // the uncalled 300 is back already
      expect(g.publicState()['banner'], contains('Deal out the rest'));
      expect(pot(), 700);
      host('award', choice: ['a']); // main pot 3 x 100
      expect(chipsOf('a'), 300);
      expect(control('award')!.options.map((o) => o.id), ['b', 'c']); // side pot: a isn't in it
      host('award', choice: ['b']); // side pot 2 x 200
      expect(chipsOf('b'), 400);
      expect(phase(), 'between');
      expect(total(), 1000);
    });

    test('split pot: odd chip goes left of the dealer', () {
      newGame(['a', 'b', 'c']);
      act('a', 'call');
      act('b', 'fold'); // b's small blind (10) stays in: pot 50
      act('c', 'check');
      for (var i = 0; i < 3; i++) {
        act('c', 'check');
        act('a', 'check');
      }
      host('award', choice: ['a', 'c']);
      expect(chipsOf('c'), 1005);
      expect(chipsOf('a'), 1005);
      expect(chipsOf('b'), 990);
    });

    test('a busted player sits out until the host adds chips', () {
      newGame(['a', 'b', 'c'], buyIn: 500);
      act('a', 'allin');
      act('b', 'fold');
      act('c', 'call');
      host('award', choice: ['c']);
      expect(chipsOf('a'), 0);
      expect(status('a'), contains('out of chips'));
      expect(g.publicState()['log'], contains('a is out of chips.'));
      expect(g.privateState('a').body, contains('out of chips'));
      expect(g.privateState('a').options, isEmpty);
      host('next');
      expect(g.privateState('a').title, contains('Hand 2'));
      expect(toAct(), isNot('a'));
      act(toAct()!, 'fold');
      // Revive a with the buy-in.
      final add = control('chips')!;
      expect(add.input!.defaultValue, 500);
      expect(add.options.firstWhere((o) => o.id == 'a').sub, 'out of chips');
      host('chips', choice: ['a'], value: 500);
      expect(chipsOf('a'), 500);
      expect(status('a'), contains('in for 1000 (-500)'));
      host('next');
      expect(row('a')['dim'], isFalse);
      expect(status('a'), isNot(contains('sitting out')));
    });

    test('nobody left to play waits for a revive instead of ending', () {
      newGame(['a', 'b']);
      act('a', 'allin');
      act('b', 'call');
      host('award', choice: ['b']);
      expect(g.isOver, isFalse);
      expect(control('next'), isNull);
      expect(tryHost('next').ok, isFalse);
      host('chips', choice: ['a'], value: 1000);
      expect(control('next'), isNotNull);
    });

    test('the buy-in can change mid-game, and auto rebuy uses it', () {
      newGame(['a', 'b', 'c'], autoRebuy: true);
      host('buyin', value: 2500);
      expect(control('buyin')!.label, 'Buy-in: 2500');
      expect(control('chips')!.input!.defaultValue, 2500);
      expect(g.publicState()['subtitle'], contains('Buy-in: 2500'));
      act('a', 'allin');
      act('b', 'fold');
      act('c', 'call');
      host('award', choice: ['c']);
      expect(chipsOf('a'), 2500); // rebought automatically
      expect(status('a'), contains('in for 3500'));
      host('autorebuy', choice: ['off']);
      expect(control('autorebuy')!.label, 'Auto rebuy: off');
    });

    test('chips cannot be added to a player still in the hand', () {
      newGame(['a', 'b', 'c']);
      expect(control('chips')!.options.map((o) => o.id), isEmpty);
      act('a', 'fold');
      expect(control('chips')!.options.map((o) => o.id), ['a']);
      expect(tryHost('chips', choice: ['b'], value: 100).ok, isFalse);
    });

    test('blinds change from the next hand', () {
      newGame(['a', 'b', 'c']);
      host('blinds', value: 50);
      expect([for (final p in ps) betOf(p.id)], [0, 10, 20]);
      act('a', 'fold');
      act('b', 'fold');
      host('next');
      expect([for (final p in ps) betOf(p.id)], [50, 0, 25]);
    });

    test('sitting out skips a player and keeps their chips', () {
      newGame(['a', 'b', 'c']);
      host('sitout', choice: ['c']);
      act('a', 'fold');
      act('b', 'fold');
      host('next');
      expect(status('c'), contains('sitting out'));
      expect(g.privateState('c').kind, ScreenKind.waiting);
      expect(chipsOf('c'), 1010);
    });

    test('the host can play for someone and undo mistakes', () {
      newGame(['a', 'b', 'c']);
      final pf = control('playfor')!;
      expect(pf.label, 'Play for a');
      expect(pf.options.map((o) => o.id), containsAll(['fold', 'call', 'raise', 'allin']));
      host('playfor', choice: ['raise'], value: 100);
      expect(betOf('a'), 100);
      host('undo');
      expect(betOf('a'), 0);
      expect(toAct(), 'a');
      expect(total(), 3000);
      act('a', 'call');
      act('b', 'call');
      act('c', 'check');
      expect(title(), contains('Flop'));
      host('undo'); // back to c's turn before the flop
      expect(title(), contains('Pre-flop'));
      expect(toAct(), 'c');
      act('c', 'check');
      // Undo a payout.
      for (var i = 0; i < 3; i++) {
        act('b', 'check');
        act('c', 'check');
        act('a', 'check');
      }
      host('award', choice: ['a']);
      host('undo');
      expect(phase(), 'showdown');
      host('award', choice: ['b']);
      expect(chipsOf('b'), 1040);
    });

    test('a player leaving mid-hand folds and clears undo', () {
      newGame(['a', 'b', 'c']);
      act('a', 'call');
      g.onPlayerRemoved('b');
      expect(folded('b'), isTrue);
      expect(control('undo'), isNull);
      act('c', 'check');
      expect(title(), contains('Flop'));
      act('c', 'fold');
      expect(phase(), 'between');
      host('next');
      expect(status('b'), contains('left'));
      expect(row('b')['dim'], isTrue);
      expect(ctx.updates, greaterThan(0));
    });

    test('offline players are still dealt in (the cards are real)', () {
      newGame(['a', 'b', 'c']);
      g.onPlayerConnectionChanged('a', false);
      expect(status('a'), contains('offline'));
      expect(toAct(), 'a');
      expect(g.publicState()['secondsLeft'], isNull); // no auto-fold
      act('a', 'fold');
      act('b', 'fold');
      host('next');
      expect(status('a'), isNot(contains('sitting out')));
    });

    test('timeout checks or folds', () {
      newGame(['a', 'b', 'c'], turnSeconds: 30);
      expect(g.publicState()['secondsLeft'], inInclusiveRange(29, 30));
      g.timeoutForTesting();
      expect(folded('a'), isTrue);
      act('b', 'call');
      g.timeoutForTesting();
      expect(folded('c'), isFalse);
      expect(title(), contains('Flop'));
    });

    test('random games conserve chips', () {
      for (var seed = 0; seed < 40; seed++) {
        final rng = Random(seed);
        newGame(['a', 'b', 'c', 'd'], buyIn: 200, bb: 20, seed: seed, dealer: seed % 4);
        var given = 800;
        for (var i = 0; i < 1500; i++) {
          final pid = toAct();
          if (pid == null) {
            final award = control('award');
            if (award != null) {
              final n = 1 + rng.nextInt(award.options.length);
              host('award', choice: [for (final o in (award.options.toList()..shuffle(rng)).take(n)) o.id]);
            } else if (control('next') != null) {
              host('next');
            } else {
              host('chips', choice: [ps[rng.nextInt(4)].id], value: 200);
              given += 200;
            }
            continue;
          }
          final ids = g.privateState(pid).options.map((o) => o.id).toList();
          final move = ids[rng.nextInt(ids.length)];
          final input = option(pid, 'raise')?.input;
          act(pid, move, move == 'raise' ? input!.min + rng.nextInt(input.max - input.min + 1) : null);
          if (rng.nextInt(20) == 0 && control('undo') != null) host('undo');
          // Undo can take back a rebuy, so count what's actually been given.
          final bought = ps.map((p) => int.parse(RegExp(r'in for (\d+)').firstMatch(status(p.id))?.group(1) ?? '0'));
          if (phase() == 'between') given = bought.reduce((a, b) => a + b);
          expect(total(), given, reason: 'seed $seed step $i');
        }
        for (final p in ps) {
          expect(chipsOf(p.id), greaterThanOrEqualTo(0));
        }
        g.dispose();
      }
    });
  });
}
