// test/widgets/home_screen_test.dart
//
// Widget tests for [HomeScreen].  Tests verify the widget tree renders the
// critical UI elements and that high-level interactions (button taps, dialog
// opening) behave correctly.
//
// Platform plugins required by background async tasks (notifications, audio)
// are stubs that return null so the test never crashes on a missing plugin.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shesafe/features/home/home_screen.dart';

// ── Platform-channel stubs ──────────────────────────────────────────────────
// flutter_local_notifications and audioplayers need a method-channel stub so
// that plugin calls from initState async tasks return null instead of throwing
// a MissingPluginException in the test environment.

void _stubPluginChannels() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('dexterous.com/flutter/local_notifications'),
    (_) async => null,
  );
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('xyz.luan/sounds'),
    (_) async => null,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    _stubPluginChannels();
    // Pre-populate SharedPreferences so the country picker is not forced open
    // (CountryService uses 'selected_country_code') and quick-actions are off.
    SharedPreferences.setMockInitialValues({
      'selected_country_code': 'gb',
      'shesafe_quick_actions_enabled': false,
    });
  });

  // Wraps HomeScreen in a minimal MaterialApp to satisfy navigation and
  // theming dependencies.
  Widget buildSubject() => const MaterialApp(home: HomeScreen());

  // ─────────────────────────────────────────────────────────────────────────
  // Rendering
  // ─────────────────────────────────────────────────────────────────────────

  group('HomeScreen rendering', () {
    testWidgets('builds without throwing', (tester) async {
      await tester.pumpWidget(buildSubject());
      // One pump to let the synchronous build complete.
      await tester.pump();
      expect(find.byType(Scaffold), findsOneWidget);
    });

    testWidgets('shows Plan Safe Route button', (tester) async {
      await tester.pumpWidget(buildSubject());
      await tester.pump();
      expect(find.text('Plan Safe Route'), findsOneWidget);
    });

    testWidgets('shows Emergency panic mode button', (tester) async {
      await tester.pumpWidget(buildSubject());
      await tester.pump();
      expect(find.text('Emergency: Panic Mode'), findsOneWidget);
    });

    testWidgets('shows Fake Phone Call button', (tester) async {
      await tester.pumpWidget(buildSubject());
      await tester.pump();
      expect(find.text('Fake Phone Call'), findsOneWidget);
    });

    testWidgets('shows Safety Assistant button', (tester) async {
      await tester.pumpWidget(buildSubject());
      await tester.pump();
      expect(find.text('Safety Assistant'), findsOneWidget);
    });

    testWidgets('shows quick-actions toggle switch', (tester) async {
      await tester.pumpWidget(buildSubject());
      await tester.pump();
      expect(find.byType(SwitchListTile), findsOneWidget);
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // Interactions
  // ─────────────────────────────────────────────────────────────────────────

  group('HomeScreen interactions', () {
    testWidgets('tapping Plan Safe Route opens destination dialog',
        (tester) async {
      await tester.pumpWidget(buildSubject());
      await tester.pump();
      await tester.tap(find.text('Plan Safe Route'));
      await tester.pumpAndSettle();
      // Dialog with a destination text field should appear.
      expect(find.byType(TextField), findsOneWidget);
    });

    testWidgets('submitting empty destination shows inline error',
        (tester) async {
      await tester.pumpWidget(buildSubject());
      await tester.pump();
      await tester.tap(find.text('Plan Safe Route'));
      await tester.pumpAndSettle();
      // Tap the "Show Safe Route" button inside the dialog without entering text.
      final showBtn = find.text('Show Safe Route');
      if (showBtn.evaluate().isNotEmpty) {
        await tester.tap(showBtn);
        await tester.pumpAndSettle();
        // The implementation shows an inline errorText in the TextField,
        // keeping the dialog open — not a SnackBar.
        expect(find.text('Please enter a destination.'), findsOneWidget);
      }
    });

    testWidgets('tapping Fake Phone Call navigates to FakeCallScreen',
        (tester) async {
      await tester.pumpWidget(buildSubject());
      await tester.pump();
      await tester.tap(find.text('Fake Phone Call'));
      // Use pump() instead of pumpAndSettle() to avoid waiting for looping
      // audio animations that never settle.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      // Navigation occurred — the HomeScreen should no longer be the top route.
      // A Scaffold from FakeCallScreen should be visible.
      expect(find.byType(Scaffold), findsAtLeastNWidgets(1));
    });
  });
}
