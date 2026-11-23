import 'package:flutter/material.dart';
import 'package:platform_core/platform_core.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:transport/transport.dart';

import '../host_controller.dart';

class LobbyScreen extends StatelessWidget {
  const LobbyScreen({super.key, required this.controller});
  final HostController controller;

  Platform get p => controller.platform;

  Future<void> _confirmStop(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Close the room?'),
        content: const Text('Everyone will be disconnected.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Close room')),
        ],
      ),
    );
    if (ok == true) await controller.stopHosting();
  }

  void _start(BuildContext context) {
    final error = p.startGame();
    if (error != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final info = p.joinInfo!;
    final theme = Theme.of(context);
    final game = p.selectedGame;

    return Scaffold(
      appBar: AppBar(
        title: Text('Lobby · ${info.mode}'),
        leading: IconButton(icon: const Icon(Icons.close), onPressed: () => _confirmStop(context)),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _StatusBanner(status: p.transportStatus, warning: info.warning),
            Center(
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12)),
                child: QrImageView(data: info.url, size: 220, backgroundColor: Colors.white),
              ),
            ),
            const SizedBox(height: 12),
            Text('Room ${info.roomCode}',
                style: theme.textTheme.headlineMedium?.copyWith(letterSpacing: 4, fontWeight: FontWeight.bold),
                textAlign: TextAlign.center),
            SelectableText(info.url, textAlign: TextAlign.center, style: theme.textTheme.bodySmall),
            const SizedBox(height: 20),
            Text('Players (${p.players.length})', style: theme.textTheme.titleMedium),
            if (p.players.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text('Waiting for players to scan the code…'),
              ),
            for (final pl in p.players)
              ListTile(
                leading: Icon(pl.connected ? Icons.person : Icons.person_off),
                title: Text(pl.name),
                subtitle: pl.connected ? null : const Text('offline'),
                trailing: IconButton(
                  tooltip: 'Remove',
                  icon: const Icon(Icons.remove_circle_outline),
                  onPressed: () => p.kick(pl.id),
                ),
              ),
            const Divider(height: 32),
            Text('Game', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                for (final g in p.catalog)
                  ChoiceChip(
                    label: Text(g.displayName),
                    selected: g.id == p.selectedGameId,
                    onSelected: (_) => p.selectGame(g.id),
                  ),
              ],
            ),
            if (game != null) ...[
              const SizedBox(height: 8),
              Text('${game.description}  (${game.minPlayers}–${game.maxPlayers} players)'),
              const SizedBox(height: 8),
              for (final s in game.settings) _SettingRow(platform: p, setting: s),
            ],
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: () => _start(context),
              icon: const Icon(Icons.play_arrow),
              label: const Padding(padding: EdgeInsets.all(12), child: Text('Start game')),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusBanner extends StatelessWidget {
  const _StatusBanner({required this.status, this.warning});
  final TransportStatus status;
  final String? warning;

  @override
  Widget build(BuildContext context) {
    final text = switch (status) {
      TransportStatus.reconnecting => 'Lost connection to the relay. Reconnecting…',
      TransportStatus.failed => 'The connection failed. Close the room and try again.',
      _ => warning,
    };
    if (text == null) return const SizedBox.shrink();
    return Card(
      color: Theme.of(context).colorScheme.errorContainer,
      child: Padding(padding: const EdgeInsets.all(12), child: Text(text)),
    );
  }
}

class _SettingRow extends StatelessWidget {
  const _SettingRow({required this.platform, required this.setting});
  final Platform platform;
  final GameSetting setting;

  @override
  Widget build(BuildContext context) {
    final value = platform.gameSettings[platform.selectedGameId]![setting.key] ?? setting.defaultValue;
    if (setting.isBool) {
      return SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(setting.label),
        value: value as bool,
        onChanged: (v) => platform.setSetting(setting.key, v),
      );
    }
    final n = value as int;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(setting.label),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(Icons.remove),
            onPressed: n - setting.step >= setting.min ? () => platform.setSetting(setting.key, n - setting.step) : null,
          ),
          SizedBox(width: 56, child: Text('$n', textAlign: TextAlign.center)),
          IconButton(
            icon: const Icon(Icons.add),
            onPressed: n + setting.step <= setting.max ? () => platform.setSetting(setting.key, n + setting.step) : null,
          ),
        ],
      ),
    );
  }
}
