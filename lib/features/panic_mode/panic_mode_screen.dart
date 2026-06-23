import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:slide_to_act/slide_to_act.dart';
import 'package:geolocator/geolocator.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:permission_handler/permission_handler.dart';
import '../../services/secure_storage_service.dart';
import '../../services/safe_word_verification_service.dart';
import '../../services/battery_alert_service.dart';
import '../../services/direct_sms_service.dart';
import '../../services/event_log_service.dart';
import '../../services/motion_baseline_service.dart';
import '../../services/panic_escalation_service.dart';
import '../../services/integration_pipeline_service.dart';
import '../../models/alert_metadata.dart';
import '../../models/event_log.dart';
import '../../app_navigator.dart';


// ─────────────────────────────────────────────────────────────────────────────

class PanicModeScreen extends StatefulWidget {
  /// When true the screen was opened via the "Safe Word" notification button.
  /// A prominent banner is shown so the user knows the safe word listener is
  /// active and they can say their safe word to trigger the emergency alert.
  final bool safeWordMode;

  const PanicModeScreen({super.key, this.safeWordMode = false});

  @override
  State<PanicModeScreen> createState() => _PanicModeScreenState();
}

class _PanicModeScreenState extends State<PanicModeScreen>
    with TickerProviderStateMixin {
  // ── Services ────────────────────────────────────────────────────────────────
  final MotionBaselineService _motionService = MotionBaselineService();
  final PanicEscalationService _escalation = PanicEscalationService();
  final EventLogService _eventLogService = EventLogService();
  final DirectSmsService _directSmsService = DirectSmsService();
  final BatteryAlertService _batteryAlertService = BatteryAlertService();

  // ── Session ──────────────────────────────────────────────────────────────────
  late String _sessionId;

  // ── Motion (legacy fallback) ─────────────────────────────────────────────────
  StreamSubscription<AccelerometerEvent>? _accelerometerSubscription;
  StreamSubscription<AccelerometerEvent>? _displayAccelSubscription; // for bar display only
  // ignore: unused_field
  double _currentMagnitude = 0.0;   // includes gravity (used internally / anomaly)
  double _linearMagnitude = 0.0;    // high-pass filtered, gravity removed (display bar)
  // High-pass filter state (isolates movement, removes gravity)
  double _gravX = 0, _gravY = 0, _gravZ = 0;
  static const double _hpAlpha = 0.8; // smoothing factor (~5 Hz cutoff)
  double _baselineMagnitude = 0.0;
  // ignore: unused_field
  bool _usingPersonalizedBaseline = false;
  double _currentAnomalyScore = 0.0;
  final double _fallbackMovementThreshold = 15.0;

  // ── Speech recognition ────────────────────────────────────────────────────────
  late stt.SpeechToText _speech;
  bool _isListening = false;
  String _recognizedWords = '';
  String _safeWord = ''; // empty until loaded from secure storage
  int _verificationAttempts = 0;
  bool _speechRestartPending = false;

  // ── Escalation UI state ───────────────────────────────────────────────────────
  EscalationStage _stage = EscalationStage.monitoring;
  EscalationTrigger? _lastTrigger;

  /// Seconds remaining for the active timer (check-in or countdown).
  int _timerRemaining = 0;

  /// Metadata bundle attached to the dispatched alert (non-null when
  /// stage == resolved).
  AlertMetadata? _alertMetadata;

  bool _isInitializing = true;

  /// Guard that prevents _sendEmergencyAlert from being called twice.
  bool _isDispatching = false;

  /// True when battery has dropped to warning level during this panic session.
  bool _lowBatteryPanicWarning = false;

  /// Loaded user display name for personalised SMS messages.
  String _userName = '';

  /// Per-contact alert delivery results shown in the resolved view.
  List<Map<String, String>> _alertResults = [];

  /// Progress text shown during the dispatching stage.
  String _dispatchProgress = '';

  /// Live delivery log — one entry per individual SMS, shown in both the
  /// dispatching and resolved views so the user can see proof of every send.
  final List<String> _dispatchLog = [];

  /// The exact SMS bodies that were sent, shown in the resolved receipt.
  String _sentLocationBody = '';
  String _sentSpamBody = '';

  /// Stable key for the slide-to-cancel widget so it isn't reset on every timer tick.
  final GlobalKey<SlideActionState> _slideKey = GlobalKey<SlideActionState>();

  // ── Animation ──────────────────────────────────────────────────────────────────
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;

  // ════════════════════════════════════════════════════════════════════════════
  // Init
  // ════════════════════════════════════════════════════════════════════════════

  @override
  void initState() {
    super.initState();
    panicModeActive.value = true; // hide SOS pill for entire lifetime of this screen
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    )..repeat(reverse: true);
    _pulseAnimation = Tween<double>(begin: 0.82, end: 1.0).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    _initializePanicMode();
  }

  Future<void> _initializePanicMode() async {
    _sessionId =
        '${DateTime.now().millisecondsSinceEpoch}_${Random().nextInt(9999)}';

    // Wire callbacks before initialize() so the first transition  is captured.
    _escalation.onStageChanged = _onEscalationStageChanged;
    _escalation.onCountdownTick = _onCountdownTick;
    await _escalation.initialize(sessionId: _sessionId);

    await _loadSafeWord();
    await _loadUserName();

    // Feature 3: battery alert monitoring during Panic Mode session.
    // If battery drops critically while waiting for escalation, contacts should
    // be notified immediately — phone dying in an emergency is dangerous.
    _batteryAlertService.startMonitoring(
      sessionId: BatteryAlertService.kPanicModeSession,
      userName: _userName,
      getLastPosition: () => null, // Panic Mode has no live GPS stream
      onLowBattery: (level) {
        if (!mounted) return;
        setState(() => _lowBatteryPanicWarning = true);
      },
      onCriticalAlert: (level, lat, lon) {
        if (!mounted) return;
        // SMS auto-sent by BatteryAlertService. Show inline confirmation.
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
              '🔴 Battery critical ($level%) — SMS sent to all contacts automatically.'),
          backgroundColor: Colors.red.shade700,
          duration: const Duration(seconds: 6),
        ));
      },
    );

    // Pre-request SMS permission here, during the 'initialising' phase, so
    // the system dialog never appears mid-emergency while alerts are sending.
    // We AWAIT the result so dispatch can proceed silently once the user grants.
    await Permission.sms.request();
    await _initializeSpeech();
    await _motionService.initialize();
    _startMotionMonitoring();

    // Separate subscription for the display bar: raw accelerometer + high-pass
    // filter to strip gravity. Works reliably on all Android devices.
    _displayAccelSubscription = accelerometerEventStream().listen((e) {
      // Low-pass filter extracts gravity component
      _gravX = _hpAlpha * _gravX + (1 - _hpAlpha) * e.x;
      _gravY = _hpAlpha * _gravY + (1 - _hpAlpha) * e.y;
      _gravZ = _hpAlpha * _gravZ + (1 - _hpAlpha) * e.z;
      // Subtract gravity to get linear acceleration
      final lx = e.x - _gravX;
      final ly = e.y - _gravY;
      final lz = e.z - _gravZ;
      final mag = sqrt(lx * lx + ly * ly + lz * lz);
      if (mounted) setState(() => _linearMagnitude = mag);
    });

    if (_speech.isAvailable) _startListening();

    _eventLogService.logEvent(
      type: EventType.panicModeActivated,
      outcome: EventOutcome.success,
      description: 'Panic Mode activated '
          '(${_motionService.isCalibrated ? "personalized" : "standard"} baseline)',
      metadata: {
        'sessionId': _sessionId,
        'personalizedBaseline': _motionService.isCalibrated,
      },
    );

    if (mounted) {
      setState(() {
        _isInitializing = false;
        _usingPersonalizedBaseline = _motionService.isCalibrated;
      });
    }
  }

  // ════════════════════════════════════════════════════════════════════════════
  // Escalation callbacks
  // ════════════════════════════════════════════════════════════════════════════

  void _onEscalationStageChanged(
      EscalationStage stage, EscalationTrigger trigger) {
    if (!mounted) return;

    setState(() {
      _stage = stage;
      _lastTrigger = trigger;
    });

    // ── Notify backend (fire-and-forget, capped at 1.5 s) ───────────────────────
    unawaited(
      IntegrationPipelineService.instance.notifyEscalation(
        sessionId:      _sessionId,
        stage:          stage.name,
        trigger:        trigger.name,
        triggerHistory: _escalation.triggerHistory.map((t) => t.name).toList(),
        anomalyScore:   _currentAnomalyScore > 0 ? _currentAnomalyScore : null,
      ),
    );  // errors are silently ignored inside the service

    // Kick off the actual alert dispatch exactly once.
    if (stage == EscalationStage.dispatching && !_isDispatching) {
      _isDispatching = true;
      _sendEmergencyAlert();
    }

    // Shut down sensors / speech once we no longer need them.
    if (stage == EscalationStage.cancelled ||
        stage == EscalationStage.dispatching) {
      _stopAllMonitoring();
    }
  }

  void _onCountdownTick(int remaining) {
    if (!mounted) return;
    setState(() => _timerRemaining = remaining);
  }

  // ════════════════════════════════════════════════════════════════════════════
  // Safe word
  // ════════════════════════════════════════════════════════════════════════════

  Future<void> _loadSafeWord() async {
    try {
      final stored = await SecureStorageService().getSafeWord();
      if (stored != null && stored.isNotEmpty) {
        setState(() => _safeWord = stored.toLowerCase());
      }
    } catch (e) {
      debugPrint('❌ Error loading safe word: $e');
    }
  }

  Future<void> _loadUserName() async {
    try {
      final storage = SecureStorageService();
      final name = (await storage.getUserNameAsync()).trim();
      if (name.isNotEmpty) {
        _userName = name;
        debugPrint('👤 Loaded user name: $_userName');
      }
    } catch (e) {
      debugPrint('❌ Error loading user name: $e');
    }
  }

  Future<void> _initializeSpeech() async {
    try {
      _speech = stt.SpeechToText();
      final available = await _speech.initialize(
        onStatus: (status) {
          // Android speech_to_text can return 'notListening', 'done', or
          // 'doneNoResult' when an utterance ends. Restart on all of them so
          // the mic stays active across sentence pauses.
          if ((status == 'notListening' ||
                  status == 'done' ||
                  status == 'doneNoResult') &&
              {EscalationStage.monitoring, EscalationStage.countdown}
                  .contains(_stage)) {
            _scheduleListenerRestart();
          }
        },
        onError: (error) {
          debugPrint('⚠️ Speech error: ${error.errorMsg} (permanent: ${error.permanent})');
          if (mounted) setState(() => _isListening = false);
          // Restart unless it is a fatal permanent error or we have left the
          // active stages (e.g. SOS already dispatched).
          if (!error.permanent &&
              {EscalationStage.monitoring, EscalationStage.countdown}
                  .contains(_stage)) {
            _scheduleListenerRestart();
          }
        },
      );
      debugPrint(available ? '✅ Speech initialized' : '⚠️ Speech unavailable');
    } catch (e) {
      debugPrint('❌ Speech init failed: $e');
    }
  }

  /// Schedules one listener restart, deduplicating concurrent requests from
  /// both `onStatus` and `onResult` so we never start two sessions at once.
  void _scheduleListenerRestart() {
    if (_speechRestartPending) return;
    _speechRestartPending = true;
    Future.delayed(const Duration(milliseconds: 150), () {
      _speechRestartPending = false;
      if (!mounted) { return; }
      if (!{EscalationStage.monitoring, EscalationStage.countdown}
              .contains(_stage)) { return; }
      _startListening();
    });
  }

  void _startListening() {
    const activeStages = {
      EscalationStage.monitoring,
      EscalationStage.countdown,
    };
    if (!_speech.isAvailable || !activeStages.contains(_stage)) return;
    if (_safeWord.isEmpty) return; // no safe word configured – don't listen

    try {
      _speech.listen(
        onResult: (result) {
          if (!mounted || !activeStages.contains(_stage)) return;
          setState(
              () => _recognizedWords = result.recognizedWords.toLowerCase());
          if (result.recognizedWords.isNotEmpty) {
            _checkSafeWordWithAPI(
                _recognizedWords, _safeWord, result.confidence);
          }
          // After each complete utterance, schedule a restart so the mic
          // keeps listening for the next sentence.
          if (result.finalResult) { _scheduleListenerRestart(); }
        },
        listenFor: const Duration(minutes: 1),
        pauseFor: const Duration(seconds: 5),
        listenOptions: stt.SpeechListenOptions(
          listenMode: stt.ListenMode.dictation,
          cancelOnError: false,
          partialResults: true,
        ),
      );
      if (mounted) setState(() => _isListening = true);
    } catch (e) {
      debugPrint('❌ Failed to start listening: $e');
    }
  }

  Future<void> _checkSafeWordWithAPI(
      String recognized, String safeWord, double confidence) async {
    if (recognized.isEmpty || safeWord.isEmpty) return;
    _verificationAttempts++;
    debugPrint('🔐 Safe-word check #$_verificationAttempts: "$recognized"');

    try {
      final result = await SafeWordVerificationService.verifySafeWord(
        sessionId: _sessionId,
        phrase: recognized,
        confidence: confidence,
        storedSafeWord: safeWord,
      );
      if (!mounted) return;

      if (result.isError) {
        if (_localMatch(recognized, safeWord)) {
          _escalation.triggerSafeWord(
              confidence: confidence, matchedViaApi: false);
        }
        return;
      }

      if (result.isVerified) {
        _escalation.triggerSafeWord(
            confidence: result.confidence, matchedViaApi: true);
      } else if (!result.shouldRetry) {
        if (_localMatch(recognized, safeWord)) {
          _escalation.triggerSafeWord(
              confidence: confidence, matchedViaApi: false);
        }
      }
    } catch (_) {
      if (_localMatch(recognized, safeWord)) {
        _escalation.triggerSafeWord(confidence: confidence, matchedViaApi: false);
      }
    }
  }

  bool _localMatch(String recognized, String safeWord) {
    final r = recognized.trim().toLowerCase();
    final s = safeWord.trim().toLowerCase();
    if (r.isEmpty || s.isEmpty) return false;
    if (r == s || r.contains(s)) return true;
    final sw = s.split(' ');
    final rw = r.split(' ');
    return sw.every(
        (w) => w.isEmpty || rw.any((rr) => rr.contains(w) || w.contains(rr)));
  }

  // ════════════════════════════════════════════════════════════════════════════
  // Motion monitoring
  // ════════════════════════════════════════════════════════════════════════════

  void _startMotionMonitoring() {
    if (_motionService.isCalibrated) {
      _startPersonalizedMotionMonitoring();
    } else {
      _startFallbackMotionMonitoring();
    }
  }

  void _startPersonalizedMotionMonitoring() {
    _motionService.onWindowProcessed = (features) {
      if (mounted) setState(() => _currentMagnitude = features.meanMagnitude);
    };

    _motionService.onAnomalyDetected = (result) {
      if (!mounted) return;
      setState(() => _currentAnomalyScore = result.score);
      _eventLogService.logEvent(
        type: EventType.motionAnomalyDetected,
        outcome: EventOutcome.warning,
        description: result.description,
        metadata: {
          'sessionId': _sessionId,
          'score': result.score,
          'consecutiveWindows': _motionService.consecutiveAnomalyWindows,
        },
      );
    };

    // Route motion concerns through the escalation state machine.
    _motionService.onMotionConcernTriggered = (triggered) {
      if (!mounted || !triggered) return;
      _escalation.triggerMotionAnomaly(
        score: _currentAnomalyScore,
        description:
            'Motion concern: ${_motionService.consecutiveAnomalyWindows} anomalous windows',
        consecutiveWindows: _motionService.consecutiveAnomalyWindows,
      );
    };

    _motionService.startMonitoring();
  }

  void _startFallbackMotionMonitoring() {
    final baselineReadings = <double>[];
    _accelerometerSubscription =
        accelerometerEventStream().listen((AccelerometerEvent event) {
      final mag =
          sqrt(event.x * event.x + event.y * event.y + event.z * event.z);
      if (mounted) setState(() => _currentMagnitude = mag);

      if (baselineReadings.length < 300) {
        baselineReadings.add(mag);
        if (baselineReadings.length == 300) {
          _baselineMagnitude = baselineReadings.fold(0.0, (a, b) => a + b) /
              baselineReadings.length;
        }
        return;
      }

      final deviation = (mag - _baselineMagnitude).abs();
      if (deviation > _fallbackMovementThreshold &&
          _stage == EscalationStage.monitoring) {
        _escalation.triggerMotionAnomaly(
          score: (deviation / (_fallbackMovementThreshold * 2)).clamp(0.0, 1.0),
          description:
              'Significant movement detected (magnitude: ${mag.toStringAsFixed(1)})',
          consecutiveWindows: 1,
        );
      }
    });
  }

  void _stopAllMonitoring() {
    _accelerometerSubscription?.cancel();
    _displayAccelSubscription?.cancel();
    _motionService.stopMonitoring();
    _batteryAlertService.stopMonitoring(BatteryAlertService.kPanicModeSession);
    if (_speech.isAvailable) {
      try {
        _speech.stop();
      } catch (_) {}
    }
    if (mounted) setState(() => _isListening = false);
  }

  // ════════════════════════════════════════════════════════════════════════════
  // Alert dispatch
  // ════════════════════════════════════════════════════════════════════════════

  Future<void> _sendEmergencyAlert() async {
    // ── 0. Ensure SMS permission is granted before any sends ──────────────────
    var smsStatus = await Permission.sms.status;
    if (smsStatus.isDenied) {
      smsStatus = await Permission.sms.request();
    }
    if (smsStatus.isPermanentlyDenied || !smsStatus.isGranted) {
      // Show a prominent warning so the user knows why nothing will send.
      if (mounted) {
        setState(() {
          _dispatchLog
            ..clear()
            ..add('DENIED SMS permission not granted.')
            ..add('Go to: Settings > Apps > SheSafe > Permissions > SMS > Allow')
            ..add('Then re-trigger SOS.');
        });
      }
      debugPrint('❌ SMS permission not granted — cannot send emergency alerts');
      return;
    }

    // ── 1. Fetch GPS in parallel; notify backend fire-and-forget ─────────────
    // Backend notification is unawaited — if the server is offline it must
    // never delay or block the SMS dispatch path.
    unawaited(
      IntegrationPipelineService.instance.notifyEscalation(
        sessionId:      _sessionId,
        stage:          EscalationStage.dispatching.name,
        trigger:        (_lastTrigger ?? EscalationTrigger.manualSOS).name,
        triggerHistory: _escalation.triggerHistory.map((t) => t.name).toList(),
        anomalyScore:   _currentAnomalyScore > 0 ? _currentAnomalyScore : null,
        anomalyConsecutiveWindows:
            _motionService.consecutiveAnomalyWindows > 0
                ? _motionService.consecutiveAnomalyWindows
                : null,
      ),
    );

    // GPS fetch is awaited (result is used for the location SMS).
    double? lat, lng;

    Future<void> fetchGps() async {
      try {
        final serviceEnabled = await Geolocator.isLocationServiceEnabled();
        if (!serviceEnabled) {
          debugPrint('⚠️ Location services disabled');
          return;
        }
        var perm = await Geolocator.checkPermission();
        if (perm == LocationPermission.denied) {
          perm = await Geolocator.requestPermission();
        }
        if (perm == LocationPermission.denied ||
            perm == LocationPermission.deniedForever) {
          debugPrint('⚠️ Location permission denied — alert without GPS');
          return;
        }
        // LocationAccuracy.best = full GPS + network fusion (most accurate).
        // Hard 20-second ceiling so dispatch is never blocked by a slow fix.
        final pos = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.best,
        ).timeout(
          const Duration(seconds: 20),
          onTimeout: () => throw TimeoutException('GPS timed out'),
        );
        lat = pos.latitude;
        lng = pos.longitude;
        debugPrint(
            '📍 GPS fix: $lat, $lng (±${pos.accuracy.toStringAsFixed(1)} m)');
      } on TimeoutException {
        debugPrint('⚠️ GPS timed out — alert proceeding without location');
      } catch (e) {
        debugPrint('⚠️ GPS fetch failed: $e — alert will proceed anyway');
      }
    }

    await fetchGps();

    // ── 2. Build metadata + SMS bodies ────────────────────────────────────────
    final metadata =
        _escalation.buildAlertMetadata(latitude: lat, longitude: lng);
    debugPrint('📋 Alert metadata: trigger=${metadata.triggerType.label}, '
        'location=${metadata.locationString}');

    // ── 3. Get trusted contacts ───────────────────────────────────────────────
    final contactsData = await SecureStorageService().getTrustedContacts();
    if (contactsData.isEmpty) {
      debugPrint('⚠️ No trusted contacts — cannot send emergency alert');
      if (mounted) _showNoContactsDialog();
      _finalizeDispatch(metadata, alertResults: []);
      return;
    }

    // ── 4. For each contact: 1 full emergency SMS + 6 short repeated alerts ──
    //   Message 1  : full formatted SMS with GPS link + Call 999
    //   Messages 2-7: single-line repeated warning with name in CAPS
    //   All sent silently via Android SmsManager — no user interaction needed.
    const spamCount  = 6;
    const totalCount = spamCount + 1; // 7
    final who          = _userName.trim().isNotEmpty ? _userName.trim() : 'The user';
    final locationBody = _buildSmsBody(metadata);
    final spamBody     = '${who.toUpperCase()} MAY BE IN DANGER!!!';

    // Store for the resolved receipt view.
    if (mounted) {
      setState(() {
        _sentLocationBody = locationBody;
        _sentSpamBody     = spamBody;
        _dispatchLog.clear();
      });
    }
    final results = <Map<String, String>>[];

    for (final contact in contactsData) {
      final phone = contact['phone'] as String? ?? '';
      final name  = contact['name']  as String? ?? 'Contact';
      if (phone.isEmpty) continue;

      debugPrint('📤 Sending 1 location + $spamCount spam to $name ($phone)');
      int sentCount = 0;

      // ── Step A: Full emergency SMS (most important; delivered first) ──────
      if (mounted) {
        setState(() => _dispatchProgress = 'Sending full alert to $name…');
      }
      try {
        final ok = await _directSmsService.sendEmergency(
            phone: phone, message: locationBody);
        if (ok) {
          sentCount++;
          debugPrint('  ✅ Location SMS → $name');
          if (mounted) setState(() => _dispatchLog.add('SENT   Full alert → $name (${_maskPhone(phone)})'));
        } else {
          debugPrint('  ⚠️ Location SMS failed → $name');
          if (mounted) setState(() => _dispatchLog.add('FAILED Full alert → $name (${_maskPhone(phone)})'));
        }
      } catch (e) {
        debugPrint('  ❌ Location SMS error → $name: $e');
        if (mounted) setState(() => _dispatchLog.add('ERROR  Full alert → $name (${_maskPhone(phone)})'));
      }

      // ── Step B: 6 short repeated alerts ──────────────────────────────────
      for (int i = 1; i <= spamCount; i++) {
        if (mounted) {
          setState(() =>
              _dispatchProgress = 'Sending repeat alert $i/$spamCount to $name…');
        }
        try {
          final ok = await _directSmsService.sendEmergency(
              phone: phone, message: spamBody);
          if (ok) {
            sentCount++;
            debugPrint('  ✅ Spam $i/$spamCount → $name');
            if (mounted) setState(() => _dispatchLog.add('SENT   Repeat $i/$spamCount → $name (${_maskPhone(phone)})'));
          } else {
            debugPrint('  ⚠️ Spam $i/$spamCount failed → $name');
            if (mounted) setState(() => _dispatchLog.add('FAILED Repeat $i/$spamCount → $name (${_maskPhone(phone)})'));
          }
        } catch (e) {
          debugPrint('  ❌ Spam $i/$spamCount error → $name: $e');
          if (mounted) setState(() => _dispatchLog.add('ERROR  Repeat $i/$spamCount → $name (${_maskPhone(phone)}))'));
        }
        await Future.delayed(const Duration(seconds: 2));
      }

      results.add({
        'name': name,
        'phone': phone,
        'sent': '$sentCount',
        'total': '$totalCount',
      });

      _eventLogService.logEvent(
        type: EventType.emergencyAlertDispatched,
        outcome: sentCount > 0 ? EventOutcome.success : EventOutcome.failure,
        description: sentCount > 0
            ? 'Emergency alert sent to $name ($sentCount/$totalCount delivered)'
            : 'Emergency alert failed for $name (0/$totalCount delivered)',
        metadata: {
          ...metadata.toJson(),
          'contactName': name,
          'triggerSource': (_lastTrigger ?? EscalationTrigger.manualSOS).name,
          'sentCount': sentCount,
          'totalCount': totalCount,
        },
      );
    }

    // ── 5. Finalise ───────────────────────────────────────────────────────────
    _finalizeDispatch(metadata, alertResults: results);
  }

  void _finalizeDispatch(
    AlertMetadata metadata, {
    required List<Map<String, String>> alertResults,
  }) {
    final anySuccess =
        alertResults.any((r) => int.tryParse(r['sent'] ?? '0')! > 0);

    _eventLogService.logEvent(
      type: EventType.emergencyAlertDispatched,
      outcome: alertResults.isEmpty
          ? EventOutcome.failure
          : anySuccess
              ? EventOutcome.success
              : EventOutcome.failure,
      description: alertResults.isEmpty
          ? 'Emergency alert – no trusted contacts configured'
          : anySuccess
              ? 'Emergency alerts dispatched to ${alertResults.length} contact(s)'
              : 'Emergency alert – all deliveries failed',
      metadata: {
        ...metadata.toJson(),
        'contactsAttempted': alertResults.length,
      },
    );

    _escalation.markResolved();

    if (mounted) {
      setState(() {
        _alertMetadata = metadata;
        _alertResults  = alertResults;
      });
      if (anySuccess) {
        final names = alertResults
            .where((r) => int.tryParse(r['sent'] ?? '0')! > 0)
            .map((r) => r['name'] ?? '')
            .where((n) => n.isNotEmpty)
            .toList();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('✅ Emergency alerts sent to: ${names.join(', ')}'),
            backgroundColor: Colors.green,
            duration: const Duration(seconds: 6),
          ),
        );
      }
    }
  }

  String _buildSmsBody(AlertMetadata meta) {
    final who = _userName.trim().isNotEmpty ? _userName.trim() : 'The user';
    final location = meta.hasLocation ? meta.googleMapsUrl! : 'unavailable';
    return 'Emergency Alert: $who may be in danger.\n'
        'Location: $location\n'
      'Please check on her immediately or call 999.';
  }

  void _showNoContactsDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('No Emergency Contacts'),
        content: const Text(
            'No trusted contacts are configured. Please add contacts in Settings.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  // ════════════════════════════════════════════════════════════════════════════
  // Cancel / exit
  // ════════════════════════════════════════════════════════════════════════════

  void _onUserCancelRequested() async {
    final confirmed = await _showCancelConfirmDialog();
    if (confirmed && mounted) _escalation.cancelAll();
  }

  Future<bool> _showCancelConfirmDialog() async {
    return await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Cancel Panic Mode?'),
            content:
                const Text('Are you safe? Monitoring will stop completely.'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Stay Active'),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.green,
                    foregroundColor: Colors.white),
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text("I'm Safe – Cancel"),
              ),
            ],
          ),
        ) ??
        false;
  }

  // ════════════════════════════════════════════════════════════════════════════
  // Lifecycle
  // ════════════════════════════════════════════════════════════════════════════

  @override
  void dispose() {
    panicModeActive.value = false; // restore SOS pill now that panic mode is gone
    // Log panic mode deactivation
    EventLogService().logEvent(
      type: EventType.panicModeDeactivated,
      outcome: EventOutcome.info,
      description: 'Panic mode deactivated — user exited the screen',
    );
    _escalation.dispose();
    _stopAllMonitoring();
    _pulseController.dispose();
    super.dispose();
  }

  // ════════════════════════════════════════════════════════════════════════════
  // BUILD
  // ════════════════════════════════════════════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: _stage == EscalationStage.resolved ||
          _stage == EscalationStage.cancelled,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _onUserCancelRequested();
      },
      child: Scaffold(
        backgroundColor: _stageColor,
        body: SafeArea(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 350),
            switchInCurve: Curves.easeIn,
            switchOutCurve: Curves.easeOut,
            child: _isInitializing
                ? _buildInitializingView()
                : _buildStageView(),
          ),
        ),
      ),
    );
  }

  // ── Stage background colour ────────────────────────────────────────────────

  Color get _stageColor {
    switch (_stage) {
      case EscalationStage.monitoring:
      case EscalationStage.checkIn:
        return Colors.red.shade700;
      case EscalationStage.countdown:
        return Colors.deepOrange.shade800;
      case EscalationStage.dispatching:
        return Colors.red.shade900;
      case EscalationStage.resolved:
        return Colors.green.shade700;
      case EscalationStage.cancelled:
        return Colors.grey.shade800;
    }
  }

  // ── Router ─────────────────────────────────────────────────────────────────

  Widget _buildInitializingView() {
    return const Center(
      key: ValueKey('init'),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          CircularProgressIndicator(color: Colors.white),
          SizedBox(height: 20),
          Text(
            'Initializing safety systems…',
            style: TextStyle(color: Colors.white, fontSize: 16),
          ),
        ],
      ),
    );
  }

  Widget _buildStageView() {
    switch (_stage) {
      case EscalationStage.monitoring:
      case EscalationStage.checkIn:
        return _buildMonitoringView();
      case EscalationStage.countdown:
        return _buildCountdownView();
      case EscalationStage.dispatching:
        return _buildDispatchingView();
      case EscalationStage.resolved:
        return _buildResolvedView();
      case EscalationStage.cancelled:
        return _buildCancelledView();
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Stage 1 – Monitoring
  // ══════════════════════════════════════════════════════════════════════════

  Widget _buildMonitoringView() {
    return SingleChildScrollView(
      key: const ValueKey('monitoring'),
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
      child: Column(
        children: [
          // ── Header ──────────────────────────────────────────────────────
          const Icon(Icons.shield_outlined, size: 50, color: Colors.white70),
          const SizedBox(height: 10),
          const Text(
            'PANIC MODE ACTIVE',
            style: TextStyle(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.bold,
              letterSpacing: 2,
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            'Monitoring your safety. Press SOS to alert contacts.',
            style: TextStyle(color: Colors.white70, fontSize: 13),
            textAlign: TextAlign.center,
          ),

          // ── Low battery warning ──────────────────────────────────────────
          if (_lowBatteryPanicWarning)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.orange.shade400),
                ),
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Row(
                  children: [
                    Icon(Icons.battery_alert,
                        color: Colors.orange.shade700, size: 16),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        'Battery low — trigger SOS before your phone dies.',
                        style: TextStyle(
                            color: Colors.orange.shade800,
                            fontSize: 12,
                            fontWeight: FontWeight.w600),
                      ),
                    ),
                  ],
                ),
              ),
            ),

          const SizedBox(height: 36),

          // ── Big SOS button ───────────────────────────────────────────────
          // RepaintBoundary isolates the constantly-animating SOS button so
          // that the pulse does not trigger a repaint on the surrounding UI.
          Semantics(
            label: 'SOS button — tap to send emergency alert to your contacts',
            button: true,
            hint: 'Immediately dispatches an emergency SMS',
            child: RepaintBoundary(
              child: ScaleTransition(
              scale: _pulseAnimation,
              child: Material(
                color: Colors.transparent,
                shape: const CircleBorder(),
                child: InkWell(
                onTap: _escalation.triggerManualSOS,
                customBorder: const CircleBorder(),
                focusColor: Colors.white.withValues(alpha: 0.2),
                child: Stack(
                alignment: Alignment.center,
                children: [
                  // Outer glow ring
                  Container(
                    width: 210,
                    height: 210,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.white.withValues(alpha: 0.15),
                    ),
                  ),
                  // Middle ring
                  Container(
                    width: 190,
                    height: 190,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.white.withValues(alpha: 0.2),
                    ),
                  ),
                  // Main button
                  Container(
                    width: 160,
                    height: 160,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: const RadialGradient(
                        colors: [Color(0xFFFF1744), Color(0xFFB71C1C)],
                        center: Alignment(-0.3, -0.3),
                      ),
                      border: Border.all(color: Colors.white, width: 3),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.red.withValues(alpha: 0.6),
                          blurRadius: 28,
                          spreadRadius: 6,
                        ),
                      ],
                    ),
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'SOS',
                          style: TextStyle(
                            fontSize: 46,
                            fontWeight: FontWeight.w900,
                            color: Colors.white,
                            letterSpacing: 6,
                            shadows: [
                              Shadow(
                                color: Colors.black38,
                                blurRadius: 6,
                                offset: Offset(1, 2),
                              ),
                            ],
                          ),
                        ),
                        SizedBox(height: 2),
                        Text(
                          'HOLD FOR HELP',
                          style: TextStyle(
                            fontSize: 9,
                            fontWeight: FontWeight.w600,
                            color: Colors.white70,
                            letterSpacing: 2,
                          ),
                        ),
                      ],
                    ),
                    ),  // FittedBox
                  ),
                ],
              ),
            ),  // InkWell
            ),  // Material
          ),
          ),
          ),

          const SizedBox(height: 12),
          const Text(
            'Tap to send emergency alert',
            style: TextStyle(color: Colors.white70, fontSize: 13),
          ),

          const SizedBox(height: 32),

          // ── Safe word card ────────────────────────────────────────────────
          _buildSafeWordCard(),

          const SizedBox(height: 16),

          // ── Movement bar ──────────────────────────────────────────────────
          _buildMovementBar(),

          const SizedBox(height: 32),

          // ── Cancel button ─────────────────────────────────────────────────
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _onUserCancelRequested,
              icon: const Icon(Icons.close),
              label: const Text(
                'Cancel Panic Mode',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.white,
                foregroundColor: Colors.red.shade700,
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
                elevation: 4,
              ),
            ),
          ),

        ],
      ),
    );
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Stage 3 – Countdown
  // ══════════════════════════════════════════════════════════════════════════

  Widget _buildCountdownView() {
    final seconds =
        _timerRemaining.clamp(0, PanicEscalationService.countdownDurationSeconds);
    final progress = seconds / PanicEscalationService.countdownDurationSeconds;
    final urgentColor = seconds <= 3 ? Colors.orange.shade200 : Colors.white;

    return Padding(
      key: const ValueKey('countdown'),
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.timer, size: 60, color: Colors.white),
          const SizedBox(height: 16),
          const Text(
            'EMERGENCY ALERT',
            style: TextStyle(
                fontSize: 26, fontWeight: FontWeight.bold, color: Colors.white),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 30),
          // Modern timer ring
          SizedBox(
            width: 160,
            height: 160,
            child: Stack(
              alignment: Alignment.center,
              children: [
                SizedBox.expand(
                  child: CircularProgressIndicator(
                    value: progress,
                    strokeWidth: 12,
                    backgroundColor: Colors.white24,
                    color: urgentColor,
                  ),
                ),
                Text(
                  '$seconds',
                  style: TextStyle(
                    fontSize: 60,
                    fontWeight: FontWeight.bold,
                    color: urgentColor,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 30),
          const Text(
            'Your emergency contacts will be notified unless you cancel.',
            style: TextStyle(color: Colors.white, fontSize: 16, height: 1.5),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 12),
          if (_lastTrigger != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.white24,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                'Triggered by: ${_lastTrigger!.label}',
                style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 13,
                    fontStyle: FontStyle.italic),
              ),
            ),
          const SizedBox(height: 28),
          SlideAction(
            key: _slideKey,
            onSubmit: () {
              _escalation.cancelAll();
              return null;
            },
            text: 'Slide to Cancel Alert',
            textStyle: const TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w700,
              color: Colors.deepOrange,
              letterSpacing: 0.5,
            ),
            outerColor: Colors.white,
            innerColor: Colors.deepOrange.shade600,
            sliderButtonIconPadding: 16,
            elevation: 4,
            borderRadius: 40,
            sliderRotate: true,
            animationDuration: const Duration(milliseconds: 300),
            submittedIcon: const Icon(Icons.check, color: Colors.white, size: 28),
            sliderButtonIcon: const Icon(Icons.chevron_right, color: Colors.white, size: 32),
          ),
          if (_isListening) ...[
            const SizedBox(height: 16),
            Text(
              'Say "${_safeWord.toUpperCase()}" to dispatch immediately',
              style: const TextStyle(
                  color: Colors.white60,
                  fontSize: 13,
                  fontStyle: FontStyle.italic),
              textAlign: TextAlign.center,
            ),
          ],
        ],
      ),
    );
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Stage 4 – Dispatching
  // ══════════════════════════════════════════════════════════════════════════

  Widget _buildDispatchingView() {
    return LayoutBuilder(
      key: const ValueKey('dispatching'),
      builder: (context, constraints) {
        return SingleChildScrollView(
          padding: const EdgeInsets.all(32),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  RepaintBoundary(
                    child: ScaleTransition(
                      scale: _pulseAnimation,
                      child: const Icon(
                        Icons.notification_important,
                        size: 100,
                        color: Colors.white,
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  const Text(
                    'SENDING EMERGENCY ALERT',
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Acquiring GPS and notifying your emergency contacts.',
                    style: TextStyle(
                      color: Colors.white70,
                      fontSize: 15,
                      height: 1.5,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  if (_dispatchProgress.isNotEmpty)
                    Text(
                      _dispatchProgress,
                      style: const TextStyle(
                        color: Colors.white60,
                        fontSize: 14,
                        fontStyle: FontStyle.italic,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  if (_dispatchLog.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.black26,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: _dispatchLog
                            .map(
                              (line) => Padding(
                                padding: const EdgeInsets.symmetric(vertical: 2),
                                child: Text(
                                  line,
                                  softWrap: true,
                                  style: TextStyle(
                                    color: line.startsWith('SENT')
                                        ? Colors.greenAccent
                                        : Colors.redAccent,
                                    fontSize: 13,
                                    fontFamily: 'monospace',
                                  ),
                                ),
                              ),
                            )
                            .toList(),
                      ),
                    ),
                  ],
                  const SizedBox(height: 32),
                  const CircularProgressIndicator(color: Colors.white),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Stage 5 – Resolved
  // ══════════════════════════════════════════════════════════════════════════

  Widget _buildResolvedView() {
    final meta = _alertMetadata;
    final path = meta == null
        ? '—'
        : meta.triggerHistory.map((t) => t.label).join(' > ');

    return SingleChildScrollView(
      key: const ValueKey('resolved'),
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          const Icon(Icons.check_circle_outline, size: 72, color: Colors.white),
          const SizedBox(height: 12),
          const Text(
            'ALERT DISPATCHED',
            style: TextStyle(
                fontSize: 26, fontWeight: FontWeight.bold, color: Colors.white,
                letterSpacing: 1.5),
          ),
          const SizedBox(height: 4),
          const Text(
            'Emergency SMS sent to your trusted contacts',
            style: TextStyle(color: Colors.white70, fontSize: 14),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),

          // Alert metadata card
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _metaRow(
                  Icons.access_time,
                  'Dispatched at',
                  meta?.timestamp.toLocal().toString().substring(0, 19) ?? '—',
                ),
                const Divider(color: Colors.white24, height: 20),
                // ─ GPS label update ───────────────────────────────────────
                _metaRow(
                  Icons.location_on,
                  'GPS Coordinates (sent in alert)',
                  meta?.hasLocation == true
                      ? meta!.locationString
                      : 'Location unavailable — GPS was not acquired',
                ),
                if (meta?.hasLocation ?? false) ...[
                  const SizedBox(height: 6),
                  InkWell(
                    onTap: () async {
                      final url = Uri.parse(meta!.googleMapsUrl!);
                      if (await canLaunchUrl(url)) launchUrl(url);
                    },
                    child: const Text(
                      'Open in Google Maps',
                      style: TextStyle(
                          color: Colors.white,
                          decoration: TextDecoration.underline,
                          fontSize: 13),
                    ),
                  ),
                ],
                if (!(meta?.hasLocation ?? false)) ...[
                  const SizedBox(height: 6),
                  const Text(
                    'The location SMS still sent — contacts were notified without GPS.',
                    style: TextStyle(color: Colors.white60, fontSize: 12, height: 1.4),
                  ),
                ],
                const Divider(color: Colors.white24, height: 20),
                _metaRow(Icons.route, 'Escalation path', path),
                if (meta?.anomalyScore != null) ...[
                  const Divider(color: Colors.white24, height: 20),
                  _metaRow(
                    Icons.sensors,
                    'Motion anomaly',
                    '${(meta!.anomalyScore! * 100).toStringAsFixed(0)}% confidence'
                        '${meta.anomalyConsecutiveWindows != null ? " (${meta.anomalyConsecutiveWindows} windows)" : ""}',
                  ),
                ],
                if (meta?.safeWordConfidence != null) ...[
                  const Divider(color: Colors.white24, height: 20),
                  _metaRow(
                    Icons.mic,
                    'Safe word match',
                    '${(meta!.safeWordConfidence! * 100).toStringAsFixed(0)}% confidence'
                        ' (${meta.safeWordMatchedViaApi == true ? "API" : "local"})',
                  ),
                ],
                // ─ Message content proof ─────────────────────────────────
                if (_sentLocationBody.isNotEmpty) ...[
                  const Divider(color: Colors.white24, height: 20),
                  _sectionLabel(Icons.sms_outlined, 'Message 1 of 7 — Full emergency alert'),
                  const SizedBox(height: 6),
                  _codeBox(_sentLocationBody),
                  const SizedBox(height: 10),
                  _sectionLabel(Icons.sms_outlined, 'Messages 2–7 — Repeated alert (sent 6 times, 2 s apart)'),
                  const SizedBox(height: 6),
                  _codeBox(_sentSpamBody),
                ],
                // ─ Per-message delivery log ───────────────────────────────
                if (_dispatchLog.isNotEmpty) ...[
                  const Divider(color: Colors.white24, height: 20),
                  _sectionLabel(Icons.receipt_long, 'Delivery log (one row per SMS)'),
                  const SizedBox(height: 8),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    decoration: BoxDecoration(
                      color: Colors.black26,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: _dispatchLog.map((line) {
                        final isSent = line.startsWith('SENT');
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 2),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Container(
                                width: 44,
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 4, vertical: 1),
                                decoration: BoxDecoration(
                                  color: isSent
                                      ? Colors.green.shade800
                                      : Colors.red.shade900,
                                  borderRadius: BorderRadius.circular(3),
                                ),
                                child: Text(
                                  isSent ? 'SENT' : 'FAIL',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 10,
                                    fontWeight: FontWeight.bold,
                                    letterSpacing: 0.5,
                                  ),
                                  textAlign: TextAlign.center,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  line.replaceFirst(
                                      RegExp(r'^(SENT|FAILED|ERROR)\s+'), ''),
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 12,
                                    fontFamily: 'monospace',
                                  ),
                                ),
                              ),
                            ],
                          ),
                        );
                      }).toList(),
                    ),
                  ),
                ],
                // ─ Contacts summary ───────────────────────────────────────
                if (_alertResults.isNotEmpty) ...[
                  const Divider(color: Colors.white24, height: 20),
                  _sectionLabel(Icons.people_outline, 'Contacts alerted'),
                  const SizedBox(height: 8),
                  ..._alertResults.map((r) {
                    final sent  = int.tryParse(r['sent']  ?? '0') ?? 0;
                    final total = int.tryParse(r['total'] ?? '0') ?? 0;
                    final ok      = sent == total && sent > 0;
                    final partial = sent > 0 && sent < total;
                    final phone   = r['phone'] ?? '';
                    return Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: ok
                            ? Colors.green.shade900.withValues(alpha: 0.6)
                            : partial
                                ? Colors.orange.shade900.withValues(alpha: 0.6)
                                : Colors.red.shade900.withValues(alpha: 0.6),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: ok
                              ? Colors.green.shade700
                              : partial
                                  ? Colors.orange.shade700
                                  : Colors.red.shade700,
                          width: 1,
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            ok
                                ? Icons.check_circle_outline
                                : partial
                                    ? Icons.warning_amber_outlined
                                    : Icons.cancel_outlined,
                            size: 20,
                            color: ok
                                ? Colors.greenAccent
                                : partial
                                    ? Colors.orangeAccent
                                    : Colors.redAccent,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  r['name'] ?? '',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  phone,
                                  style: const TextStyle(
                                    color: Colors.white70,
                                    fontSize: 12,
                                    fontFamily: 'monospace',
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Text(
                                '$sent / $total',
                                style: TextStyle(
                                  color: ok
                                      ? Colors.greenAccent
                                      : partial
                                          ? Colors.orangeAccent
                                          : Colors.redAccent,
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              const Text(
                                'messages sent',
                                style: TextStyle(
                                    color: Colors.white54, fontSize: 10),
                              ),
                            ],
                          ),
                        ],
                      ),
                    );
                  }),
                ],
              ],
            ),
          ),
          const SizedBox(height: 28),

          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: () =>
                  navigatorKey.currentState?.popUntil((route) => route.isFirst),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.white,
                foregroundColor: Colors.green.shade700,
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
              child: const Text(
                'Return to Home',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Stage 6 – Cancelled
  // ══════════════════════════════════════════════════════════════════════════

  Widget _buildCancelledView() {
    return Center(
      key: const ValueKey('cancelled'),
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.shield, size: 80, color: Colors.white),
            const SizedBox(height: 24),
            const Text(
              "YOU'RE SAFE",
              style: TextStyle(
                  fontSize: 30,
                  fontWeight: FontWeight.bold,
                  color: Colors.white),
            ),
            const SizedBox(height: 12),
            const Text(
              'Panic Mode has been cancelled.\nNo alert was sent.',
              style:
                  TextStyle(color: Colors.white70, fontSize: 16, height: 1.5),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 36),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: () =>
                    navigatorKey.currentState?.popUntil((route) => route.isFirst),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.white,
                  foregroundColor: Colors.grey.shade800,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
                child: const Text(
                  'Return to Home',
                  style:
                      TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Shared widget builders
  // ══════════════════════════════════════════════════════════════════════════

  Widget _buildSafeWordCard() {
    final srLabel = _safeWord.isEmpty
        ? 'Safe word not configured'
        : _isListening
            ? 'Microphone active — safe word listener running'
            : 'Microphone unavailable — movement monitoring active';
    return Semantics(
      label: srLabel,
      liveRegion: true,
      child: Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: _isListening
                ? Colors.green.withValues(alpha: 0.4)
                : Colors.black12,
            blurRadius: _isListening ? 14 : 4,
            spreadRadius: _isListening ? 2 : 0,
          ),
        ],
      ),
      child: Column(
        children: [
          Icon(Icons.mic,
              size: 48, color: _isListening ? Colors.red : Colors.grey),
          const SizedBox(height: 10),
          Text(
            _safeWord.isEmpty
                ? 'No safe word set – go to Settings to configure one'
                : _isListening
                    ? 'Say your safe word to trigger alert:'
                    : 'Microphone unavailable – movement monitoring active',
            style: TextStyle(
              fontSize: 14,
              color: _safeWord.isEmpty ? Colors.orange.shade800 : Colors.black87,
            ),
            textAlign: TextAlign.center,
          ),
          if (_safeWord.isNotEmpty) ...[  
            const SizedBox(height: 8),
            Text(
              '"$_safeWord"',
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.bold,
                color: _isListening ? Colors.red : Colors.grey,
              ),
            ),
          ],
          if (_recognizedWords.isNotEmpty) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.blue.shade50,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                children: [
                  const Text('👂 Heard:',
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: Colors.black54)),
                  const SizedBox(height: 4),
                  Text(
                    '"$_recognizedWords"',
                    style: TextStyle(
                        fontSize: 13,
                        color: Colors.blue.shade900,
                        fontWeight: FontWeight.w500),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    ),  // Semantics
    );
  }

  // ignore: unused_element
  Widget _buildManualSOSButton() {
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton.icon(
        onPressed: _escalation.triggerManualSOS,
        icon: const Icon(Icons.emergency),
        label: const Text(
          'MANUAL SOS',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
        ),
        style: ElevatedButton.styleFrom(
          backgroundColor: const Color(0xFFB07080),
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      ),
    );
  }

  Widget _buildMovementBar() {
    final mag = _linearMagnitude;
    // Thresholds calibrated for walking: ~1-3 m/s², running: 4-8+ m/s²
    final Color barColor;
    final String status;
    if (mag < 0.5) {
      barColor = Colors.green;
      status = 'Still';
    } else if (mag < 2.5) {
      barColor = Colors.lightGreen;
      status = 'Walking';
    } else if (mag < 5.0) {
      barColor = Colors.orange;
      status = 'Running';
    } else {
      barColor = Colors.red;
      status = 'High motion';
    }

    return Semantics(
      label: 'Movement sensor: $status — ${mag.toStringAsFixed(1)} metres per second squared',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.9),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Text(
              'Movement:',
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: LinearProgressIndicator(
                  value: (mag / 8.0).clamp(0.0, 1.0),
                  minHeight: 16,
                  backgroundColor: Colors.grey.shade300,
                  valueColor: AlwaysStoppedAnimation<Color>(barColor),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  status,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: barColor,
                  ),
                ),
                Text(
                  '${mag.toStringAsFixed(1)} m/s²',
                  style: const TextStyle(fontSize: 10, color: Colors.black45),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // ignore: unused_element
  Widget _buildCancelButton(String label) {
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton(
        onPressed: _onUserCancelRequested,
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.white,
          foregroundColor: Colors.red.shade700,
          padding: const EdgeInsets.symmetric(vertical: 16),
          elevation: 2,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12)),
        ),
        child: Text(
          label,
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
      ),
    );
  }

  /// Circular timer ring used in both the check-in and (smaller) countdown
  /// views.
  // ignore: unused_element
  Widget _buildTimerRing({
    required int remaining,
    required int total,
    required String label,
  }) {
    final progress = (remaining / total).clamp(0.0, 1.0);
    final urgent = remaining <= 5;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        SizedBox(
          width: 76,
          height: 76,
          child: Stack(
            alignment: Alignment.center,
            children: [
              SizedBox.expand(
                child: CircularProgressIndicator(
                  value: progress,
                  strokeWidth: 8,
                  backgroundColor: Colors.white24,
                  color: urgent ? Colors.orange.shade200 : Colors.white,
                ),
              ),
              Text(
                '$remaining',
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.bold,
                  color: urgent ? Colors.orange.shade100 : Colors.white,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Text(
            label,
            style: const TextStyle(color: Colors.white70, fontSize: 14),
          ),
        ),
      ],
    );
  }

  // ignore: unused_element
  Widget _buildGuidanceCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white30),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.shield, color: Colors.white, size: 18),
              SizedBox(width: 8),
              Text(
                'Safety Guidance',
                style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 15),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _bullet('Stay calm and breathe slowly'),
          _bullet('Move to a lit, populated area if possible'),
          _bullet('Your location is being monitored'),
          _bullet('Contacts will be notified automatically if needed'),
        ],
      ),
    );
  }

  Widget _bullet(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('• ', style: TextStyle(color: Colors.white70)),
            Expanded(
              child: Text(text,
                  style:
                      const TextStyle(color: Colors.white70, fontSize: 13)),
            ),
          ],
        ),
      );

  Widget _metaRow(IconData icon, String label, String value) => Padding(
        padding: const EdgeInsets.only(bottom: 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: Colors.white70, size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      style: const TextStyle(
                          color: Colors.white60, fontSize: 11)),
                  Text(value,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w600)),
                ],
              ),
            ),
          ],
        ),
      );

  /// Section heading with icon for the resolved view.
  Widget _sectionLabel(IconData icon, String label) => Row(
        children: [
          Icon(icon, size: 15, color: Colors.white60),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              label,
              style: const TextStyle(
                color: Colors.white60,
                fontSize: 11,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.4,
              ),
            ),
          ),
        ],
      );

  /// Monospace code-style box for SMS body content.
  Widget _codeBox(String text) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: Colors.black26,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          text,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 12,
            height: 1.6,
            fontFamily: 'monospace',
          ),
        ),
      );

  /// Returns a partially-masked phone number for the delivery log,
  /// e.g. "+447911123456" → "+44791112****".
  String _maskPhone(String phone) {
    if (phone.length <= 6) return phone;
    return '${phone.substring(0, phone.length - 4)}****';
  }
}
