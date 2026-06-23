// test/widgets/fake_call_screen_test.dart
//
// Widget tests for [FakeCallScreen].  Plugin channels used by audio (audioplayers,
// flutter_tts) and system-UI calls are replaced with no-op stubs so the tests
// run entirely in the host VM without hardware or platform services.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shesafe/features/home/fake_call_screen.dart';

// ── Minimal plugin stubs ──────────────────────────────────────────────────────

void _stubAudioChannels() {
  // audioplayers
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('xyz.luan/audioplayers'),
    (_) async => 1,
  );
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('xyz.luan/audioplayers/events'),
    (_) async => null,
  );
  // flutter_tts
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('flutter_tts'),
    (_) async => 1,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(_stubAudioChannels);

  Widget buildSubject({String? name, String? number}) => MaterialApp(
        home: FakeCallScreen(
          callerName: name ?? 'Test Caller',
          callerNumber: number ?? '+44 7911 000000',
        ),
      );

  // ─────────────────────────────────────────────────────────────────────────
  // Rendering
  // ─────────────────────────────────────────────────────────────────────────

  group('FakeCallScreen rendering — ringing phase', () {
    testWidgets('builds without throwing', (tester) async {
      await tester.pumpWidget(buildSubject());
      await tester.pump();
      expect(find.byType(Scaffold), findsOneWidget);
    });

    testWidgets('caller name is visible', (tester) async {
      await tester.pumpWidget(buildSubject(name: 'Mum 📞'));
      await tester.pump();
      expect(find.text('Mum 📞'), findsOneWidget);
    });

    testWidgets('caller number is visible', (tester) async {
      await tester.pumpWidget(buildSubject(number: '+44 7700 900001'));
      await tester.pump();
      expect(find.text('+44 7700 900001'), findsOneWidget);
    });

    testWidgets('Accept and Decline buttons are shown', (tester) async {
      await tester.pumpWidget(buildSubject());
      await tester.pump();
      expect(find.text('Accept'), findsOneWidget);
      expect(find.text('Decline'), findsOneWidget);
    });

    testWidgets('"Incoming call…" indicator is shown', (tester) async {
      await tester.pumpWidget(buildSubject());
      await tester.pump();
      expect(find.textContaining('Incoming call'), findsOneWidget);
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // Accepting the call
  // ─────────────────────────────────────────────────────────────────────────

  group('FakeCallScreen — accepting the call', () {
    testWidgets('Accept tap transitions to in-call phase (hides Decline button)',
        (tester) async {
      await tester.pumpWidget(buildSubject());
      await tester.pump();

      await tester.tap(find.text('Accept'));
      await tester.pump(); // synchronous setState
      await tester.pump(const Duration(milliseconds: 100));

      // After accepting, the Decline button should no longer be visible.
      expect(find.text('Decline'), findsNothing);
    });

    testWidgets('elapsed timer label appears in in-call phase', (tester) async {
      await tester.pumpWidget(buildSubject(name: 'Mum 📞'));
      await tester.pump();
      await tester.tap(find.text('Accept'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // Caller name stays visible in-call
      expect(find.text('Mum 📞'), findsOneWidget);
      // Elapsed timer is reset to '00:00'
      expect(find.text('00:00'), findsOneWidget);
    });

    testWidgets('Speaker toggle button appears in-call', (tester) async {
      await tester.pumpWidget(buildSubject());
      await tester.pump();
      await tester.tap(find.text('Accept'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.textContaining('Speaker'), findsOneWidget);
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // Default caller values
  // ─────────────────────────────────────────────────────────────────────────

  group('FakeCallScreen default parameter values', () {
    testWidgets('default caller name is "Twin sissy 💕"', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: FakeCallScreen()));
      await tester.pump();
      expect(find.text('Twin sissy 💕'), findsOneWidget);
    });

    testWidgets('default number contains +44', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: FakeCallScreen()));
      await tester.pump();
      expect(find.textContaining('+44'), findsOneWidget);
    });
  });
}
