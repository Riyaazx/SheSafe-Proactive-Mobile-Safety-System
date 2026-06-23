import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../config/backend_config.dart';

// ─────────────────────────────────────────────────────────────────────────────
// URL helpers — all come from the single BackendConfig constant.
// ─────────────────────────────────────────────────────────────────────────────

/// Latency budget constants (ms).
const int _kRouteExplanationTimeoutMs = 2000; // Safety Mode budget
const int _kEscalationTimeoutMs       = 1500; // Panic Mode budget
const int _kHealthTimeoutMs           = 1000; // Reachability probe

// ─────────────────────────────────────────────────────────────────────────────
// Data classes
// ─────────────────────────────────────────────────────────────────────────────

/// Backend safety explanation for a route request (from /route/safest).
class BackendRouteExplanation {
  final String summary;
  final String details;
  final List<String> warnings;
  final int safetyScore;       // 0–100
  final String riskLevel;      // "low" | "medium" | "high"
  final int riskZonesNearby;
  final int latencyMs;         // end-to-end round-trip time

  const BackendRouteExplanation({
    required this.summary,
    required this.details,
    required this.warnings,
    required this.safetyScore,
    required this.riskLevel,
    required this.riskZonesNearby,
    required this.latencyMs,
  });

  bool get isWithinLatencyBudget => latencyMs < _kRouteExplanationTimeoutMs;
}

/// Result returned by [IntegrationPipelineService.notifyEscalation].
class EscalationAck {
  final bool success;
  final String? backendStage;
  final String? message;
  final int latencyMs;

  const EscalationAck({
    required this.success,
    this.backendStage,
    this.message,
    required this.latencyMs,
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// Service
// ─────────────────────────────────────────────────────────────────────────────

/// Central integration coordinator for Safety Mode and Panic Mode pipelines.
///
/// Responsibilities:
///   - Safety Mode : fetch backend route-safety explanation in parallel with
///     local route generation so UI has enriched data with <2 s overhead.
///   - Panic Mode  : fire-and-forget escalation event to backend endpoint
///     (with timeout) so the state machine is never delayed.
///   - Health      : lightweight reachability probe so calling code can
///     gracefully degrade when the backend is unreachable.
///
/// All network errors are caught internally; callers receive `null` / a
/// failure [EscalationAck] rather than thrown exceptions.
class IntegrationPipelineService {
  IntegrationPipelineService._();
  static final IntegrationPipelineService instance =
      IntegrationPipelineService._();

  // ── Backend reachability cache ────────────────────────────────────────────

  /// Cached result of the last health check (null = not yet probed).
  bool? _backendReachable;
  DateTime? _lastHealthCheck;

  /// Returns true if the backend responded to a /health probe within the
  /// last 60 seconds.  Re-probes on first call or when cache expires.
  Future<bool> isBackendReachable() async {
    final now = DateTime.now();
    if (_backendReachable != null &&
        _lastHealthCheck != null &&
        now.difference(_lastHealthCheck!).inSeconds < 60) {
      return _backendReachable!;
    }
    final reachable = await _probe();
    _backendReachable = reachable;
    _lastHealthCheck  = now;
    return reachable;
  }

  /// Invalidates the cached health state (call after a network error).
  void invalidateHealthCache() {
    _backendReachable = null;
    _lastHealthCheck  = null;
  }

  // ── Safety Mode Pipeline ──────────────────────────────────────────────────

  /// Fetches a route safety explanation from the backend **in parallel** with
  /// local route generation.
  ///
  /// Designed to be launched with [Future.wait] alongside
  /// [RouteGeneratorService.generateRoutes] so neither blocks the other.
  ///
  /// Returns `null` if the backend is unreachable, times out, or returns an
  /// error — callers should display local analysis in that case (graceful
  /// degradation).
  Future<BackendRouteExplanation?> fetchRouteExplanation({
    required double originLat,
    required double originLon,
    required double destinationLat,
    required double destinationLon,
    String? destinationAddress,
  }) async {
    final sw = Stopwatch()..start();
    try {
      final response = await http
          .post(
            Uri.parse(BackendConfig.routeSafest),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'origin_lat':        originLat,
              'origin_lon':        originLon,
              'destination_lat':   destinationLat,
              'destination_lon':   destinationLon,
              'destination_address': ?destinationAddress,
            }),
          )
          .timeout(Duration(milliseconds: _kRouteExplanationTimeoutMs));

      sw.stop();

      if (response.statusCode != 200) {
        debugPrint('⚠️ /route/safest returned ${response.statusCode}');
        return null;
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      if (data['status'] != 'success') return null;

      final expl    = data['explanation']      as Map<String, dynamic>? ?? {};
      final safety  = data['safety_analysis']  as Map<String, dynamic>? ?? {};

      final warnings = (expl['warnings'] as List<dynamic>? ?? [])
          .map((e) => e.toString())
          .toList();

      debugPrint('⚡ /route/safest ← ${sw.elapsedMilliseconds} ms');

      return BackendRouteExplanation(
        summary:        expl['summary']?.toString()            ?? '',
        details:        expl['details']?.toString()            ?? '',
        warnings:       warnings,
        safetyScore:    (safety['overall_safety_score'] as num?)?.toInt() ?? 100,
        riskLevel:      safety['risk_level']?.toString()       ?? 'low',
        riskZonesNearby:(safety['risk_zones_nearby'] as num?)?.toInt() ?? 0,
        latencyMs:      sw.elapsedMilliseconds,
      );
    } on TimeoutException {
      sw.stop();
      debugPrint('⏰ /route/safest timed out after ${sw.elapsedMilliseconds} ms – using local analysis');
      invalidateHealthCache();
      return null;
    } catch (e) {
      sw.stop();
      debugPrint('❌ /route/safest error (${sw.elapsedMilliseconds} ms): $e');
      invalidateHealthCache();
      return null;
    }
  }

  // ── Panic Mode Pipeline ───────────────────────────────────────────────────

  /// Sends a panic-escalation event to the backend.
  ///
  /// This is intentionally **fire-and-forget**: the Panic Mode state machine
  /// MUST NOT be blocked waiting for a network round-trip.  A 1.5 s hard
  /// timeout guarantees the call never delays SMS dispatch.
  ///
  /// Call this in parallel with the GPS fetch and SMS launch:
  /// ```dart
  /// await Future.wait([
  ///   _notifyEscalation(...),
  ///   _fetchGps(),
  /// ]);
  /// ```
  Future<EscalationAck> notifyEscalation({
    required String sessionId,
    required String stage,
    required String trigger,
    required List<String> triggerHistory,
    double? latitude,
    double? longitude,
    double? anomalyScore,
    int? anomalyConsecutiveWindows,
    double? safeWordConfidence,
  }) async {
    final sw = Stopwatch()..start();
    try {
      final body = <String, dynamic>{
        'session_id':     sessionId,
        'stage':          stage,
        'trigger':        trigger,
        'trigger_history': triggerHistory,
        'timestamp':      DateTime.now().toUtc().toIso8601String(),
      };
      if (latitude  != null) { body['latitude']  = latitude; }
      if (longitude != null) { body['longitude'] = longitude; }
      if (anomalyScore != null) { body['anomaly_score'] = anomalyScore; }
      if (anomalyConsecutiveWindows != null) {
        body['anomaly_consecutive_windows'] = anomalyConsecutiveWindows;
      }
      if (safeWordConfidence != null) {
        body['safe_word_confidence'] = safeWordConfidence;
      }

      final response = await http
          .post(
            Uri.parse(BackendConfig.panicEscalate),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(body),
          )
          .timeout(Duration(milliseconds: _kEscalationTimeoutMs));

      sw.stop();

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        debugPrint('⚡ /panic/escalate ← ${sw.elapsedMilliseconds} ms  '
            '(stage: $stage, ack: ${data['status']})');
        return EscalationAck(
          success:      data['status'] == 'received',
          backendStage: data['stage']?.toString(),
          message:      data['message']?.toString(),
          latencyMs:    sw.elapsedMilliseconds,
        );
      }
      return EscalationAck(
          success: false, latencyMs: sw.elapsedMilliseconds);
    } on TimeoutException {
      sw.stop();
      debugPrint('⏰ /panic/escalate timed out (${sw.elapsedMilliseconds} ms) – continuing offline');
      invalidateHealthCache();
      return EscalationAck(success: false, latencyMs: sw.elapsedMilliseconds);
    } catch (e) {
      sw.stop();
      debugPrint('❌ /panic/escalate error (${sw.elapsedMilliseconds} ms): $e');
      invalidateHealthCache();
      return EscalationAck(success: false, latencyMs: sw.elapsedMilliseconds);
    }
  }

  // ── Private helpers ───────────────────────────────────────────────────────

  Future<bool> _probe() async {
    try {
      final response = await http
          .get(Uri.parse(BackendConfig.healthEndpoint))
          .timeout(Duration(milliseconds: _kHealthTimeoutMs));
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }
}
