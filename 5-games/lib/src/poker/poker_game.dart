import 'dart:async';

import 'package:meta/meta.dart';
import 'package:platform_core/platform_core.dart';

import 'pots.dart';

class _Seat {
  _Seat(this.player, this.chips) : boughtIn = chips;
  final Player player;
  int chips;
  int boughtIn; // every chip this player was ever given (buy-in + rebuys)
  bool inHand = false; // dealt into the current hand
  bool folded = false;
  bool allIn = false;
  bool acted = false;
  bool mayRaise = true; // false once they've acted since the last full raise
  int roundBet = 0; // chips put in on this betting round
  int handBet = 0; // chips put in this hand (for side pots)
  bool readyForNext = false;
  bool sittingOut = false; // the host took them out of the deal for now
  bool connected = true;
  bool left = false; // left for good (kicked or pressed Leave)

  String get id => player.id;
  String get name => player.name;
  bool get live => inHand && !folded; // still in this hand
  bool get canAct => live && !allIn;

  /// Can be dealt into the next hand. Being offline doesn't matter: the
  /// cards are dealt at a real table, and the host can play for them.
  bool get canPlay => chips > 0 && !left && !sittingOut;

  /// Owes an action on this betting round.
  bool needsToAct(int currentBet) => canAct && (!acted || roundBet < currentBet);

  int get net => chips + handBet - boughtIn;

  List<Object> save() =>
      [chips, boughtIn, inHand, folded, allIn, acted, mayRaise, roundBet, handBet, readyForNext, sittingOut];
  void restore(List<Object> v) {
    chips = v[0] as int;
    boughtIn = v[1] as int;
    inHand = v[2] as bool;
    folded = v[3] as bool;
    allIn = v[4] as bool;
    acted = v[5] as bool;
    mayRaise = v[6] as bool;
    roundBet = v[7] as int;
    handBet = v[8] as int;
    readyForNext = v[9] as bool;
    sittingOut = v[10] as bool;
  }
}

enum _Phase { between, betting, showdown }

const _streetNames = ['Pre-flop', 'Flop', 'Turn', 'River'];
const _dealPrompts = ['', 'Deal the flop', 'Deal the turn', 'Deal the river'];
const _maxChipsInput = 1000000;

String _signed(int n) => n > 0 ? '+$n' : '$n';

/// Chip tracker for no-limit Texas Hold'em played with real cards.
///
/// The cards are dealt at the table; this keeps the chips: blinds, whose
/// turn it is, each player's bet on every betting round, side pots, and
/// paying out the winners the host picks. The host can top players up,
/// change the buy-in or blinds, choose the dealer and undo mistakes.
class PokerGame extends Game {
  /// [dealerForTesting] is the first dealer's seat and [chipsForTesting]
  /// gives named players different starting stacks. Tests only.
  PokerGame({this.dealerForTesting, this.chipsForTesting});

  @visibleForTesting
  final int? dealerForTesting;
  @visibleForTesting
  final Map<String, int>? chipsForTesting;

  @override
  String get id => 'poker';
  @override
  String get displayName => 'Poker';
  @override
  String get description =>
      "Chip tracker for Texas Hold'em. Deal real cards; the app keeps the chips, bets, pots and dealer.";
  @override
  int get minPlayers => 2;
  @override
  int get maxPlayers => 10;

  @override
  List<GameSetting> get settings => const [
        GameSetting.integer('buyIn', 'Buy-in (chips per player)', defaultValue: 1000, min: 100, max: 100000, step: 100),
        GameSetting.toggle('autoRebuy', 'Auto rebuy players who run out', defaultValue: false),
        GameSetting.integer('bigBlind', 'Big blind', defaultValue: 20, min: 2, max: 10000, step: 2),
        GameSetting.integer('turnSeconds', 'Seconds per turn (0 = no limit)', defaultValue: 0, min: 0, max: 300, step: 15),
      ];

  late GameContext _ctx;
  final _seats = <_Seat>[];
  int _buyIn = 1000;
  bool _autoRebuy = false;
  int _bigBlind = 20;
  int _smallBlind = 10;
  int _turnSeconds = 0;

  _Phase _phase = _Phase.between;
  int _hand = 0;
  int _dealer = -1; // dealer of the current (or last) hand
  int? _dealerPick; // the host's choice of dealer for the next hand
  int _sb = -1;
  int _bb = -1;
  int _street = 0;
  int _toAct = -1;
  int _currentBet = 0;
  int _minRaise = 0;
  int _actionCount = 0;
  List<Pot> _pots = []; // still to be paid out at the showdown
  int _potNumber = 0; // how many pots of this hand were paid out already
  List<String> _lastResult = [];
  List<String> _streets = []; // one summary per finished betting round of this hand
  List<String> _streetActions = []; // what happened on this betting round
  final List<String> _log = [];
  final List<void Function()> _undo = [];

  Timer? _timer;
  DateTime? _deadline;

  // ------------------------------------------------------------- lifecycle

  @override
  void start(GameContext ctx, List<Player> players, Map<String, Object> settings) {
    _ctx = ctx;
    _buyIn = settings['buyIn'] as int? ?? 1000;
    _autoRebuy = settings['autoRebuy'] as bool? ?? false;
    _setBlinds(settings['bigBlind'] as int? ?? 20);
    _turnSeconds = settings['turnSeconds'] as int? ?? 0;
    _seats
      ..clear()
      ..addAll(players.map((p) => _Seat(p, chipsForTesting?[p.id] ?? _buyIn)));
    _dealerPick = dealerForTesting ?? ctx.random.nextInt(_seats.length);
    _phase = _Phase.between;
    _log.add('Everyone bought in for $_buyIn.');
  }

  void _setBlinds(int bigBlind) {
    _bigBlind = bigBlind;
    _smallBlind = bigBlind ~/ 2 < 1 ? 1 : bigBlind ~/ 2;
  }

  @override
  void dispose() => _timer?.cancel();

  /// The game runs until the host ends it: busted players can be revived.
  @override
  bool get isOver => false;

  @override
  void onPlayerConnectionChanged(String playerId, bool connected) {
    final s = _seatOf(playerId);
    if (s == null) return;
    s.connected = connected;
    _ctx.requestUpdate(); // the table shows who is offline
  }

  /// Left for good (kicked or pressed Leave): fold now, never dealt in again.
  @override
  void onPlayerRemoved(String playerId) {
    final s = _seatOf(playerId);
    if (s == null || s.left) return;
    s.left = true;
    s.connected = false;
    _log.add('${s.name} left the game.');
    if (_phase == _Phase.betting && s.live) {
      if (_seats[_toAct] == s) {
        _apply(s, 'fold', null);
      } else {
        s.folded = true;
        _streetActions.add('${s.name} folds (left).');
        final live = _seats.where((x) => x.live).toList();
        if (live.length == 1) {
          _winUncontested(live.single);
        } else if (_roundDone()) {
          _endRound();
        }
      }
    } else if (_phase == _Phase.showdown) {
      _dropFromPots(s.id);
    } else if (_phase == _Phase.between && _allReady()) {
      _startHand();
    }
    _undo.clear(); // an undo must never bring them back into the hand
    _ctx.requestUpdate();
  }

  /// Test-only: what happens when the turn timer runs out.
  @visibleForTesting
  void timeoutForTesting() => _onTimeout();

  // ------------------------------------------------------------- dealing

  int _next(int from, bool Function(_Seat) test) {
    for (var i = 1; i <= _seats.length; i++) {
      final idx = (from + i) % _seats.length;
      if (test(_seats[idx])) return idx;
    }
    return -1;
  }

  /// Who deals the next hand: the host's pick, or the next player round
  /// the table from the last dealer.
  int get _nextDealer {
    final pick = _dealerPick;
    if (pick != null && _seats[pick].canPlay) return pick;
    return _next(pick ?? _dealer, (s) => s.canPlay);
  }

  List<_Seat> get _playable => _seats.where((s) => s.canPlay).toList();

  bool _allReady() => _playable.length >= 2 && _playable.every((x) => x.readyForNext);

  /// Deals a new hand and posts the blinds. Returns why it couldn't, or null.
  String? _startHand() {
    if (_playable.length < 2) return 'At least two players need chips to start a hand.';
    _setTimer(null);

    _hand++;
    _phase = _Phase.betting;
    _street = 0;
    _lastResult = [];
    _streets = [];
    _streetActions = [];
    _pots = [];
    _potNumber = 0;
    for (final s in _seats) {
      s
        ..inHand = s.canPlay
        ..folded = false
        ..allIn = false
        ..acted = false
        ..mayRaise = true
        ..roundBet = 0
        ..handBet = 0
        ..readyForNext = false;
    }

    _dealer = _nextDealer;
    _dealerPick = null;
    final headsUp = _seats.where((s) => s.inHand).length == 2;
    _sb = headsUp ? _dealer : _next(_dealer, (s) => s.live);
    _bb = _next(_sb, (s) => s.live);
    _post(_seats[_sb], _smallBlind);
    _post(_seats[_bb], _bigBlind);
    // If a blind is all in for less, players only need to match what was actually put in.
    _currentBet = _seats[_sb].roundBet > _seats[_bb].roundBet ? _seats[_sb].roundBet : _seats[_bb].roundBet;
    _minRaise = _bigBlind;
    _log.add('Hand $_hand: ${_seats[_dealer].name} deals.');
    _streetActions.add('${_seats[_sb].name} posts the small blind (${_seats[_sb].roundBet}).');
    _streetActions.add('${_seats[_bb].name} posts the big blind (${_seats[_bb].roundBet}).');

    // Blinds can put everyone all in: then nobody has anything to decide.
    final actors = _seats.where((s) => s.canAct).toList();
    if (actors.isEmpty || (actors.length == 1 && actors.single.roundBet >= _currentBet)) {
      _endRound();
      return null;
    }
    _toAct = _next(_bb, (s) => s.canAct);
    _afterChange();
    return null;
  }

  void _post(_Seat s, int amount) {
    final amt = amount < s.chips ? amount : s.chips;
    s.chips -= amt;
    s.roundBet += amt;
    s.handBet += amt;
    if (s.chips == 0) s.allIn = true;
  }

  int get _pot =>
      _phase == _Phase.showdown ? _pots.fold(0, (a, p) => a + p.amount) : _seats.fold(0, (a, s) => a + s.handBet);
  int get _roundPot => _seats.fold(0, (a, s) => a + s.roundBet);

  List<_Seat> get _stillToAct {
    if (_phase != _Phase.betting || _toAct < 0) return const [];
    // In turn order, starting with whoever is up now.
    return [
      for (var i = 0; i < _seats.length; i++)
        if (_seats[(_toAct + i) % _seats.length].needsToAct(_currentBet)) _seats[(_toAct + i) % _seats.length]
    ];
  }

  // ------------------------------------------------------------- betting

  ({List<Option> options, int toCall, int minTo, int maxTo, bool canRaise}) _optionsFor(_Seat s) {
    final toCall = _currentBet - s.roundBet;
    final othersCanAct = _seats.any((o) => o != s && o.canAct);
    final canRaise = s.chips > toCall && s.mayRaise && othersCanAct;
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
    if (canRaise) {
      if (maxTo > fullMinTo) {
        options.add(Option(
          'raise',
          _currentBet == 0 ? 'Bet' : 'Raise',
          input: OptionInput(
            min: minTo,
            max: maxTo,
            step: 1,
            label: _currentBet == 0 ? 'Bet' : 'Raise to',
            defaultValue: minTo,
          ),
        ));
      }
      options.add(Option('allin', 'All in ($maxTo)', sub: '${s.chips} more chips'));
    }
    return (options: options, toCall: toCall, minTo: minTo, maxTo: maxTo, canRaise: canRaise);
  }

  String get _actionId => 'h$_hand-a$_actionCount';

  @override
  ActionResult handleAction(String playerId, PlayerAction action) {
    final s = _seatOf(playerId);
    if (s == null) return const ActionResult.error('You are not in this game.');

    switch (_phase) {
      case _Phase.between:
        if (action.first != 'next') return const ActionResult.error('Wait for the next hand.');
        if (!s.canPlay) return const ActionResult.error("You can't play the next hand.");
        s.readyForNext = true;
        if (_allReady()) {
          _saveUndo();
          _startHand();
        }
        return const ActionResult.ok();
      case _Phase.showdown:
        return const ActionResult.error('The host is paying out the pot.');
      case _Phase.betting:
        if (_toAct < 0 || _seats[_toAct] != s) return const ActionResult.error("It's not your turn.");
        if (action.actionId != _actionId) return const ActionResult.error('That turn has passed.');
        return _apply(s, action.first, action.value);
    }
  }

  /// [s] (whose turn it is) makes [move]. Checks it's legal first.
  ActionResult _apply(_Seat s, String? move, Object? value) {
    final o = _optionsFor(s);
    final restore = _capture();
    switch (move) {
      case 'fold':
        s.folded = true;
        _streetActions.add('${s.name} folds.');
      case 'check':
        if (o.toCall > 0) return const ActionResult.error("You can't check, there's a bet.");
        _streetActions.add('${s.name} checks.');
      case 'call':
        if (o.toCall <= 0) return const ActionResult.error('Nothing to call.');
        final before = s.chips;
        _post(s, o.toCall);
        _streetActions.add('${s.name} calls ${before - s.chips}${s.allIn ? ' (all in)' : ''}.');
      case 'raise' || 'allin':
        if (!o.canRaise) return const ActionResult.error("You can't raise now.");
        final int? to;
        if (move == 'allin') {
          to = o.maxTo;
        } else {
          to = value is num && value == value.roundToDouble() ? value.toInt() : null; // whole numbers only
          if (to == null || to < o.minTo || to > o.maxTo) {
            return ActionResult.error('Raise to between ${o.minTo} and ${o.maxTo}.');
          }
        }
        _post(s, to - s.roundBet);
        final raiseBy = to - _currentBet;
        final full = raiseBy >= _minRaise;
        if (full) _minRaise = raiseBy; // a short all-in doesn't change the minimum
        final wasBet = _currentBet == 0;
        _currentBet = to;
        for (final other in _seats) {
          if (other != s) {
            other.acted = false; // everyone has to respond again
            if (full) other.mayRaise = true; // a full raise reopens the betting
          }
        }
        _streetActions.add('${s.name} ${wasBet ? 'bets' : 'raises to'} $to${s.allIn ? ' (all in)' : ''}.');
      default:
        return const ActionResult.error('Unknown move.');
    }
    _pushUndo(restore);
    s.acted = true;
    s.mayRaise = false;
    _advance();
    return const ActionResult.ok();
  }

  /// After an action: move to the next player, the next round, or the showdown.
  void _advance() {
    final live = _seats.where((s) => s.live).toList();
    if (live.length == 1) return _winUncontested(live.single);

    if (!_roundDone()) {
      _toAct = _next(_toAct, (s) => s.needsToAct(_currentBet));
      _afterChange();
      return;
    }
    _endRound();
  }

  bool _roundDone() {
    final actors = _seats.where((s) => s.canAct).toList();
    return actors.isEmpty ||
        actors.every((s) => s.acted && s.roundBet == _currentBet) ||
        (actors.length == 1 && actors.single.roundBet >= _currentBet);
  }

  /// "Flop · pot 180: Ana 40, Ben 40 (folded), Cal 100 (all in)"
  String _roundSummary() {
    final bets = [
      for (final s in _seats)
        if (s.inHand && (s.roundBet > 0 || s.live))
          '${s.name} ${s.roundBet}${s.folded ? ' (folded)' : s.allIn ? ' (all in)' : ''}'
    ];
    return '${_streetNames[_street]} · pot $_pot: ${bets.join(', ')}';
  }

  /// The betting round is over: on to the next card, or the showdown.
  void _endRound() {
    _streets.add(_roundSummary());
    _streetActions = [];
    for (final s in _seats) {
      s
        ..roundBet = 0
        ..mayRaise = true
        ..acted = false;
    }
    _currentBet = 0;
    _minRaise = _bigBlind;

    // After the river, or when fewer than two players can still bet, there's
    // nothing left to decide: deal the rest out and show the hands.
    if (_street == 3 || _seats.where((s) => s.canAct).length < 2) return _startShowdown();
    _street++;
    _toAct = _next(_dealer, (s) => s.canAct);
    _afterChange();
  }

  List<String> _orderFromDealer() =>
      [for (var i = 1; i <= _seats.length; i++) _seats[(_dealer + i) % _seats.length].id];

  void _startShowdown() {
    _phase = _Phase.showdown;
    _toAct = -1;
    _setTimer(null);
    _actionCount++;
    final order = _orderFromDealer();
    _pots = buildPots({for (final s in _seats) s.id: s.handBet}, {for (final s in _seats) if (s.folded) s.id})
      ..forEach((p) => p.eligible.sort((a, b) => order.indexOf(a).compareTo(order.indexOf(b))));
    _lastResult = [];
    _payObviousPots();
  }

  /// A pot only one player can win (e.g. an uncalled all-in) goes straight to them.
  void _payObviousPots() {
    for (final p in [..._pots]) {
      if (p.eligible.length == 1) {
        final s = _seatOf(p.eligible.single)!;
        s.chips += p.amount;
        _lastResult.add('${s.name} gets ${p.amount} back (nobody could match it).');
        _pots.remove(p);
      }
    }
    if (_pots.isEmpty) _endHand();
  }

  String get _potName => _potNumber == 0 ? 'the main pot' : 'side pot $_potNumber';

  /// The host picked who won the next pot. Split pots: the odd chips go to the
  /// first winner left of the dealer.
  void _awardPot(List<String> winnerIds) {
    final pot = _pots.removeAt(0);
    final order = _orderFromDealer();
    final winners = order.where(winnerIds.contains).map((id) => _seatOf(id)!).toList();
    final share = pot.amount ~/ winners.length;
    final rem = pot.amount % winners.length;
    for (var i = 0; i < winners.length; i++) {
      winners[i].chips += share + (i < rem ? 1 : 0);
    }
    final name = _potName;
    final line = winners.length == 1
        ? '${winners.single.name} wins $name (${pot.amount}).'
        : '${winners.map((w) => w.name).join(' and ')} split $name (${pot.amount}).';
    _lastResult.add(line);
    _log.add(line);
    _potNumber++;
    _actionCount++;
    _payObviousPots();
  }

  /// A player left during the showdown: they can't win anything now.
  void _dropFromPots(String id) {
    for (var i = 0; i < _pots.length; i++) {
      _pots[i].eligible.remove(id);
    }
    // A pot nobody can win any more joins the pot before it.
    for (var i = _pots.length - 1; i >= 0; i--) {
      if (_pots[i].eligible.isEmpty) {
        final dead = _pots.removeAt(i);
        if (i > 0) {
          _pots[i - 1].amount += dead.amount;
        } else if (_pots.isNotEmpty) {
          _pots[0].amount += dead.amount;
        }
      }
    }
    _payObviousPots();
  }

  void _winUncontested(_Seat winner) {
    _streets.add(_roundSummary());
    final pot = _pot;
    winner.chips += pot;
    _lastResult = ['${winner.name} wins $pot (everyone else folded).'];
    _log.add(_lastResult.single);
    _endHand();
  }

  void _endHand() {
    _phase = _Phase.between;
    _toAct = -1;
    _pots = [];
    _setTimer(null);
    _actionCount++;
    for (final s in _seats) {
      s
        ..handBet = 0
        ..roundBet = 0
        ..readyForNext = false;
      if (s.inHand && s.chips == 0 && !s.left) {
        if (_autoRebuy) {
          s
            ..chips = _buyIn
            ..boughtIn += _buyIn;
          _lastResult.add('${s.name} is out of chips and rebuys for $_buyIn.');
        } else {
          _lastResult.add('${s.name} is out of chips.');
        }
      }
    }
  }

  /// Start the right timer for the new turn.
  void _afterChange() {
    _actionCount++;
    if (_phase == _Phase.betting && _toAct >= 0 && _turnSeconds > 0) {
      _setTimer(Duration(seconds: _turnSeconds), _onTimeout);
    } else {
      _setTimer(null);
    }
  }

  /// Time ran out: check if possible, otherwise fold.
  void _onTimeout() {
    if (_phase != _Phase.betting || _toAct < 0) return;
    final s = _seats[_toAct];
    _apply(s, _currentBet - s.roundBet <= 0 ? 'check' : 'fold', null);
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

  // ------------------------------------------------------------- undo

  /// Everything a move can change, so the host can put it back.
  void Function() _capture() {
    final seats = [for (final s in _seats) s.save()];
    final phase = _phase, hand = _hand, dealer = _dealer, dealerPick = _dealerPick, sb = _sb, bb = _bb;
    final street = _street, toAct = _toAct, currentBet = _currentBet, minRaise = _minRaise;
    final buyIn = _buyIn, autoRebuy = _autoRebuy, bigBlind = _bigBlind, potNumber = _potNumber;
    final pots = [for (final p in _pots) Pot(p.amount, [...p.eligible])];
    final lastResult = [..._lastResult], streets = [..._streets], streetActions = [..._streetActions];
    final logLength = _log.length;
    return () {
      for (var i = 0; i < _seats.length; i++) {
        _seats[i].restore(seats[i]);
      }
      _phase = phase;
      _hand = hand;
      _dealer = dealer;
      _dealerPick = dealerPick;
      _sb = sb;
      _bb = bb;
      _street = street;
      _toAct = toAct;
      _currentBet = currentBet;
      _minRaise = minRaise;
      _buyIn = buyIn;
      _autoRebuy = autoRebuy;
      _setBlinds(bigBlind);
      _potNumber = potNumber;
      _pots = pots;
      _lastResult = lastResult;
      _streets = streets;
      _streetActions = streetActions;
      if (_log.length > logLength) _log.removeRange(logLength, _log.length);
    };
  }

  void _pushUndo(void Function() restore) {
    _undo.add(restore);
    if (_undo.length > 50) _undo.removeAt(0);
  }

  void _saveUndo() => _pushUndo(_capture());

  // ------------------------------------------------------------- host controls

  List<Option> _seatOptions(bool Function(_Seat) test, [String? Function(_Seat)? sub]) => [
        for (final s in _seats)
          if (test(s)) Option(s.id, s.name, sub: sub?.call(s))
      ];

  @override
  List<HostControl> hostControls() {
    final controls = <HostControl>[];
    switch (_phase) {
      case _Phase.between:
        if (_playable.length >= 2) {
          controls.add(HostControl('next', _hand == 0 ? 'Start first hand' : 'Next hand', primary: true));
        }
        final dealerChoices = _seatOptions((s) => s.canPlay);
        if (dealerChoices.length >= 2) {
          controls.add(HostControl('dealer', 'Choose dealer',
              options: dealerChoices, help: 'Who deals the next hand. After that the button moves on as usual.'));
        }
      case _Phase.betting:
        final s = _seats[_toAct];
        controls.add(HostControl('playfor', 'Play for ${s.name}',
            options: _optionsFor(s).options, help: "Make ${s.name}'s move for them (e.g. their phone is off)."));
      case _Phase.showdown:
        final pot = _pots.first;
        controls.add(HostControl('award', 'Who won ${_potName}?',
            primary: true,
            multi: true,
            options: [for (final id in pot.eligible) Option(id, _seatOf(id)!.name)], // from the dealer's left
            help: 'Pick the winner of ${_potName} (${pot.amount}). Pick more than one to split it.'));
    }
    controls.add(HostControl('chips', 'Add chips',
        options: _seatOptions((s) => !s.left && !(_phase == _Phase.betting && s.live),
            (s) => s.chips == 0 ? 'out of chips' : '${s.chips} chips'),
        input: OptionInput(min: 1, max: _maxChipsInput, label: 'Chips to add', defaultValue: _buyIn),
        help: 'Rebuy or revive a player. Players still in a hand can be topped up once it ends.'));
    controls.add(HostControl('buyin', 'Buy-in: $_buyIn',
        input: OptionInput(min: 1, max: _maxChipsInput, label: 'New buy-in', defaultValue: _buyIn),
        help: 'How many chips a rebuy gives. Stacks already on the table stay as they are.'));
    controls.add(HostControl('autorebuy', 'Auto rebuy: ${_autoRebuy ? 'on' : 'off'}',
        options: const [Option('on', 'On', sub: 'Out of chips? Rebuy for the buy-in automatically'), Option('off', 'Off')]));
    controls.add(HostControl('blinds', 'Blinds: $_smallBlind/$_bigBlind',
        input: OptionInput(min: 2, max: 100000, label: 'New big blind', defaultValue: _bigBlind),
        help: 'Takes effect from the next hand. The small blind is half the big blind.'));
    final sitChoices = _seatOptions((s) => !s.left, (s) => s.sittingOut ? 'sitting out' : 'playing');
    controls.add(HostControl('sitout', 'Sit out / back in',
        options: sitChoices, help: 'Takes effect from the next hand. Players sitting out keep their chips.'));
    if (_undo.isNotEmpty) controls.add(const HostControl('undo', 'Undo'));
    return controls;
  }

  @override
  ActionResult handleHostAction(PlayerAction action) {
    final pick = action.first;
    final seat = pick == null ? null : _seatOf(pick);
    final amount = action.intValue;
    switch (action.actionId) {
      case 'next':
        if (_phase != _Phase.between) return const ActionResult.error('A hand is already going.');
        final restore = _capture();
        final error = _startHand();
        if (error != null) return ActionResult.error(error);
        _pushUndo(restore);
      case 'dealer':
        if (_phase != _Phase.between) return const ActionResult.error('Choose the dealer between hands.');
        if (seat == null || !seat.canPlay) return const ActionResult.error("They can't deal the next hand.");
        _saveUndo();
        _dealerPick = _seats.indexOf(seat);
        _log.add('${seat.name} will deal the next hand.');
      case 'playfor':
        if (_phase != _Phase.betting) return const ActionResult.error("It's nobody's turn.");
        return _apply(_seats[_toAct], pick, action.value);
      case 'award':
        if (_phase != _Phase.showdown || _pots.isEmpty) return const ActionResult.error('There is no pot to pay out.');
        if (action.choice.isEmpty || !action.choice.every(_pots.first.eligible.contains)) {
          return const ActionResult.error('Only players still in for this pot can win it.');
        }
        _saveUndo();
        _awardPot(action.choice);
      case 'chips':
        if (seat == null || seat.left) return const ActionResult.error('Pick a player.');
        if (_phase == _Phase.betting && seat.live) {
          return const ActionResult.error("Chips can't be added during a hand they're in.");
        }
        if (amount == null || amount < 1) return const ActionResult.error('Enter how many chips.');
        _saveUndo();
        seat
          ..chips += amount
          ..boughtIn += amount;
        _log.add('${seat.name} adds $amount chips.');
        _lastResult.add('${seat.name} adds $amount chips.');
      case 'buyin':
        if (amount == null || amount < 1) return const ActionResult.error('Enter the buy-in.');
        _saveUndo();
        _buyIn = amount;
        _log.add('The buy-in is now $amount.');
      case 'autorebuy':
        _saveUndo();
        _autoRebuy = pick == 'on';
      case 'blinds':
        if (amount == null || amount < 2) return const ActionResult.error('The big blind must be at least 2.');
        _saveUndo();
        _setBlinds(amount);
        _log.add('Blinds are now $_smallBlind/$_bigBlind from the next hand.');
      case 'sitout':
        if (seat == null || seat.left) return const ActionResult.error('Pick a player.');
        _saveUndo();
        seat.sittingOut = !seat.sittingOut;
        if (_dealerPick != null && !_seats[_dealerPick!].canPlay) _dealerPick = null;
      case 'undo':
        if (_undo.isEmpty) return const ActionResult.error('Nothing to undo.');
        _undo.removeLast()();
        _actionCount++; // screens from before the undo are out of date
        if (_phase == _Phase.betting) {
          _afterChange();
        } else {
          _setTimer(null);
        }
      default:
        return const ActionResult.error('Unknown button.');
    }
    return const ActionResult.ok();
  }

  // ------------------------------------------------------------- what people see

  List<String> _info(_Seat s) => [
        'Pot: $_pot',
        'Your chips: ${s.chips}',
        if (_phase == _Phase.betting && s.inHand) 'Your bet this round: ${s.roundBet}',
      ];

  String _stillToActLine() {
    final names = _stillToAct.map((s) => s.name).toList();
    return names.isEmpty ? '' : 'Still to act: ${names.join(', ')}';
  }

  @override
  Screen privateState(String playerId) {
    final s = _seatOf(playerId);
    if (s == null) return Screen.waiting('Watching this game.');
    if (s.left) return Screen.waiting('You left the game.');

    final standing = 'Bought in: ${s.boughtIn} (net ${_signed(s.net)})';
    switch (_phase) {
      case _Phase.between:
        final showReady = s.canPlay && !s.readyForNext;
        return Screen.results(
          title: _hand == 0 ? 'Ready to play' : 'Hand $_hand is over',
          body: s.left
              ? null
              : s.chips == 0
                  ? "You're out of chips. Ask the host to add some."
                  : s.sittingOut
                      ? "You're sitting out. Ask the host to deal you back in."
                      : null,
          lines: [..._lastResult, 'Your chips: ${s.chips}', standing, 'Next dealer: ${_dealerName()}'],
          options: showReady ? [Option('next', _hand == 0 ? 'Ready' : 'Next hand')] : const [],
          actionId: showReady ? 'next-$_hand' : null,
        );
      case _Phase.showdown:
        return Screen.waiting('Show your cards. The host is paying out the pot.',
            title: 'Showdown', lines: [..._info(s), if (s.live) 'You put in: ${s.handBet}']);
      case _Phase.betting:
        final street = _streetNames[_street];
        if (!s.inHand) {
          return Screen.waiting(s.chips == 0 ? "You're out of chips. Ask the host to add some." : "You're not in this hand.",
              title: 'Hand $_hand · $street', lines: _info(s));
        }
        if (s.folded) {
          return Screen.waiting('Wait for the next hand.', title: 'You folded', lines: [..._info(s), _stillToActLine()]);
        }
        if (_toAct >= 0 && _seats[_toAct] == s) {
          final o = _optionsFor(s);
          return Screen.choice(
            actionId: _actionId,
            title: 'Your turn · $street',
            lines: [..._info(s), if (o.toCall > 0) 'To call: ${o.toCall}'],
            options: o.options,
            secondsLeft: secondsUntil(_deadline),
          );
        }
        final who = _toAct >= 0 ? _seats[_toAct].name : 'the deal';
        return Screen.waiting(null,
            title: s.allIn ? 'You are all in · $street' : 'Waiting for $who · $street',
            lines: [..._info(s), _stillToActLine()]);
    }
  }

  String _dealerName() {
    final d = _phase == _Phase.between ? _nextDealer : _dealer;
    return d < 0 ? 'nobody yet' : _seats[d].name;
  }

  @override
  Map<String, dynamic> publicState() {
    final rows = [
      for (var i = 0; i < _seats.length; i++)
        {
          'label': _seatLabel(i),
          'value': _seatStatus(_seats[i]),
          'highlight': i == _toAct,
          'dim': _seats[i].left ||
              (_phase == _Phase.between ? !_seats[i].canPlay : (!_seats[i].inHand || _seats[i].folded)),
        }
    ];
    final street = _streetNames[_street];
    final subtitle = <String>[
      'Pot: $_pot',
      if (_phase == _Phase.betting) ...[
        'This round: $_roundPot',
        if (_currentBet > 0) 'To match: $_currentBet',
        if (_stillToActLine().isNotEmpty) _stillToActLine(),
      ],
      'Blinds: $_smallBlind/$_bigBlind',
      'Buy-in: $_buyIn',
    ];
    String? banner;
    if (_phase == _Phase.showdown) {
      banner = _street < 3 ? 'Deal out the rest, then pick who won ${_potName}' : 'Who won ${_potName}?';
    } else if (_phase == _Phase.betting && _street > 0 && !_seats.any((s) => s.acted)) {
      banner = _dealPrompts[_street];
    }
    return {
      'title': switch (_phase) {
        _Phase.between => _hand == 0 ? 'Ready to start · ${_dealerName()} deals first' : 'Hand $_hand over · ${_dealerName()} deals next',
        _Phase.betting => 'Hand $_hand · $street',
        _Phase.showdown => 'Hand $_hand · Showdown',
      },
      'subtitle': subtitle.join('   ·   '),
      if (banner != null) 'banner': banner,
      'secondsLeft': secondsUntil(_deadline),
      'rows': rows,
      'log': [
        ..._streets,
        if (_phase == _Phase.betting) ..._streetActions.reversed.take(6).toList().reversed,
        ..._lastResult,
      ],
    };
  }

  String _seatLabel(int i) {
    final tags = <String>[
      if (_phase == _Phase.between ? i == _nextDealer : i == _dealer) 'D',
      if (_phase != _Phase.between && i == _sb && _seats[i].inHand) 'SB',
      if (_phase != _Phase.between && i == _bb && _seats[i].inHand) 'BB',
    ];
    return '${_seats[i].name}${tags.isEmpty ? '' : ' (${tags.join(', ')})'}';
  }

  String _seatStatus(_Seat s) {
    final parts = <String>['${s.chips} chips'];
    if (_phase == _Phase.between) {
      parts.add('in for ${s.boughtIn} (${_signed(s.net)})');
      if (s.chips == 0 && !s.left) parts.add('out of chips');
    } else if (s.inHand) {
      if (_phase == _Phase.betting) parts.add('bet ${s.roundBet}');
      if (s.handBet > 0 && (_street > 0 || _phase == _Phase.showdown)) parts.add('in pot ${s.handBet}');
      if (s.folded) {
        parts.add('folded');
      } else if (s.allIn) {
        parts.add('ALL IN');
      } else if (_phase == _Phase.betting) {
        parts.add(s.needsToAct(_currentBet) ? 'to act' : 'done');
      }
    } else if (!s.left) {
      parts.add(s.chips == 0 ? 'out of chips' : 'sitting out');
    }
    if (s.sittingOut && !s.left && _phase == _Phase.between) parts.add('sitting out');
    if (s.left) parts.add('left');
    if (!s.connected && !s.left) parts.add('offline');
    return parts.join(' · ');
  }
}
