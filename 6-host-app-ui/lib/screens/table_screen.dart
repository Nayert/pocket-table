import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';

import '../host_controller.dart';
import '../widgets/playing_card.dart';

/// The "table / TV" view. Draws any game's publicState() using the standard
/// keys documented on the Game interface (title, banner, cards, rows, log...).
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
    if (ok == true) controller.platform.endGame();
  }

  @override
  Widget build(BuildContext context) {
    final p = controller.platform;
    final game = p.activeGame!;
    final s = game.publicState();
    final theme = Theme.of(context);

    final banner = s['banner'] as String?;
    final secondsLeft = s['secondsLeft'] as int?;
    final cards = (s['cards'] as List?)?.cast<String>() ?? const [];
    final rows = (s['rows'] as List?)?.cast<Map<String, dynamic>>() ?? const [];
    final log = (s['log'] as List?)?.cast<String>() ?? const [];

    return Scaffold(
      appBar: AppBar(
        title: Text('${game.displayName} · Room ${p.joinInfo?.roomCode ?? ''}'),
        automaticallyImplyLeading: false,
        actions: [
          if (!game.isOver)
            TextButton.icon(
              onPressed: () => _confirmEnd(context),
              icon: const Icon(Icons.stop),
              label: const Text('End'),
            ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            if (banner != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Text(banner,
                    style: theme.textTheme.displaySmall?.copyWith(fontWeight: FontWeight.bold),
                    textAlign: TextAlign.center),
              ),
            Row(
              children: [
                Expanded(child: Text(s['title'] as String? ?? '', style: theme.textTheme.headlineMedium)),
                if (secondsLeft != null)
                  Text('${secondsLeft}s',
                      style: theme.textTheme.headlineMedium?.copyWith(
                        color: secondsLeft <= 10 ? theme.colorScheme.error : null,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      )),
              ],
            ),
            if (s['subtitle'] != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(s['subtitle'] as String, style: theme.textTheme.titleMedium),
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
            for (final r in rows)
              Card(
                color: r['highlight'] == true ? theme.colorScheme.primaryContainer : null,
                child: ListTile(
                  title: Text('${r['label']}',
                      style: TextStyle(
                        fontSize: 20,
                        color: r['dim'] == true ? theme.disabledColor : null,
                        decoration: r['dim'] == true ? TextDecoration.lineThrough : null,
                      )),
                  trailing: Text('${r['value'] ?? ''}', style: const TextStyle(fontSize: 16)),
                ),
              ),
            if (log.isNotEmpty) ...[
              const SizedBox(height: 16),
              for (final line in log)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Text(line, style: theme.textTheme.bodyLarge),
                ),
            ],
            if (game.isOver) ...[
              const SizedBox(height: 28),
              FilledButton.icon(
                onPressed: p.endGame,
                icon: const Icon(Icons.replay),
                label: const Padding(padding: EdgeInsets.all(12), child: Text('Back to lobby')),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
