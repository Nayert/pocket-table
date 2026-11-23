import 'package:flutter/material.dart';

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
