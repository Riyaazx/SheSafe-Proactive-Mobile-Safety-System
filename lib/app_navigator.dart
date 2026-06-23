import 'package:flutter/material.dart';

/// Global navigator key used by the persistent SOS overlay.
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

/// Controls SOS pill visibility. Updated by [sosObserver] on every route change.
/// Starts false (hidden) — becomes true when a non-excluded screen is on top.
final ValueNotifier<bool> showSosButton = ValueNotifier<bool>(false);

/// Set to true by PanicModeScreen.initState, cleared in dispose.
/// Provides a hard override so the SOS pill can never appear while
/// Panic Mode is alive, regardless of transient route events.
final ValueNotifier<bool> panicModeActive = ValueNotifier<bool>(false);

/// Broadcast channel for notification quick-action payloads.
/// Foreground: set by [handleQuickActionPayload] in quick_action_notification_service.
/// Background/cold-launch: consumed from SharedPreferences by MapHomeScreen.
/// MapHomeScreen listens to this and reacts without needing a navigator push.
final ValueNotifier<String> pendingNotificationAction = ValueNotifier<String>('');

/// Named routes where the SOS pill is suppressed.
///   '/panic' → PanicModeScreen (has its own SOS button)
const Set<String> _hiddenSosRoutes = {'/panic'};

/// Watches navigator push/pop events and drives [showSosButton].
///
/// Rule:
///   • Route name in [_hiddenSosRoutes]  → hide pill
///   • All other routes (named or anonymous) → show pill
///   • [PopupRoute] (dialogs, bottom‑sheets) → no change (inherit parent state)
class SosNavigatorObserver extends NavigatorObserver {
  void _update(Route<dynamic>? top) {
    if (top is PopupRoute) return; // dialogs don't change pill visibility
    final name = top?.settings.name;
    showSosButton.value = !_hiddenSosRoutes.contains(name);
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _update(route);

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _update(previousRoute);

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _update(previousRoute);

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) =>
      _update(newRoute);
}

/// Singleton observer — register in [MaterialApp.navigatorObservers].
final SosNavigatorObserver sosObserver = SosNavigatorObserver();
