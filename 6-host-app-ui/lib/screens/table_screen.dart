import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:platform_core/platform_core.dart';

import '../host_controller.dart';
import '../widgets/playing_card.dart';
import 'lobby_screen.dart' show PlayerTile, StatusBanner, confirmKick;

/// The shared "table / TV" view on the host phone. Everyone in the room can
/// see it, so it draws ONLY the game's publicState() (the standard keys on
/// the Game interface: title, subtitle, banner, secondsLeft, cards, rows, log).
/// Roles and hole cards never reach this screen; players see those on their
/// own phones.
class TableScreen extends StatelessWidget {
  const TableScreen({super.key, required this.controller});
  final HostController controller;

  Future<void> _confirmEnd(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('End the game?'),
        content: const Text('Everyone goes back to the lobby.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep playing')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('End game')),
        ],
      ),
    );
    if (ok == true) controller.endGame();
  }

  void _showPlayers(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => ListenableBuilder(
        listenable: controller,
        builder: (ctx, _) {
          final players = controller.platform.players;
          return SafeArea(
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
              children: [
                Text('Players', style: Theme.of(ctx).textTheme.titleLarge),
                for (final pl in players)
                  PlayerTile(
                    name: pl.name,
                    connected: pl.connected,
                    onKick: () => confirmKick(ctx, controller, pl.id, pl.name),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }

  /// A host button: ask for the picks / number it needs, then send it.
  Future<void> _pressControl(BuildContext context, HostControl hc) async {
    var answer = (choice: const <String>[], value: null as int?);
    if (hc.options.isNotEmpty || hc.input != null) {
      final a = await showDialog<({List<String> choice, int? value})>(
        context: context,
        builder: (_) => HostControlDialog(control: hc),
      );
      if (a == null) return;
      answer = a;
    }
    final error = controller.hostAction(hc.id, choice: answer.choice, value: answer.value);
    if (error != null && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = controller.platform;
    final game = p.activeGame;
    if (game == null) return const SizedBox.shrink();
    final s = game.publicState();
    final theme = Theme.of(context);

    final banner = s['banner'] as String?;
    final secondsLeft = s['secondsLeft'] as int?;
    final cards = (s['cards'] as List?)?.cast<String>() ?? const <String>[];
    final rows = (s['rows'] as List?)?.cast<Map<String, dynamic>>() ?? const <Map<String, dynamic>>[];
    final log = (s['log'] as List?)?.cast<String>() ?? const <String>[];
    final offline = p.players.where((pl) => !pl.connected).length;
    final controls = game.hostControls();

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && !game.isOver) _confirmEnd(context);
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text('${game.displayName} · Room ${p.joinInfo?.roomCode ?? ''}'),
          automaticallyImplyLeading: false,
          actions: [
            IconButton(
              tooltip: 'Players',
              onPressed: () => _showPlayers(context),
              icon: Badge(
                isLabelVisible: offline > 0,
                label: Text('$offline'),
                child: const Icon(Icons.people),
              ),
            ),
            if (!game.isOver)
              TextButton.icon(
                onPressed: () => _confirmEnd(context),
                icon: const Icon(Icons.stop),
                label: const Text('End'),
              ),
          ],
        ),
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 900),
              child: ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  StatusBanner(status: p.transportStatus),
                  if (banner != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 16),
                      child: Semantics(
                        liveRegion: true,
                        child: Text(banner,
                            style: theme.textTheme.displaySmall?.copyWith(fontWeight: FontWeight.bold),
                            textAlign: TextAlign.center),
                      ),
                    ),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Semantics(
                          header: true,
                          liveRegion: true,
                          child: Text(s['title'] as String? ?? '', style: theme.textTheme.headlineMedium),
                        ),
                      ),
                      if (secondsLeft != null) _Countdown(seconds: secondsLeft),
                    ],
                  ),
                  if (s['subtitle'] != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(s['subtitle'] as String, style: theme.textTheme.titleLarge),
                    ),
                  if (cards.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 20),
                      child: Wrap(
                        alignment: WrapAlignment.center,
                        spacing: 10,
                        runSpacing: 10,
                        children: [for (final c in cards) PlayingCard(code: c, width: 64)],
                      ),
                    ),
                  if (controls.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 16),
                      child: Wrap(
                        spacing: 10,
                        runSpacing: 10,
                        children: [
                          for (final hc in controls)
                            hc.primary
                                ? FilledButton(
                                    onPressed: () => _pressControl(context, hc),
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(vertical: 10),
                                      child: Text(hc.label, style: const TextStyle(fontSize: 18)),
                                    ),
                                  )
                                : OutlinedButton(onPressed: () => _pressControl(context, hc), child: Text(hc.label)),
                        ],
                      ),
                    ),
                  const SizedBox(height: 12),
                  for (final r in rows) _Row(row: r),
                  if (log.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    Text('What happened', style: theme.textTheme.titleMedium),
                    const SizedBox(height: 4),
                    for (final line in log)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: Text(line, style: theme.textTheme.bodyLarge),
                      ),
                  ],
                  if (game.isOver) ...[
                    const SizedBox(height: 28),
                    FilledButton.icon(
                      onPressed: controller.endGame,
                      icon: const Icon(Icons.replay),
                      label: const Padding(padding: EdgeInsets.all(12), child: Text('Back to lobby')),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A seat / player row. The highlighted one (whose turn it is) also gets an
/// arrow and the word "turn", so it isn't shown by colour alone.
class _Row extends StatelessWidget {
  const _Row({required this.row});
  final Map<String, dynamic> row;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final highlight = row['highlight'] == true;
    final dim = row['dim'] == true;
    return Card(
      color: highlight ? theme.colorScheme.primaryContainer : null,
      shape: highlight
          ? RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(color: theme.colorScheme.primary, width: 3),
            )
          : null,
      child: ListTile(
        leading: highlight ? Icon(Icons.play_arrow, color: theme.colorScheme.onPrimaryContainer) : null,
        title: Text('${row['label']}${highlight ? '  · turn' : ''}',
            style: TextStyle(
              fontSize: 22,
              fontWeight: highlight ? FontWeight.bold : null,
              color: dim ? theme.disabledColor : (highlight ? theme.colorScheme.onPrimaryContainer : null),
              decoration: dim ? TextDecoration.lineThrough : null,
            )),
        subtitle: Text('${row['value'] ?? ''}',
            style: TextStyle(
              fontSize: 17,
              color: highlight ? theme.colorScheme.onPrimaryContainer : null,
            )),
      ),
    );
  }
}

class _Countdown extends StatelessWidget {
  const _Countdown({required this.seconds});
  final int seconds;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final low = seconds <= 10;
    return Semantics(
      label: '$seconds seconds left',
      excludeSemantics: true,
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(low ? Icons.timer_off_outlined : Icons.timer_outlined,
            color: low ? theme.colorScheme.error : null, size: 30),
        const SizedBox(width: 4),
        Text('${seconds}s',
            style: theme.textTheme.headlineMedium?.copyWith(
              color: low ? theme.colorScheme.error : null,
              fontWeight: low ? FontWeight.bold : null,
              fontFeatures: const [FontFeature.tabularFigures()],
            )),
      ]),
    );
  }
}

/// Asks the host for what a [HostControl] needs: pick one (or, with
/// multi, several) of its options and/or type a number.
class HostControlDialog extends StatefulWidget {
  const HostControlDialog({super.key, required this.control});
  final HostControl control;

  @override
  State<HostControlDialog> createState() => _HostControlDialogState();
}

class _HostControlDialogState extends State<HostControlDialog> {
  final Set<String> _picked = {};
  final _amount = TextEditingController();
  String? _error;

  HostControl get hc => widget.control;

  /// The number asked for: the control's own, or the picked option's.
  OptionInput? get _input {
    if (hc.input != null) return hc.input;
    if (_picked.length != 1) return null;
    return hc.options.where((o) => o.id == _picked.first).firstOrNull?.input;
  }

  @override
  void initState() {
    super.initState();
    _prefill();
  }

  void _prefill() {
    final d = _input?.defaultValue ?? _input?.min;
    _amount.text = d == null ? '' : '$d';
  }

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  void _toggle(String id) {
    final before = _input;
    setState(() {
      if (hc.multi) {
        _picked.contains(id) ? _picked.remove(id) : _picked.add(id);
      } else {
        _picked
          ..clear()
          ..add(id);
      }
      _error = null;
      if (_input != before) _prefill();
    });
  }

  void _submit() {
    if (hc.options.isNotEmpty && _picked.isEmpty) {
      setState(() => _error = hc.multi ? 'Pick at least one.' : 'Pick one.');
      return;
    }
    final input = _input;
    int? value;
    if (input != null) {
      value = int.tryParse(_amount.text.trim());
      if (value == null || value < input.min || value > input.max) {
        setState(() => _error = 'Enter a number from ${input.min} to ${input.max}.');
        return;
      }
    }
    Navigator.pop(context, (choice: _picked.toList(), value: value));
  }

  @override
  Widget build(BuildContext context) {
    final input = _input;
    return AlertDialog(
      title: Text(hc.label),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (hc.help != null) Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(hc.help!)),
            for (final o in hc.options)
              hc.multi
                  ? CheckboxListTile(
                      value: _picked.contains(o.id),
                      onChanged: (_) => _toggle(o.id),
                      title: Text(o.label),
                      subtitle: o.sub == null ? null : Text(o.sub!),
                    )
                  : ListTile(
                      leading: Icon(_picked.contains(o.id) ? Icons.radio_button_checked : Icons.radio_button_off),
                      selected: _picked.contains(o.id),
                      onTap: () => _toggle(o.id),
                      title: Text(o.label),
                      subtitle: o.sub == null ? null : Text(o.sub!),
                    ),
            if (input != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: TextField(
                  controller: _amount,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: InputDecoration(
                    labelText: input.label ?? 'Amount',
                    helperText: '${input.min} to ${input.max}',
                  ),
                  onSubmitted: (_) => _submit(),
                ),
              ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: _submit, child: const Text('OK')),
      ],
    );
  }
}
