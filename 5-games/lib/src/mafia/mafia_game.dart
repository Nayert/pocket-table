import 'dart:async';

import 'package:platform_core/platform_core.dart';

/// Ported from prototype/mafia.py (which has the tests that pin the rules down).
///
/// Phases loop: reveal -> night -> dawn -> day -> vote -> verdict -> night ...
/// A phase ends early once every living player has acted, otherwise when its
/// timer runs out (missing actions count as "no action" / abstain).
enum Role { mafia, doctor, detective, villager }

enum _Phase { reveal, night, dawn, day, vote, verdict, over }

const _nobody = 'nobody';
const _ready = 'ready';

const _roleNames = {
  Role.mafia: 'Mafia',
  Role.doctor: 'Doctor',
  Role.detective: 'Detective',
  Role.villager: 'Villager',
};

const _roleBlurbs = {
  Role.mafia: 'Each night, choose someone to kill with the other Mafia. By day, blend in.',
  Role.doctor: 'Each night, choose one person to protect. You can protect yourself.',
  Role.detective: 'Each night, investigate one person to learn if they are Mafia.',
  Role.villager: 'Find the Mafia and vote them out during the day.',
};

class MafiaGame extends Game {
  @override
  String get id => 'mafia';
  @override
  String get displayName => 'Mafia';
  @override
  String get description => 'Hidden roles. The town must find the Mafia before it is too late.';
  @override
  int get minPlayers => 4;
  @override
  int get maxPlayers => 20;

  @override
  List<GameSetting> get settings => const [
        GameSetting.integer('mafiaCount', 'Mafia (0 = automatic)', defaultValue: 0, min: 0, max: 6),
        GameSetting.toggle('doctor', 'Doctor', defaultValue: true),
        GameSetting.toggle('detective', 'Detective', defaultValue: true),
        GameSetting.toggle('revealRoles', 'Reveal roles when voted out', defaultValue: true),
        GameSetting.integer('nightSeconds', 'Night (seconds)', defaultValue: 60, min: 20, max: 300, step: 10),
        GameSetting.integer('daySeconds', 'Discussion (seconds)', defaultValue: 180, min: 30, max: 900, step: 30),
        GameSetting.integer('voteSeconds', 'Voting (seconds)', defaultValue: 60, min: 15, max: 300, step: 15),
      ];

  late GameContext _ctx;
  final List<Player> _players = [];
  final Map<String, Role> _roles = {};
  final Set<String> _alive = {};
  final Map<String, String> _acted = {};
  final List<String> _log = [];
  final Map<String, String> _detectiveResults = {};
  _Phase _phase = _Phase.reveal;
  int _round = 1;
  String? _winner;
  bool _revealRoles = true;
  late Map<_Phase, int> _durations;

  Timer? _timer;
  DateTime? _deadline;

  // ------------------------------------------------------------- setup

  @override
  void start(GameContext ctx, List<Player> players, Map<String, Object> settings) {
    _ctx = ctx;
    _players
      ..clear()
      ..addAll(players);
    _revealRoles = settings['revealRoles'] as bool? ?? true;
    _durations = {
      _Phase.reveal: 30,
      _Phase.night: settings['nightSeconds'] as int? ?? 60,
      _Phase.dawn: 20,
      _Phase.day: settings['daySeconds'] as int? ?? 180,
      _Phase.vote: settings['voteSeconds'] as int? ?? 60,
      _Phase.verdict: 20,
    };
    _assignRoles(
      mafiaCount: settings['mafiaCount'] as int? ?? 0,
      doctor: settings['doctor'] as bool? ?? true,
      detective: settings['detective'] as bool? ?? true,
    );
    _alive.addAll(_players.map((p) => p.id));
    _enter(_Phase.reveal);
  }

  void _assignRoles({required int mafiaCount, required bool doctor, required bool detective}) {
    final n = _players.length;
    final k = mafiaCount > 0 ? mafiaCount.clamp(1, n - 1).toInt() : (n ~/ 4 < 1 ? 1 : n ~/ 4);
    final specials = [if (doctor) Role.doctor, if (detective) Role.detective];
    while (specials.isNotEmpty && k + specials.length > n - 1) {
      specials.removeLast(); // drop detective first, then doctor
    }
    final roles = [
      for (var i = 0; i < k; i++) Role.mafia,
      ...specials,
    ];
    while (roles.length < n) {
      roles.add(Role.villager);
    }
    roles.shuffle(_ctx.random);
    for (var i = 0; i < n; i++) {
      _roles[_players[i].id] = roles[i];
    }
  }

  @override
  void dispose() => _timer?.cancel();

  @override
  bool get isOver => _phase == _Phase.over;

  // ------------------------------------------------------------- rules

  String _name(String id) => _players.firstWhere((p) => p.id == id).name;
  List<Player> get _alivePlayers => _players.where((p) => _alive.contains(p.id)).toList();
  List<String> get _mafiaIds => [for (final e in _roles.entries) if (e.value == Role.mafia) e.key];

  /// Option ids this player may pick right now (empty = nothing to do).
  List<String> _optionIds(String pid) {
    if (!_alive.contains(pid) || _acted.containsKey(pid) || _phase == _Phase.over) return const [];
    switch (_phase) {
      case _Phase.reveal || _Phase.dawn || _Phase.day || _Phase.verdict:
        return const [_ready];
      case _Phase.night:
        final others = [for (final p in _alivePlayers) if (p.id != pid) p.id];
        return switch (_roles[pid]!) {
          Role.mafia => [for (final id in others) if (_roles[id] != Role.mafia) id],
          Role.doctor => [for (final p in _alivePlayers) p.id],
          _ => others, // detective investigates; villagers pick a decoy "suspect"
        };
      case _Phase.vote:
        return [for (final p in _alivePlayers) if (p.id != pid) p.id, _nobody];
      case _Phase.over:
        return const [];
    }
  }

  String get _actionId => '${_phase.name}-$_round';

  @override
  ActionResult handleAction(String playerId, PlayerAction action) {
    final choice = action.first;
    if (action.actionId != _actionId) return const ActionResult.error('That phase has ended.');
    if (choice == null || !_optionIds(playerId).contains(choice)) {
      return const ActionResult.error("You can't choose that.");
    }
    _acted[playerId] = choice;
    if (_alive.every(_acted.containsKey)) _endPhase();
    return const ActionResult.ok();
  }

  void _enter(_Phase phase) {
    _phase = phase;
    _timer?.cancel();
    if (phase == _Phase.over) {
      _deadline = null;
      return;
    }
    final d = Duration(seconds: _durations[phase]!);
    _deadline = DateTime.now().add(d);
    _timer = Timer(d, () {
      _endPhase();
      _ctx.requestUpdate();
    });
  }

  void _endPhase() {
    final acted = Map.of(_acted);
    _acted.clear();
    switch (_phase) {
      case _Phase.reveal:
        _enter(_Phase.night);
      case _Phase.night:
        _resolveNight(acted);
        _enter(_checkWin() ? _Phase.over : _Phase.dawn);
      case _Phase.dawn:
        _detectiveResults.clear();
        _enter(_Phase.day);
      case _Phase.day:
        _enter(_Phase.vote);
      case _Phase.vote:
        _resolveVote(acted);
        _enter(_checkWin() ? _Phase.over : _Phase.verdict);
      case _Phase.verdict:
        _round++;
        _enter(_Phase.night);
      case _Phase.over:
        break;
    }
  }

  String? _plurality(List<String> votes) {
    if (votes.isEmpty) return null;
    final tally = <String, int>{};
    for (final v in votes) {
      tally[v] = (tally[v] ?? 0) + 1;
    }
    final top = tally.values.reduce((a, b) => a > b ? a : b);
    final tied = [for (final e in tally.entries) if (e.value == top) e.key]..sort();
    return tied[_ctx.random.nextInt(tied.length)];
  }

  void _resolveNight(Map<String, String> acted) {
    final target = _plurality([for (final e in acted.entries) if (_roles[e.key] == Role.mafia) e.value]);
    final saved = {for (final e in acted.entries) if (_roles[e.key] == Role.doctor) e.value};
    for (final e in acted.entries) {
      if (_roles[e.key] == Role.detective) {
        final isMafia = _roles[e.value] == Role.mafia;
        _detectiveResults[e.key] = '${_name(e.value)} is ${isMafia ? '' : 'NOT '}Mafia.';
      }
    }
    if (target != null && !saved.contains(target)) {
      _alive.remove(target);
      _log.add('Night $_round: ${_name(target)} was killed.');
    } else {
      _log.add('Night $_round: nobody died.');
    }
  }

  void _resolveVote(Map<String, String> acted) {
    if (acted.isEmpty) {
      _log.add('Day $_round: nobody voted.');
      return;
    }
    final tally = <String, int>{};
    for (final v in acted.values) {
      tally[v] = (tally[v] ?? 0) + 1;
    }
    final top = tally.values.reduce((a, b) => a > b ? a : b);
    final leaders = [for (final e in tally.entries) if (e.value == top) e.key];
    if (leaders.length > 1 || leaders.single == _nobody) {
      _log.add('Day $_round: no one was voted out.');
      return;
    }
    final out = leaders.single;
    _alive.remove(out);
    final extra = _revealRoles ? ' They were ${_roleNames[_roles[out]]}.' : '';
    _log.add('Day $_round: ${_name(out)} was voted out.$extra');
  }

  bool _checkWin() {
    final mafia = _alive.where((id) => _roles[id] == Role.mafia).length;
    final town = _alive.length - mafia;
    if (mafia == 0) {
      _winner = 'Town';
    } else if (mafia >= town) {
      _winner = 'Mafia';
    }
    return _winner != null;
  }

  // ------------------------------------------------------------- screens

  List<Option> _playerOptions(List<String> ids) =>
      [for (final id in ids) Option(id, id == _nobody ? 'Nobody' : _name(id))];

  @override
  Screen privateState(String pid) {
    final role = _roles[pid];
    if (role == null) return Screen.waiting('Watching this game.');
    final secs = secondsUntil(_deadline);
    final roleLine = 'You are: ${_roleNames[role]}';

    if (_phase == _Phase.over) {
      return Screen.results(
        title: '$_winner wins!',
        lines: [
          for (final p in _players)
            '${p.name}: ${_roleNames[_roles[p.id]]}${_alive.contains(p.id) ? '' : ' (dead)'}',
          ..._log,
        ],
      );
    }

    if (!_alive.contains(pid)) {
      return Screen.waiting("You're out. Stay quiet and watch!", title: 'Dead', lines: _log.reversed.take(3).toList());
    }

    final options = _optionIds(pid);
    if (options.isEmpty) {
      return Screen.waiting('Waiting for everyone else…', lines: [roleLine], secondsLeft: secs);
    }

    switch (_phase) {
      case _Phase.reveal:
        final team = role == Role.mafia ? [for (final id in _mafiaIds) if (id != pid) _name(id)] : <String>[];
        return Screen.private(
          title: 'You are ${role == Role.mafia ? 'in the Mafia' : 'the ${_roleNames[role]}'}',
          body: _roleBlurbs[role],
          lines: team.isEmpty ? null : ['Your fellow Mafia: ${team.join(', ')}'],
          options: const [Option(_ready, 'Got it')],
          actionId: _actionId,
          secondsLeft: secs,
        );

      case _Phase.night:
        final (title, body) = switch (role) {
          Role.mafia => ('Who should the Mafia kill?', 'Agree with your team. If you disagree, the most votes wins.'),
          Role.doctor => ('Who will you protect?', null),
          Role.detective => ('Who will you investigate?', null),
          Role.villager => ('Who do you suspect?', 'Everyone taps something at night so no one can tell who has a power.'),
        };
        final lines = <String>[roleLine];
        if (role == Role.mafia) {
          for (final id in _mafiaIds) {
            if (id != pid && _alive.contains(id)) {
              final pick = _acted[id];
              lines.add('${_name(id)}: ${pick == null ? 'deciding…' : _name(pick)}');
            }
          }
        }
        return Screen.choice(
          actionId: _actionId,
          title: 'Night $_round: $title',
          body: body,
          lines: lines,
          options: _playerOptions(options),
          secondsLeft: secs,
        );

      case _Phase.dawn:
        return Screen.private(
          title: 'Morning',
          body: _log.last,
          lines: [if (_detectiveResults[pid] != null) 'Your investigation: ${_detectiveResults[pid]}'],
          options: const [Option(_ready, 'Continue')],
          actionId: _actionId,
          secondsLeft: secs,
        );

      case _Phase.day:
        return Screen.private(
          title: 'Day $_round: discuss',
          body: 'Talk it over out loud. Who is lying?',
          lines: [roleLine, 'Alive: ${_alivePlayers.map((p) => p.name).join(', ')}'],
          options: const [Option(_ready, 'Ready to vote')],
          actionId: _actionId,
          secondsLeft: secs,
        );

      case _Phase.vote:
        return Screen.choice(
          actionId: _actionId,
          title: 'Vote someone out',
          lines: [roleLine],
          options: _playerOptions(options),
          secondsLeft: secs,
        );

      case _Phase.verdict:
        return Screen.private(
          title: 'The vote is in',
          body: _log.last,
          options: const [Option(_ready, 'Continue')],
          actionId: _actionId,
          secondsLeft: secs,
        );

      case _Phase.over:
        return Screen.waiting('Game over.');
    }
  }

  static const _phaseTitles = {
    _Phase.reveal: 'Check your role',
    _Phase.night: 'Night',
    _Phase.dawn: 'Morning',
    _Phase.day: 'Day: discussion',
    _Phase.vote: 'Voting',
    _Phase.verdict: 'Verdict',
    _Phase.over: 'Game over',
  };

  static const _narration = {
    _Phase.reveal: 'Everyone, look at your phone to see your role. Keep it secret!',
    _Phase.night: 'Everyone close your eyes… Mafia, Doctor and Detective, make your choices.',
    _Phase.dawn: 'Everyone open your eyes.',
    _Phase.day: 'Discuss! Who do you think is Mafia?',
    _Phase.vote: 'Time to vote on your phones.',
    _Phase.verdict: 'The town has spoken.',
  };

  @override
  Map<String, dynamic> publicState() {
    final over = _phase == _Phase.over;
    final waitingOn = _alive.where((id) => !_acted.containsKey(id)).length;
    return {
      'title': over || _phase == _Phase.reveal ? _phaseTitles[_phase] : '${_phaseTitles[_phase]} $_round',
      'subtitle': over ? null : '${_narration[_phase]}\n${_alive.length - waitingOn}/${_alive.length} ready',
      if (over) 'banner': '$_winner wins!',
      'secondsLeft': secondsUntil(_deadline),
      'rows': [
        for (final p in _players)
          {
            'label': p.name,
            'value': _alive.contains(p.id)
                ? (over ? _roleNames[_roles[p.id]] : 'alive')
                : 'dead${_revealRoles || over ? ' · ${_roleNames[_roles[p.id]]}' : ''}',
            'dim': !_alive.contains(p.id),
            'highlight': false,
          }
      ],
      'log': _log.reversed.take(6).toList().reversed.toList(),
    };
  }
}
