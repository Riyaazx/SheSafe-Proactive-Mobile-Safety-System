import 'dart:async';
import 'package:battery_plus/battery_plus.dart';
import 'event_log_service.dart';
import 'secure_storage_service.dart';
import 'direct_sms_service.dart';
import '../models/event_log.dart';

// =============================================================================
// BatteryAlertService — Feature 3: Low-Battery Last-Known Location Alert
// =============================================================================
//
// Implements a two-tier threshold-based battery monitoring system:
//
//   Tier 1 — WARNING  (≤ 20%):
//     • LowBatteryFlag becomes true.
//     • onLowBattery callback fires → UI shows in-app warning banner.
//     • Logged for audit trail.
//
//   Tier 2 — CRITICAL (≤ 10%):
//     • Automatic SMS sent to ALL trusted contacts containing:
//         - User's last known GPS position as a Google Maps link.
//         - Battery level and SheSafe attribution.
//     • onCriticalAlert callback fires → UI confirms alert was sent.
//     • Each tier fires only ONCE per walk session to prevent spam.
//
// The service uses a periodic Timer (every 60 s) because
// Battery.onBatteryStateChanged only fires on charge/discharge state changes,
// not on level changes.
//
// Academic rationale:
//   Context-aware       → monitors actual device state (battery level).
//   Threshold-based     → LowBatteryFlag = (batteryLevel ≤ warningThreshold).
//   Automatic response  → contacts notified without user intervention.
//
// Usage:
//   BatteryAlertService().startMonitoring(
//     sessionId: BatteryAlertService.kSafetyModeSession,
//     userName: 'Riya',
//     getLastPosition: () => (lat: pos.latitude, lon: pos.longitude),
//     onLowBattery:   (level) => showWarningBanner(),
//     onCriticalAlert:(level, lat, lon) => showContactPicker(),
//   );
//   BatteryAlertService().stopMonitoring(BatteryAlertService.kSafetyModeSession);
//
// Multiple concurrent sessions (e.g. Safety Mode + Safe Route) are supported.
// Each registers with its own sessionId. Polling continues until all sessions
// have called stopMonitoring. Each screen receives its own callbacks so that
// every active UI can display its own battery-warning banner independently.
// =============================================================================

/// Holds the registration data for one active safety session.
class _BatterySession {
  final String id;
  final String userName;
  final ({double lat, double lon})? Function() getLastPosition;
  final void Function(int level)? onLowBattery;
  final void Function(int level, double? lat, double? lon)? onCriticalAlert;
  const _BatterySession({
    required this.id,
    required this.userName,
    required this.getLastPosition,
    this.onLowBattery,
    this.onCriticalAlert,
  });
}

class BatteryAlertService {
  // ── Singleton ──────────────────────────────────────────────────────────────
  static final BatteryAlertService _instance =
      BatteryAlertService._internal();
  factory BatteryAlertService() => _instance;
  BatteryAlertService._internal();

  // ── Thresholds ─────────────────────────────────────────────────────────────

  /// Tier 1: LowBatteryFlag is set, user warned in-app.
  static const int warningThresholdPercent = 20;

  /// Tier 2: Contacts notified — UI callback fires so the user can choose who.
  static const int criticalThresholdPercent = 10;

  /// How often to poll the battery level during a safety session.
  static const Duration _pollInterval = Duration(seconds: 60);

  // ── Session-ID constants ───────────────────────────────────────────────────
  /// Stable session identifier for a Safe Route walk session.
  static const String kSafeRouteSession  = 'safe_route_walk';
  /// Stable session identifier for a Safety Mode session.
  static const String kSafetyModeSession = 'safety_mode';
  /// Stable session identifier for a Panic Mode session.
  static const String kPanicModeSession  = 'panic_mode';

  // ── Public state ───────────────────────────────────────────────────────────

  /// True when battery has dropped to or below [warningThresholdPercent].
  /// Remains true until the last active session ends.
  bool lowBatteryFlag = false;

  /// True while at least one safety session is registered.
  bool get isMonitoring => _pollTimer != null;

  // ── Private state ──────────────────────────────────────────────────────────

  /// All currently active safety sessions.
  /// Polling runs for as long as this list is non-empty.
  final List<_BatterySession> _sessions = [];

  final Battery _battery = Battery();
  Timer? _pollTimer;
  bool _warningSent  = false; // fire-once guard per monitoring lifecycle
  bool _criticalSent = false; // fire-once guard per monitoring lifecycle

  /// Overrides the battery level used by [_checkBattery].
  /// Set to a non-null value in unit tests to avoid reading real hardware.
  /// Must be reset to null between tests.
  int? _testBatteryLevelOverride;

  final SecureStorageService _storage = SecureStorageService();
  final EventLogService _eventLog = EventLogService();

  // ── Public API ─────────────────────────────────────────────────────────────

  /// Registers a safety session and starts (or continues) battery polling.
  ///
  /// [sessionId]       – stable identifier for this session; use the
  ///                     [kSafeRouteSession] / [kSafetyModeSession] constants.
  ///                     Re-registering the same ID replaces the previous entry.
  /// [userName]        – displayed in the outgoing SMS body.
  /// [getLastPosition] – returns the most recent GPS fix, or null.
  /// [onLowBattery]    – called when battery ≤ [warningThresholdPercent].
  ///                     Also called immediately if the battery is already low
  ///                     when this session registers, so the screen can show
  ///                     its banner without waiting for the next poll.
  /// [onCriticalAlert] – called when battery ≤ [criticalThresholdPercent].
  void startMonitoring({
    required String sessionId,
    required String userName,
    required ({double lat, double lon})? Function() getLastPosition,
    void Function(int level)? onLowBattery,
    void Function(int level, double? lat, double? lon)? onCriticalAlert,
  }) {
    // Dedup: replace any existing registration with the same session ID.
    _sessions.removeWhere((s) => s.id == sessionId);
    _sessions.add(_BatterySession(
      id: sessionId,
      userName: userName,
      getLastPosition: getLastPosition,
      onLowBattery: onLowBattery,
      onCriticalAlert: onCriticalAlert,
    ));

    if (_sessions.length == 1) {
      // First session — reset per-lifecycle guards and start fresh polling.
      lowBatteryFlag = false;
      _warningSent   = false;
      _criticalSent  = false;
      _pollTimer?.cancel();
      _checkBattery();
      _pollTimer = Timer.periodic(_pollInterval, (_) => _checkBattery());
    } else {
      // Additional session joining an already-running monitoring cycle.
      // If battery is already in warning state, notify the new session
      // immediately so its screen can display the banner straight away.
      if (lowBatteryFlag) onLowBattery?.call(warningThresholdPercent);
    }
  }

  /// Resets the per-lifecycle fire-once guards so a simulation can trigger
  /// the same threshold more than once in a single session.
  ///
  /// Only active in debug/profile builds (stripped by `assert` in release).
  /// Use this before each [simulateBatteryLevel] call in the debug test screen.
  void resetThresholdFlags() {
    assert(() {
      _warningSent   = false;
      _criticalSent  = false;
      lowBatteryFlag = false;
      return true;
    }());
  }

  /// De-registers a safety session from battery monitoring.
  ///
  /// Polling stops only when the last active session is removed.
  ///
  /// Pass [sessionId] matching the value used in [startMonitoring].  Passing
  /// `null` (or calling with no argument) is a nuclear stop that clears all
  /// sessions — useful only in debug/test tools.
  void stopMonitoring([String? sessionId]) {
    if (sessionId == null) {
      _sessions.clear();
    } else {
      _sessions.removeWhere((s) => s.id == sessionId);
    }
    if (_sessions.isEmpty) {
      _pollTimer?.cancel();
      _pollTimer = null;
      lowBatteryFlag = false;
      _warningSent   = false;
      _criticalSent  = false;
    }
  }

  // ── Internal ───────────────────────────────────────────────────────────────

  /// Test helper — injects a synthetic battery level and immediately runs
  /// the threshold checks.  Call [stopMonitoring] between tests to reset state.
  ///
  /// Example (inside a test):
  /// ```dart
  /// service.startMonitoring(userName: 'Test', getLastPosition: () => null, ...);
  /// await service.simulateBatteryLevel(15);
  /// expect(service.lowBatteryFlag, isTrue);
  /// ```
  /// Test helper — injects a synthetic battery level and immediately runs
  /// the threshold checks.  The public signature is unchanged for compatibility.
  Future<void> simulateBatteryLevel(
    int level, {
    required String userName,
    required ({double lat, double lon})? Function() getLastPosition,
  }) async {
    // Push a temporary session so _checkBattery has something to iterate.
    const simulateId = '__simulate__';
    _sessions.removeWhere((s) => s.id == simulateId);
    _sessions.add(_BatterySession(
      id: simulateId,
      userName: userName,
      getLastPosition: getLastPosition,
    ));
    _testBatteryLevelOverride = level;
    await _checkBattery();
    _testBatteryLevelOverride = null;
    _sessions.removeWhere((s) => s.id == simulateId);
  }

  Future<void> _checkBattery() async {
    if (_warningSent && _criticalSent) return;
    if (_sessions.isEmpty) return;

    // The most-recently-registered session provides the SMS name and GPS
    // position (typically the foreground / highest-accuracy session).
    final primary = _sessions.last;

    try {
      // Skip while charging — no risk of dying.
      // NOTE: charging check intentionally skipped during development
      // (phone is connected via USB). Re-add for production:
      // final state = await _battery.batteryState;
      // if (state == BatteryState.charging || state == BatteryState.full) return;

      final level = _testBatteryLevelOverride ?? await _battery.batteryLevel;

      // ── Tier 1: Warning (≤ 20%) ────────────────────────────────────────
      if (!_warningSent && level <= warningThresholdPercent) {
        _warningSent  = true;
        lowBatteryFlag = true;

        // Notify EVERY active session so each UI can show its own banner.
        for (final s in List.of(_sessions)) {
          s.onLowBattery?.call(level);
        }

        // Auto-SMS uses primary session's last-known GPS position.
        final pos = primary.getLastPosition();
        _sendCriticalSms(
          userName: primary.userName,
          lat: pos?.lat,
          lon: pos?.lon,
          batteryLevel: level,
        ).catchError((_) {});

        _eventLog.logEvent(
          type: EventType.safetyModeActivated,
          outcome: EventOutcome.warning,
          description:
              'LowBatteryFlag set to true. '
              'Battery: $level% (threshold: $warningThresholdPercent%). '
              'Auto-notifying trusted contacts.',
          metadata: {'batteryLevel': level, 'flag': 'lowBatteryFlag=true'},
        );
      }

      // ── Tier 2: Critical (≤ 10%) ───────────────────────────────────────
      // SMS is also sent automatically here — same as Tier 1 but with a
      // more urgent message body.  The onCriticalAlert callback fires
      // afterwards so each UI can show a confirmation notification.
      if (!_criticalSent && level <= criticalThresholdPercent) {
        _criticalSent = true;
        final pos = primary.getLastPosition();

        // Auto-send to ALL trusted contacts — no user intervention required.
        _sendCriticalSms(
          userName: primary.userName,
          lat: pos?.lat,
          lon: pos?.lon,
          batteryLevel: level,
        ).catchError((_) {});

        _eventLog.logEvent(
          type: EventType.safetyModeActivated,
          outcome: EventOutcome.warning,
          description:
              'Critical battery — auto-SMS sent to all trusted contacts. '
              'Battery: $level%  Lat: ${pos?.lat}  Lon: ${pos?.lon}',
          metadata: {'batteryLevel': level, 'lat': pos?.lat, 'lon': pos?.lon},
        );

        // Notify every active session so each UI can show a confirmation.
        for (final s in List.of(_sessions)) {
          s.onCriticalAlert?.call(level, pos?.lat, pos?.lon);
        }
      }
    } catch (e) {
      // Non-fatal — battery_plus may not be available in all environments.
      _eventLog.logEvent(
        type: EventType.safetyModeActivated,
        outcome: EventOutcome.warning,
        description: 'BatteryAlertService: failed to read battery — $e',
      );
    }
  }

  // ── Public SMS helper ── called by the UI after the user picks contacts ──

  /// Sends a critical battery SMS to [phones] (list of E.164 numbers).
  /// [lat] / [lon] may be null if GPS was not available.
  Future<void> sendCriticalSms({
    required String userName,
    required List<String> phones,
    required int batteryLevel,
    required double? lat,
    required double? lon,
  }) async {
    if (phones.isEmpty) return;

    final String locationSnippet;
    if (lat != null && lon != null) {
      final link =
          'https://maps.google.com/?q=${lat.toStringAsFixed(6)},${lon.toStringAsFixed(6)}';
      locationSnippet = 'Last known location: $link';
    } else {
      locationSnippet = 'Location unavailable (GPS not fixed).';
    }

    final who = userName.trim().isNotEmpty ? userName.trim() : 'Someone';
    final smsBody =
        '🔴 $who\'s phone battery is critically low ($batteryLevel%). '
        'Her SheSafe walk tracking may stop soon. '
        '$locationSnippet '
        '(Sent automatically by SheSafe)';

    final sms = DirectSmsService();
    int sent = 0;
    for (final phone in phones) {
      if (phone.isEmpty) continue;
      // Use sendEmergency (silent-only) so the system never opens an SMS app
      // requiring manual intervention during a low-battery automated alert.
      final ok = await sms.sendEmergency(phone: phone, message: smsBody);
      if (ok) sent++;
    }

    _eventLog.logEvent(
      type: EventType.safetyModeActivated,
      outcome: EventOutcome.success,
      description:
          'Critical battery SMS sent to $sent contact(s). '
          'Battery: $batteryLevel%',
      metadata: {'batteryLevel': batteryLevel, 'sent': sent},
    );
  }

  // ── Legacy private helper (kept for reference, no longer auto-called) ──
  Future<void> _sendCriticalSms({
    required String userName,
    required double? lat,
    required double? lon,
    required int batteryLevel,
  }) async {
    final contacts = await _storage.getTrustedContacts();
    if (contacts.isEmpty) return;

    // Build location part
    final String locationPart;
    if (lat != null && lon != null) {
      locationPart =
          'https://maps.google.com/?q=${lat.toStringAsFixed(6)},${lon.toStringAsFixed(6)}';
    } else {
      locationPart = 'Location unavailable';
    }

    final who = userName.trim().isNotEmpty ? userName.trim() : 'Someone';

    final smsBody = '$who is low in battery\nher last location: $locationPart';

    final sms = DirectSmsService();
    final phones = contacts
        .map((c) => c['phone'] as String? ?? '')
        .where((p) => p.isNotEmpty)
        .toList();

    int sent = 0;
    for (final phone in phones) {
      // Use sendEmergency (silent-only) so the system never opens an SMS app
      // requiring manual intervention during a critical-battery automated alert.
      final ok = await sms.sendEmergency(phone: phone, message: smsBody);
      if (ok) sent++;
    }

    _eventLog.logEvent(
      type: EventType.safetyModeActivated,
      outcome: EventOutcome.warning,
      description:
          'Critical battery alert sent to $sent contact(s). '
          'Battery: $batteryLevel%  Lat: $lat  Lon: $lon',
      metadata: {
        'batteryLevel': batteryLevel,
        'lat': lat,
        'lon': lon,
        'contactCount': sent,
      },
    );
  }
}
