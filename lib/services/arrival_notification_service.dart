import '../services/secure_storage_service.dart';
import '../services/event_log_service.dart';
import '../services/direct_sms_service.dart';
import '../models/event_log.dart';

// =============================================================================
// ArrivalNotificationService
// =============================================================================
//
// Sends an "arrived safely" SMS to the user's trusted contacts when the
// navigation in the Safest Route feature completes.
//
// Integration:
//   SafeRouteScreen holds a toggle ("Notify my Trusted Contact when I arrive
//   safely").  When the user taps "Complete" on the final navigation step and
//   the toggle is ON, this service:
//     1. Loads trusted contacts from encrypted secure storage.
//     2. Builds a short, friendly SMS body.
//     3. Sends via DirectSmsService.sendEmergency() — native Android SmsManager.
//     4. Logs the outcome to EventLogService for audit purposes.
//
// Design notes:
//   • The SMS is sent silently via native SmsManager (no UI prompt).
//     This ensures delivery without user intervention and handles multipart
//     SMS automatically for longer messages.
//   • If no trusted contacts exist the service returns gracefully without
//     attempting to launch SMS.
//   • The service is intentionally stateless (no timers, no listeners) to
//     keep battery & memory impact at zero unless actually invoked.
// =============================================================================

class ArrivalNotificationService {
  // ---------------------------------------------------------------------------
  // Singleton
  // ---------------------------------------------------------------------------
  static final ArrivalNotificationService _instance =
      ArrivalNotificationService._internal();
  factory ArrivalNotificationService() => _instance;
  ArrivalNotificationService._internal();

  final SecureStorageService _storage = SecureStorageService();
  final EventLogService _eventLog = EventLogService();

  // ---------------------------------------------------------------------------
  // Configuration
  // ---------------------------------------------------------------------------

  /// The radius (in metres) within which the user is considered to have
  /// "arrived" at the destination.  50 m accounts for GPS drift on most
  /// consumer-grade phones.
  static const double arrivalRadiusMetres = 50.0;

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  /// Builds the arrival SMS body.
  ///
  /// [destination] is the address or label the user searched for.
  /// [userName]    is an optional display name; falls back to "I".
  String buildArrivalSmsBody({
    required String destination,
    String? userName,
  }) {
    final trimmed = userName?.trim();
    final subject =
        (trimmed == null || trimmed.isEmpty) ? 'I have' : '$trimmed has';
    return '✅ $subject safely arrived at 📍 $destination (Sent via SheSafe)';
  }

  /// Returns the list of trusted contacts as maps with 'name', 'phone',
  /// 'id', etc.  Used by the UI to show a contact picker with names.
  Future<List<Map<String, dynamic>>> getTrustedContacts() async {
    return await _storage.getTrustedContacts();
  }

  /// Sends an "arrived safely" SMS to a SINGLE trusted contact.
  ///
  /// Each contact gets its own SMS intent so messages are individual,
  /// not a group text.
  ///
  /// Returns `true` if the SMS intent was launched successfully.
  Future<bool> sendToSingleContact({
    required String phone,
    required String contactName,
    required String destination,
    String? userName,
  }) async {
    final body = buildArrivalSmsBody(
      destination: destination,
      userName: userName,
    );

    // Send silently via native SmsManager — no SMS composer opened.
    final launched = await DirectSmsService().sendEmergency(phone: phone, message: body);

    _log(
      outcome: launched ? EventOutcome.success : EventOutcome.failure,
      description: launched
          ? 'Arrival SMS sent to $contactName'
          : 'Arrival SMS failed for $contactName.',
      metadata: {
        'destination': destination,
        'contactName': contactName,
        'phone': phone,
        'launched': launched,
      },
    );

    return launched;
  }

  /// Sends an "arrived safely" SMS to every trusted contact that has a phone
  /// number on file.  Each contact receives a separate individual SMS.
  ///
  /// Returns `true` if the SMS intent was launched for at least one contact,
  /// `false` otherwise (no contacts, no phone numbers, or launch failure).
  Future<bool> sendArrivalNotification({
    required String destination,
    String? userName,
    List<Map<String, dynamic>>? selectedContacts,
  }) async {
    // 1. Load trusted contacts (or use pre-selected list)
    final contacts = selectedContacts ?? await _storage.getTrustedContacts();
    if (contacts.isEmpty) {
      _log(
        outcome: EventOutcome.warning,
        description:
            'Arrival notification skipped – no trusted contacts configured.',
      );
      return false;
    }

    // 2. Send individual SMS to each contact
    int successCount = 0;
    final contactNames = <String>[];

    for (final contact in contacts) {
      final phone = contact['phone'] as String?;
      final name = contact['name'] as String? ?? 'Unknown';
      if (phone == null || phone.trim().isEmpty) continue;

      contactNames.add(name);
      final ok = await sendToSingleContact(
        phone: phone,
        contactName: name,
        destination: destination,
        userName: userName,
      );
      if (ok) successCount++;
    }

    final launched = successCount > 0;

    _log(
      outcome: launched ? EventOutcome.success : EventOutcome.failure,
      description: launched
          ? 'Arrival notification sent to $successCount contact(s): ${contactNames.join(", ")}'
          : 'Arrival notification failed – could not launch any SMS intent.',
      metadata: {
        'destination': destination,
        'contactCount': contacts.length,
        'successCount': successCount,
        'contactNames': contactNames,
      },
    );

    return launched;
  }

  // ---------------------------------------------------------------------------
  // Internal
  // ---------------------------------------------------------------------------

  void _log({
    required EventOutcome outcome,
    required String description,
    Map<String, dynamic>? metadata,
  }) {
    _eventLog.logEvent(
      type: EventType.arrivalNotificationSent,
      outcome: outcome,
      description: description,
      metadata: metadata,
    );
  }
}
