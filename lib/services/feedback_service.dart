import 'dart:convert';
import 'dart:io';

import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Available feedback categories.
enum FeedbackCategory {
  bug,
  featureRequest,
  uiDesign,
  safetyAlert,
  other;

  /// Human-readable label shown in the UI.
  String get label => switch (this) {
        FeedbackCategory.bug => 'Bug',
        FeedbackCategory.featureRequest => 'Feature Request',
        FeedbackCategory.uiDesign => 'UI / Design',
        FeedbackCategory.safetyAlert => 'Safety Alert',
        FeedbackCategory.other => 'Other',
      };

  /// Stable string stored in SharedPreferences.
  String get key => name;

  static FeedbackCategory fromKey(String key) =>
      FeedbackCategory.values.firstWhere(
        (c) => c.key == key,
        orElse: () => FeedbackCategory.other,
      );
}

/// A single piece of user feedback.
class FeedbackEntry {
  final int rating;
  final String comment;
  final FeedbackCategory? category;
  final DateTime timestamp;
  final String appVersion;
  final String platform;
  final String screenName;

  const FeedbackEntry({
    required this.rating,
    required this.comment,
    required this.timestamp,
    required this.appVersion,
    required this.platform,
    this.category,
    this.screenName = '',
  });

  Map<String, dynamic> toJson() => {
        'rating': rating,
        'comment': comment,
        'category': category?.key,
        'timestamp': timestamp.toIso8601String(),
        'appVersion': appVersion,
        'platform': platform,
        'screenName': screenName,
      };

  factory FeedbackEntry.fromJson(Map<String, dynamic> m) => FeedbackEntry(
        rating: (m['rating'] as num).toInt(),
        comment: (m['comment'] as String?) ?? '',
        category: m['category'] == null
            ? null
            : FeedbackCategory.fromKey(m['category'] as String),
        timestamp: DateTime.parse(m['timestamp'] as String),
        appVersion: (m['appVersion'] as String?) ?? '',
        platform: (m['platform'] as String?) ?? '',
        screenName: (m['screenName'] as String?) ?? '',
      );
}

/// Thrown when the user attempts to submit feedback too quickly after a
/// previous submission (within [FeedbackService.dedupeWindow]).
class DuplicateFeedbackException implements Exception {
  const DuplicateFeedbackException();
  @override
  String toString() => 'Feedback already submitted recently.';
}

/// Persists feedback entries locally via SharedPreferences.
///
/// Storage layout:
///   Key `shesafe_feedback_entries`  → JSON-encoded list of [FeedbackEntry]
///   Key `shesafe_feedback_last_ts`  → ISO-8601 timestamp of last submission
///
/// No network calls are made. All data stays on-device.
class FeedbackService {
  // ── SharedPreferences keys ───────────────────────────────────────────────
  static const String _entriesKey = 'shesafe_feedback_entries';
  static const String _lastTsKey = 'shesafe_feedback_last_ts';

  // ── Configuration ────────────────────────────────────────────────────────

  /// Window in which a second submission is rejected as a duplicate.
  static const Duration dedupeWindow = Duration(seconds: 30);

  // ── Public API ───────────────────────────────────────────────────────────

  /// Reads the real app version from the OS via [PackageInfo].
  /// Falls back to `'unknown'` if the platform call fails.
  static Future<String> fetchAppVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      return info.version; // e.g. "1.0.0"
    } catch (_) {
      return 'unknown';
    }
  }

  /// Saves [entry] to SharedPreferences.
  ///
  /// Throws [DuplicateFeedbackException] if called within [dedupeWindow]
  /// of the previous submission.
  /// Throws [Exception] on any SharedPreferences I/O failure.
  Future<void> submit(FeedbackEntry entry) async {
    final prefs = await SharedPreferences.getInstance();

    // Duplicate-submission guard
    final lastRaw = prefs.getString(_lastTsKey);
    if (lastRaw != null) {
      final lastTime = DateTime.tryParse(lastRaw);
      if (lastTime != null &&
          entry.timestamp.difference(lastTime) < dedupeWindow) {
        throw const DuplicateFeedbackException();
      }
    }

    // Append new entry to the stored list
    final existing = prefs.getStringList(_entriesKey) ?? [];
    existing.add(jsonEncode(entry.toJson()));

    await prefs.setStringList(_entriesKey, existing);
    await prefs.setString(_lastTsKey, entry.timestamp.toIso8601String());
  }

  /// Returns the timestamp of the most recent submission, or null if never
  /// submitted.  Used by the debug screen to display a "Last saved" row.
  Future<DateTime?> getLastSubmittedTime() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_lastTsKey);
    return raw == null ? null : DateTime.tryParse(raw);
  }

  /// Returns all stored feedback entries, newest first.
  Future<List<FeedbackEntry>> getAll() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_entriesKey) ?? [];
    return raw
        .map((e) => FeedbackEntry.fromJson(
            jsonDecode(e) as Map<String, dynamic>))
        .toList()
        .reversed
        .toList();
  }

  // ── Export tracking & cleanup ────────────────────────────────────────────

  static const String _lastExportKey = 'shesafe_feedback_last_export';

  /// Records the current time as the last export timestamp.
  Future<void> recordExport() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_lastExportKey, DateTime.now().toIso8601String());
  }

  /// Returns the timestamp of the last export, or null if never exported.
  Future<DateTime?> getLastExportTime() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_lastExportKey);
    return raw == null ? null : DateTime.tryParse(raw);
  }

  /// Deletes all stored feedback entries and resets all timestamps.
  Future<void> clearAll() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_entriesKey);
    await prefs.remove(_lastTsKey);
    await prefs.remove(_lastExportKey);
  }

  // ── Helpers ──────────────────────────────────────────────────────────────

  /// Resolves the current platform name.
  static String get currentPlatform {
    if (Platform.isAndroid) return 'android';
    if (Platform.isIOS) return 'ios';
    return 'unknown';
  }
}
