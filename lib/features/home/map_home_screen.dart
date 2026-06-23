import 'dart:async';
import 'dart:io';
import 'dart:math' as math;


import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:battery_plus/battery_plus.dart';
import 'package:sensors_plus/sensors_plus.dart';

import '../../app_navigator.dart';
import '../../services/country_service.dart';
import '../../services/direct_sms_service.dart';
import '../../services/event_log_service.dart';
import '../../services/motion_baseline_service.dart';
import '../../services/panic_escalation_service.dart';
import '../../services/feedback_service.dart';
import '../../services/safety_guidance_service.dart';
import '../../services/quick_action_notification_service.dart';
import '../../services/risk_engine_service.dart';
import '../../services/silent_safe_word_service.dart';
import '../../models/alert_metadata.dart';
import '../../models/event_log.dart';
import '../../models/safety_guidance.dart';
import '../history/history_screen.dart';
import '../onboarding/screens/motion_baseline_calibration_screen.dart';
import '../panic_mode/panic_mode_screen.dart';
import 'change_safe_word_screen.dart';
import 'fake_call_screen.dart';
import 'guidance_assistant_screen.dart';
import 'helpline_contacts_screen.dart';
import 'incident_report_screen.dart';
import 'manage_trusted_contacts_screen.dart';
import '../../widgets/data_coverage_sheet.dart';
import 'debug_evaluation_screen.dart';
import 'safe_route_screen.dart';
import 'safety_profile_screen.dart';

import '../../services/secure_storage_service.dart';
import '../../services/arrival_notification_service.dart';
import '../../services/battery_alert_service.dart';
import '../../services/connectivity_service.dart';
import '../../services/safety_audio_alert_service.dart';

// ──────────────────────────────────────────────────────────────────────────────

class MapHomeScreen extends StatefulWidget {
  const MapHomeScreen({super.key});

  @override
  State<MapHomeScreen> createState() => _MapHomeScreenState();
}

class _MapHomeScreenState extends State<MapHomeScreen>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  // ── Services ────────────────────────────────────────────────────────────────
  final EventLogService _eventLogService = EventLogService();
  final MotionBaselineService _motionService = MotionBaselineService();
  final RiskEngineService _riskEngine = RiskEngineService();
  final PanicEscalationService _safetyEscalation = PanicEscalationService();
  final DirectSmsService _directSmsService = DirectSmsService();
  final BatteryAlertService _batteryAlertService = BatteryAlertService();

  // ── Map state ───────────────────────────────────────────────────────────────
  final MapController _mapController = MapController();
  LatLng _currentPosition = const LatLng(52.4092, -1.5055); // Coventry default
  bool _locationLoaded = false;
  /// True once the live GPS stream has centred the map. Separate from
  /// [_locationLoaded] so that a stale cached position doesn't prevent
  /// the real GPS fix from re-centring the camera.
  bool _centeredOnRealGPS = false;
  StreamSubscription<Position>? _positionSub;
  bool _tilesFailedToLoad = false;

  // ── Safety mode ─────────────────────────────────────────────────────────────
  bool _safetyModeActive = false;
  /// Contacts selected BEFORE safety mode starts to receive the arrival message.
  List<Map<String, dynamic>>? _safetyModeContacts;
  StreamSubscription<GyroscopeEvent>? _safetyGyroSub;
  /// Dedicated high-frequency GPS stream used ONLY while Safety Mode is active.
  /// Fully cancelled when Safety Mode ends — completely separate from [_positionSub].
  StreamSubscription<Position>? _safetyPositionSub;
  Position? _lastSafetyPosition;
  double? _lastSafetySpeedMps;
  DateTime? _lastRiskZoneAlertAt;
  String? _lastRiskZoneName;
  DateTime? _lastFastTurnAlertAt;
  DateTime? _lastRunningAlertAt;
  DateTime? _lastSuddenStopAlertAt;
  bool _safetyDialogVisible = false;
  bool _safetyDispatchInFlight = false;
  int _safetyCountdownRemaining = 0;
  String _safetySessionId = '';

  // ── Emergency alert repeat count ─────────────────────────────────────────
  // Matches the 5–6 alert requirement.  Change this one constant to adjust
  // how many SMS messages are sent per trusted contact on escalation.
  static const int _kEmergencyRepeatCount = 6;

  // Audio alert played when abnormal behaviour is detected (before dialog).
  final SafetyAudioAlertService _safetyAudioAlert = SafetyAudioAlertService();
  // Dedicated accelerometer stream for instantaneous fall/impact detection.
  StreamSubscription<AccelerometerEvent>? _safetyImpactSub;
  DateTime? _lastImpactAlertAt;
  // Sliding window of sharp-turn timestamps used by the gyroscope escalation
  // logic.  Turns older than 45 s are purged automatically on each new event.
  final List<DateTime> _sharpTurnTimestamps = [];
  // Number of consecutive GPS updates where speed ≥ 3.0 m/s (jogging pace).
  // Three in a row (≈ 9 s minimum) triggers rapid-movement escalation.
  int _consecutiveHighSpeedUpdates = 0;
  // Number of consecutive GPS updates where speed ≥ 2.0 m/s, used to confirm
  // real motion before a sudden-stop can be detected.  GPS can report spurious
  // high-speed readings on a stationary phone; requiring 2+ consecutive fixes
  // at that speed ensures the motion was real before flagging any stop.
  int _consecutiveSpeedAbove2MpsCount = 0;
  // True once 2+ consecutive GPS fixes above 2 m/s have been seen; reset when
  // the device clearly stops (< 0.5 m/s).  Prevents a single GPS speed glitch
  // from being mistaken for real walking motion.
  bool _confirmedMotionAbove2Mps = false;
  // Timestamp when Safety Mode was activated.  All sensor listeners ignore
  // events for the first 5 seconds after activation to avoid false positives
  // caused by the physical tap on the button or sensor initialisation spikes.
  DateTime? _safetyModeStartedAt;

  // ── Feature 3: Battery alert during Safety Mode ──────────────────────────────
  /// True when battery has dropped to or below 20 % while Safety Mode is active.
  /// Drives the in-app warning banner shown inside the Safety Mode panel.
  bool _lowBatterySafetyWarning = false;

  // ── Motion AI status ─────────────────────────────────────────────────────────
  bool _motionCalibrated = false;

  // ── Setup completeness (for "Complete Your Setup" banner) ────────────────────
  bool _hasSafeWord = false;
  bool _hasTrustedContacts = false;
  // ignore: unused_field
  bool _setupStatusLoaded = false;

  // ── Country & tips ──────────────────────────────────────────────────────────
  CountryInfo? _selectedCountry;
  List<SafetyGuidance> _tips = [];

  // ── Feature 2: Lock-Screen Quick Actions ─────────────────────────────────────
  bool _quickActionsEnabled = false;
  static const String _quickActionsKey = 'shesafe_quick_actions_enabled';
  final QuickActionNotificationService _quickActionSvc =
      QuickActionNotificationService();

  /// True while the app is in the background (user switched to another app).
  /// Used to decide whether to show an in-app dialog or post a notification.
  bool _isInBackground = false;

  // (info is now shown in a dialog inside the lock-screen shortcuts card)

  // ── Sheet controller ─────────────────────────────────────────────────────────
  final DraggableScrollableController _sheetController =
      DraggableScrollableController();

  // ── Connectivity (offline / online banner) ───────────────────────────────────
  bool _isOnline = true;
  StreamSubscription<bool>? _connectivitySub;
  /// Prevents repeated live fetches within the same app session.
  bool _liveDataFetchedThisSession = false;

  // ── Battery-aware location throttle ─────────────────────────────────────────
  /// When true, GPS accuracy is reduced to conserve battery at ≤ 20 %.
  bool _batteryThrottled = false;
  Timer? _batteryTimer;
  final Battery _battery = Battery();

  // ── Animation for Safety Mode button ────────────────────────────────────────
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;

  // ── Animation for AI badge ───────────────────────────────────────────────────
  late AnimationController _badgeController;
  late Animation<double> _badgeOpacity;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat(reverse: true);
    _pulseAnimation = Tween<double>(begin: 1.0, end: 1.03).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    _badgeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    )..forward();
    _badgeOpacity = CurvedAnimation(
      parent: _badgeController,
      curve: Curves.easeIn,
    );

    _loadCountry();
    _loadTips();
    _loadMotionStatus();
    _initRiskEngine();
    _loadSetupStatus();
    _loadQuickActionsState();
    _startLocationTracking();
    _initConnectivity();
    _initBatteryThrottle();
    WidgetsBinding.instance.addObserver(this);
    // Foreground path: notification tapped while app is already on screen.
    pendingNotificationAction.addListener(_onNotificationAction);
    // Update notification button label when safe-word listener toggles.
    SilentSafeWordService.instance.isActive.addListener(_onSafeWordListenerChanged);
    // Cold-launch / background path: read from SharedPreferences.
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkPendingNavigation());
  }

  @override
  void dispose() {
    pendingNotificationAction.removeListener(_onNotificationAction);
    SilentSafeWordService.instance.isActive.removeListener(_onSafeWordListenerChanged);
    WidgetsBinding.instance.removeObserver(this);
    _pulseController.dispose();
    _badgeController.dispose();
    _sheetController.dispose();
    _positionSub?.cancel();
    _safetyPositionSub?.cancel();
    _safetyGyroSub?.cancel();
    _safetyImpactSub?.cancel();
    _safetyEscalation.dispose();
    _safetyAudioAlert.dispose();
    _connectivitySub?.cancel();
    _batteryTimer?.cancel();
    // Safety net: if Safety Mode was still active when the widget was disposed
    // (e.g. app navigated away without toggling off), stop battery monitoring
    // so the singleton timer does not continue with stale closures.
    if (_safetyModeActive) {
      _batteryAlertService.stopMonitoring(BatteryAlertService.kSafetyModeSession);
    }
    _mapController.dispose();
    super.dispose();
  }

  /// Called whenever [SilentSafeWordService.isActive] flips.
  /// Re-posts the persistent notification with the updated button label and
  /// rebuilds the Lock-Screen Shortcuts card so the LIVE badge appears/hides.
  void _onSafeWordListenerChanged() {
    if (!mounted) return;
    setState(() {}); // rebuild in-app card
    if (_quickActionsEnabled) {
      _quickActionSvc.showSafetyNotification(
        safeWordActive: SilentSafeWordService.instance.isActive.value,
      );
    }
  }

  // ── Pending navigation (from lock-screen notification) ────────────────────────

  /// Called when the app returns to the foreground.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _isInBackground = state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden;
    if (state == AppLifecycleState.resumed) {
      // Delay lets the background isolate finish writing to SharedPreferences
      // before we read it — avoids the race condition where we read an empty
      // value because onBackgroundNotificationTap hasn't committed yet.
      Future.delayed(const Duration(milliseconds: 400), _checkPendingNavigation);
    }
  }

  /// Foreground path: called when [pendingNotificationAction] is set
  /// by the notification handler while the app is already on screen.
  void _onNotificationAction() {
    final payload = pendingNotificationAction.value;
    if (payload.isEmpty) return;
    pendingNotificationAction.value = ''; // consume
    _handleQuickAction(payload);
  }

  /// Background / cold-launch path: reads pending action from SharedPreferences.
  Future<void> _checkPendingNavigation() async {
    final prefs = await SharedPreferences.getInstance();
    final pending = prefs.getString(kPendingNavAction) ?? '';
    if (pending.isEmpty) return;
    await prefs.remove(kPendingNavAction);
    if (!mounted) return;
    _handleQuickAction(pending);
  }

  Future<List<Map<String, dynamic>>?> _requireTrustedContacts({
    required String modeLabel,
    bool notifyShortcut = false,
  }) async {
    final contacts = await SecureStorageService().getTrustedContacts();
    if (contacts.isNotEmpty) return contacts;

    if (notifyShortcut) {
      await _quickActionSvc.showAlertNotification(
        title: '⚠️ No trusted contacts',
        body: 'Add a trusted contact in SheSafe before using $modeLabel.',
      );
    }

    if (!mounted) return null;

    final openContacts = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('No Trusted Contacts'),
        content: Text(
          'You must add at least one trusted contact before activating '
          '$modeLabel.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            style: TextButton.styleFrom(
              minimumSize: const Size(0, 34),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              visualDensity: VisualDensity.compact,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: const Text('OK'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFB07080),
              foregroundColor: Colors.white,
              minimumSize: const Size(0, 34),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              visualDensity: VisualDensity.compact,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: const Text('Add Trusted Contact'),
          ),
        ],
      ),
    );

    if (openContacts == true && mounted) {
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => const ManageTrustedContactsScreen(),
        ),
      );
      if (mounted) {
        _loadSetupStatus();
      }
    }

    return null;
  }

  /// Shared handler invoked by both foreground and background notification paths.
  Future<void> _handleQuickAction(String payload) async {
    if (!mounted) return;
    if (payload == 'quick_safety_mode') {
      final contacts = await _requireTrustedContacts(
        modeLabel: 'Safety Mode',
        notifyShortcut: true,
      );
      if (contacts == null) return;
      if (!_safetyModeActive) {
        setState(() {
          _safetyModeActive = true;
          _safetyModeContacts = contacts;
        });
        await _startSafetyModeMonitoring();
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Safety Mode activated. Your movement and route are now being monitored.',
            ),
            duration: Duration(seconds: 3),
          ),
        );
      }
    } else if (payload == 'quick_panic') {
      // Start silent background Panic Mode — works while user is in any app.
      // SilentSafeWordService listens for the safe word and auto-dispatches.
      await _startBackgroundPanicMode();
    }
  }

  /// Activates Panic Mode silently without opening a screen.
  /// Starts the safe-word listener (microphone stays on in background) and
  /// posts a visible confirmation notification. When the safe word is spoken,
  /// [SilentSafeWordService] automatically dispatches SMS directly (no screen needed).
  Future<void> _startBackgroundPanicMode() async {
    final contacts = await _requireTrustedContacts(
      modeLabel: 'Panic Mode',
      notifyShortcut: true,
    );
    if (contacts == null) {
      return;
    }

    final storage = SecureStorageService();

    // Guard: no safe word configured
    final safeWord = await storage.getSafeWord();
    if (safeWord == null || safeWord.isEmpty) {
      await _quickActionSvc.showAlertNotification(
        title: '⚠️ No safe word set',
        body: 'Set a safe word in SheSafe to use background Panic Mode.',
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Set a safe word first — go to Settings.'),
            backgroundColor: Color(0xFFB07080),
            duration: Duration(seconds: 5),
          ),
        );
      }
      return;
    }

    // Start (or no-op if already running) the silent safe-word listener.
    await SilentSafeWordService.instance.start();

    // Post a heads-up notification visible even while app is behind Instagram etc.
    await _quickActionSvc.showAlertNotification(
      title: '🚨 Panic Mode Active',
      body: 'Listening for your safe word. Say it to alert contacts instantly.',
    );

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Panic Mode activated — say your safe word to alert contacts.',
          ),
          backgroundColor: Colors.red,
          duration: Duration(seconds: 4),
        ),
      );
    }
  }

  // ── Motion AI status ─────────────────────────────────────────────────────────

  Future<void> _loadMotionStatus() async {
    await _motionService.initialize();
    if (mounted) {
      setState(() => _motionCalibrated = _motionService.isCalibrated);
    }
  }

  Future<void> _initRiskEngine() async {
    await _riskEngine.initialize();
  }

  // ── Setup completeness check ─────────────────────────────────────────────────

  Future<void> _loadSetupStatus() async {
    final storage = SecureStorageService();
    final safeWord = await storage.getSafeWord();
    final contacts = await storage.getTrustedContacts();
    if (mounted) {
      setState(() {
        _hasSafeWord = safeWord != null && safeWord.isNotEmpty;
        _hasTrustedContacts = contacts.isNotEmpty;
        _setupStatusLoaded = true;
      });
    }
  }

  // ignore: unused_element
  bool get _setupComplete =>
      _hasSafeWord && _hasTrustedContacts && _motionCalibrated;

  // ── Feature 2: Quick Actions notification ─────────────────────────────────

  Future<void> _loadQuickActionsState() async {
    final prefs = await SharedPreferences.getInstance();
    final enabled = prefs.getBool(_quickActionsKey) ?? false;
    await _quickActionSvc.init();

    if (mounted) {
      setState(() => _quickActionsEnabled = enabled);
    }

    // Keep quick-action notification persistent across launches/resumes.
    // It should only be dismissed when the user turns the toggle OFF.
    if (enabled) {
      await _quickActionSvc.showSafetyNotification(
        safeWordActive: SilentSafeWordService.instance.isActive.value,
      );
    } else {
      await _quickActionSvc.dismissSafetyNotification();
    }
  }

  Future<void> _toggleQuickActions(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_quickActionsKey, value);
    setState(() => _quickActionsEnabled = value);
    await _quickActionSvc.init();
    if (value) {
      await _quickActionSvc.showSafetyNotification(
        safeWordActive: SilentSafeWordService.instance.isActive.value,
      );
    } else {
      await _quickActionSvc.dismissSafetyNotification();
    }
  }

  int get _missingSetupCount {
    int count = 0;
    if (!_hasSafeWord) count++;
    if (!_hasTrustedContacts) count++;
    if (!_motionCalibrated) count++;
    return count;
  }

  // ── Location ─────────────────────────────────────────────────────────────────

  Future<void> _startLocationTracking() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) return;

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) return;
    }
    if (permission == LocationPermission.deniedForever) return;

    // ── Step 1: instant display using the last cached position ────────────────
    try {
      final last = await Geolocator.getLastKnownPosition();
      if (last != null && mounted) {
        setState(() {
          _currentPosition = LatLng(last.latitude, last.longitude);
          _locationLoaded = true;
        });
        _mapController.move(_currentPosition, 15.5);
      }
    } catch (_) {}

    // ── Step 2: GPS stream for map display only ─────────────────────────────
    // This stream updates the visible user position on the map.
    // Safety Mode position processing is handled by a SEPARATE dedicated stream
    // (_safetyPositionSub) so that this stream is never aware of Safety Mode
    // state and does not run in high-frequency when Safety Mode is inactive.
    //
    // Battery throttled (≤ 20 %): medium accuracy, every 30 m / 15 s.
    // Normal:                      high accuracy,   every 10 m / 5 s.
    final accuracy =
        _batteryThrottled ? LocationAccuracy.medium : LocationAccuracy.high;
    final distanceFilter = _batteryThrottled ? 30 : 10;
    final intervalDuration = _batteryThrottled
        ? const Duration(seconds: 15)
        : const Duration(seconds: 5);

    debugPrint(
      '🗺️ [Location] Starting map display stream — '
      'batteryThrottled=$_batteryThrottled '
      'distanceFilter=${distanceFilter}m '
      'interval=${intervalDuration.inSeconds}s '
      '(Safety Mode tracking is a separate stream)',
    );

    final LocationSettings locationSettings = Platform.isAndroid
        ? AndroidSettings(
            accuracy: accuracy,
            distanceFilter: distanceFilter,
            intervalDuration: intervalDuration,
            forceLocationManager: false,
            // No foreground notification here — that is only shown by the
            // dedicated Safety Mode stream (_safetyPositionSub).
          )
        : LocationSettings(
            accuracy: accuracy,
            distanceFilter: distanceFilter,
          );

    _positionSub = Geolocator.getPositionStream(
      locationSettings: locationSettings,
    ).listen((pos) {
      if (mounted) {
        final newPos = LatLng(pos.latitude, pos.longitude);
        final needsCenter = !_centeredOnRealGPS;
        setState(() {
          _currentPosition = newPos;
          _locationLoaded = true;
          _centeredOnRealGPS = true;
        });
        // NOTE: Safety Mode position processing (_handleSafetyModePositionUpdate)
        // is NOT called here — it is handled exclusively by _safetyPositionSub.
        if (needsCenter) {
          _mapController.move(newPos, 15.5);
        }
        // ── Trigger live risk-zone fetch on first real GPS fix (if online) ──
        // This is the only automatic live-data fetch in normal usage.
        // On success, the result is saved to local cache so the next offline
        // launch reads cached live zones instead of the bundled CSV.
        if (!_liveDataFetchedThisSession && _isOnline) {
          _liveDataFetchedThisSession = true;
          debugPrint(
            '🌐 [RiskEngine] First GPS fix received — '
            'triggering live risk zone fetch to populate local cache',
          );
          _riskEngine.initializeWithLiveData(
            pos.latitude, pos.longitude,
          ).then((_) {
            if (mounted) setState(() {}); // refresh map overlays if zones changed
          });
        }
      }
    });
  }

  /// Start a **dedicated** Safety Mode GPS stream.
  ///
  /// This stream is completely separate from the map-display stream
  /// ([_positionSub]).  It uses high accuracy and a short update interval
  /// so safety monitoring is responsive, and it posts the foreground
  /// wake-lock notification.  It is the ONLY place that calls
  /// [_handleSafetyModePositionUpdate].
  ///
  /// When Safety Mode ends, [_safetyPositionSub] is cancelled entirely.
  /// The map-display stream is unaffected.
  Future<void> _startSafetyLocationTracking() async {
    await _safetyPositionSub?.cancel();
    _safetyPositionSub = null;

    debugPrint(
      '🟢 [Location] Starting Safety Mode dedicated stream — '
      'distanceFilter=5m interval=3s (separate from map display stream)',
    );

    final LocationSettings safetySettings = Platform.isAndroid
        ? AndroidSettings(
            accuracy: LocationAccuracy.high,
            distanceFilter: 5,
            intervalDuration: const Duration(seconds: 3),
            forceLocationManager: false,
            foregroundNotificationConfig: const ForegroundNotificationConfig(
              notificationTitle: 'SheSafe Safety Mode',
              notificationText:
                  'Monitoring movement, location, and nearby risk zones.',
              enableWakeLock: true,
            ),
          )
        : const LocationSettings(
            accuracy: LocationAccuracy.high,
            distanceFilter: 5,
          );

    _safetyPositionSub = Geolocator.getPositionStream(
      locationSettings: safetySettings,
    ).listen((pos) {
      if (!mounted || !_safetyModeActive) return;
      // Also update shared position so the map reflects the more accurate fix.
      setState(() {
        _currentPosition = LatLng(pos.latitude, pos.longitude);
        _locationLoaded = true;
      });
      _handleSafetyModePositionUpdate(pos);
    });
  }

  // ── Data loading ─────────────────────────────────────────────────────────────

  // ── Connectivity detection ──────────────────────────────────────────────────

  Future<void> _initConnectivity() async {
    final svc = ConnectivityService();
    // ConnectivityService.init() is already called in main() — just seed state.
    _isOnline = svc.isOnline;
    debugPrint('📡 [Connectivity] Initial state: online=$_isOnline');
    if (mounted) setState(() {});
    _connectivitySub = svc.statusStream.listen((online) {
      if (!mounted) return;
      final wasOnline = _isOnline;
      setState(() => _isOnline = online);
      if (!online) {
        debugPrint(
          '🔴 [Connectivity] Went offline — '
          'showing cached risk zone data (${_riskEngine.allRiskZones.length} zones loaded)',
        );
      } else if (!wasOnline && online) {
        debugPrint('🟢 [Connectivity] Back online — refreshing live risk zone data');
        _refreshLiveDataOnReconnect();
      }
    });
  }

  /// Automatically called when internet is restored after an offline period.
  /// Silently re-fetches live risk zones so the map uses the latest data.
  Future<void> _refreshLiveDataOnReconnect() async {
    if (!mounted) return;
    try {
      await _riskEngine.initializeWithLiveData(
        _currentPosition.latitude,
        _currentPosition.longitude,
      );
      debugPrint('✅ [Connectivity] Live risk data refreshed after reconnect');
      if (mounted) setState(() {}); // rebuild to reflect any zone updates
    } catch (e) {
      debugPrint('⚠️ [Connectivity] Could not refresh live data after reconnect: $e');
    }
  }

  // ── Battery-aware throttle ──────────────────────────────────────────────────

  Future<void> _initBatteryThrottle() async {
    await _checkBatteryLevel();
    // Recheck every 2 minutes while the screen is alive.
    _batteryTimer = Timer.periodic(const Duration(minutes: 2), (_) {
      _checkBatteryLevel();
    });
  }

  Future<void> _checkBatteryLevel() async {
    try {
      final level = await _battery.batteryLevel;
      final shouldThrottle = level <= 20;
      if (shouldThrottle == _batteryThrottled) return; // no change
      if (mounted) setState(() => _batteryThrottled = shouldThrottle);
      // Restart GPS stream with new accuracy settings.
      _positionSub?.cancel();
      _positionSub = null;
      _startLocationTracking();
    } catch (_) {}
  }

  // ── Feedback — in-app form ──────────────────────────────────────────────────

  void _openFeedbackSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const _FeedbackSheet(screenName: 'map_home_screen'),
    );
  }

  Future<void> _loadTips() async {
    final svc = SafetyGuidanceService();
    await svc.initialize();
    final all = svc.allEntries;
    if (all.isNotEmpty && mounted) {
      final shuffled = List.of(all)..shuffle();
      setState(() => _tips = shuffled.take(3).toList());
    }
  }

  Future<void> _loadCountry() async {
    // UK-only design: auto-set UK, no picker needed
    final country = await CountryService().getSelectedCountry();
    if (mounted) setState(() => _selectedCountry = country);
  }

  void _showDataCoverageSheet(BuildContext ctx) {
    showDataCoverageSheet(ctx);
  }

  // ── Safety mode ───────────────────────────────────────────────────────────

  void _configureSafetyModeEscalation() {
    _safetyEscalation.onCountdownTick = (remaining) {
      if (!mounted) return;
      setState(() => _safetyCountdownRemaining = remaining);
    };
    _safetyEscalation.onStageChanged = (stage, trigger) {
      if (!mounted || !_safetyModeActive) return;

      // When the user is in another app, deliver alerts as notifications
      // so they are visible without the user needing to open SheSafe.
      if (_isInBackground) {
        switch (stage) {
          case EscalationStage.checkIn:
            _quickActionSvc.showAlertNotification(
              title: 'SheSafe Safety Check',
              body: 'Are you okay? Open SheSafe to confirm.',
            );
          case EscalationStage.countdown:
            _quickActionSvc.showAlertNotification(
              title: '⚠️ SheSafe — Sending help soon',
              body: 'No response detected. Open SheSafe to cancel.',
            );
          case EscalationStage.dispatching:
            _quickActionSvc.showAlertNotification(
              title: '🚨 SheSafe — Emergency alert sent',
              body: 'Your trusted contacts have been notified.',
            );
            _dispatchSafetyModeEmergencyAlert(trigger);
          case EscalationStage.cancelled:
            break;
          default:
            break;
        }
        return;
      }

      switch (stage) {
        case EscalationStage.checkIn:
          _showSafetyCheckInDialog(trigger);
          break;
        case EscalationStage.countdown:
          _showSafetyCountdownDialog(trigger);
          break;
        case EscalationStage.dispatching:
          _dispatchSafetyModeEmergencyAlert(trigger);
          break;
        case EscalationStage.cancelled:
          _dismissSafetyDialogIfVisible();
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: const Text('Safety check cancelled. Monitoring continues.'),
              backgroundColor: const Color(0xFFB07080),
            ),
          );
          break;
        default:
          break;
      }
    };
  }

  Future<void> _startSafetyModeMonitoring() async {
    _configureSafetyModeEscalation();
    _safetySessionId =
        'safety_${DateTime.now().millisecondsSinceEpoch}_${math.Random().nextInt(9999)}';
    debugPrint('🟢 [Safety] Mode starting — session: $_safetySessionId');
    await _safetyEscalation.initialize(sessionId: _safetySessionId);
    await _motionService.initialize();
    if (!_riskEngine.isInitialized) {
      await _riskEngine.initialize();
    }

    _motionService.onAnomalyDetected = (result) {
      _logSafetyConcern(
        description: result.description,
        outcome: EventOutcome.warning,
        type: EventType.motionAnomalyDetected,
        metadata: {
          'score': result.score,
          'sessionId': _safetySessionId,
          'consecutiveWindows': _motionService.consecutiveAnomalyWindows,
        },
      );
    };
    _motionService.onMotionConcernTriggered = (triggered) {
      if (!triggered || !_safetyModeActive) return;
      // Ignore callbacks during the startup warm-up window.
      if (_safetyModeStartedAt != null &&
          DateTime.now().difference(_safetyModeStartedAt!) <
              const Duration(seconds: 5)) {
        return;
      }
      _eventLogService.logEvent(
        type: EventType.motionConcernTriggered,
        outcome: EventOutcome.warning,
        description: 'Safety Mode flagged sustained unusual movement.',
        metadata: {
          'sessionId': _safetySessionId,
          'consecutiveWindows': _motionService.consecutiveAnomalyWindows,
        },
      );
      _safetyEscalation.triggerMotionAnomaly(
        score: 0.9,
        description:
            'Sustained unusual movement detected (${_motionService.consecutiveAnomalyWindows} windows).',
        consecutiveWindows: _motionService.consecutiveAnomalyWindows,
      );
    };
    _safetyModeStartedAt = DateTime.now();
    _motionService.startMonitoring();

    await _startGyroscopeMonitoring();
    await _startImpactDetection();
    // Start the dedicated Safety Mode GPS stream (separate from map display).
    await _startSafetyLocationTracking();
    await SilentSafeWordService.instance.start();

    // ── Feature 3: Battery alert — active for the whole Safety Mode session ──
    final userName = await SecureStorageService().getUserNameAsync();
    _batteryAlertService.startMonitoring(
      sessionId: BatteryAlertService.kSafetyModeSession,
      userName: userName,
      getLastPosition: () {
        if (_lastSafetyPosition == null) return null;
        return (
          lat: _lastSafetyPosition!.latitude,
          lon: _lastSafetyPosition!.longitude,
        );
      },
      // Tier 1 (≤ 20 %): show in-app warning banner
      onLowBattery: (level) {
        if (!mounted) return;
        setState(() => _lowBatterySafetyWarning = true);
      },
      // Tier 2 (≤ 10 %): prompt user to select contacts for critical SMS
      onCriticalAlert: (level, lat, lon) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
              '🔴 Battery critical ($level%) — SMS sent to all contacts automatically.'),
          backgroundColor: Colors.red.shade700,
          duration: const Duration(seconds: 6),
        ));
      },
    );
  }

  Future<void> _stopSafetyModeMonitoring() async {
    debugPrint(
      '🔴 [Safety] Mode stopping — '
      'cancelling Safety Mode location, gyroscope, motion and safe-word',
    );
    _dismissSafetyDialogIfVisible();
    _motionService.onAnomalyDetected = null;
    _motionService.onMotionConcernTriggered = null;
    await _motionService.stopMonitoring();
    await _safetyGyroSub?.cancel();
    _safetyGyroSub = null;
    await _safetyImpactSub?.cancel();
    _safetyImpactSub = null;
    // Cancel the dedicated Safety Mode GPS stream fully.
    await _safetyPositionSub?.cancel();
    _safetyPositionSub = null;
    debugPrint(
      '🔴 [Location] Safety Mode stream fully cancelled — '
      'map display stream (_positionSub) continues independently at normal frequency',
    );
    SilentSafeWordService.instance.stop();
    _safetyDispatchInFlight = false;
    _safetyCountdownRemaining = 0;
    _lastSafetyPosition = null;
    _lastSafetySpeedMps = null;
    _lastRiskZoneAlertAt = null;
    _lastRiskZoneName = null;
    _lastFastTurnAlertAt = null;
    _lastRunningAlertAt = null;
    _lastSuddenStopAlertAt = null;
    _lastImpactAlertAt = null;
    _sharpTurnTimestamps.clear();
    _consecutiveHighSpeedUpdates = 0;
    _consecutiveSpeedAbove2MpsCount = 0;
    _confirmedMotionAbove2Mps = false;
    _safetyModeStartedAt = null;
    // Stop any playing warning audio.
    await _safetyAudioAlert.stop();
    _safetyEscalation.dispose();
    // ── Feature 3: stop battery alert monitoring for this session ──────────
    _batteryAlertService.stopMonitoring(BatteryAlertService.kSafetyModeSession);
    _lowBatterySafetyWarning = false;
    // NOTE: _positionSub (map display) is NOT touched here — it was never part
    // of Safety Mode and continues running at its normal low frequency.
    debugPrint(
      '🗺️ [Location] Map display stream unaffected — '
      'Safety Mode tracking was always a separate subscription',
    );
  }

  Future<void> _startGyroscopeMonitoring() async {
    await _safetyGyroSub?.cancel();
    _safetyGyroSub = gyroscopeEventStream(
      samplingPeriod: const Duration(milliseconds: 200),
    ).listen((event) {
      if (!_safetyModeActive) return;
      // Skip all readings during the 5-second startup warm-up period.
      if (_safetyModeStartedAt != null &&
          DateTime.now().difference(_safetyModeStartedAt!) <
              const Duration(seconds: 5)) {
        return;
      }
      final turnRate = math.sqrt(
        event.x * event.x + event.y * event.y + event.z * event.z,
      );
      if (turnRate < 5.0) return;

      final now = DateTime.now();

      // Track this qualifying sharp turn in a 45-second sliding window.
      // Turns older than 45 s are pruned so the window stays tight.
      _sharpTurnTimestamps.add(now);
      _sharpTurnTimestamps.removeWhere(
        (t) => now.difference(t) > const Duration(seconds: 45),
      );

      // Rate-limit the per-turn Snackbar to once per 12 s so the UI stays
      // calm, but still accumulate turns for the escalation counter.
      if (_lastFastTurnAlertAt == null ||
          now.difference(_lastFastTurnAlertAt!) >= const Duration(seconds: 12)) {
        _lastFastTurnAlertAt = now;
        _logSafetyConcern(
          description:
              'Sharp turn detected. Stay alert and keep your phone accessible.',
          outcome: EventOutcome.warning,
          type: EventType.motionAnomalyDetected,
          metadata: {
            'sessionId': _safetySessionId,
            'turnRate': turnRate,
            'turnsInWindow': _sharpTurnTimestamps.length,
            'source': 'gyroscope',
          },
        );
      }

      // Escalate if 3 or more sharp turns are recorded within 45 seconds.
      // A single turn is normal (corners, bag adjustments); 3+ in rapid
      // succession is associated with erratic movement, pursuit, or panic.
      if (_sharpTurnTimestamps.length >= 3) {
        final turnCount = _sharpTurnTimestamps.length;
        _sharpTurnTimestamps.clear(); // reset window so next cluster can fire
        debugPrint(
          '🌀 [Safety] $turnCount sharp turns in 45 s — triggering escalation',
        );
        _safetyEscalation.triggerMotionAnomaly(
          score: 0.75,
          description:
              '$turnCount sharp turns detected in rapid succession — '
              'possible erratic movement or distress.',
          consecutiveWindows: 2,
        );
      }
    });
  }

  /// Monitors accelerometer for instantaneous high-magnitude spikes that
  /// indicate a fall or collision — completely separate from the baseline
  /// service's window-based anomaly detection.
  ///
  /// Threshold: 25 m/s² total acceleration.  Normal walking peaks at 8–20 m/s²;
  /// falls and hard collisions typically produce 25–80+ m/s².
  Future<void> _startImpactDetection() async {
    await _safetyImpactSub?.cancel();
    // 35 m/s² is reliably above normal phone handling (walking peaks at
    // 10–20 m/s² including gravity) while still catching real falls and
    // collisions (typically 30–80+ m/s² with the raw accelerometer).
    const double impactThreshold = 35.0;
    _safetyImpactSub = accelerometerEventStream(
      samplingPeriod: const Duration(milliseconds: 50),
    ).listen((event) {
      if (!_safetyModeActive) return;
      // Skip all readings during the 5-second startup warm-up period.
      if (_safetyModeStartedAt != null &&
          DateTime.now().difference(_safetyModeStartedAt!) <
              const Duration(seconds: 5)) {
        return;
      }
      final mag = math.sqrt(
          event.x * event.x + event.y * event.y + event.z * event.z);
      if (mag < impactThreshold) return;

      final now = DateTime.now();
      // Rate-limit: at most one alert per 20 seconds to avoid rapid re-triggers.
      if (_lastImpactAlertAt != null &&
          now.difference(_lastImpactAlertAt!) <
              const Duration(seconds: 20)) {
        return;
      }
      _lastImpactAlertAt = now;

      debugPrint(
          '💥 [Safety] Impact spike: mag=${mag.toStringAsFixed(1)} m/s²');
      _logSafetyConcern(
        description:
            'Strong impact detected. SheSafe is checking if you are okay.',
        outcome: EventOutcome.warning,
        type: EventType.motionConcernTriggered,
        metadata: {
          'sessionId': _safetySessionId,
          'impactMagnitude': mag,
          'source': 'accelerometer_impact',
        },
      );
      // Treat high-confidence impact as two consecutive anomaly windows so
      // PanicEscalationService transitions straight to check-in.
      _safetyEscalation.triggerMotionAnomaly(
        score: 0.95,
        description:
            'Strong impact detected (${mag.toStringAsFixed(1)} m/s²) — '
            'possible fall or collision.',
        consecutiveWindows: 2,
      );
    });
  }

  void _handleSafetyModePositionUpdate(Position position) {
    _lastSafetyPosition = position;

    // Ignore fixes with poor horizontal accuracy — GPS drift on a stationary
    // phone can produce spurious position jumps and speed readings that look
    // like real movement.  25 m is a generous but reliable cut-off; typical
    // urban GPS is 3–8 m, and anything > 25 m is too imprecise to act on.
    if (position.accuracy > 25.0) {
      debugPrint(
        '🛰️ [Safety GPS] Discarding fix — accuracy=${position.accuracy.toStringAsFixed(0)} m > 25 m',
      );
      _checkNearbyRiskZones(position);
      return;
    }

    final speedMps = position.speed >= 0 ? position.speed : 0.0;

    // Track consecutive fixes at or above 2 m/s so we can distinguish real
    // walking speed from a one-off GPS speed glitch.
    // _confirmedMotionAbove2Mps becomes true only after 2+ consecutive fixes.
    if (speedMps >= 2.0) {
      _consecutiveSpeedAbove2MpsCount++;
      if (_consecutiveSpeedAbove2MpsCount >= 2) {
        _confirmedMotionAbove2Mps = true;
      }
    } else {
      _consecutiveSpeedAbove2MpsCount = 0;
      if (speedMps < 0.5) {
        // Clearly stopped — reset the confirmed-motion flag so the next
        // bout of movement must be confirmed from scratch.
        _confirmedMotionAbove2Mps = false;
      }
    }

    if (_lastSafetySpeedMps != null) {
      final previousSpeed = _lastSafetySpeedMps!;
      final now = DateTime.now();

      // Sudden stop: only fire when confirmed real motion (2+ consecutive fixes
      // at ≥ 2 m/s) has just dropped to near-zero.  Single GPS speed spikes on
      // a stationary phone will never set _confirmedMotionAbove2Mps, so they
      // cannot falsely trigger a sudden-stop alert.
      if (_confirmedMotionAbove2Mps && previousSpeed >= 2.0 && speedMps <= 0.35) {
        _confirmedMotionAbove2Mps = false; // require re-confirmation next time
        if (_lastSuddenStopAlertAt == null ||
            now.difference(_lastSuddenStopAlertAt!) >
                const Duration(seconds: 20)) {
          _lastSuddenStopAlertAt = now;
          _logSafetyConcern(
            description:
                'Sudden stop detected. SheSafe is checking whether you are okay.',
            outcome: EventOutcome.warning,
            type: EventType.motionConcernTriggered,
            metadata: {
              'sessionId': _safetySessionId,
              'previousSpeed': previousSpeed,
              'currentSpeed': speedMps,
              'source': 'gps',
            },
          );
          _safetyEscalation.triggerMotionAnomaly(
            score: 0.8,
            description: 'Sudden stop detected from GPS speed change.',
            consecutiveWindows: 1,
          );
        }
      } else if (speedMps >= 3.0) {
        // Sustained jogging/running speed (≥ 3.0 m/s ≈ 10.8 km/h).
        // Track consecutive GPS updates at this speed to confirm it is real
        // sustained movement, not a momentary GPS spike.
        _consecutiveHighSpeedUpdates++;

        // Warn on first detection per occurrence so the user is aware.
        if (_consecutiveHighSpeedUpdates == 1 &&
            (_lastRunningAlertAt == null ||
                now.difference(_lastRunningAlertAt!) >
                    const Duration(seconds: 30))) {
          _lastRunningAlertAt = now;
          _logSafetyConcern(
            description:
                'Rapid movement detected. SheSafe is watching for further risk.',
            outcome: EventOutcome.warning,
            type: EventType.motionAnomalyDetected,
            metadata: {
              'sessionId': _safetySessionId,
              'speedMps': speedMps,
              'source': 'gps_rapid',
            },
          );
        }

        // Three consecutive high-speed fixes (≥ 9 s of sustained running)
        // confirms abnormal movement — trigger escalation.
        if (_consecutiveHighSpeedUpdates >= 3) {
          final hsCnt = _consecutiveHighSpeedUpdates;
          _consecutiveHighSpeedUpdates = 0; // reset so next cluster can trigger
          debugPrint(
            '🏃 [Safety] Sustained rapid movement: $hsCnt consecutive GPS '
            'updates at ${speedMps.toStringAsFixed(1)} m/s — escalating',
          );
          _safetyEscalation.triggerMotionAnomaly(
            score: 0.80,
            description:
                'Sustained rapid movement detected '
                '(${speedMps.toStringAsFixed(1)} m/s over '
                '$hsCnt consecutive GPS fixes).',
            consecutiveWindows: 2,
          );
        }
      } else {
        // Speed below running threshold — reset the consecutive counter.
        _consecutiveHighSpeedUpdates = 0;
      }
    }

    _lastSafetySpeedMps = speedMps;
    _checkNearbyRiskZones(position);
  }

  void _checkNearbyRiskZones(Position position) {
    if (!_riskEngine.isInitialized) return;

    final zones = _riskEngine.allRiskZones.where((zone) {
      final distance = zone.distanceFromPoint(position.latitude, position.longitude);
      return zone.containsPoint(position.latitude, position.longitude) ||
          distance <= math.max(zone.radiusMeters + 60, 150);
    }).toList()
      ..sort((a, b) => b.riskScore.compareTo(a.riskScore));

    if (zones.isEmpty) return;

    final primaryZone = zones.first;
    final now = DateTime.now();
    final isDuplicateZone = _lastRiskZoneName == primaryZone.zoneName &&
        _lastRiskZoneAlertAt != null &&
        now.difference(_lastRiskZoneAlertAt!) < const Duration(minutes: 2);
    if (isDuplicateZone) return;

    _lastRiskZoneName = primaryZone.zoneName;
    _lastRiskZoneAlertAt = now;
    _logSafetyConcern(
      description:
          'Nearby ${primaryZone.riskLevel.displayName.toLowerCase()} area: ${primaryZone.zoneName}. Stay alert and keep safety support ready.',
      outcome: EventOutcome.warning,
      type: EventType.riskZoneDetected,
      metadata: {
        'sessionId': _safetySessionId,
        'zone': primaryZone.zoneName,
        'riskLevel': primaryZone.riskLevel.name,
        'riskScore': primaryZone.riskScore,
      },
    );
  }

  void _logSafetyConcern({
    required String description,
    required EventOutcome outcome,
    required EventType type,
    Map<String, dynamic>? metadata,
  }) {
    if (!mounted || !_safetyModeActive) return;

    _eventLogService.logEvent(
      type: type,
      outcome: outcome,
      description: description,
      metadata: metadata,
    );

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(description),
        backgroundColor: outcome == EventOutcome.info
            ? Colors.blueGrey.shade700
            : Colors.orange.shade700,
        duration: const Duration(seconds: 4),
      ),
    );
  }

  void _dismissSafetyDialogIfVisible() {
    if (!_safetyDialogVisible || !mounted) return;
    Navigator.of(context, rootNavigator: true).maybePop();
    _safetyDialogVisible = false;
  }

  Future<void> _showSafetyCheckInDialog(EscalationTrigger trigger) async {
    _dismissSafetyDialogIfVisible();
    _safetyDialogVisible = true;
    // Play loud audio warning — ringtone + TTS voice — so the alert is heard
    // even if the screen is dim or the user's attention is elsewhere.
    // Not awaited: audio runs concurrently while the dialog is displayed.
    _safetyAudioAlert.playWarning(
      message: 'Warning! SheSafe has detected unusual movement. '
          'Tap I\'m okay if you are safe, or tap Send Help to alert '
          'your emergency contacts now.',
    );
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Safety Check'),
        content: Text(
          'SheSafe noticed unusual activity (${trigger.label.toLowerCase()}). Are you okay?',
        ),
        actions: [
          TextButton(
            onPressed: () {
              // Stop the alarm the moment the user confirms they are safe.
              _safetyAudioAlert.stop();
              Navigator.pop(ctx);
              _safetyEscalation.respondOkay();
            },
            child: const Text('I\'m okay'),
          ),
          ElevatedButton(
            onPressed: () {
              // Stop alarm — emergency dispatch will handle everything next.
              _safetyAudioAlert.stop();
              Navigator.pop(ctx);
              _safetyEscalation.respondHelp();
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red.shade700,
              foregroundColor: Colors.white,
            ),
            child: const Text('Send Help'),
          ),
        ],
      ),
    );
    _safetyDialogVisible = false;
  }

  Future<void> _showSafetyCountdownDialog(EscalationTrigger trigger) async {
    _dismissSafetyDialogIfVisible();
    _safetyDialogVisible = true;
    // Escalate audio with a more urgent TTS message — no response was given
    // during the check-in window, so time is running out.
    _safetyAudioAlert.playWarning(
      message: 'Emergency alert! No response received. '
          'Your emergency contacts will be alerted in seconds. '
          'Tap I\'m okay right now if you are safe to cancel.',
    );
    // Patch the countdown tick so that the dialog button text also rebuilds
    // every second.  We chain on top of the existing handler (which updates
    // the parent widget's _safetyCountdownRemaining via setState).
    final previousTick = _safetyEscalation.onCountdownTick;
    void Function(VoidCallback)? dialogSetState;
    _safetyEscalation.onCountdownTick = (remaining) {
      previousTick?.call(remaining);
      dialogSetState?.call(() {});
    };

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          dialogSetState = setDialogState;
          return AlertDialog(
            title: const Text('Preparing Safety Support'),
            content: Text(
              'No response detected after ${trigger.label.toLowerCase()}. Emergency support will be prepared and your trusted contacts will be alerted if you do not respond.',
            ),
            actions: [
              TextButton(
                onPressed: () {
                  _safetyAudioAlert.stop();
                  Navigator.pop(ctx);
                  _safetyEscalation.respondOkay();
                },
                child: const Text('I\'m okay'),
              ),
              ElevatedButton(
                onPressed: () {
                  _safetyAudioAlert.stop();
                  Navigator.pop(ctx);
                  _safetyEscalation.triggerManualSOS();
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.red.shade700,
                  foregroundColor: Colors.white,
                ),
                child: Text(
                  _safetyCountdownRemaining > 0
                      ? 'Send Now (${_safetyCountdownRemaining}s)'
                      : 'Send Now',
                ),
              ),
            ],
          );
        },
      ),
    );

    // Restore the tick handler and clean up.
    _safetyEscalation.onCountdownTick = previousTick;
    dialogSetState = null;
    _safetyDialogVisible = false;
  }

  Future<void> _dispatchSafetyModeEmergencyAlert(
    EscalationTrigger trigger,
  ) async {
    if (_safetyDispatchInFlight) return;
    _safetyDispatchInFlight = true;
    _dismissSafetyDialogIfVisible();
    // Stop any warning audio now that emergency SMS is being dispatched.
    await _safetyAudioAlert.stop();

    try {
      final storage = SecureStorageService();
      final contacts = await storage.getTrustedContacts();
      final userName = (await storage.getUserNameAsync()).trim();

      double? lat = _lastSafetyPosition?.latitude;
      double? lon = _lastSafetyPosition?.longitude;
      if (lat == null || lon == null) {
        try {
          final current = await Geolocator.getCurrentPosition(
            desiredAccuracy: LocationAccuracy.high,
          );
          lat = current.latitude;
          lon = current.longitude;
        } catch (_) {}
      }

      final metadata = _safetyEscalation.buildAlertMetadata(
        latitude: lat,
        longitude: lon,
      );

      if (contacts.isEmpty) {
        _eventLogService.logEvent(
          type: EventType.emergencyAlertDispatched,
          outcome: EventOutcome.failure,
          description:
              'Safety Mode escalation could not notify anyone because no trusted contacts are saved.',
          metadata: metadata.toJson(),
        );
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: const Text(
                'Safety alert triggered, but no trusted contacts are configured.',
              ),
              backgroundColor: Colors.red.shade700,
            ),
          );
        }
        return;
      }

      final smsBody = _buildSafetyModeEmergencySms(
        metadata: metadata,
        userName: userName,
      );

      // Number of SMS alerts sent per trusted contact — see _kEmergencyRepeatCount
      // (currently 6, satisfying the 5–6 alert requirement).
      const repeatCount = _kEmergencyRepeatCount;
      int totalSent = 0;
      final sentNames = <String>[];

      for (final contact in contacts) {
        final phone = contact['phone'] as String? ?? '';
        final name = contact['name'] as String? ?? 'Contact';
        if (phone.isEmpty) continue;

        debugPrint('📤 [Safety] Sending $repeatCount alerts to $name ($phone)');
        int sentForContact = 0;
        for (int i = 1; i <= repeatCount; i++) {
          try {
            final ok = await _directSmsService.sendEmergency(phone: phone, message: smsBody);
            if (ok) {
              sentForContact++;
              debugPrint('  ✅ [Safety] Alert $i/$repeatCount → $name');
            } else {
              debugPrint('  ⚠️ [Safety] Alert $i/$repeatCount failed → $name');
            }
          } catch (e) {
            debugPrint('  ❌ [Safety] Alert $i/$repeatCount error → $name: $e');
          }
          if (i < repeatCount) {
            await Future.delayed(const Duration(seconds: 2));
          }
        }

        if (sentForContact > 0) {
          totalSent += sentForContact;
          sentNames.add(name);
        }

        _eventLogService.logEvent(
          type: EventType.emergencyAlertDispatched,
          outcome: sentForContact > 0 ? EventOutcome.success : EventOutcome.failure,
          description: sentForContact > 0
              ? 'Safety Mode alert sent to $name ($sentForContact/$repeatCount delivered)'
              : 'Safety Mode alert failed for $name (0/$repeatCount delivered)',
          metadata: {
            ...metadata.toJson(),
            'contactName': name,
            'sentCount': sentForContact,
            'repeatCount': repeatCount,
            'trigger': trigger.name,
          },
        );
      }

      final overallSuccess = totalSent > 0;
      _eventLogService.logEvent(
        type: EventType.emergencyAlertDispatched,
        outcome: overallSuccess ? EventOutcome.success : EventOutcome.failure,
        description: overallSuccess
            ? 'Safety Mode alert sent to ${sentNames.length} contact(s).'
            : 'Safety Mode alert could not be delivered to any trusted contact.',
        metadata: {
          ...metadata.toJson(),
          'totalSent': totalSent,
          'trigger': trigger.name,
        },
      );

      if (overallSuccess) {
        _safetyEscalation.markResolved();
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              overallSuccess
                  ? 'Emergency alert sent to ${sentNames.join(', ')}.'
                  : 'Emergency alert could not be sent.',
            ),
            backgroundColor:
                overallSuccess ? Colors.red.shade700 : const Color(0xFFB07080),
            duration: const Duration(seconds: 5),
          ),
        );
      }
    } finally {
      _safetyDispatchInFlight = false;
    }
  }

  String _buildSafetyModeEmergencySms({
    required AlertMetadata metadata,
    required String userName,
  }) {
    final who = userName.trim().isNotEmpty ? userName.trim() : 'The user';
    final location =
        metadata.hasLocation ? metadata.googleMapsUrl! : 'unavailable';
    return 'Emergency Alert: $who may be in danger.\n'
        'Location: $location\n'
        'Please check on her immediately or call 999.';
  }

  Future<void> _toggleSafetyMode() async {
    if (_safetyModeActive) {
      // ── Deactivating: stop monitoring and auto-send arrival messages ──────
      await _stopSafetyModeMonitoring();
      if (!mounted) return;
      setState(() {
        _safetyModeActive = false;
      });

      // Auto-send arrival message to all selected contacts silently
      final contacts = _safetyModeContacts;
      if (contacts != null && contacts.isNotEmpty) {
        final svc = ArrivalNotificationService();
        final storage = SecureStorageService();
        final userName = await storage.getUserNameAsync();
        int sentCount = 0;
        final sentNames = <String>[];
        for (final contact in contacts) {
          final phone = contact['phone'] as String? ?? '';
          final name  = contact['name']  as String? ?? 'Contact';
          if (phone.isEmpty) continue;
          final ok = await svc.sendToSingleContact(
            phone: phone,
            contactName: name,
            destination: 'your destination',
            userName: userName.isEmpty ? null : userName,
          );
          if (ok) {
            sentCount++;
            sentNames.add(name);
          }
        }
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Row(
                children: [
                  const Icon(Icons.check_circle, color: Colors.white, size: 18),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      sentCount > 0
                          ? '📩 Arrival message sent to ${sentNames.join(', ')}.'
                          : '⚠️ Could not send arrival message.',
                    ),
                  ),
                ],
              ),
              backgroundColor: sentCount > 0
                  ? const Color(0xFFB07080)
                  : Colors.orange,
              duration: const Duration(seconds: 4),
            ),
          );
        }
      }

      _safetyModeContacts = null;
      _eventLogService.logEvent(
        type: EventType.safetyModeActivated,
        outcome: EventOutcome.success,
        description: 'Safety monitoring deactivated',
      );
    } else {
      // ── Activating: pick contacts first ──────────────────────────────────
      final contacts = await _requireTrustedContacts(modeLabel: 'Safety Mode');
      if (!mounted) return;
      if (contacts == null) return;

      final picked = await showModalBottomSheet<List<Map<String, dynamic>>>(
        context: context,
        isScrollControlled: true,
        isDismissible: false,
        enableDrag: false,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        builder: (_) => _SafetyModeContactPicker(contacts: contacts),
      );
      if (!mounted) return;

      // User closed without selecting — abort
      if (picked == null || picked.isEmpty) return;

      setState(() {
        _safetyModeActive = true;
        _safetyModeContacts = picked;
      });

      await _startSafetyModeMonitoring();

      final names = picked.map((c) => c['name'] as String? ?? 'Contact').join(', ');
      _eventLogService.logEvent(
        type: EventType.safetyModeActivated,
        outcome: EventOutcome.success,
        description: 'Safety monitoring activated — arrival contacts: $names',
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '🛡️ Safety Mode active — monitoring started. $names will be notified when you arrive safely.',
            ),
            backgroundColor: const Color(0xFFB07080),
            duration: const Duration(seconds: 4),
          ),
        );
      }
    }
  }

  // ── Route dialog ────────────────────────────────────────────────────────────

  void _openRouteDialog() {
    String destination = '';
    final country = _selectedCountry;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        String? errorText;
        return StatefulBuilder(
          builder: (ctx, setSheetState) {
            return Padding(
            padding: EdgeInsets.only(
              left: 24,
              right: 24,
              top: 24,
              bottom: MediaQuery.of(ctx).viewInsets.bottom + 24,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
            Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: const Color(0xFFF8D7E3),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(Icons.map,
                      color: const Color(0xFFB07080), size: 22),
                ),
                const SizedBox(width: 12),
                const Text(
                  'Plan Safe Route',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
              ],
            ),
            const SizedBox(height: 20),
            TextField(
              autofocus: true,
              decoration: InputDecoration(
                labelText: 'Where are you going?',
                hintText: country?.hintShort ?? 'e.g. Priory Street, Coventry',
                prefixIcon: const Icon(Icons.location_on_outlined),
                errorText: errorText,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
                filled: true,
                fillColor: Colors.grey.shade50,
              ),
              onChanged: (v) {
                destination = v;
                // Clear inline error as soon as the user types something valid
                if (errorText != null && v.trim().isNotEmpty) {
                  setSheetState(() => errorText = null);
                }
              },
              onSubmitted: (v) {
                final trimmed = v.trim();
                if (trimmed.isNotEmpty) {
                  _eventLogService.logEvent(
                    type: EventType.safeRouteAttempted,
                    outcome: EventOutcome.info,
                    description: 'Safe Route planning started',
                    metadata: {'destination': trimmed, 'trigger': 'mapHomeRouteDialog'},
                  );
                  debugPrint('[MapHome] Planning safe route to: "$trimmed"');
                  Navigator.of(ctx).pop();
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => SafeRouteScreen(destination: trimmed),
                    ),
                  );
                } else {
                  // Keep sheet open — show inline error
                  setSheetState(() => errorText = 'Please enter a destination.');
                  _eventLogService.logEvent(
                    type: EventType.safeRouteAttempted,
                    outcome: EventOutcome.warning,
                    description: 'Safe Route attempt blocked: destination field was empty',
                    metadata: {'screen': 'MapHomeScreen', 'trigger': 'routeDialogSubmit'},
                  );
                  debugPrint('[MapHome] Blocked — empty destination on submit');
                }
              },
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: () {
                  final trimmed = destination.trim();
                  if (trimmed.isNotEmpty) {
                    _eventLogService.logEvent(
                      type: EventType.safeRouteAttempted,
                      outcome: EventOutcome.info,
                      description: 'Safe Route planning started',
                      metadata: {'destination': trimmed, 'trigger': 'mapHomeRouteButton'},
                    );
                    debugPrint('[MapHome] Planning safe route to: "$trimmed"');
                    Navigator.of(ctx).pop();
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => SafeRouteScreen(destination: trimmed),
                      ),
                    );
                  } else {
                    // Keep sheet open — show inline error
                    setSheetState(() => errorText = 'Please enter a destination.');
                    _eventLogService.logEvent(
                      type: EventType.safeRouteAttempted,
                      outcome: EventOutcome.warning,
                      description: 'Safe Route attempt blocked: destination field was empty',
                      metadata: {'screen': 'MapHomeScreen', 'trigger': 'routeDialogButton'},
                    );
                    debugPrint('[MapHome] Blocked — empty destination on button press');
                  }
                },
                icon: const Icon(Icons.directions_walk),
                label: const Text('Show Safe Route',
                    style: TextStyle(fontSize: 15)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFB07080),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
              ),
            ),
          ],
        ),
          );
          },
        );
      },
    );
  }

  // ── Locate me ───────────────────────────────────────────────────────────────

  // ── Safety Profile navigation (replaces flat Settings dialog) ───────────────

  void _openSafetyProfile() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const SafetyProfileScreen()),
    ).then((_) {
      // Refresh motion-calibration badge and setup status when returning.
      _loadMotionStatus();
      _loadSetupStatus();
    });
  }

  // ─────────────────────────────────────────────────────────────────────────────
  //  BUILD
  // ─────────────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          // ── Layer 1: Full-screen map (with swipe-up-to-expand gesture) ──
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onVerticalDragUpdate: (details) {
                final screenH = MediaQuery.of(context).size.height;
                final delta = -(details.primaryDelta ?? 0) / screenH;
                final newSize =
                    (_sheetController.size + delta).clamp(0.14, 0.90);
                _sheetController.jumpTo(newSize);
              },
              onVerticalDragEnd: (details) {
                final v = details.primaryVelocity ?? 0;
                double snapTo;
                if (v < -300) {
                  snapTo = _sheetController.size < 0.55 ? 0.42 : 0.90;
                } else if (v > 300) {
                  snapTo = _sheetController.size > 0.30 ? 0.14 : 0.14;
                } else {
                  // Snap to nearest
                  final s = _sheetController.size;
                  if (s < 0.28) { snapTo = 0.14; }
                  else if (s < 0.66) { snapTo = 0.42; }
                  else { snapTo = 0.90; }
                }
                _sheetController.animateTo(
                  snapTo,
                  duration: const Duration(milliseconds: 300),
                  curve: Curves.easeOut,
                );
              },
              child: _buildMap(),
            ),
          ),

          // ── Layer 2: Floating overlays (search bar, icon strip) ─────────
          SafeArea(
            child: Stack(
              children: [
                _buildFloatingSearchBar(),
                _buildMapIconStrip(),
              ],
            ),
          ),

          // ── Layer 3: Draggable AI Control Center ────────────────────────
          DraggableScrollableSheet(
            controller: _sheetController,
            initialChildSize: 0.42,
            minChildSize: 0.14,
            maxChildSize: 0.90,
            snap: true,
            snapSizes: const [0.14, 0.42, 0.90],
            builder: (_, scrollController) =>
                _buildControlCenter(scrollController),
          ),
        ],
      ),
    );
  }

  // ── Map layer ────────────────────────────────────────────────────────────────

  Widget _buildMap() {
    return FlutterMap(
      mapController: _mapController,
      options: MapOptions(
        initialCenter: _currentPosition,
        initialZoom: 15.5,
        interactionOptions: const InteractionOptions(
          flags: InteractiveFlag.pinchZoom | InteractiveFlag.drag,
        ),
      ),
      children: [
        TileLayer(
          // OpenStreetMap standard — vivid full-colour tiles, no API key required.
          urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
          userAgentPackageName: 'com.shesafe.app',
          maxZoom: 19,
          // Keep extra tile buffer so panning doesn't show empty edges.
          keepBuffer: 4,
          tileBuilder: (context, tileWidget, tile) {
            // Tile loaded — clear error overlay once (no rebuild per tile).
            if (_tilesFailedToLoad) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (_tilesFailedToLoad && mounted) {
                  setState(() => _tilesFailedToLoad = false);
                }
              });
            }
            return tileWidget;
          },
          errorTileCallback: (tile, error, stackTrace) {
            if (!_tilesFailedToLoad && mounted) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) setState(() => _tilesFailedToLoad = true);
              });
            }
          },
        ),
        // ── No-internet overlay ──────────────────────────────────────────────
        if (_tilesFailedToLoad)
          Positioned.fill(
            child: IgnorePointer(
              child: Center(
                child: Container(
                  margin: const EdgeInsets.symmetric(horizontal: 32),
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                  decoration: BoxDecoration(
                    color: Colors.white.withAlpha(220),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: Colors.grey.shade300),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withAlpha(20),
                        blurRadius: 12,
                      ),
                    ],
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.wifi_off_rounded,
                          color: Colors.grey.shade500, size: 28),
                      const SizedBox(width: 14),
                      Flexible(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Map tiles unavailable',
                              style: TextStyle(
                                fontWeight: FontWeight.w700,
                                fontSize: 14,
                              ),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              'Enable mobile data or Wi-Fi to load the map. Your location is still tracked.',
                              style: TextStyle(
                                fontSize: 12,
                                color: Colors.grey.shade600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        // Current location marker
        if (_locationLoaded)
          MarkerLayer(
            markers: [
              Marker(
                point: _currentPosition,
                width: 48,
                height: 48,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    // Outer pulse ring
                    Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.pink.withAlpha(40),
                      ),
                    ),
                    // Inner dot
                    Container(
                      width: 22,
                      height: 22,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: const Color(0xFFB07080),
                        border: Border.all(color: Colors.white, width: 3),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withAlpha(50),
                            blurRadius: 6,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        const RichAttributionWidget(
          attributions: [
            TextSourceAttribution('OpenStreetMap contributors'),
          ],
        ),
      ],
    );
  }

  // ── Floating search bar (top-centre of map) ──────────────────────────────────

  Widget _buildFloatingSearchBar() {
    return Positioned(
      top: 10,
      left: 12,
      right: 60,
      child: Semantics(
        label: 'Search for a destination',
        button: true,
        hint: 'Opens route planner',
        child: Material(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          elevation: 4,
          shadowColor: Colors.black.withAlpha(40),
          child: InkWell(
            onTap: _openRouteDialog,
            borderRadius: BorderRadius.circular(14),
            splashColor: Colors.pink.withAlpha(25),
            child: SizedBox(
              height: 48,
              child: Row(
                children: [
                  const SizedBox(width: 14),
                  Icon(Icons.search, color: Colors.grey.shade600, size: 20),
                  const SizedBox(width: 10),
                  Flexible(
                    child: Text(
                      'Where are you walking to?',
                      style: TextStyle(
                        fontSize: 14,
                        color: Colors.grey.shade600,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ── Floating icon strip (top-right of map) ───────────────────────────────────

  Widget _buildMapIconStrip() {
    return Positioned(
      top: 10,
      right: 10,
      child: Column(
        children: [
          _mapFab(
            icon: Icons.my_location,
            onTap: () => _mapController.move(_currentPosition, 15.5),
            tooltip: 'My location',
          ),
          const SizedBox(height: 8),
          _mapFab(
            icon: Icons.verified_user_outlined,
            onTap: () => _showDataCoverageSheet(context),
            tooltip: 'Data coverage',
          ),
          const SizedBox(height: 8),
          _mapFab(
            icon: Icons.history,
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const HistoryScreen()),
            ),
            tooltip: 'Event history',
          ),
          const SizedBox(height: 8),
          _mapFab(
            icon: Icons.manage_accounts_outlined,
            onTap: _openSafetyProfile,
            tooltip: 'My Safety Profile',
          ),
          const SizedBox(height: 8),
          _mapFab(
            icon: Icons.feedback_outlined,
            onTap: _openFeedbackSheet,
            tooltip: 'Send feedback',
          ),
        ],
      ),
    );
  }

  Widget _mapFab({
    IconData? icon,
    String? label,
    required VoidCallback onTap,
    String? tooltip,
  }) {
    return Semantics(
      label: tooltip ?? label ?? '',
      button: true,
      child: Tooltip(
        message: tooltip ?? '',
        child: Material(
          color: Colors.white,
          shape: const CircleBorder(),
          elevation: 3,
          shadowColor: Colors.black.withAlpha(40),
          child: InkWell(
            onTap: onTap,
            customBorder: const CircleBorder(),
            splashColor: Colors.pink.withAlpha(30),
            child: SizedBox(
              width: 42,
              height: 42,
              child: Center(
                child: icon != null
                    ? Icon(icon, size: 19, color: Colors.grey.shade700)
                    : Text(label ?? '', style: const TextStyle(fontSize: 18)),
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ── "Complete Your Setup" banner ───────────────────────────────────────────

  // ignore: unused_element
  Widget _buildSetupBanner() {
    final missing = <_SetupItem>[];
    if (!_hasTrustedContacts) {
      missing.add(_SetupItem(
        icon: Icons.people_outline,
        label: 'Trusted Contacts',
        description: 'Add people to alert in emergencies',
        color: const Color(0xFFB07080),
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(
              builder: (_) => const ManageTrustedContactsScreen()),
        ).then((_) => _loadSetupStatus()),
      ));
    }
    if (!_hasSafeWord) {
      missing.add(_SetupItem(
        icon: Icons.lock_outline,
        label: 'Safe Word',
        description: 'Set a voice-activated panic trigger',
        color: const Color(0xFF9B72CB),
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(
              builder: (_) => const ChangeSafeWordScreen()),
        ).then((_) => _loadSetupStatus()),
      ));
    }
    if (!_motionCalibrated) {
      missing.add(_SetupItem(
        icon: Icons.sensors,
        label: 'Motion AI',
        description: 'Calibrate walking-anomaly detection',
        color: Colors.orange,
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(
              builder: (_) => const MotionBaselineCalibrationScreen()),
        ).then((_) {
          _loadMotionStatus();
          _loadSetupStatus();
        }),
      ));
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [Colors.amber.shade50, Colors.orange.shade50],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.amber.shade200),
        ),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: Colors.amber.shade100,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(Icons.checklist_rounded,
                        color: Colors.amber.shade800, size: 18),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Complete Your Setup',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            color: Colors.amber.shade900,
                          ),
                        ),
                        Text(
                          '$_missingSetupCount item${_missingSetupCount == 1 ? '' : 's'} remaining',
                          style: TextStyle(
                            fontSize: 11.5,
                            color: Colors.amber.shade700,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              ...missing.map((item) => Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: InkWell(
                      onTap: item.onTap,
                      borderRadius: BorderRadius.circular(10),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 10),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                              color: item.color.withAlpha(60)),
                        ),
                        child: Row(
                          children: [
                            Icon(item.icon,
                                size: 20, color: item.color),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment:
                                    CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    item.label,
                                    style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600,
                                      color: Colors.grey.shade800,
                                    ),
                                  ),
                                  Text(
                                    item.description,
                                    style: TextStyle(
                                      fontSize: 11,
                                      // shade600 on white ≈ 5.7:1 — WCAG AA
                                      color: Colors.grey.shade600,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Icon(Icons.chevron_right,
                                size: 18,
                                color: Colors.grey.shade500),
                          ],
                        ),
                      ),
                    ),
                  )),
            ],
          ),
        ),
      ),
    );
  }

  // ── Floating AI status badge (centre-bottom of map section) ──────────────────

  // ignore: unused_element
  Widget _buildAIBadge() {
    final bool calibrated = _motionCalibrated;
    final Color badgeColor = Colors.grey.shade600;
    final Color badgeBg = Colors.grey.shade100;
    final String badgeText =
        calibrated ? 'Motion AI: Active' : 'Motion AI: Uncalibrated';
    final String subText = calibrated
        ? 'Isolation Forest ready'
        : 'Tap to calibrate';

    return Center(
      child: FadeTransition(
        opacity: _badgeOpacity,
        child: GestureDetector(
          onTap: calibrated
              ? null
              : () => Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) =>
                            const MotionBaselineCalibrationScreen()),
                  ),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
              color: badgeBg,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: Colors.grey.shade300),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(
                    badgeText,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: badgeColor,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    '·  $subText',
                    style: TextStyle(
                      fontSize: 11.5,
                      color: badgeColor.withAlpha(200),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────────
  //  BOTTOM 40 % — AI CONTROL CENTER
  // ─────────────────────────────────────────────────────────────────────────────

  Widget _buildControlCenter(ScrollController scrollController) {
    final bottomInset = MediaQuery.of(context).viewPadding.bottom;
    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: SingleChildScrollView(
        controller: scrollController,
        padding: EdgeInsets.fromLTRB(20, 0, 20, 24 + bottomInset),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ── Drag handle ────────────────────────────────────────────────
            Semantics(
              label: 'Drag handle – swipe up to expand control panel',
              hint: 'Swipe up or down',
              child: Padding(
                padding: const EdgeInsets.only(top: 10, bottom: 6),
                child: Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.grey.shade300,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              ),
            ),

            // ── Offline banner (shown only when device has no network) ─────
            if (!_isOnline)
              Semantics(
                liveRegion: true,
                label: 'No internet connection. Risk zone data may be cached.',
                child: Container(
                  margin: const EdgeInsets.only(bottom: 10),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: Colors.orange.shade50,
                    border: Border.all(color: Colors.orange.shade200),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.wifi_off_rounded,
                          size: 16, color: Colors.orange.shade700),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Offline — showing cached risk zone data',
                          style: TextStyle(
                              fontSize: 12, color: Colors.orange.shade800),
                        ),
                      ),
                    ],
                  ),
                ),
              ),

            // ── Status row (2 chips) ─────────────────────────────────────
            Row(
              children: [
                // Chip 1: Data sources
                Expanded(
                  flex: 2,
                  child: _statusChip(
                    icon: Icons.check_circle_outline,
                    label: 'Risk Zones: On',
                  ),
                ),
                const SizedBox(width: 8),
                // Chip 2: Motion AI
                Expanded(
                  flex: 3,
                  child: GestureDetector(
                    onTap: _motionCalibrated
                        ? null
                        : () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                  builder: (_) =>
                                      const MotionBaselineCalibrationScreen()),
                            ).then((_) {
                              _loadMotionStatus();
                              _loadSetupStatus();
                            }),
                    child: _statusChip(
                      icon: _motionCalibrated
                          ? Icons.memory
                          : Icons.memory_outlined,
                      label: _motionCalibrated
                          ? 'Motion AI: Active'
                          : 'Motion AI: Uncalibrated',
                    ),
                  ),
                ),
              ],
            ),

            // ── Battery-throttle notice (only when GPS is reduced) ──────────
            if (_batteryThrottled)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: _statusChip(
                  icon: Icons.battery_alert,
                  label: 'Low battery — GPS reduced',
                ),
              ),

            // ── Low battery warning banner (Safety Mode, battery ≤ 20 %) ───
            if (_safetyModeActive && _lowBatterySafetyWarning)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.orange.shade50,
                    border: Border.all(color: Colors.orange.shade300),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  padding: const EdgeInsets.symmetric(
                      horizontal: 10, vertical: 7),
                  child: Row(
                    children: [
                      Icon(Icons.battery_alert,
                          color: Colors.orange.shade700, size: 16),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          '⚠️ Battery low — contacts notified at 10%',
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.orange.shade800,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                      GestureDetector(
                        onTap: () => setState(
                            () => _lowBatterySafetyWarning = false),
                        child: Icon(Icons.close,
                            size: 14, color: Colors.orange.shade600),
                      ),
                    ],
                  ),
                ),
              ),


            const SizedBox(height: 14),

            // ── 2. THE MAIN EVENT — Activate Safety Mode ───────────────────
            Semantics(
              label: _safetyModeActive
                  ? 'Safety Mode is active. Tap to deactivate.'
                  : 'Activate Safety Mode. Starts motion and audio monitoring.',
              button: true,
              child: ScaleTransition(
                scale: _safetyModeActive
                    ? const AlwaysStoppedAnimation(1.0)
                    : _pulseAnimation,
                child: Material(
                  color: Colors.transparent,
                  borderRadius: BorderRadius.circular(16),
                  child: InkWell(
                    onTap: () => _toggleSafetyMode(),
                    borderRadius: BorderRadius.circular(16),
                    focusColor: Colors.white.withValues(alpha: 0.15),
                    child: AnimatedContainer(
                  duration: const Duration(milliseconds: 350),
                  constraints: const BoxConstraints(minHeight: 56),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: _safetyModeActive
                          ? [const Color(0xFFB07080), const Color(0xFFA0406A)]
                          : [const Color(0xFFB07080), const Color(0xFFA0406A)],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.circular(16),
                    boxShadow: _safetyModeActive
                        ? [
                            BoxShadow(
                              color: const Color(0xFFB07080).withAlpha(200),
                              blurRadius: 24,
                              spreadRadius: 2,
                              offset: const Offset(0, 4),
                            ),
                            BoxShadow(
                              color: const Color(0xFFB07080).withAlpha(100),
                              blurRadius: 40,
                              spreadRadius: 4,
                            ),
                          ]
                        : [
                            BoxShadow(
                              color: const Color(0xFFB07080).withAlpha(100),
                              blurRadius: 8,
                              offset: const Offset(0, 2),
                            ),
                          ],
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        _safetyModeActive
                            ? Icons.shield
                            : Icons.shield_outlined,
                        color: _safetyModeActive
                            ? Colors.white
                            : Colors.white,
                        size: 28,
                      ),
                      const SizedBox(width: 12),
                      Flexible(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _safetyModeActive
                                  ? 'SAFETY MODE ACTIVE'
                                  : 'ACTIVATE SAFETY MODE',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 16,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 0.4,
                              ),
                            ),
                            Text(
                              _safetyModeActive
                                  ? 'Tap to deactivate monitoring'
                                  : 'Starts motion & audio monitoring',
                              style: TextStyle(
                                color: Colors.white.withAlpha(200),
                                fontSize: 11.5,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  ),
                ),
              ),
            ),
            ),

            const SizedBox(height: 14),

            // ── 3. Quick action row ────────────────────────────────────────
            Row(
              children: [
                _quickActionCard(
                  icon: Icons.support_agent,
                  label: 'Safety\nAssistant',
                  color: const Color(0xFF9B72CB),
                  bg: const Color(0xFFEDE7F6),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => const GuidanceAssistantScreen()),
                  ),
                ),
                const SizedBox(width: 10),
                _quickActionCard(
                  icon: Icons.warning_amber_rounded,
                  label: 'Panic\nMode',
                  color: Colors.red.shade600,
                  bg: Colors.red.shade50,
                  onTap: () async {
                    final contacts = await _requireTrustedContacts(
                      modeLabel: 'Panic Mode',
                    );
                    if (!context.mounted) return;
                    if (contacts == null) return;
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                          settings: const RouteSettings(name: '/panic'),
                          builder: (_) => const PanicModeScreen()),
                    );
                  },
                ),
                const SizedBox(width: 10),
                _quickActionCard(
                  icon: Icons.directions_walk,
                  label: 'Plan\nRoute',
                  color: const Color(0xFFB07080),
                  bg: const Color(0xFFF8D7E3),
                  onTap: _openRouteDialog,
                ),
                const SizedBox(width: 10),
                _quickActionCard(
                  icon: Icons.history,
                  label: 'Event\nHistory',
                  color: Colors.orange.shade600,
                  bg: Colors.orange.shade50,
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const HistoryScreen()),
                  ),
                ),
              ],
            ),

            // ── 3. Quick action row 2: new safety features ────────────────
            const SizedBox(height: 10),
            Row(
              children: [
                // Fake Phone Call
                _quickActionCard(
                  icon: Icons.phone_in_talk,
                  label: 'Fake\nPhone Call',
                  color: const Color(0xFFE8956D),
                  bg: const Color(0xFFFFF1E8),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const FakeCallScreen()),
                  ),
                ),
                const SizedBox(width: 10),
                // Lock-Screen Shortcuts — same card style as Fake Phone Call
                Expanded(
                  child: Semantics(
                    label: _quickActionsEnabled
                        ? 'Lock-Screen Shortcuts enabled. Tap to disable.'
                        : 'Enable Lock-Screen Shortcuts for quick access to Panic Mode.',
                    button: true,
                    toggled: _quickActionsEnabled,
                    child: Material(
                      color: const Color(0xFFEDE7F6),
                      borderRadius: BorderRadius.circular(14),
                      child: InkWell(
                        onTap: () => _toggleQuickActions(!_quickActionsEnabled),
                        borderRadius: BorderRadius.circular(14),
                        child: Stack(
                          children: [
                            Container(
                              constraints: const BoxConstraints(minHeight: 72),
                              alignment: Alignment.center,
                              padding: const EdgeInsets.symmetric(
                                  vertical: 8, horizontal: 4),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(
                                    _quickActionsEnabled
                                        ? Icons.notifications_active
                                        : Icons.notifications_outlined,
                                    color: const Color(0xFF9B72CB),
                                    size: 22,
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    'Lock-Screen\nShortcuts',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      fontSize: 10.5,
                                      color: _quickActionsEnabled
                                          ? const Color(0xFF7B52AB)
                                          : const Color(0xFF9B72CB),
                                      fontWeight: FontWeight.w600,
                                      height: 1.25,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Positioned(
                              top: 5,
                              right: 5,
                              child: Semantics(
                                label: 'Info: what are Lock-Screen Shortcuts',
                                button: true,
                                child: InkWell(
                                  borderRadius: BorderRadius.circular(20),
                                  onTap: () => showDialog<void>(
                                    context: context,
                                    builder: (_) => AlertDialog(
                                      title: const Text('Lock-Screen Shortcuts'),
                                      content: const Text(
                                        'When enabled, Safety Mode and Panic Mode '
                                        'buttons appear in your notification bar '
                                        'for quick safety access from your lock screen.',
                                      ),
                                      actions: [
                                        TextButton(
                                          onPressed: () => Navigator.pop(context),
                                          child: const Text('Got it'),
                                        ),
                                      ],
                                    ),
                                  ),
                                  child: Container(
                                    padding: const EdgeInsets.all(3),
                                    decoration: BoxDecoration(
                                      color: Colors.white.withValues(alpha: 0.85),
                                      shape: BoxShape.circle,
                                    ),
                                    child: Icon(
                                      Icons.info_outline,
                                      size: 13,
                                      color: Colors.grey.shade600,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),

            // ── 3b. My Reports shortcut ───────────────────────────────────
            const SizedBox(height: 10),
            InkWell(
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) => const IncidentReportScreen()),
              ),
              borderRadius: BorderRadius.circular(12),
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 14, vertical: 12),
                decoration: BoxDecoration(
                  color: const Color(0xFFEDE7F6),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                      color: const Color(0xFFCEB8E8), width: 1),
                ),
                child: Row(
                  children: [
                    CircleAvatar(
                      radius: 18,
                      backgroundColor:
                          const Color(0xFFEDE7F6),
                      child: Icon(Icons.description_outlined,
                          size: 18,
                          color: const Color(0xFF9B72CB)),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment:
                            CrossAxisAlignment.start,
                        children: [
                          Text(
                            'My Reports',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                              color: const Color(0xFF6B4F8A),
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'View, share or create incident reports',
                            style: TextStyle(
                              fontSize: 11,
                              color: const Color(0xFF9B72CB),
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Icon(Icons.chevron_right,
                        color: const Color(0xFF9B72CB).withValues(alpha: 0.6)),
                  ],
                ),
              ),
            ),

            // ── 3c. Helpline Contacts shortcut ────────────────────────────
            const SizedBox(height: 10),
            InkWell(
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) => const HelplineContactsScreen()),
              ),
              borderRadius: BorderRadius.circular(12),
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 14, vertical: 12),
                decoration: BoxDecoration(
                  color: Colors.red.shade50,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                      color: Colors.red.shade100, width: 1),
                ),
                child: Row(
                  children: [
                    CircleAvatar(
                      radius: 18,
                      backgroundColor: Colors.red.shade100,
                      child: Icon(Icons.phone_in_talk,
                          size: 18, color: Colors.red.shade700),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment:
                            CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Helpline Contacts',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                              color: Colors.red.shade900,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'Police, Childline, Samaritans & more',
                            style: TextStyle(
                              fontSize: 11,
                              color: Colors.red.shade300,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Icon(Icons.chevron_right,
                        color: Colors.red.shade300),
                  ],
                ),
              ),
            ),

            // ── 4. Safety tips (visible when scrolled) ────────────────────
            if (_tips.isNotEmpty) ...[
              const SizedBox(height: 16),
              Row(
                children: [
                  Icon(Icons.lightbulb_outline,
                      size: 15, color: Colors.amber.shade700),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      "Today's Safety Tips",
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                        color: Colors.grey.shade800,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Semantics(
                    label: 'See all safety tips',
                    button: true,
                    child: InkWell(
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                            builder: (_) => const GuidanceAssistantScreen()),
                      ),
                      borderRadius: BorderRadius.circular(4),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                        child: Text(
                          'See all →',
                          style: TextStyle(
                            fontSize: 11.5,
                            color: const Color(0xFF9B72CB),
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              ..._tips.map((tip) => _buildTipCard(tip)),
            ],
          ],
        ),
      ),
    );
  }

  // ── Data source badge ─────────────────────────────────────────────────────────

  // ignore: unused_element
  Widget _buildDataSourceBadge(bool isUk) {
    if (isUk) {
      return Wrap(
        spacing: 8,
        runSpacing: 6,
        children: [
          _statusChip(icon: Icons.check_circle_outline, label: 'UK Crime Data Active'),
          _statusChip(icon: Icons.sensors, label: 'Risk Zones: On'),
        ],
      );
    } else {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: Colors.grey.shade100,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: Colors.grey.shade300),
        ),
        child: Row(
          children: [
            Icon(Icons.info_outline, size: 15, color: Colors.grey.shade600),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                'International Mode — crime data limited to UK.',
                style: TextStyle(fontSize: 11.5, color: Colors.grey.shade700),
              ),
            ),
          ],
        ),
      );
    }
  }

  Widget _statusChip({required IconData icon, required String label}) {
    return Semantics(
      label: label,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: Colors.grey.shade100,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Colors.grey.shade300),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 13, color: Colors.grey.shade700),
            const SizedBox(width: 5),
            Flexible(
              child: Text(
                label,
                style: TextStyle(
                    fontSize: 11.5,
                    // shade700 on grey100 ≈ 5.7:1 — passes WCAG AA
                    color: Colors.grey.shade700,
                    fontWeight: FontWeight.w500),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _quickActionCard({
    required IconData icon,
    required String label,
    required Color color,
    required Color bg,
    required VoidCallback onTap,
    String? semanticLabel,
  }) {
    // Flatten the two-line label into a single string for screen readers
    final srLabel = semanticLabel ?? label.replaceAll('\n', ' ');
    return Expanded(
      child: Semantics(
        label: srLabel,
        button: true,
        child: Material(
          color: bg,
          borderRadius: BorderRadius.circular(14),
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(14),
            splashColor: color.withAlpha(40),
            highlightColor: color.withAlpha(20),
            child: Container(
              constraints: const BoxConstraints(minHeight: 72),
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(icon, color: color, size: 22),
                  const SizedBox(height: 4),
                  Text(
                    label,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 10.5,
                      color: color,
                      fontWeight: FontWeight.w600,
                      height: 1.25,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTipCard(SafetyGuidance tip) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 5),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.pink.shade50,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.pink.shade100),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              tip.situation,
              style: const TextStyle(
                  fontSize: 12.5, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 5),
            Text(
              tip.advice,
              style: TextStyle(
                  fontSize: 12, color: Colors.grey.shade700, height: 1.4),
            ),
            const SizedBox(height: 4),
            Text(
              tip.category.displayName,
              style: TextStyle(
                  fontSize: 10.5,
                color: Colors.pink.shade400,
                  fontWeight: FontWeight.w500),
            ),
          ],
        ),
      ),
    );
  }
}

/// Describes a single missing setup item for the "Complete Your Setup" banner.
class _SetupItem {
  final IconData icon;
  final String label;
  final String description;
  final Color color;
  final VoidCallback onTap;

  const _SetupItem({
    required this.icon,
    required this.label,
    required this.description,
    required this.color,
    required this.onTap,
  });
}

// ── Safety Mode Contact Picker ─────────────────────────────────────────────

class _SafetyModeContactPicker extends StatefulWidget {
  final List<Map<String, dynamic>> contacts;
  const _SafetyModeContactPicker({required this.contacts});

  @override
  State<_SafetyModeContactPicker> createState() =>
      _SafetyModeContactPickerState();
}

class _SafetyModeContactPickerState extends State<_SafetyModeContactPicker> {
  late List<bool> _selected;

  @override
  void initState() {
    super.initState();
    // default: all contacts selected
    _selected = List.filled(widget.contacts.length, true);
  }

  @override
  Widget build(BuildContext context) {
    final anySelected = _selected.contains(true);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Who should receive your arrival message?',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            Text(
              'Select one or more contacts to notify when you arrive safely.',
              style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
            ),
            const SizedBox(height: 8),
            ...widget.contacts.asMap().entries.map((e) => CheckboxListTile(
                  value: _selected[e.key],
                  onChanged: (v) =>
                      setState(() => _selected[e.key] = v ?? false),
                  title: Text(e.value['name'] as String? ?? 'Unknown'),
                  subtitle: Text(e.value['phone'] as String? ?? ''),
                  activeColor: const Color(0xFFB07080),
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                )),
            const SizedBox(height: 8),
            Row(
              children: [
                const Spacer(),
                ElevatedButton(
                  onPressed: anySelected
                      ? () {
                          final chosen = widget.contacts
                              .asMap()
                              .entries
                              .where((e) => _selected[e.key])
                              .map((e) => e.value)
                              .toList();
                          Navigator.pop(context, chosen);
                        }
                      : null,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFB07080),
                    foregroundColor: Colors.white,
                  ),
                  child: const Text('Confirm'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ── In-app feedback sheet ───────────────────────────────────────────────────

enum _SubmitState { idle, submitting, success, error }

class _FeedbackSheet extends StatefulWidget {
  /// The screen from which the feedback sheet was opened.
  /// Stored in [FeedbackEntry.screenName] so entries can be traced back
  /// to their source when collected from multiple pages in the future.
  final String screenName;

  const _FeedbackSheet({this.screenName = 'map_home_screen'});

  @override
  State<_FeedbackSheet> createState() => _FeedbackSheetState();
}

class _FeedbackSheetState extends State<_FeedbackSheet> {
  static const _kAccent = Color(0xFFB07080);
  static const _kSoft = Color(0xFFFFF5F8);
  static const _kBorder = Color(0xFFF2D5E2);

  final _ctrl = TextEditingController();
  final _svc = FeedbackService();
  int _stars = 0;
  FeedbackCategory? _category;
  _SubmitState _state = _SubmitState.idle;
  String _errorMsg = '';
  String _appVersion = 'unknown';

  @override
  void initState() {
    super.initState();
    FeedbackService.fetchAppVersion().then((v) {
      if (mounted) setState(() => _appVersion = v);
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    // Guard: rating required; ignore repeated taps while in-flight
    if (_stars == 0 || _state == _SubmitState.submitting) return;

    setState(() {
      _state = _SubmitState.submitting;
      _errorMsg = '';
    });

    try {
      final entry = FeedbackEntry(
        rating: _stars,
        comment: _ctrl.text.trim().replaceAll(RegExp(r' {2,}'), ' '),
        category: _category,
        timestamp: DateTime.now(),
        appVersion: _appVersion,
        platform: FeedbackService.currentPlatform,
        screenName: widget.screenName,
      );
      await _svc.submit(entry);
      if (mounted) setState(() => _state = _SubmitState.success);
    } on DuplicateFeedbackException {
      if (mounted) {
        setState(() {
          _state = _SubmitState.error;
          _errorMsg =
              'You\'ve already submitted feedback recently. Please try again in a moment.';
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _state = _SubmitState.error;
          _errorMsg =
              'Something went wrong saving your feedback. Please try again.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    final maxHeight = MediaQuery.of(context).size.height * 0.85;
    return Container(
      constraints: BoxConstraints(maxHeight: maxHeight),
      decoration: const BoxDecoration(
        color: _kSoft,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      padding: EdgeInsets.fromLTRB(24, 20, 24, 24 + bottom),
      child: SingleChildScrollView(
        physics: const ClampingScrollPhysics(),
        child:
            _state == _SubmitState.success ? _buildThankYou() : _buildForm(),
      ),
    );
  }

  // ── Thank-you state ──────────────────────────────────────────────────────

  Widget _buildThankYou() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: 12),
        const Icon(Icons.check_circle_outline,
          size: 52, color: _kAccent),
        const SizedBox(height: 16),
        const Text(
          'Thank you!',
          style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w800,
              color: Color(0xFF1A1A1A)),
        ),
        const SizedBox(height: 8),
        Text(
          'Your feedback has been saved on this device.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 14.5, color: Colors.grey.shade600),
        ),
        const SizedBox(height: 28),
        SizedBox(
          width: double.infinity,
          height: 50,
          child: ElevatedButton(
            onPressed: () => Navigator.pop(context),
            style: ElevatedButton.styleFrom(
              backgroundColor: _kAccent,
              foregroundColor: Colors.white,
              elevation: 0,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14)),
            ),
            child: const Text('Done',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          ),
        ),
      ],
    );
  }

  // ── Form state ───────────────────────────────────────────────────────────

  Widget _buildForm() {
    final isSubmitting = _state == _SubmitState.submitting;
    final canSubmit = _stars > 0 && !isSubmitting;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Drag handle
        Center(
          child: Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.grey.shade300,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
        const SizedBox(height: 20),
        const Text(
          'Share your feedback',
          style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w800,
            color: Color(0xFF7A3552)),
        ),
        const SizedBox(height: 6),
        Text(
          'How has SheSafe been for you?',
          style: TextStyle(fontSize: 14, color: Colors.grey.shade600),
        ),
        const SizedBox(height: 20),

        // Star rating — requires at least 1 star to unlock submit
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: List.generate(5, (i) {
            final filled = i < _stars;
            return GestureDetector(
              onTap: isSubmitting
                  ? null
                  : () => setState(() => _stars = i + 1),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: Icon(
                  filled ? Icons.star_rounded : Icons.star_outline_rounded,
                  size: 38,
                  color: filled
                      ? _kAccent
                      : Colors.grey.shade300,
                ),
              ),
            );
          }),
        ),
        const SizedBox(height: 20),

        // Category (optional)
        Wrap(
          spacing: 8,
          runSpacing: 6,
          children: FeedbackCategory.values.map((cat) {
            final selected = _category == cat;
            return ChoiceChip(
              label: Text(cat.label),
              selected: selected,
              onSelected: isSubmitting
                  ? null
                  : (_) => setState(
                      () => _category = selected ? null : cat),
              selectedColor: _kAccent,
              labelStyle: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: selected ? Colors.white : Colors.grey.shade700,
              ),
              backgroundColor: _kSoft,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
                side: BorderSide(
                  color: selected
                      ? _kAccent
                      : _kBorder,
                ),
              ),
              showCheckmark: false,
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            );
          }).toList(),
        ),
        const SizedBox(height: 20),

        // Optional comment
        Text(
          'Optional comment',
          style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: Colors.grey.shade700),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _ctrl,
          onChanged: (_) => setState(() {}),
          maxLines: 4,
          maxLength: 300,
          enabled: !isSubmitting,
          textInputAction: TextInputAction.newline,
          decoration: InputDecoration(
            hintText: 'Tell us what could be improved',
            hintStyle:
                TextStyle(color: Colors.grey.shade400, fontSize: 13.5),
            filled: true,
            fillColor: _kSoft,
            counterStyle:
                TextStyle(color: Colors.grey.shade400, fontSize: 11.5),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide:
                  const BorderSide(color: _kAccent, width: 2),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: _kBorder),
            ),
            disabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: _kBorder),
            ),
          ),
        ),

        // Inline error message (shown on retry)
        if (_state == _SubmitState.error) ...[
          const SizedBox(height: 12),
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: const Color(0xFFFFF0F0),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: const Color(0xFFFFCDD2)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.error_outline,
                    color: Color(0xFFE53935), size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _errorMsg,
                    style: const TextStyle(
                        color: Color(0xFFE53935), fontSize: 13),
                  ),
                ),
              ],
            ),
          ),
        ],

        const SizedBox(height: 16),

        // Storage disclosure
        Container(
          padding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          decoration: BoxDecoration(
              color: _kSoft,
            borderRadius: BorderRadius.circular(10),
              border: Border.all(color: _kBorder),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.info_outline,
                  size: 14, color: Colors.grey.shade500),
              const SizedBox(width: 7),
              Expanded(
                child: GestureDetector(
                  onTap: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => DebugEvaluationScreen(),
                      ),
                    );
                  },
                  child: Text.rich(
                    TextSpan(
                      text: 'Your feedback is stored only on this device. ',
                      style: TextStyle(fontSize: 11.5, color: Colors.grey.shade500),
                      children: [
                        TextSpan(
                          text: 'Export feedback',
                          style: TextStyle(
                            color: _kAccent,
                            decoration: TextDecoration.underline,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        TextSpan(text: ' from the debug screen.'),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),

        // Privacy note
        Row(
          children: [
            Icon(Icons.lock_outline,
                size: 13, color: Colors.grey.shade400),
            const SizedBox(width: 4),
            Expanded(
              child: Text(
                'Your feedback is only used to improve SheSafe.',
                style:
                    TextStyle(fontSize: 12, color: Colors.grey.shade400),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),

        // Save button
        SizedBox(
          width: double.infinity,
          height: 50,
          child: ElevatedButton(
            onPressed: canSubmit ? _submit : null,
            style: ElevatedButton.styleFrom(
              backgroundColor: _kAccent,
              foregroundColor: Colors.white,
              disabledBackgroundColor: Colors.grey.shade200,
              elevation: 0,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14)),
            ),
            child: isSubmitting
                ? const SizedBox(
                    height: 22,
                    width: 22,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.5,
                      valueColor:
                          AlwaysStoppedAnimation<Color>(Colors.white),
                    ),
                  )
                : Text(
                    _state == _SubmitState.error
                        ? 'Try Again'
                        : 'Save Feedback',
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w700),
                  ),
          ),
        ),
      ],
    );
  }
}
