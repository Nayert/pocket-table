import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:games/games.dart';
import 'package:platform_core/platform_core.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:transport/transport.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

/// What the mode-select screen is waiting on while starting to host.
enum HostStage { idle, waking, connecting }

/// Bridges the pure-Dart platform core to Flutter widgets.
///
/// Screens only read state from here (and from [platform]'s fields) and call
/// the action methods below. All decisions live here or in the platform core.
class HostController extends ChangeNotifier {
  HostController({Platform? platform, bool useDeviceServices = true})
      : platform = platform ?? Platform(games: allGames),
        _device = useDeviceServices {
    _sub = this.platform.changes.listen((_) => notifyListeners());
    if (_device) _loadRelayUrl();
  }

  /// The relay this project deploys to. Used until the host saves another.
  static const defaultRelayUrl = 'https://pocket-table-relay.onrender.com';
  static const _relayKey = 'relayUrl';

  final Platform platform;
  final bool _device; // false in widget tests: no prefs, wakelock or assets
  late final StreamSubscription<void> _sub;

  HostStage stage = HostStage.idle;
  bool get busy => stage != HostStage.idle;
  String? error;
  String relayUrl = defaultRelayUrl;

  /// When waking the relay started, for the "waking server… 23s" label.
  DateTime? wakeStartedAt;
  Timer? _wakeTicker;
  int _attempt = 0; // bumps on cancel so a late result is ignored

  Future<void> _loadRelayUrl() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(_relayKey);
      if (saved != null && saved.trim().isNotEmpty) relayUrl = saved;
    } catch (_) {/* first run or no storage: keep the default */}
    notifyListeners();
  }

  // ------------------------------------------------------------ hosting

  Future<void> hostLocal() => _host(() => LocalTransport(loadAsset: _loadPlayerAsset));

  Future<void> hostOnline(String url) async {
    final u = url.trim();
    if (u.isEmpty) {
      error = 'Enter the relay server address first.';
      notifyListeners();
      return;
    }
    final insecure = insecureRelayProblem(u);
    if (insecure != null) {
      error = insecure;
      notifyListeners();
      return;
    }
    relayUrl = u;

    final attempt = ++_attempt;
    error = null;
    stage = HostStage.waking;
    wakeStartedAt = DateTime.now();
    _wakeTicker?.cancel();
    _wakeTicker = Timer.periodic(const Duration(seconds: 1), (_) => notifyListeners());
    notifyListeners();
    try {
      // Free hosting sleeps when idle; the first request can take ~a minute.
      await OnlineTransport.wakeRelay(relayUrl);
    } on TimeoutException {
      if (attempt != _attempt) return;
      _stopWaking();
      error = "The server didn't answer within 100 seconds. Check the address and your internet, then try again.";
      notifyListeners();
      return;
    } catch (e) {
      if (attempt != _attempt) return;
      _stopWaking();
      error = 'Could not reach the server: $e';
      notifyListeners();
      return;
    }
    if (attempt != _attempt) return; // cancelled while waking
    _stopWaking();
    if (_device) {
      // Remember the address only once it has actually answered.
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_relayKey, relayUrl);
      } catch (_) {/* not fatal */}
    }
    await _host(() => OnlineTransport(relayUrl: relayUrl, maxPlayers: platform.maxPlayers));
  }

  /// Everything (roles, cards, seat tokens) goes through the relay, so a
  /// relay on the internet must use https/wss. Plain http/ws is only allowed
  /// for addresses on your own network (testing a relay on your computer).
  static String? insecureRelayProblem(String url) {
    final u = url.trim().toLowerCase();
    if (!u.startsWith('http://') && !u.startsWith('ws://')) return null;
    final host = Uri.tryParse(u)?.host ?? '';
    if (_isLocalHost(host)) return null;
    return 'Use an https:// address for a server on the internet. Plain http:// would let others '
        'on the network read roles, cards and seat tokens. (http:// works only for addresses on your own network.)';
  }

  static bool _isLocalHost(String h) {
    if (h == 'localhost' || h.endsWith('.local')) return true;
    final m = RegExp(r'^(\d+)\.(\d+)\.\d+\.\d+$').firstMatch(h);
    if (m == null) return false;
    final a = int.parse(m.group(1)!), b = int.parse(m.group(2)!);
    return a == 127 || a == 10 || (a == 192 && b == 168) || (a == 172 && b >= 16 && b <= 31);
  }

  /// Give up waiting for the relay to wake.
  void cancelHosting() {
    if (stage != HostStage.waking) return;
    _attempt++;
    _stopWaking();
    notifyListeners();
  }

  void _stopWaking() {
    _wakeTicker?.cancel();
    _wakeTicker = null;
    wakeStartedAt = null;
    stage = HostStage.idle;
  }

  int get wakeSeconds => wakeStartedAt == null ? 0 : DateTime.now().difference(wakeStartedAt!).inSeconds;

  Future<void> _host(Transport Function() make) async {
    stage = HostStage.connecting;
    error = null;
    notifyListeners();
    try {
      await platform.host(make());
      if (_device) await WakelockPlus.enable(); // keep the screen on while hosting
    } catch (e) {
      await platform.shutdown();
      error = 'Could not start: $e';
    } finally {
      stage = HostStage.idle;
      notifyListeners();
    }
  }

  Future<void> stopHosting() async {
    await platform.shutdown();
    if (_device) await WakelockPlus.disable();
    notifyListeners();
  }

  // ------------------------------------------------------------ lobby

  /// Null when the host can press Start, otherwise why not (shown under the button).
  String? get startProblem => platform.startProblem;
  bool get canStart => startProblem == null;

  void selectGame(String id) => platform.selectGame(id);
  void setSetting(String key, Object value) => platform.setSetting(key, value);
  Object settingValue(GameSetting s) =>
      platform.gameSettings[platform.selectedGameId]?[s.key] ?? s.defaultValue;

  /// The value [s] would have after one step up (+1) or down (-1), or null
  /// if that's outside its allowed range.
  int? steppedValue(GameSetting s, int direction) {
    final v = settingValue(s);
    if (v is! int) return null;
    final next = v + direction * s.step;
    return next < s.min || next > s.max ? null : next;
  }

  /// Returns an error message, or null when the game started.
  String? startGame() => platform.startGame();
  void endGame() => platform.endGame();
  void kick(String playerId) => platform.kick(playerId);

  /// Returns an error message, or null when it worked.
  String? hostAction(String controlId, {List<String> choice = const [], Object? value}) =>
      platform.hostAction(controlId, choice: choice, value: value);

  // ------------------------------------------------------------ assets

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
    _wakeTicker?.cancel();
    _sub.cancel();
    platform.shutdown();
    super.dispose();
  }
}
