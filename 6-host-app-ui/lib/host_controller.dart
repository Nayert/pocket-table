import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:games/games.dart';
import 'package:platform_core/platform_core.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:transport/transport.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

/// Bridges the pure-Dart platform core to Flutter widgets.
class HostController extends ChangeNotifier {
  HostController() {
    _sub = platform.changes.listen((_) => notifyListeners());
    _loadRelayUrl();
  }

  final Platform platform = Platform(games: allGames);
  late final StreamSubscription<void> _sub;

  bool busy = false;
  String? error;
  String relayUrl = '';

  static const _relayKey = 'relayUrl';

  Future<void> _loadRelayUrl() async {
    final prefs = await SharedPreferences.getInstance();
    relayUrl = prefs.getString(_relayKey) ?? '';
    notifyListeners();
  }

  Future<void> hostLocal() => _host(() => LocalTransport(loadAsset: _loadPlayerAsset));

  Future<void> hostOnline(String url) async {
    relayUrl = url.trim();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_relayKey, relayUrl);
    if (relayUrl.isEmpty) {
      error = 'Enter the relay server address first.';
      notifyListeners();
      return;
    }
    await _host(() => OnlineTransport(relayUrl: relayUrl, maxPlayers: platform.maxPlayers));
  }

  Future<void> _host(Transport Function() make) async {
    busy = true;
    error = null;
    notifyListeners();
    try {
      await platform.host(make());
      await WakelockPlus.enable(); // keep the screen on while hosting
    } catch (e) {
      await platform.shutdown();
      error = 'Could not start: $e';
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> stopHosting() async {
    await platform.shutdown();
    await WakelockPlus.disable();
    notifyListeners();
  }

  /// Serves files of the player page from app assets (Local mode).
  static Future<List<int>?> _loadPlayerAsset(String path) async {
    try {
      final data = await rootBundle.load('assets/player_client/$path');
      return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    } catch (_) {
      return null;
    }
  }

  @override
  void dispose() {
    _sub.cancel();
    platform.shutdown();
    super.dispose();
  }
}
