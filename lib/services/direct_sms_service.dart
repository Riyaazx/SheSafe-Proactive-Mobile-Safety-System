import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

// =============================================================================
// DirectSmsService
// =============================================================================
//
// Sends SMS silently (no user interaction) via a Kotlin MethodChannel that
// calls Android's SmsManager.sendTextMessage().
//
// All sends are automatic — the SMS composer is never opened.
// SEND_SMS permission must be granted at runtime; if denied the send
// returns false and logs the failure.
//
// Usage:
//   await DirectSmsService().sendEmergency(phone: '+447911123456', message: 'Hi!');
// =============================================================================

class DirectSmsService {
  // ── Singleton ──────────────────────────────────────────────────────────────
  static final DirectSmsService _i = DirectSmsService._();
  factory DirectSmsService() => _i;
  DirectSmsService._();

  static const MethodChannel _channel =
      MethodChannel('com.shesafe.app/sms');

  // ── Public API ─────────────────────────────────────────────────────────────

  /// Send [message] to [phone] automatically (no user interaction).
  ///
  /// Delegates directly to [sendEmergency]. Returns `true` if the SMS
  /// was accepted by the native layer; `false` otherwise.
  Future<bool> send({
    required String phone,
    required String message,
  }) => sendEmergency(phone: phone, message: message);

  /// Emergency-only send — silent MethodChannel only, no SMS-app fallback.
  ///
  /// The Android-native layer is the authoritative permission check.
  /// Any PlatformException (including NO_PERMISSION) is logged so failures
  /// are always diagnosable in the debug console.
  /// Returns `true` only when Android's sendTextMessage() accepted the message
  /// without throwing an exception.
  Future<bool> sendEmergency({
    required String phone,
    required String message,
  }) async {
    if (phone.isEmpty || message.isEmpty) {
      debugPrint('❌ [SMS] sendEmergency: empty phone or message — skipping');
      return false;
    }
    debugPrint('📤 [SMS] sendEmergency → $phone (${message.length} chars)');
    try {
      // Use untyped invokeMethod to avoid any Dart<→Kotlin bool-coercion edge
      // case (e.g. Kotlin Boolean encoded as int on some Android versions).
      final dynamic rawResult = await _channel.invokeMethod(
        'sendSms',
        {'phone': phone, 'message': message},
      );
      final bool ok = rawResult == true;
      if (ok) {
        debugPrint('✅ [SMS] Accepted by radio → $phone');
      } else {
        debugPrint('⚠️ [SMS] Unexpected result ($rawResult) → $phone');
      }
      return ok;
    } on PlatformException catch (e) {
      // e.code will be "NO_PERMISSION", "SMS_FAILED", "INVALID_ARGS", etc.
      debugPrint('❌ [SMS] PlatformException [${e.code}]: ${e.message} → $phone');
      return false;
    } catch (e) {
      debugPrint('❌ [SMS] Unexpected Dart exception: $e → $phone');
      return false;
    }
  }

}
