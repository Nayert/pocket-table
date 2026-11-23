import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:platform_core/platform_core.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:transport/transport.dart';

import '../host_controller.dart';

/// Room code + QR, live player list, game picker and settings, Start.
/// Only reads state and calls controller actions.
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
    final error = controller.startGame();
    if (error != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final info = p.joinInfo!;
    final theme = Theme.of(context);
    final game = p.selectedGame;
    final connected = p.connectedPlayers.length;
    final problem = controller.startProblem;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _confirmStop(context);
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(info.mode == 'Online' ? 'Lobby · Online' : 'Lobby · Same Wi-Fi'),
          leading: IconButton(
            tooltip: 'Close the room',
            icon: const Icon(Icons.close),
            onPressed: () => _confirmStop(context),
          ),
        ),
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640),
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  StatusBanner(status: p.transportStatus, warning: info.warning),
                  _JoinCard(info: info),
                  const SizedBox(height: 20),
                  Row(children: [
                    Expanded(child: Text('Players', style: theme.textTheme.titleLarge)),
                    Text('$connected connected${p.players.length > connected ? ' · ${p.players.length - connected} offline' : ''}'),
                  ]),
                  const SizedBox(height: 4),
                  if (p.players.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 16),
                      child: Text('Waiting for players to scan the code…'),
                    ),
                  for (final pl in p.players)
                    PlayerTile(
                      name: pl.name,
                      connected: pl.connected,
                      onKick: () => confirmKick(context, controller, pl.id, pl.name),
                    ),
                  const Divider(height: 32),
                  Text('Game', style: theme.textTheme.titleLarge),
                  const SizedBox(height: 8),
                  SegmentedButton<String>(
                    segments: [
                      for (final g in p.catalog) ButtonSegment(value: g.id, label: Text(g.displayName)),
                    ],
                    selected: {if (p.selectedGameId != null) p.selectedGameId!},
                    onSelectionChanged: (s) => controller.selectGame(s.first),
                  ),
                  if (game != null) ...[
                    const SizedBox(height: 10),
                    Text(game.description),
                    Text('${game.minPlayers}–${game.maxPlayers} players', style: theme.textTheme.bodySmall),
                    const SizedBox(height: 8),
                    for (final s in game.settings) _SettingRow(controller: controller, setting: s),
                  ],
                  const SizedBox(height: 24),
                  FilledButton.icon(
                    onPressed: problem == null ? () => _start(context) : null,
                    icon: const Icon(Icons.play_arrow),
                    label: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Text('Start ${game?.displayName ?? 'game'}', style: const TextStyle(fontSize: 18)),
                    ),
                  ),
                  if (problem != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(problem, textAlign: TextAlign.center, style: theme.textTheme.bodyMedium),
                    ),
                  const SizedBox(height: 24),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Big room code, QR code and the join link.
class _JoinCard extends StatelessWidget {
  const _JoinCard({required this.info});
  final JoinInfo info;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final width = MediaQuery.sizeOf(context).width;
    final qrSize = (width - 96).clamp(160.0, 280.0);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Text('Room code', style: theme.textTheme.titleMedium),
            Semantics(
              label: 'Room code ${info.roomCode.split('').join(' ')}',
              excludeSemantics: true,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  info.roomCode,
                  style: theme.textTheme.displayLarge?.copyWith(letterSpacing: 10, fontWeight: FontWeight.w800),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Semantics(
              label: 'QR code to join the room',
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12)),
                child: QrImageView(data: info.url, size: qrSize, backgroundColor: Colors.white),
              ),
            ),
            const SizedBox(height: 12),
            Text('Scan, or open this link and enter the code:', style: theme.textTheme.bodySmall),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Flexible(child: SelectableText(info.url, textAlign: TextAlign.center)),
                IconButton(
                  tooltip: 'Copy link',
                  icon: const Icon(Icons.copy, size: 20),
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: info.url));
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Link copied')));
                  },
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// One player row with a status word (not just an icon or colour) and kick.
class PlayerTile extends StatelessWidget {
  const PlayerTile({super.key, required this.name, required this.connected, required this.onKick, this.trailing});
  final String name;
  final bool connected;
  final VoidCallback onKick;
  final String? trailing;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(connected ? Icons.person : Icons.person_off_outlined),
      title: Text(name, style: const TextStyle(fontSize: 18)),
      subtitle: Text([connected ? 'connected' : 'offline', if (trailing != null) trailing!].join(' · ')),
      trailing: IconButton(
        tooltip: 'Remove $name',
        icon: const Icon(Icons.person_remove_outlined),
        onPressed: onKick,
      ),
    );
  }
}

Future<void> confirmKick(BuildContext context, HostController controller, String id, String name) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('Remove $name?'),
      content: const Text("They'll be disconnected and lose their seat. During a game they can't come back until it ends."),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Remove')),
      ],
    ),
  );
  if (ok == true) controller.kick(id);
}

/// Shows relay trouble or a transport warning (e.g. no Wi-Fi found).
class StatusBanner extends StatelessWidget {
  const StatusBanner({super.key, required this.status, this.warning});
  final TransportStatus status;
  final String? warning;

  @override
  Widget build(BuildContext context) {
    final text = switch (status) {
      TransportStatus.reconnecting => 'Lost connection to the server. Reconnecting… Players keep their seats.',
      TransportStatus.failed => 'The connection failed. Close the room and start again.',
      _ => warning,
    };
    if (text == null) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      liveRegion: true,
      child: Card(
        color: scheme.errorContainer,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(children: [
            Icon(Icons.warning_amber_rounded, color: scheme.onErrorContainer),
            const SizedBox(width: 10),
            Expanded(child: Text(text, style: TextStyle(color: scheme.onErrorContainer))),
          ]),
        ),
      ),
    );
  }
}

class _SettingRow extends StatelessWidget {
  const _SettingRow({required this.controller, required this.setting});
  final HostController controller;
  final GameSetting setting;

  @override
  Widget build(BuildContext context) {
    final value = controller.settingValue(setting);
    if (setting.isBool) {
      return SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(setting.label),
        value: value as bool,
        onChanged: (v) => controller.setSetting(setting.key, v),
      );
    }
    final n = value as int;
    final down = controller.steppedValue(setting, -1);
    final up = controller.steppedValue(setting, 1);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(setting.label),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: 'Less',
            icon: const Icon(Icons.remove),
            onPressed: down == null ? null : () => controller.setSetting(setting.key, down),
          ),
          SizedBox(
            width: 60,
            child: Text('$n', textAlign: TextAlign.center, style: const TextStyle(fontSize: 18)),
          ),
          IconButton(
            tooltip: 'More',
            icon: const Icon(Icons.add),
            onPressed: up == null ? null : () => controller.setSetting(setting.key, up),
          ),
        ],
      ),
    );
  }
}
