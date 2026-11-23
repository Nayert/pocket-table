import 'package:flutter/material.dart';

import '../host_controller.dart';

class ModeSelectScreen extends StatefulWidget {
  const ModeSelectScreen({super.key, required this.controller});
  final HostController controller;

  @override
  State<ModeSelectScreen> createState() => _ModeSelectScreenState();
}

class _ModeSelectScreenState extends State<ModeSelectScreen> {
  final _relay = TextEditingController();
  bool _filled = false;

  @override
  void dispose() {
    _relay.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    if (!_filled && c.relayUrl.isNotEmpty) {
      _relay.text = c.relayUrl;
      _filled = true;
    }
    final theme = Theme.of(context);

    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            const SizedBox(height: 24),
            Text('Party Games', style: theme.textTheme.displaySmall, textAlign: TextAlign.center),
            const SizedBox(height: 8),
            Text('How will players join?', style: theme.textTheme.titleMedium, textAlign: TextAlign.center),
            const SizedBox(height: 28),
            _ModeCard(
              icon: Icons.wifi,
              title: 'Same Wi-Fi (Local)',
              text: 'Everyone is in the room and on the same Wi-Fi or your hotspot. No internet needed.',
              child: FilledButton(
                onPressed: c.busy ? null : c.hostLocal,
                child: const Text('Host on this Wi-Fi'),
              ),
            ),
            const SizedBox(height: 16),
            _ModeCard(
              icon: Icons.public,
              title: 'Online',
              text: 'Players join from anywhere through your relay server.',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    controller: _relay,
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                    decoration: const InputDecoration(
                      labelText: 'Relay server',
                      hintText: 'https://your-relay.onrender.com',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  FilledButton(
                    onPressed: c.busy ? null : () => c.hostOnline(_relay.text),
                    child: const Text('Host online'),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            if (c.busy) const Center(child: CircularProgressIndicator()),
            if (c.error != null)
              Text(c.error!, style: TextStyle(color: theme.colorScheme.error), textAlign: TextAlign.center),
          ],
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
              Text(title, style: Theme.of(context).textTheme.titleLarge),
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
