import 'dart:async';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';

// =============================================================================
// ConnectivityService — Graceful offline / online detection
// =============================================================================
//
// Monitors network reachability and exposes:
//   • isOnline      — last-known connectivity state (true = connected)
//   • statusStream  — broadcast stream of bool changes (true = online)
//   • checkNow()    — one-shot async check that also updates [isOnline]
//   • init()        — begins listening; call once at app start
//
// "Online" means ANY non-none connectivity (WiFi, mobile, ethernet, VPN, …).
// The service does NOT make an HTTP probe — it only checks OS-level link state.
// This is intentional: the goal is to detect "certainly offline" rather than
// "reachable server", which is fast, battery-efficient, and always available.
//
// When offline, the home screen shows a cached-data banner so users understand
// that risk-zone data may be from the last successful session.
// =============================================================================

class ConnectivityService {
  // ── Singleton ──────────────────────────────────────────────────────────────
  static final ConnectivityService _instance = ConnectivityService._internal();
  factory ConnectivityService() => _instance;
  ConnectivityService._internal();

  final _connectivity = Connectivity();
  final StreamController<bool> _controller =
      StreamController<bool>.broadcast();
  StreamSubscription<List<ConnectivityResult>>? _sub;

  bool _online = true;

  // ── Public API ─────────────────────────────────────────────────────────────

  /// Last-known online state. `true` = at least one interface is connected.
  bool get isOnline => _online;

  /// Fires whenever connectivity changes: `true` = back online, `false` = offline.
  Stream<bool> get statusStream => _controller.stream;

  /// Start monitoring. Safe to call multiple times — only registers one listener.
  Future<void> init() async {
    if (_sub != null) return; // already initialised
    await checkNow(); // seed with current state before subscribing
    _sub = _connectivity.onConnectivityChanged.listen(_onChanged);
  }

  /// Perform an immediate connectivity check and update [isOnline].
  Future<bool> checkNow() async {
    try {
      final results = await _connectivity.checkConnectivity();
      _online = results.any((r) => r != ConnectivityResult.none);
    } catch (_) {
      // If the platform call throws, assume online to avoid false-negative banners.
      _online = true;
    }
    debugPrint('📡 [ConnectivityService] checkNow() → online=$_online');
    return _online;
  }

  void dispose() {
    _sub?.cancel();
    _sub = null;
    _controller.close();
  }

  // ── Private ────────────────────────────────────────────────────────────────

  void _onChanged(List<ConnectivityResult> results) {
    final online = results.any((r) => r != ConnectivityResult.none);
    if (online == _online) return; // no real change — skip rebuild
    _online = online;
    if (online) {
      debugPrint('🟢 [ConnectivityService] Network restored — device is back online');
    } else {
      debugPrint('🔴 [ConnectivityService] Network lost — device is offline');
    }
    _controller.add(online);
  }
}
