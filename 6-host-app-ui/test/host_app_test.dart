// Run with:  flutter test   (from 6-host-app-ui/)
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:games/games.dart';
import 'package:host_app/host_controller.dart';
import 'package:host_app/screens/lobby_screen.dart';
import 'package:host_app/screens/mode_select_screen.dart';
import 'package:host_app/screens/table_screen.dart';
import 'package:host_app/widgets/playing_card.dart';
import 'package:platform_core/platform_core.dart';
import 'package:transport/transport.dart';

Widget app(Widget home) => MaterialApp(home: home);

void main() {
  late HostController c;
  late FakeTransport t;

  setUp(() {
    c = HostController(platform: Platform(games: allGames), useDeviceServices: false);
    t = FakeTransport();
  });

  tearDown(() async {
    await c.platform.shutdown(); // stops game timers
  });

  void join(String conn, String name) {
    t.simulateJoin(conn);
    t.simulateMessage(conn, 'join', {'v': protocolVersion, 'name': name});
  }

  testWidgets('mode select offers both modes and defaults to the project relay', (tester) async {
    await tester.pumpWidget(app(ModeSelectScreen(controller: c)));
    expect(find.text('Host on this Wi-Fi'), findsOneWidget);
    expect(find.text('Host online'), findsOneWidget);
    expect(c.relayUrl, HostController.defaultRelayUrl);
    expect(find.text('Server: default (change)'), findsOneWidget);
    await tester.tap(find.text('Server: default (change)'));
    await tester.pump();
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, HostController.defaultRelayUrl);
  });

  testWidgets('mode select shows the waking state with a cancel button', (tester) async {
    c.stage = HostStage.waking;
    c.wakeStartedAt = DateTime.now();
    await tester.pumpWidget(app(ModeSelectScreen(controller: c)));
    expect(find.textContaining('Waking server'), findsOneWidget);
    expect(find.text('Cancel'), findsOneWidget);
    expect(find.text('Host online'), findsNothing);
  });

  testWidgets('lobby: Start is disabled until enough players joined', (tester) async {
    tester.view.physicalSize = const Size(1200, 4000); // whole lobby on screen
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await c.platform.host(t);
    c.selectGame('poker');
    await tester.pumpWidget(app(ListenableBuilder(
        listenable: c, builder: (_, __) => LobbyScreen(controller: c))));
    expect(find.text('TEST'), findsOneWidget); // big room code
    FilledButton startButton() => tester.widget<FilledButton>(find.ancestor(
        of: find.text('Start Poker'), matching: find.byWidgetPredicate((w) => w is FilledButton)));
    expect(startButton().onPressed, isNull);
    expect(find.textContaining('2 more'), findsOneWidget);

    join('c1', 'Ana');
    join('c2', 'Ben');
    await tester.pump();
    expect(find.text('Ana'), findsOneWidget);
    expect(startButton().onPressed, isNotNull);
  });

  testWidgets('table view never shows hole cards or roles', (tester) async {
    await c.platform.host(t);
    c.selectGame('poker');
    join('c1', 'Ana');
    join('c2', 'Ben');
    expect(c.startGame(), isNull);
    await tester.pumpWidget(app(TableScreen(controller: c)));
    await tester.pump();

    // Every card drawn on the table must be a community card.
    final drawn = tester.widgetList<PlayingCard>(find.byType(PlayingCard)).map((w) => w.code).toSet();
    final game = c.platform.activeGame!;
    final board = ((game.publicState()['cards'] as List?) ?? const []).cast<String>().toSet();
    expect(drawn.difference(board), isEmpty);
    for (final pl in c.platform.players) {
      final hole = game.privateState(pl.id).cards ?? const <String>[];
      expect(hole, isNotEmpty);
      for (final card in hole) {
        expect(drawn, isNot(contains(card)));
      }
    }
    c.endGame();
  });

  testWidgets('table view for Mafia shows no role names before the end', (tester) async {
    await c.platform.host(t);
    c.selectGame('mafia');
    for (final n in ['Ana', 'Ben', 'Cal', 'Dee']) {
      join('c$n', n);
    }
    expect(c.startGame(), isNull);
    await tester.pumpWidget(app(TableScreen(controller: c)));
    await tester.pump();
    for (final role in ['Doctor', 'Detective', 'Villager', 'You are', 'Your role']) {
      expect(find.textContaining(role), findsNothing, reason: role);
    }
    // "Mafia" appears only as the game's name in the app bar.
    expect(find.textContaining('Mafia'), findsOneWidget);
    expect(find.text('Mafia · Room TEST'), findsOneWidget);
    c.endGame();
  });

  test('plain http relays are refused unless they are on the local network', () {
    expect(HostController.insecureRelayProblem('https://pocket-table-relay.onrender.com'), isNull);
    expect(HostController.insecureRelayProblem('http://192.168.1.20:8000'), isNull);
    expect(HostController.insecureRelayProblem('http://localhost:8000'), isNull);
    expect(HostController.insecureRelayProblem('http://10.0.0.5:8000'), isNull);
    expect(HostController.insecureRelayProblem('http://example.com'), isNotNull);
    expect(HostController.insecureRelayProblem('ws://8.8.8.8'), isNotNull);
    expect(HostController.insecureRelayProblem('http://172.32.0.1'), isNotNull);
  });
}
