import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/event_log.dart';

/// Service for logging and managing app events
class EventLogService {
  static final EventLogService _instance = EventLogService._internal();
  factory EventLogService() => _instance;
  EventLogService._internal();

  SharedPreferences? _prefs;
  static const String _eventLogsKey = 'event_logs';
  static const int _maxEvents = 500; // Limit to prevent excessive storage

  /// Initialize the service
  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
  }

  /// Log a new event
  Future<void> logEvent({
    required EventType type,
    required EventOutcome outcome,
    required String description,
    Map<String, dynamic>? metadata,
  }) async {
    try {
      if (_prefs == null) {
        await init();
      }

      final event = EventLog(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        timestamp: DateTime.now(),
        type: type,
        outcome: outcome,
        description: description,
        metadata: metadata,
      );

      final events = await getAllEvents();
      events.insert(0, event); // Add to beginning (most recent first)

      // Limit the number of stored events
      if (events.length > _maxEvents) {
        events.removeRange(_maxEvents, events.length);
      }

      await _saveEvents(events);
    } catch (e) {
      debugPrint('Error logging event: $e');
    }
  }

  /// Get all logged events
  Future<List<EventLog>> getAllEvents() async {
    try {
      if (_prefs == null) {
        await init();
      }

      final eventsJson = _prefs?.getString(_eventLogsKey);
      if (eventsJson == null) return [];

      final List<dynamic> decoded = jsonDecode(eventsJson);
      return decoded.map((json) => EventLog.fromJson(json)).toList();
    } catch (e) {
      debugPrint('Error getting events: $e');
      return [];
    }
  }

  /// Get events filtered by type
  Future<List<EventLog>> getEventsByType(EventType type) async {
    final events = await getAllEvents();
    return events.where((event) => event.type == type).toList();
  }

  /// Get events filtered by outcome
  Future<List<EventLog>> getEventsByOutcome(EventOutcome outcome) async {
    final events = await getAllEvents();
    return events.where((event) => event.outcome == outcome).toList();
  }

  /// Get events within a date range
  Future<List<EventLog>> getEventsByDateRange({
    required DateTime start,
    required DateTime end,
  }) async {
    final events = await getAllEvents();
    return events.where((event) {
      return event.timestamp.isAfter(start) && event.timestamp.isBefore(end);
    }).toList();
  }

  /// Get events from the last N days
  Future<List<EventLog>> getRecentEvents(int days) async {
    final cutoff = DateTime.now().subtract(Duration(days: days));
    final events = await getAllEvents();
    return events.where((event) => event.timestamp.isAfter(cutoff)).toList();
  }

  /// Get the most recent event, or null if no events have been logged.
  Future<EventLog?> getLatestEvent() async {
    final events = await getAllEvents();
    return events.isEmpty ? null : events.first;
  }

  /// Clear all events
  Future<void> clearAllEvents() async {
    if (_prefs == null) {
      await init();
    }
    await _prefs?.remove(_eventLogsKey);
  }

  /// Export events to a formatted string (for sharing/reports)
  Future<String> exportEvents({
    DateTime? startDate,
    DateTime? endDate,
    List<EventType>? filterTypes,
  }) async {
    var events = await getAllEvents();

    // Apply filters
    if (startDate != null) {
      events = events.where((e) => e.timestamp.isAfter(startDate)).toList();
    }
    if (endDate != null) {
      events = events.where((e) => e.timestamp.isBefore(endDate)).toList();
    }
    if (filterTypes != null && filterTypes.isNotEmpty) {
      events = events.where((e) => filterTypes.contains(e.type)).toList();
    }

    // Format as readable text
    final buffer = StringBuffer();
    buffer.writeln('SheSafe - Event History Report');
    buffer.writeln('Generated: ${DateTime.now().toString()}');
    buffer.writeln('Total Events: ${events.length}');
    buffer.writeln('${'=' * 50}\n');

    for (final event in events) {
      buffer.writeln('Event: ${event.typeName}');
      buffer.writeln('Time: ${_formatDateTime(event.timestamp)}');
      buffer.writeln('Status: ${event.outcomeLabel}');
      buffer.writeln('Details: ${event.description}');
      
      if (event.metadata != null && event.metadata!.isNotEmpty) {
        buffer.writeln('Additional Info:');
        event.metadata!.forEach((key, value) {
          // Only include non-sensitive metadata
          if (!_isSensitiveKey(key)) {
            buffer.writeln('  - $key: $value');
          }
        });
      }
      
      buffer.writeln('${'-' * 50}\n');
    }

    return buffer.toString();
  }

  /// Export events as JSON
  Future<String> exportEventsAsJson({
    DateTime? startDate,
    DateTime? endDate,
    List<EventType>? filterTypes,
  }) async {
    var events = await getAllEvents();

    // Apply filters
    if (startDate != null) {
      events = events.where((e) => e.timestamp.isAfter(startDate)).toList();
    }
    if (endDate != null) {
      events = events.where((e) => e.timestamp.isBefore(endDate)).toList();
    }
    if (filterTypes != null && filterTypes.isNotEmpty) {
      events = events.where((e) => filterTypes.contains(e.type)).toList();
    }

    final data = {
      'generatedAt': DateTime.now().toIso8601String(),
      'totalEvents': events.length,
      'events': events.map((e) {
        final json = e.toJson();
        // Remove sensitive metadata
        if (json['metadata'] != null) {
          final metadata = json['metadata'] as Map<String, dynamic>;
          metadata.removeWhere((key, value) => _isSensitiveKey(key));
        }
        return json;
      }).toList(),
    };

    return jsonEncode(data);
  }

  /// Get event statistics
  Future<Map<String, dynamic>> getStatistics() async {
    final events = await getAllEvents();
    final now = DateTime.now();
    final last7Days = now.subtract(const Duration(days: 7));
    final last30Days = now.subtract(const Duration(days: 30));

    final recentEvents = events.where((e) => e.timestamp.isAfter(last7Days)).toList();
    final monthlyEvents = events.where((e) => e.timestamp.isAfter(last30Days)).toList();

    // Count by type
    final typeCount = <EventType, int>{};
    for (final event in events) {
      typeCount[event.type] = (typeCount[event.type] ?? 0) + 1;
    }

    // Count by outcome
    final outcomeCount = <EventOutcome, int>{};
    for (final event in events) {
      outcomeCount[event.outcome] = (outcomeCount[event.outcome] ?? 0) + 1;
    }

    return {
      'totalEvents': events.length,
      'last7Days': recentEvents.length,
      'last30Days': monthlyEvents.length,
      'byType': typeCount,
      'byOutcome': outcomeCount,
      'mostRecentEvent': events.isNotEmpty ? events.first.timestamp : null,
    };
  }

  // Private helper methods

  Future<void> _saveEvents(List<EventLog> events) async {
    final eventsJson = jsonEncode(events.map((e) => e.toJson()).toList());
    await _prefs?.setString(_eventLogsKey, eventsJson);
  }

  String _formatDateTime(DateTime dt) {
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} '
        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }

  bool _isSensitiveKey(String key) {
    const sensitiveKeys = [
      'location',
      'coordinates',
      'latitude',
      'longitude',
      'address',
      'phone',
      'contact',
      'password',
      'token',
    ];
    return sensitiveKeys.any((sensitive) => 
      key.toLowerCase().contains(sensitive));
  }
}
