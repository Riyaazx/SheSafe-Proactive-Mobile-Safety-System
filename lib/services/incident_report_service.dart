import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/incident_report.dart';

/// Persists [IncidentReport]s locally using SharedPreferences.
///
/// Reports are stored as a JSON-encoded list under a single key.
/// This keeps it simple (no DB dependency) while still allowing
/// full CRUD + export.
class IncidentReportService {
  // ── Singleton ─────────────────────────────────────────────────────────────
  static final IncidentReportService _instance =
      IncidentReportService._internal();
  factory IncidentReportService() => _instance;
  IncidentReportService._internal();

  static const String _storageKey = 'incident_reports';

  // ── In-memory cache ───────────────────────────────────────────────────────
  List<IncidentReport> _reports = [];
  bool _loaded = false;

  // ── Initialise ────────────────────────────────────────────────────────────
  Future<void> initialize() async {
    if (_loaded) return;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_storageKey);
    if (raw != null && raw.isNotEmpty) {
      final List<dynamic> decoded = jsonDecode(raw) as List<dynamic>;
      _reports = decoded
          .map((e) => IncidentReport.fromJson(e as Map<String, dynamic>))
          .toList();
    }
    _loaded = true;
  }

  // ── Read ──────────────────────────────────────────────────────────────────
  /// All saved reports, newest first.
  List<IncidentReport> get reports {
    final sorted = List<IncidentReport>.from(_reports);
    sorted.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return sorted;
  }

  int get count => _reports.length;

  // ── Create ────────────────────────────────────────────────────────────────
  Future<void> addReport(IncidentReport report) async {
    _reports.add(report);
    await _persist();
  }

  // ── Delete ────────────────────────────────────────────────────────────────
  Future<void> deleteReport(String id) async {
    _reports.removeWhere((r) => r.id == id);
    await _persist();
  }

  // ── Delete All ────────────────────────────────────────────────────────────
  Future<void> clearAll() async {
    _reports.clear();
    await _persist();
  }

  // ── Export ────────────────────────────────────────────────────────────────
  /// Returns a single text blob with all reports, suitable for sharing.
  String exportAllAsText() {
    if (_reports.isEmpty) return 'No incident reports on file.';
    final buf = StringBuffer();
    buf.writeln('SheSafe — Incident Report Export');
    buf.writeln('Generated: ${DateTime.now().toIso8601String()}');
    buf.writeln('Total reports: ${_reports.length}');
    buf.writeln('');
    for (final r in reports) {
      buf.writeln(r.toShareText());
      buf.writeln('');
    }
    return buf.toString();
  }

  // ── Internal persistence ─────────────────────────────────────────────────
  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    final encoded = jsonEncode(_reports.map((r) => r.toJson()).toList());
    await prefs.setString(_storageKey, encoded);
  }
}
