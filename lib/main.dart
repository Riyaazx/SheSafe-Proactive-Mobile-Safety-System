import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'services/secure_storage_service.dart';
import 'services/user_profile_service.dart';
import 'services/risk_engine_service.dart';
import 'services/crime_evidence_service.dart';
import 'services/safety_guidance_service.dart';
import 'services/event_log_service.dart';
import 'services/quick_action_notification_service.dart';
import 'services/connectivity_service.dart';
import 'models/event_log.dart';
import 'features/onboarding/screens/onboarding_flow.dart';
import 'features/home/map_home_screen.dart';
import 'features/panic_mode/panic_mode_screen.dart';
import 'widgets/sos_overlay.dart';
import 'app_navigator.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // Initialize storage service
  final storageService = SecureStorageService();
  await storageService.init();

  // If the onboarding-completed flag was lost (e.g. debug reinstall wipes SharedPrefs)
  // but the safe word is still in secure storage, restore the flag automatically so
  // the user is not forced through setup again.
  if (!storageService.isOnboardingCompleted()) {
    final existingSafeWord = await storageService.getSafeWord();
    if (existingSafeWord != null && existingSafeWord.isNotEmpty) {
      await storageService.setOnboardingCompleted(true);
    }
  }

  // Initialize user personalisation profile service (singleton, accessed via UserProfileService())
  await UserProfileService().init();
  
  // Initialize event log service
  final eventLogService = EventLogService();
  await eventLogService.init();

  // ── Global error handlers ────────────────────────────────────────────────
  // Captures widget/rendering errors (Flutter framework) and unhandled
  // platform errors, logs them via EventLogService, and shows an
  // appropriate debug trace in debug mode only.
  //
  // The previous handler is chained so that in test environments the test
  // framework (which also sets FlutterError.onError) still receives errors.
  final previousFlutterOnError = FlutterError.onError;
  FlutterError.onError = (FlutterErrorDetails details) {
    FlutterError.presentError(details); // prints stack in debug
    eventLogService.logEvent(
      type: EventType.appLaunched,
      outcome: EventOutcome.failure,
      description: 'Flutter error: ${details.exceptionAsString()}',
      metadata: {
        'library': details.library ?? 'unknown',
        'context': details.context.toString(),
      },
    );
    previousFlutterOnError?.call(details); // forward to test framework if present
  };

  PlatformDispatcher.instance.onError = (error, stack) {
    debugPrint('Unhandled platform error: $error\n$stack');
    eventLogService.logEvent(
      type: EventType.appLaunched,
      outcome: EventOutcome.failure,
      description: 'Unhandled error: $error',
      metadata: {'stack': stack.toString().truncateForLog()},
    );
    return true; // mark as handled so the app is not torn down
  };
  
  // Log app launch
  eventLogService.logEvent(
    type: EventType.appLaunched,
    outcome: EventOutcome.info,
    description: 'Application started successfully',
    metadata: {
      'timestamp': DateTime.now().toIso8601String(),
    },
  );
  
  // Pre-initialize risk engine for faster route generation
  final riskEngine = RiskEngineService();
  riskEngine.initialize().catchError((error) {
    debugPrint('Warning: Could not initialize risk engine: $error');
    // Log initialization warning
    eventLogService.logEvent(
      type: EventType.appLaunched,
      outcome: EventOutcome.warning,
      description: 'Risk engine initialization failed',
    );
  });

  // Pre-initialize crime evidence dataset (B2)
  final crimeEvidence = CrimeEvidenceService();
  crimeEvidence.initialize().catchError((error) {
    debugPrint('Warning: Could not initialize crime evidence: $error');
  });

  // Pre-initialize safety guidance dataset (B3)
  final safetyGuidance = SafetyGuidanceService();
  safetyGuidance.initialize().catchError((error) {
    debugPrint('Warning: Could not initialize safety guidance: $error');
  });
  
  // Feature 2: Initialize Quick Action notification service BEFORE runApp so
  // that cold-launch notification details are captured first.
  await QuickActionNotificationService().init(
    onActionTap: handleQuickActionPayload,
  );

  // Connectivity — seed online state before first frame so the home screen
  // receives an accurate initial value without a flicker.
  await ConnectivityService().init();

  runApp(MyApp(storageService: storageService));
}

class MyApp extends StatelessWidget {
  final SecureStorageService storageService;
  
  const MyApp({super.key, required this.storageService});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SheSafe',
      debugShowCheckedModeBanner: false,
      navigatorKey: navigatorKey,
      navigatorObservers: [sosObserver],
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFFB07080),
          brightness: Brightness.light,
        ),
        useMaterial3: true,
        // ── Typography — scale with system text size, comfortable line heights
        textTheme: const TextTheme(
          displayLarge: TextStyle(fontSize: 32, fontWeight: FontWeight.w800, height: 1.15, letterSpacing: -0.8),
          headlineMedium: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, height: 1.25),
          titleLarge: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, height: 1.3),
          titleMedium: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, height: 1.35),
          bodyLarge: TextStyle(fontSize: 16, height: 1.5),
          bodyMedium: TextStyle(fontSize: 14, height: 1.5),
          bodySmall: TextStyle(fontSize: 12, height: 1.45, color: Color(0xFF616161)),
          labelLarge: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, letterSpacing: 0.1),
        ),
        appBarTheme: const AppBarTheme(
          centerTitle: true,
          elevation: 0,
          titleTextStyle: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w700,
            color: Color(0xFF1A1A1A),
          ),
        ),
        // ── Touch targets — ensure 48 × 48 minimum for all interactive elements
        visualDensity: VisualDensity.standard,
        materialTapTargetSize: MaterialTapTargetSize.padded,
        cardTheme: CardThemeData(
          elevation: 2,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            elevation: 2,
            minimumSize: const Size(64, 60),
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            minimumSize: const Size(64, 60),
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          ),
        ),
        textButtonTheme: TextButtonThemeData(
          style: TextButton.styleFrom(
            minimumSize: const Size(48, 48),
            textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          filled: true,
          fillColor: Colors.grey.shade50,
          // Ensure labels meet 4.5:1 contrast against background
          labelStyle: TextStyle(color: Colors.grey.shade700),
          hintStyle: TextStyle(color: Colors.grey.shade500),
          floatingLabelStyle: const TextStyle(color: Color(0xFFB07080)),
        ),
        // ── Tooltip style for map FAB accessibility
        tooltipTheme: TooltipThemeData(
          decoration: BoxDecoration(
            color: const Color(0xFF212121),
            borderRadius: BorderRadius.circular(8),
          ),
          textStyle: const TextStyle(color: Colors.white, fontSize: 12),
          waitDuration: const Duration(milliseconds: 500),
          showDuration: const Duration(milliseconds: 1500),
        ),
        // ── Icon button: ensure 48 px tap area
        iconButtonTheme: IconButtonThemeData(
          style: IconButton.styleFrom(minimumSize: const Size(48, 48)),
        ),
      ),
      home: _buildInitialScreen(),
      builder: (context, child) => SosOverlay(child: child!),
      routes: {
        '/onboarding': (context) => const OnboardingFlow(),
        '/home': (context) => const MapHomeScreen(),
        // Feature 2: named route so lock-screen notification actions can
        // navigate here directly via navigatorKey.
        '/panic': (context) => const PanicModeScreen(),
      },
    );
  }

  Widget _buildInitialScreen() {
    // Check if onboarding is completed
    final isCompleted = storageService.isOnboardingCompleted();
    
    if (isCompleted) {
      return const MapHomeScreen();
    } else {
      return const OnboardingFlow();
    }
  }
}

// ── Private helper extension ──────────────────────────────────────────────────
// Limits stack-trace strings logged to EventLogService so that the 500-event
// store is not flooded by a single oversized exception entry.
extension on String {
  static const _maxLogChars = 800;
  String truncateForLog() =>
      length > _maxLogChars ? '${substring(0, _maxLogChars)}…' : this;
}
