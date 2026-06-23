import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import '../app_navigator.dart';
import '../features/panic_mode/panic_mode_screen.dart';
import 'direct_sms_service.dart';
import 'quick_action_notification_service.dart';
import 'secure_storage_service.dart';
import 'safe_word_verification_service.dart';
import 'panic_escalation_service.dart';
import 'event_log_service.dart';
import '../models/event_log.dart';

// =============================================================================
// SilentSafeWordService
// =============================================================================
//
// Runs safe-word monitoring silently in the foreground without opening the
// Panic Mode screen.  Ideal for use after tapping "Safe Word" from the
// notification — the user can continue using their phone normally while the
// mic stays active.
//
// When the safe word is detected, the service navigates to PanicModeScreen
// automatically via [navigatorKey].
//
// Usage:
//   await SilentSafeWordService.instance.start();
//   SilentSafeWordService.instance.stop();
//   SilentSafeWordService.instance.isActive // ValueNotifier<bool>
// =============================================================================

class SilentSafeWordService {
  SilentSafeWordService._();
  static final instance = SilentSafeWordService._();

  // ── Public state ─────────────────────────────────────────────────────────
  final ValueNotifier<bool> isActive = ValueNotifier(false);

  // ── Private ──────────────────────────────────────────────────────────────
  late stt.SpeechToText _speech;
  final PanicEscalationService _escalation = PanicEscalationService();
  String _safeWord = '';
  String _sessionId = '';
  bool _triggered = false;

  // ── API ───────────────────────────────────────────────────────────────────

  /// Start silent monitoring. Safe to call multiple times — no-ops if already active.
  Future<void> start() async {
    if (isActive.value) return;

    _triggered = false;
    _sessionId = '${DateTime.now().millisecondsSinceEpoch}_${Random().nextInt(9999)}';

    // Load safe word
    final storage = SecureStorageService();
    final stored = await storage.getSafeWord();
    if (stored == null || stored.isEmpty) {
      debugPrint('[SilentSafeWord] No safe word configured — aborting.');
      return;
    }
    _safeWord = stored.toLowerCase();

    // Initialize escalation service (needed for triggerSafeWord callback)
    _escalation.onStageChanged = (stage, trigger) {
      if (stage == EscalationStage.dispatching && !_triggered) {
        _triggered = true;
        _onSafeWordDetected();
      }
    };
    _escalation.onCountdownTick = (_) {};
    await _escalation.initialize(sessionId: _sessionId);

    // Initialize speech
    _speech = stt.SpeechToText();
    final available = await _speech.initialize(
      onStatus: (status) {
        if (status == 'notListening' && isActive.value && !_triggered) {
          Future.delayed(
            const Duration(milliseconds: 500),
            _listenOnce,
          );
        }
      },
      onError: (_) {},
    );

    if (!available) {
      debugPrint('[SilentSafeWord] Speech unavailable.');
      return;
    }

    isActive.value = true;
    EventLogService().logEvent(
      type: EventType.panicModeActivated,
      outcome: EventOutcome.info,
      description: 'Silent safe-word monitoring started (session: $_sessionId)',
    );

    _listenOnce();
    debugPrint('[SilentSafeWord] Started — listening for "$_safeWord"');
  }

  /// Stop monitoring.
  void stop() {
    if (!isActive.value) return;
    isActive.value = false;
    try {
      _speech.stop();
    } catch (_) {}
    _escalation.onStageChanged = null;
    debugPrint('[SilentSafeWord] Stopped.');
  }

  // ── Private helpers ───────────────────────────────────────────────────────

  void _listenOnce() {
    if (!isActive.value || _triggered) return;
    try {
      _speech.listen(
        onResult: (result) {
          if (!isActive.value || _triggered) return;
          final words = result.recognizedWords.toLowerCase();
          if (result.finalResult || words.isNotEmpty) {
            _checkSafeWord(words, result.confidence);
          }
        },
        listenFor: const Duration(minutes: 30),
        listenOptions: stt.SpeechListenOptions(
          listenMode: stt.ListenMode.dictation,
          cancelOnError: false,
          partialResults: true,
        ),
      );
    } catch (e) {
      debugPrint('[SilentSafeWord] Listen error: $e');
    }
  }

  Future<void> _checkSafeWord(String recognized, double confidence) async {
    if (recognized.isEmpty || _safeWord.isEmpty) return;
    try {
      final result = await SafeWordVerificationService.verifySafeWord(
        sessionId: _sessionId,
        phrase: recognized,
        confidence: confidence,
        storedSafeWord: _safeWord,
      );
      if (result.isVerified) {
        _escalation.triggerSafeWord(
            confidence: result.confidence, matchedViaApi: true);
      } else if (result.isError || !result.shouldRetry) {
        if (_localMatch(recognized)) {
          _escalation.triggerSafeWord(
              confidence: confidence, matchedViaApi: false);
        }
      }
    } catch (_) {
      if (_localMatch(recognized)) {
        _escalation.triggerSafeWord(confidence: confidence, matchedViaApi: false);
      }
    }
  }

  bool _localMatch(String recognized) {
    final r = recognized.trim().toLowerCase();
    final s = _safeWord.trim().toLowerCase();
    return r.isNotEmpty && s.isNotEmpty && (r == s || r.contains(s));
  }

  /// Fires when the safe word is confirmed. Sends emergency SMS directly
  /// (works in background — no UI screen required) then navigates to
  /// PanicModeScreen if the app happens to be in the foreground.
  Future<void> _onSafeWordDetected() async {
    stop();
    debugPrint('[SilentSafeWord] Safe word detected — dispatching emergency alerts');

    // ── 1. Load contacts & user name ─────────────────────────────────────
    final storage = SecureStorageService();
    final contactMaps = await storage.getTrustedContacts();
    final userName = await storage.getUserNameAsync();
    final who = userName.trim().isNotEmpty ? userName.trim() : 'SheSafe user';

    // ── 2. Best-effort GPS (last known position, 5-second timeout) ───────
    String locationLine = 'Location unavailable.';
    try {
      final pos = await Geolocator.getLastKnownPosition()
          .timeout(const Duration(seconds: 5));
      if (pos != null) {
        final url =
            'https://maps.google.com/?q=${pos.latitude},${pos.longitude}';
        locationLine = 'Last known location: $url';
      }
    } catch (_) {}

    // ── 3. Send emergency SMS to every trusted contact ───────────────────
    final sms = DirectSmsService();
    final message = '🚨 EMERGENCY: $who may be in danger and needs help. '
        'Safe word was triggered. $locationLine';
    int sentCount = 0;
    for (final c in contactMaps) {
      final phone = (c['phone'] as String?) ?? '';
      if (phone.isEmpty) continue;
      final ok = await sms.sendEmergency(phone: phone, message: message);
      if (ok) sentCount++;
    }
    debugPrint('[SilentSafeWord] Sent to $sentCount contact(s)');

    // ── 4. Post visible notification so user knows alerts were sent ───────
    final notifSvc = QuickActionNotificationService();
    if (sentCount > 0) {
      await notifSvc.showAlertNotification(
        title: '🚨 Emergency alert sent',
        body: '$sentCount contact(s) have been notified.',
      );
    } else {
      await notifSvc.showAlertNotification(
        title: '⚠️ Alert could not be sent',
        body: 'No trusted contacts were reachable.',
      );
    }

    EventLogService().logEvent(
      type: EventType.emergencyAlertDispatched,
      outcome:
          sentCount > 0 ? EventOutcome.success : EventOutcome.failure,
      description:
          'Safe word triggered background dispatch — $sentCount/${
          contactMaps.length} contact(s) reached.',
      metadata: {'sessionId': _sessionId, 'sentCount': sentCount},
    );

    // ── 5. Open PanicModeScreen if app is in foreground (optional UI) ─────
    final nav = navigatorKey.currentState;
    if (nav != null) {
      nav.push(
        MaterialPageRoute(
          settings: const RouteSettings(name: '/panic'),
          builder: (_) => const PanicModeScreen(safeWordMode: true),
        ),
      );
    }
  }
}
