import 'package:flutter/material.dart' show Color;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../app_navigator.dart';

/// SharedPreferences key used to pass a pending navigation from the
/// background isolate (where navigatorKey is unavailable) to the main isolate.
const String kPendingNavAction = 'shesafe_pending_nav_action';

// =============================================================================
// QuickActionNotificationService — Feature 2: Lock-Screen / Quick Action
// =============================================================================
//
// Shows a persistent, high-priority notification in the notification bar **and**
// on the lock screen so the user can trigger Panic Mode or Safe Word Listener
// without unlocking the phone first.
//
// Android: notification action buttons appear on the lock screen when
//   NotificationVisibility.public is set — no swipe-to-unlock needed.
//
// How it works:
//   1. The user toggles "Quick Safety Actions" on the home screen.
//   2. This service posts a persistent (ongoing) notification with two buttons:
//        • 🚨 Panic Mode   → navigates to PanicModeScreen
//        • 🎙️ Safe Word   → starts SilentSafeWordService in the background
//   3. The notification remains until the user toggles it off, or the app
//      is killed.  It is re-shown automatically on app launch if the pref is ON.
//   4. Action taps are handled via [onDidReceiveNotificationResponse] in main.dart,
//      which uses [navigatorKey] to push the correct screen.
//
// Notification IDs:
//   999 — the persistent safety-actions notification.
//
// Action payload strings (used in main.dart for routing):
//   'quick_panic'    → open PanicModeScreen
//   'quick_safeword' → open PanicModeScreen (the screen handles safe-word mode)
// =============================================================================

class QuickActionNotificationService {
  // ── Singleton ──────────────────────────────────────────────────────────────
  static final QuickActionNotificationService _instance =
      QuickActionNotificationService._internal();
  factory QuickActionNotificationService() => _instance;
  QuickActionNotificationService._internal();

  static const int _notificationId = 999;
  static const String _channelId = 'shesafe_quick_actions';

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  bool _initialised = false;

  // ── Initialisation ─────────────────────────────────────────────────────────

  /// Call once from main() / app initialisation.
  ///
  /// [onActionTap] receives the action payload string when the user taps one
  /// of the notification buttons.  Wire this up to your route handler.
  Future<void> init({
    void Function(String payload)? onActionTap,
  }) async {
    if (_initialised) return;
    _initialised = true;

    const androidSettings =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosSettings = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );

    await _plugin.initialize(
      const InitializationSettings(
          android: androidSettings, iOS: iosSettings),
      onDidReceiveNotificationResponse: (details) {
        // actionId is set when an ACTION BUTTON is tapped (e.g. 'quick_panic').
        // payload is the notification body payload ('safety_notification').
        // Always prefer actionId so action buttons route correctly.
        final payload = details.actionId ?? details.payload ?? '';
        if (payload.isNotEmpty) onActionTap?.call(payload);
      },
      // Background handler: called when the app is backgrounded/locked and
      // the user taps a notification action button.  MUST be top-level.
      onDidReceiveBackgroundNotificationResponse: onBackgroundNotificationTap,
    );

    // Cold-launch: if the app was killed and started by tapping a notification
    // action, the response arrives via getNotificationAppLaunchDetails().
    final launchDetails = await _plugin.getNotificationAppLaunchDetails();
    if (launchDetails != null &&
        launchDetails.didNotificationLaunchApp &&
        launchDetails.notificationResponse != null) {
      final r = launchDetails.notificationResponse!;
      final payload = r.actionId ?? r.payload ?? '';
      if (payload.isNotEmpty) onActionTap?.call(payload);
    }
  }

  // ── Public API ─────────────────────────────────────────────────────────────

  /// Post (or refresh) the persistent safety notification.
  /// When [safeWordActive] is true the Safe Word button label changes to
  /// indicate that background voice monitoring is currently running.
  Future<void> showSafetyNotification({bool safeWordActive = false}) async {
    final bodyText = 'Safety Mode · Panic Mode';

    final androidDetails = AndroidNotificationDetails(
      _channelId,
      'Quick Safety Actions',
      channelDescription:
          'Lock-screen shortcut buttons for Safety Mode and Panic Mode',
      importance: Importance.max,
      priority: Priority.max,
      ongoing: true,           // persistent — cannot be swiped away
      autoCancel: false,
      visibility: NotificationVisibility.public, // show on lock screen
      showWhen: false,
      ticker: 'SheSafe safety shortcuts active',
      color: const Color(0xFF1A6B4A),
      actions: [
        const AndroidNotificationAction(
          'quick_safety_mode',
          'Safety Mode',
          showsUserInterface: true,
          cancelNotification: false,
        ),
        const AndroidNotificationAction(
          'quick_panic',
          'Panic Mode',
          showsUserInterface: true,
          cancelNotification: false,
        ),
      ],
    );

    await _plugin.show(
      _notificationId,
      'SheSafe — Quick Safety Access',
      bodyText,
      NotificationDetails(android: androidDetails),
      payload: 'safety_notification',
    );
  }

  /// Dismiss the persistent notification (user disabled Quick Actions).
  Future<void> dismissSafetyNotification() async {
    await _plugin.cancel(_notificationId);
  }

  /// Post a high-priority alert notification visible even when the user is
  /// in another app (e.g. when Safety Mode escalation triggers in background).
  Future<void> showAlertNotification({
    required String title,
    required String body,
  }) async {
    const androidDetails = AndroidNotificationDetails(
      'shesafe_safety_alerts',
      'Safety Alerts',
      channelDescription: 'Urgent safety alerts from SheSafe',
      importance: Importance.max,
      priority: Priority.max,
      fullScreenIntent: true,
      category: AndroidNotificationCategory.alarm,
      visibility: NotificationVisibility.public,
      autoCancel: true,
      color: Color(0xFFB07080),
    );
    await _plugin.show(
      997,
      title,
      body,
      const NotificationDetails(android: androidDetails),
      payload: 'safety_alert',
    );
  }
}

/// Handles a notification action payload from the notification bar.
/// Called from [main.dart] inside [onDidReceiveNotificationResponse].
/// Persists for background/cold-launch AND signals via ValueNotifier for
/// in-app (foreground) delivery.
void handleQuickActionPayload(String payload) {
  if (payload != 'quick_panic' && payload != 'quick_safety_mode') return;
  // Persist for background/cold-launch path (MapHomeScreen reads this on resume)
  SharedPreferences.getInstance().then((prefs) {
    prefs.setString(kPendingNavAction, payload);
  });
  // Signal directly to MapHomeScreen via ValueNotifier (foreground path)
  pendingNotificationAction.value = payload;

  // For quick Safety Mode, explicitly bring the app to home so the action
  // always starts from the map control screen before monitoring begins.
  if (payload == 'quick_safety_mode') {
    _navigateHomeWhenReady();
  }
}

/// Background notification tap handler — MUST be a top-level function and
/// annotated with @pragma('vm:entry-point') so the Dart VM keeps it alive
/// in the background isolate when the app is killed or backgrounded.
///
/// IMPORTANT: this runs in a SEPARATE Dart isolate — navigatorKey.currentState
/// is null here. Instead we persist the intent to SharedPreferences so that
/// MapHomeScreen picks it up when it resumes to the foreground.
@pragma('vm:entry-point')
void onBackgroundNotificationTap(NotificationResponse details) {
  final payload = details.actionId ?? details.payload ?? '';
  if (payload != 'quick_panic' && payload != 'quick_safety_mode') return;
  // Store intent — MapHomeScreen reads this on resume and navigates.
  SharedPreferences.getInstance().then((prefs) {
    prefs.setString(kPendingNavAction, payload);
  });
}

/// Retries navigation to Panic Mode until the navigator is mounted.
/// Only used for the cold-launch quick_panic path via SharedPreferences
/// (handled in MapHomeScreen._checkPendingNavigation for warm launches).
// ignore: unused_element
void _navigateWhenReady([int attempt = 0]) {
  final nav = navigatorKey.currentState;
  if (nav != null) {
    nav.pushNamed('/panic');
    return;
  }
  if (attempt < 20) {
    Future.delayed(const Duration(milliseconds: 100),
        () => _navigateWhenReady(attempt + 1));
  }
}

/// Retries navigation to Home until the navigator is mounted.
/// Used by quick_safety_mode so the shortcut always opens the map home
/// surface before MapHomeScreen activates Safety Mode.
void _navigateHomeWhenReady([int attempt = 0]) {
  final nav = navigatorKey.currentState;
  if (nav != null) {
    nav.pushNamedAndRemoveUntil('/home', (route) => false);
    return;
  }
  if (attempt < 20) {
    Future.delayed(
      const Duration(milliseconds: 100),
      () => _navigateHomeWhenReady(attempt + 1),
    );
  }
}
