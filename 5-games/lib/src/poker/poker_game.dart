import 'dart:async';

import 'package:platform_core/platform_core.dart';

import 'cards.dart';
import 'hand_evaluator.dart';
import 'pots.dart';

class _Seat {
  _Seat(this.player, this.chips);
  final Player player;
  int chips;
  List<String> hole = [];
  bool folded = false;
  bool allIn = false;
  bool acted = false;
  int roundBet = 0; // chips put in on this street
  int handBet = 0; // chips put in this hand (for side pots)
  bool readyForNext = false;
  bool connected = true;

  String get id => player.id;
  String get name => player.name;
  bool get live => !folded && hole.isNotEmpty; // still in this hand
  bool get canAct => live && !allIn;
}

enum _Phase { betting, handOver, over }

const _streetNames = ['Pre-flop', 'Flop', 'Turn', 'River'];

/// No-limit Texas Hold'em with play chips.
class PokerGame extends Game {
  @override
  String get id => 'poker';
  @override
  String get displayName => 'Poker';
  @override
  String get description => "No-limit Texas Hold'em with play chips.";
  @override
  int get minPlayers => 2;
  @override
  int get maxPlayers => 9;

  @override
  List<GameSetting> get settings => const [
        GameSetting.integer('startingChips', 'Starting chips', defaultValue: 1000, min: 100, max: 100000, step: 100),
        GameSetting.integer('bigBlind', 'Big blind', defaultValue: 20, min: 2, max: 1000, step: 2),
        GameSetting.integer('turnSeconds', 'Seconds per turn (0 = no limit)', defaultValue: 60, min: 0, max: 300, step: 15),
      ];

  late GameContext _ctx;
  final _seats = <_Seat>[];
  int _bigBlind = 20;
  int _smallBlind = 10;
  int _turnSeconds = 60;

  _Phase _phase = _Phase.betting;
  int _hand = 0;
  int _dealer = -1;
  int _street = 0;
  int _toAct = -1;
  int _currentBet = 0;
  int _minRaise = 0;
  int _actionCount = 0;
  List<String> _deck = [];
  final List<String> _board = [];
  List<String> _lastResult = [];
  final Set<String> _shownHands = {};
  final List<String> _log = [];

  Timer? _timer;
  DateTime? _deadline;

  // ------------------------------------------------------------- lifecycle

  @override
  void start(GameContext ctx, List<Player> players, Map<String, Object> settings) {
    _ctx = ctx;
    final chips = settings['startingChips'] as int? ?? 1000;
    _bigBlind = settings['bigBlind'] as int? ?? 20;
    _smallBlind = _bigBlind ~/ 2 < 1 ? 1 : _bigBlind ~/ 2;
    _turnSeconds = settings['turnSeconds'] as int? ?? 60;
    _seats
      ..clear()
      ..addAll(players.map((p) => _Seat(p, chips)));
    _dealer = ctx.random.nextInt(_seats.length) - 1; // first hand moves it on by one
    _startHand();
  }

  @override
  void dispose() => _timer?.cancel();

  @override
  bool get isOver => _phase == _Phase.over;

  @override
  void onPlayerConnectionChanged(String playerId, bool connected) {
    _seatOf(playerId)?.connected = connected;
  }

  // ------------------------------------------------------------- dealing

  int _next(int from, bool Function(_Seat) test) {
    for (var i = 1; i <= _seats.length; i++) {
      final idx = (from + i) % _seats.length;
      if (test(_seats[idx])) return idx;
    }
    return -1;
  }

  void _startHand() {
    final withChips = _seats.where((s) => s.chips > 0).length;
    if (withChips < 2) {
      _phase = _Phase.over;
      _setTimer(null);
      final winner = _seats.firstWhere((s) => s.chips > 0, orElse: () => _seats.first);
      _log.add('${winner.name} wins the game!');
      return;
    }

    _hand++;
    _phase = _Phase.betting;
    _street = 0;
    _board.clear();
    _shownHands.clear();
    _lastResult = [];
    _deck = shuffledDeck(_ctx.random);
    for (final s in _seats) {
      s
        ..hole = []
        ..folded = false
        ..allIn = false
        ..acted = false
        ..roundBet = 0
        ..handBet = 0
        ..readyForNext = false;
    }
    final inHand = <_Seat>[for (final s in _seats) if (s.chips > 0) s];
    for (var round = 0; round < 2; round++) {
      for (final s in inHand) {
        s.hole.add(_deck.removeLast());
      }
    }

    _dealer = _next(_dealer, (s) => s.chips > 0);
    final headsUp = inHand.length == 2;
    final sb = headsUp ? _dealer : _next(_dealer, (s) => s.live);
    final bb = _next(sb, (s) => s.live);
    _post(_seats[sb], _smallBlind);
    _post(_seats[bb], _bigBlind);
    // If a blind is all in for less, players only need to match what was actually put in.
    _currentBet = _seats[sb].roundBet > _seats[bb].roundBet ? _seats[sb].roundBet : _seats[bb].roundBet;
    _minRaise = _bigBlind;
    _log.add('Hand $_hand: ${_seats[sb].name} posts ${_seats[sb].roundBet}, ${_seats[bb].name} posts ${_seats[bb].roundBet}.');

    // Blinds can put everyone all in: then just deal the cards out.
    final actors = _seats.where((s) => s.canAct).toList();
    if (actors.isEmpty || (actors.length == 1 && actors.single.roundBet >= _currentBet)) {
      _nextStreet();
      return;
    }
    _toAct = _next(bb, (s) => s.canAct);
    _afterChange();
  }

  void _post(_Seat s, int amount) {
    final amt = amount < s.chips ? amount : s.chips;
    s.chips -= amt;
    s.roundBet += amt;
    s.handBet += amt;
    if (s.chips == 0) s.allIn = true;
  }

  int get _pot => _seats.fold(0, (a, s) => a + s.handBet);

  // ------------------------------------------------------------- betting

  ({List<Option> options, int toCall, int minTo, int maxTo}) _optionsFor(_Seat s) {
    final toCall = _currentBet - s.roundBet;
    final options = <Option>[const Option('fold', 'Fold')];
    if (toCall <= 0) {
      options.add(const Option('check', 'Check'));
    } else {
      final amt = toCall < s.chips ? toCall : s.chips;
      options.add(Option('call', 'Call $amt', sub: amt == s.chips ? 'All in' : null));
    }
    final maxTo = s.roundBet + s.chips;
    final fullMinTo = _currentBet + _minRaise;
    final minTo = fullMinTo < maxTo ? fullMinTo : maxTo;
    if (s.chips > toCall) {
      options.add(Option(
        'raise',
        _currentBet == 0 ? 'Bet' : 'Raise',
        sub: maxTo <= fullMinTo ? 'All in only' : null,
        input: OptionInput(
          min: minTo,
          max: maxTo,
          step: 1,
          label: _currentBet == 0 ? 'Bet' : 'Raise to',
          defaultValue: minTo,
        ),
      ));
    }
    return (options: options, toCall: toCall, minTo: minTo, maxTo: maxTo);
  }

  String get _actionId => 'h$_hand-a$_actionCount';

  @override
  ActionResult handleAction(String playerId, PlayerAction action) {
    final s = _seatOf(playerId);
    if (s == null) return const ActionResult.error('You are not in this game.');

    if (_phase == _Phase.handOver) {
      if (action.first != 'next') return const ActionResult.error('Wait for the next hand.');
      s.readyForNext = true;
      final waiting = _seats.where((x) => x.chips > 0 && x.connected && !x.readyForNext);
      if (waiting.isEmpty) _startHand();
      return const ActionResult.ok();
    }
    if (_phase != _Phase.betting) return const ActionResult.error('The game is over.');
    if (_toAct < 0 || _seats[_toAct] != s) return const ActionResult.error("It's not your turn.");
    if (action.actionId != _actionId) return const ActionResult.error('That turn has passed.');

    final o = _optionsFor(s);
    switch (action.first) {
      case 'fold':
        s.folded = true;
        _log.add('${s.name} folds.');
      case 'check':
        if (o.toCall > 0) return const ActionResult.error("You can't check, there's a bet.");
        _log.add('${s.name} checks.');
      case 'call':
        if (o.toCall <= 0) return const ActionResult.error('Nothing to call.');
        final before = s.chips;
        _post(s, o.toCall);
        _log.add('${s.name} calls ${before - s.chips}${s.allIn ? ' (all in)' : ''}.');
      case 'raise':
        final to = action.intValue;
        if (s.chips <= o.toCall) return const ActionResult.error("You don't have enough to raise.");
        if (to == null || to < o.minTo || to > o.maxTo) {
          return ActionResult.error('Raise to between ${o.minTo} and ${o.maxTo}.');
        }
        _post(s, to - s.roundBet);
        final raiseBy = to - _currentBet;
        if (raiseBy >= _minRaise) _minRaise = raiseBy;
        _currentBet = to;
        for (final other in _seats) {
          if (other != s) other.acted = false; // everyone has to respond again
        }
        _log.add('${s.name} ${raiseBy == to ? 'bets' : 'raises to'} $to${s.allIn ? ' (all in)' : ''}.');
      default:
        return const ActionResult.error('Unknown move.');
    }
    s.acted = true;
    _advance();
    return const ActionResult.ok();
  }

  /// After an action: move to the next player, the next street, or the showdown.
  void _advance() {
    final live = _seats.where((s) => s.live).toList();
    if (live.length == 1) return _winUncontested(live.single);

    final actors = _seats.where((s) => s.canAct).toList();
    final roundDone = actors.every((s) => s.acted && s.roundBet == _currentBet) ||
        actors.isEmpty ||
        (actors.length == 1 && actors.single.roundBet >= _currentBet);

    if (!roundDone) {
      _toAct = _next(_toAct, (s) => s.canAct && (!s.acted || s.roundBet < _currentBet));
      _afterChange();
      return;
    }
    _nextStreet();
  }

  void _nextStreet() {
    for (final s in _seats) {
      s
        ..roundBet = 0
        ..acted = false;
    }
    _currentBet = 0;
    _minRaise = _bigBlind;

    if (_street == 3) return _showdown();
    _street++;
    _deck.removeLast(); // burn
    final count = _street == 1 ? 3 : 1;
    for (var i = 0; i < count; i++) {
      _board.add(_deck.removeLast());
    }
    _log.add('${_streetNames[_street]}: ${prettyCards(_board)}');

    // Nobody (or only one player) can still bet: deal the rest straight out.
    if (_seats.where((s) => s.canAct).length < 2) return _nextStreet();

    _toAct = _next(_dealer, (s) => s.canAct);
    _afterChange();
  }

  List<String> _orderFromDealer() =>
      [for (var i = 1; i <= _seats.length; i++) _seats[(_dealer + i) % _seats.length].id];

  void _showdown() {
    final live = _seats.where((s) => s.live).toList();
    final scores = {for (final s in live) s.id: bestHand([...s.hole, ..._board])};
    final pots = buildPots({for (final s in _seats) s.id: s.handBet}, {for (final s in _seats) if (!s.live) s.id});
    final won = awardPots(pots, scores, _orderFromDealer());

    _lastResult = [];
    for (final s in live) {
      _shownHands.add(s.id);
      _lastResult.add('${s.name}: ${prettyCards(s.hole)} (${describeScore(scores[s.id]!)})');
    }
    for (final e in won.entries) {
      final s = _seatOf(e.key)!;
      s.chips += e.value;
      final line = '${s.name} wins ${e.value} with ${describeScore(scores[s.id]!)}';
      _lastResult.add(line);
      _log.add('$line.');
    }
    _endHand();
  }

  void _winUncontested(_Seat winner) {
    final pot = _pot;
    winner.chips += pot;
    _lastResult = ['${winner.name} wins $pot (everyone else folded)'];
    _log.add('${winner.name} wins $pot.');
    _endHand();
  }

  void _endHand() {
    for (final s in _seats) {
      s
        ..handBet = 0
        ..roundBet = 0;
    }
    _toAct = -1;
    if (_seats.where((s) => s.chips > 0).length < 2) {
      _startHand(); // sets the game over
      return;
    }
    _phase = _Phase.handOver;
    _setTimer(const Duration(seconds: 12), _startHand);
  }

  /// Start the right timer for the new state.
  void _afterChange() {
    _actionCount++;
    if (_phase == _Phase.betting && _toAct >= 0 && _turnSeconds > 0) {
      _setTimer(Duration(seconds: _turnSeconds), _autoAct);
    } else if (_phase == _Phase.betting) {
      _setTimer(null);
    }
  }

  /// Time ran out: check if possible, otherwise fold.
  void _autoAct() {
    if (_phase != _Phase.betting || _toAct < 0) return;
    final s = _seats[_toAct];
    final canCheck = _currentBet - s.roundBet <= 0;
    handleAction(s.id, PlayerAction(actionId: _actionId, choice: [canCheck ? 'check' : 'fold']));
  }

  void _setTimer(Duration? d, [void Function()? onFire]) {
    _timer?.cancel();
    _timer = null;
    _deadline = d == null ? null : DateTime.now().add(d);
    if (d != null && onFire != null) {
      _timer = Timer(d, () {
        onFire();
        _ctx.requestUpdate();
      });
    }
  }

  _Seat? _seatOf(String id) => _seats.where((s) => s.id == id).firstOrNull;

  // ------------------------------------------------------------- what people see

  List<String> _tableLines() => [
        if (_board.isNotEmpty) 'Board: ${prettyCards(_board)}',
        'Pot: $_pot',
      ];

  @override
  Screen privateState(String playerId) {
    final s = _seatOf(playerId);
    if (s == null) return Screen.waiting('Watching this game.');

    if (_phase == _Phase.over) {
      final standings = [..._seats]..sort((a, b) => b.chips.compareTo(a.chips));
      return Screen.results(
        title: _log.last,
        lines: [..._lastResult, '', 'Final chips:', for (final x in standings) '${x.name}: ${x.chips}'],
      );
    }

    if (_phase == _Phase.handOver) {
      final canPlay = s.chips > 0;
      return Screen.results(
        title: 'Hand $_hand',
        cards: s.hole.isEmpty ? null : s.hole,
        lines: [if (_board.isNotEmpty) 'Board: ${prettyCards(_board)}', ..._lastResult, 'Your chips: ${s.chips}'],
        options: canPlay && !s.readyForNext ? const [Option('next', 'Next hand')] : const [],
        actionId: canPlay && !s.readyForNext ? 'next-$_hand' : null,
        secondsLeft: secondsUntil(_deadline),
      );
    }

    if (s.hole.isEmpty) return Screen.waiting("You're out of chips. Watch the rest of the game.", title: 'Out');

    final info = [..._tableLines(), 'Your chips: ${s.chips}'];
    if (s.folded) {
      return Screen.waiting('You folded. Wait for the next hand.', cards: s.hole, lines: info);
    }
    if (_toAct >= 0 && _seats[_toAct] == s) {
      final o = _optionsFor(s);
      return Screen.choice(
        actionId: _actionId,
        title: 'Your turn',
        cards: s.hole,
        lines: [...info, if (o.toCall > 0) 'To call: ${o.toCall}'],
        options: o.options,
        secondsLeft: secondsUntil(_deadline),
      );
    }
    final who = _toAct >= 0 ? _seats[_toAct].name : 'the deal';
    return Screen.waiting(s.allIn ? 'You are all in.' : 'Waiting for $who…', cards: s.hole, lines: info);
  }

  @override
  Map<String, dynamic> publicState() {
    final rows = [
      for (var i = 0; i < _seats.length; i++)
        {
          'label': '${_seats[i].name}${i == _dealer ? ' (D)' : ''}',
          'value': _seatStatus(_seats[i]),
          'highlight': i == _toAct,
          'dim': _seats[i].folded || (_seats[i].chips == 0 && _seats[i].hole.isEmpty),
        }
    ];
    return {
      'title': _phase == _Phase.over ? 'Game over' : 'Hand $_hand · ${_streetNames[_street]}',
      'subtitle': 'Pot: $_pot   Blinds: $_smallBlind/$_bigBlind',
      if (_phase == _Phase.over) 'banner': _log.last,
      'secondsLeft': secondsUntil(_deadline),
      'cards': _board,
      'rows': rows,
      'log': _phase == _Phase.handOver ? _lastResult : _log.reversed.take(6).toList().reversed.toList(),
    };
  }

  String _seatStatus(_Seat s) {
    final parts = <String>['${s.chips} chips'];
    if (s.roundBet > 0) parts.add('bet ${s.roundBet}');
    if (s.folded) parts.add('folded');
    if (s.allIn && !s.folded) parts.add('ALL IN');
    if (!s.connected) parts.add('offline');
    if (_shownHands.contains(s.id)) parts.add(prettyCards(s.hole));
    return parts.join(' · ');
  }
}
