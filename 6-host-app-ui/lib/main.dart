import 'package:flutter/material.dart';

import 'host_controller.dart';
import 'screens/lobby_screen.dart';
import 'screens/mode_select_screen.dart';
import 'screens/table_screen.dart';

void main() => runApp(const HostApp());

class HostApp extends StatefulWidget {
  const HostApp({super.key});

  @override
  State<HostApp> createState() => _HostAppState();
}

class _HostAppState extends State<HostApp> {
  final controller = HostController();

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Party Games Host',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF5B8CFF), brightness: Brightness.dark),
        useMaterial3: true,
      ),
      home: ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          final p = controller.platform;
          // Which screen to show follows directly from the platform's state.
          if (p.joinInfo == null) return ModeSelectScreen(controller: controller);
          if (p.inGame) return TableScreen(controller: controller);
          return LobbyScreen(controller: controller);
        },
      ),
    );
  }
}
