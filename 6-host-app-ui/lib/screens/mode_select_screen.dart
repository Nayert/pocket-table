import 'package:flutter/material.dart';

import '../host_controller.dart';

/// Same Wi-Fi vs Online. Reads state from the controller and calls its actions.
class ModeSelectScreen extends StatefulWidget {
  const ModeSelectScreen({super.key, required this.controller});
  final HostController controller;

  @override
  State<ModeSelectScreen> createState() => _ModeSelectScreenState();
}

class _ModeSelectScreenState extends State<ModeSelectScreen> {
  final _relay = TextEditingController();
  String? _shownUrl; // last controller URL copied into the field
  bool _editRelay = false;

  @override
  void dispose() {
    _relay.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    if (_shownUrl != c.relayUrl) {
      // The saved URL loads asynchronously; show it once it arrives.
      _relay.text = c.relayUrl;
      _shownUrl = c.relayUrl;
    }
    final theme = Theme.of(context);
    final isDefault = _relay.text.trim() == HostController.defaultRelayUrl;

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: ListView(
              padding: const EdgeInsets.all(20),
              children: [
                const SizedBox(height: 16),
                Text('Pocket Table', style: theme.textTheme.displaySmall, textAlign: TextAlign.center),
                const SizedBox(height: 8),
                Text('How will players join?', style: theme.textTheme.titleMedium, textAlign: TextAlign.center),
                const SizedBox(height: 24),
                if (c.stage == HostStage.waking)
                  _WakingCard(seconds: c.wakeSeconds, onCancel: c.cancelHosting)
                else ...[
                  _ModeCard(
                    icon: Icons.wifi,
                    title: 'Same Wi-Fi',
                    text: 'Everyone is in the room, on the same Wi-Fi or your hotspot. '
                        'No internet needed. Players scan the QR code.',
                    child: FilledButton.icon(
                      onPressed: c.busy ? null : c.hostLocal,
                      icon: const Icon(Icons.wifi),
                      label: const Padding(padding: EdgeInsets.all(12), child: Text('Host on this Wi-Fi')),
                    ),
                  ),
                  const SizedBox(height: 16),
                  _ModeCard(
                    icon: Icons.public,
                    title: 'Online',
                    text: 'Players join from any network through the relay server. '
                        'They open the link or type the room code.',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (_editRelay || !isDefault) ...[
                          TextField(
                            controller: _relay,
                            keyboardType: TextInputType.url,
                            autocorrect: false,
                            onChanged: (_) => setState(() {}),
                            decoration: InputDecoration(
                              labelText: 'Relay server',
                              hintText: HostController.defaultRelayUrl,
                              border: const OutlineInputBorder(),
                              suffixIcon: isDefault
                                  ? null
                                  : IconButton(
                                      tooltip: 'Use the default server',
                                      icon: const Icon(Icons.restore),
                                      onPressed: () => setState(() => _relay.text = HostController.defaultRelayUrl),
                                    ),
                            ),
                          ),
                          const SizedBox(height: 12),
                        ] else
                          Align(
                            alignment: Alignment.centerLeft,
                            child: TextButton.icon(
                              onPressed: () => setState(() => _editRelay = true),
                              icon: const Icon(Icons.edit, size: 18),
                              label: const Text('Server: default (change)'),
                            ),
                          ),
                        FilledButton.icon(
                          onPressed: c.busy ? null : () => c.hostOnline(_relay.text),
                          icon: const Icon(Icons.public),
                          label: const Padding(padding: EdgeInsets.all(12), child: Text('Host online')),
                        ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 20),
                if (c.stage == HostStage.connecting)
                  const Column(children: [
                    CircularProgressIndicator(),
                    SizedBox(height: 8),
                    Text('Opening the room…', textAlign: TextAlign.center),
                  ]),
                if (c.error != null)
                  Semantics(
                    liveRegion: true,
                    child: Card(
                      color: theme.colorScheme.errorContainer,
                      child: Padding(
                        padding: const EdgeInsets.all(14),
                        child: Row(children: [
                          Icon(Icons.error_outline, color: theme.colorScheme.onErrorContainer),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(c.error!, style: TextStyle(color: theme.colorScheme.onErrorContainer)),
                          ),
                        ]),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Shown while the free relay wakes up (can take about a minute).
class _WakingCard extends StatelessWidget {
  const _WakingCard({required this.seconds, required this.onCancel});
  final int seconds;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Semantics(
          liveRegion: true,
          label: 'Waking the server',
          child: Column(
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: 16),
              Text('Waking server… ${seconds}s', style: theme.textTheme.titleLarge, textAlign: TextAlign.center),
              const SizedBox(height: 8),
              const Text(
                'The free server sleeps when nobody is using it. '
                'The first start can take up to a minute.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              OutlinedButton(onPressed: onCancel, child: const Text('Cancel')),
            ],
          ),
        ),
      ),
    );
  }
}

class _ModeCard extends StatelessWidget {
  const _ModeCard({required this.icon, required this.title, required this.text, required this.child});
  final IconData icon;
  final String title;
  final String text;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              Icon(icon, size: 28),
              const SizedBox(width: 12),
              Expanded(child: Text(title, style: Theme.of(context).textTheme.titleLarge)),
            ]),
            const SizedBox(height: 8),
            Text(text),
            const SizedBox(height: 14),
            child,
          ],
        ),
      ),
    );
  }
}
