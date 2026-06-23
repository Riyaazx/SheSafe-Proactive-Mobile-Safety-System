import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../models/event_log.dart';
import '../../models/motion_baseline.dart';
import '../../services/event_log_service.dart';
import '../../services/feedback_service.dart';
import '../../services/motion_baseline_service.dart';

/// Hidden admin/debug screen — accessible only via the 5-tap version trigger.
/// Displays live system state for viva demonstration. Lightweight, text-only.
class DebugEvaluationScreen extends StatefulWidget {
  const DebugEvaluationScreen({super.key});

  @override
  State<DebugEvaluationScreen> createState() => _DebugEvaluationScreenState();
}

class _DebugEvaluationScreenState extends State<DebugEvaluationScreen> {
  final _motionService = MotionBaselineService();
  final _eventLogService = EventLogService();
  final _feedbackService = FeedbackService();

  // --- Motion state ---
  double? _anomalyScore;
  int _consecutiveAnomalies = 0;
  StreamSubscription<AnomalyResult>? _anomalySub;

  // --- GPS state ---
  double? _gpsAccuracy;
  bool _gpsActive = false;
  bool _gpsError = false;
  StreamSubscription<Position>? _gpsSub;

  // --- Last event ---
  EventLog? _latestEvent;
  bool _eventLoading = true;

  // --- Feedback stats ---
  int _feedbackCount = 0;
  DateTime? _feedbackLastSaved;
  DateTime? _feedbackLastExport;

  @override
  void initState() {
    super.initState();
    _subscribeToMotion();
    _subscribeToGps();
    _loadLatestEvent();
    _loadFeedbackStats();
  }

  void _subscribeToMotion() {
    _anomalySub = _motionService.anomalyResultStream.listen((result) {
      if (!mounted) return;
      setState(() {
        _anomalyScore = result.score;
        _consecutiveAnomalies = _motionService.consecutiveAnomalyWindows;
      });
    });
    // Show any already-available last result immediately
    final last = _motionService.lastAnomalyResult;
    if (last != null) {
      _anomalyScore = last.score;
      _consecutiveAnomalies = _motionService.consecutiveAnomalyWindows;
    }
  }

  void _subscribeToGps() {
    try {
      _gpsSub = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 0,
        ),
      ).listen(
        (pos) {
          if (!mounted) return;
          setState(() {
            _gpsAccuracy = pos.accuracy;
            _gpsActive = true;
          });
        },
        onError: (_) {
          if (!mounted) return;
          setState(() {
            _gpsActive = false;
            _gpsError = true;
          });
        },
      );
    } catch (_) {
      // Permission not granted or service unavailable — show fallback.
    }
  }

  Future<void> _loadLatestEvent() async {
    final event = await _eventLogService.getLatestEvent();
    if (!mounted) return;
    setState(() {
      _latestEvent = event;
      _eventLoading = false;
    });
  }

  Future<void> _loadFeedbackStats() async {
    final entries = await _feedbackService.getAll();
    final lastSaved = await _feedbackService.getLastSubmittedTime();
    final lastExport = await _feedbackService.getLastExportTime();
    if (!mounted) return;
    setState(() {
      _feedbackCount = entries.length;
      _feedbackLastSaved = lastSaved;
      _feedbackLastExport = lastExport;
    });
  }

  @override
  void dispose() {
    _anomalySub?.cancel();
    _gpsSub?.cancel();
    super.dispose();
  }

  // Formats a DateTime as HH:mm:ss
  String _hhmmss(DateTime dt) {
    final h = dt.hour.toString().padLeft(2, '0');
    final m = dt.minute.toString().padLeft(2, '0');
    final s = dt.second.toString().padLeft(2, '0');
    return '$h:$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final threshold = MotionBaseline.anomalyPersistenceThreshold;

    return Scaffold(
      backgroundColor: const Color(0xFFFFF0F5),
      appBar: AppBar(
        backgroundColor: Colors.white,
        foregroundColor: const Color(0xFF1A1A1A),
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        title: const Text(
          'Live System Diagnostics',
          style: TextStyle(fontWeight: FontWeight.w700, fontSize: 18),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          _buildInfoBanner(),
          const SizedBox(height: 16),
          _buildMotionCard(threshold),
          const SizedBox(height: 12),
          _buildGpsCard(),
          const SizedBox(height: 12),
          _buildEventCard(),
          const SizedBox(height: 12),
          _buildFeedbackExportCard(),
        ],
      ),
    );
  }

  // ── Info banner ──────────────────────────────────────────────────────────

  Widget _buildInfoBanner() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFFFDE8F0),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFF0B8CF)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.sensors, size: 16, color: Color(0xFFB07080)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Live data from production services — not mock values. '
              'Motion scores update during an active walk session.',
              style: TextStyle(
                fontSize: 12,
                color: Colors.pink.shade900,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Section card helper ──────────────────────────────────────────────────

  Widget _buildSectionCard({
    required IconData icon,
    required String title,
    required List<Widget> rows,
  }) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxHeight = MediaQuery.of(context).size.height * 0.85;
        return Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.04),
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: maxHeight,
            ),
            child: SingleChildScrollView(
              padding: EdgeInsets.zero,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
                    child: Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(6),
                          decoration: BoxDecoration(
                            color: const Color(0xFFFDE8F0),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Icon(icon, size: 16, color: const Color(0xFFB07080)),
                        ),
                        const SizedBox(width: 10),
                        Text(
                          title,
                          style: const TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w700,
                            color: Color(0xFF1A1A1A),
                            letterSpacing: 0.2,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1, color: Color(0xFFF0EEF0)),
                  ...rows,
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildDataRow(String label, String value, {Color? valueColor}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 5,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 13,
                color: Colors.grey.shade600,
              ),
            ),
          ),
          Expanded(
            flex: 5,
            child: Text(
              value,
              textAlign: TextAlign.end,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: valueColor ?? const Color(0xFF1A1A1A),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Motion AI card ───────────────────────────────────────────────────────

  Widget _buildMotionCard(int threshold) {
    final scoreText = _anomalyScore == null
        ? 'waiting…'
        : _anomalyScore!.toStringAsFixed(2);
    final windowsText = _anomalyScore == null
        ? 'waiting…'
        : '$_consecutiveAnomalies / $threshold';

    Color? scoreColor;
    if (_anomalyScore != null) {
      scoreColor = _anomalyScore! >= 0.7
          ? Colors.red.shade700
          : _anomalyScore! >= 0.4
              ? Colors.orange.shade700
              : Colors.green.shade700;
    }

    return _buildSectionCard(
      icon: Icons.psychology_outlined,
      title: 'Motion AI',
      rows: [
        _buildDataRow('Anomaly Score (0–1)', scoreText, valueColor: scoreColor),
        const Divider(height: 1, color: Color(0xFFF0EEF0), indent: 16),
        _buildDataRow('Consecutive Windows', windowsText),
        const Divider(height: 1, color: Color(0xFFF0EEF0), indent: 16),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Text(
            'Alert triggers at $threshold consecutive anomaly windows.',
            style: TextStyle(fontSize: 11.5, color: Colors.grey.shade500),
          ),
        ),
      ],
    );
  }

  // ── GPS card ─────────────────────────────────────────────────────────────

  Widget _buildGpsCard() {
    final String gpsText;
    Color? gpsColor;
    if ((_gpsSub == null && !_gpsActive) || _gpsError) {
      gpsText = 'unavailable';
      gpsColor = Colors.red.shade700;
    } else if (_gpsAccuracy == null) {
      gpsText = 'acquiring…';
    } else {
      gpsText = '${_gpsAccuracy!.toStringAsFixed(1)} m accuracy';
      gpsColor = _gpsAccuracy! <= 15
          ? Colors.green.shade700
          : _gpsAccuracy! <= 50
              ? Colors.orange.shade700
              : Colors.red.shade700;
    }

    return _buildSectionCard(
      icon: Icons.location_on_outlined,
      title: 'Location',
      rows: [
        _buildDataRow('GPS Accuracy', gpsText, valueColor: gpsColor),
        const Divider(height: 1, color: Color(0xFFF0EEF0), indent: 16),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Text(
            'Lower values are better. ≤15 m = excellent  ·  >50 m = poor/indoor.',
            style: TextStyle(fontSize: 11.5, color: Colors.grey.shade500),
          ),
        ),
      ],
    );
  }

  // ── Event log card ───────────────────────────────────────────────────────

  Widget _buildEventCard() {
    final String eventName;
    final String eventTime;
    if (_eventLoading) {
      eventName = 'loading…';
      eventTime = '';
    } else if (_latestEvent == null) {
      eventName = 'none recorded';
      eventTime = '';
    } else {
      eventName = _latestEvent!.typeName;
      eventTime = _hhmmss(_latestEvent!.timestamp);
    }

    return _buildSectionCard(
      icon: Icons.history_rounded,
      title: 'Event Log',
      rows: [
        _buildDataRow('Most Recent Event', eventName),
        if (eventTime.isNotEmpty) ...[
          const Divider(height: 1, color: Color(0xFFF0EEF0), indent: 16),
          _buildDataRow('Time', eventTime),
        ],
      ],
    );
  }

  // ── Feedback export card ─────────────────────────────────────────────────

  Widget _buildFeedbackExportCard() {
    final lastExportLabel = _feedbackLastExport == null
        ? 'Never'
        : _formatDateTime(_feedbackLastExport!);

    return _buildSectionCard(
      icon: Icons.feedback_outlined,
      title: 'Feedback Entries',
      rows: [
        _buildDataRow(
          'Stored entries',
          _feedbackCount == 0 ? 'None' : '$_feedbackCount',
          valueColor: _feedbackCount > 0
              ? const Color(0xFFB07080)
              : Colors.grey.shade500,
        ),
        _buildDataRow(
          'Last saved',
          _feedbackLastSaved == null
              ? 'Never'
              : _formatDateTime(_feedbackLastSaved!),
        ),
        _buildDataRow('Last exported', lastExportLabel),
        const Divider(height: 1, color: Color(0xFFF0EEF0)),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
          child: Text(
            'Export all stored feedback and share via the Android share sheet.',
            style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
          ),
        ),
        // Export JSON
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 6),
          child: SizedBox(
            width: double.infinity,
            height: 44,
            child: ElevatedButton.icon(
              onPressed: _exportFeedbackJson,
              icon: const Icon(Icons.data_object_outlined, size: 17),
              label: const Text(
                'Export as JSON',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFB07080),
                foregroundColor: Colors.white,
                elevation: 0,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ),
        ),
        // Export CSV
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
          child: SizedBox(
            width: double.infinity,
            height: 44,
            child: OutlinedButton.icon(
              onPressed: _exportFeedbackCsv,
              icon: const Icon(Icons.table_chart_outlined, size: 17),
              label: const Text(
                'Export as CSV',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
              ),
              style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFFB07080),
                side: const BorderSide(color: Color(0xFFB07080)),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ),
        ),
        const Divider(height: 1, color: Color(0xFFF0EEF0)),
        // Clear all
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 14),
          child: SizedBox(
            width: double.infinity,
            height: 44,
            child: OutlinedButton.icon(
              onPressed: _clearFeedback,
              icon: const Icon(Icons.delete_outline, size: 17),
              label: const Text(
                'Clear All Feedback',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
              ),
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.red.shade600,
                side: BorderSide(color: Colors.red.shade400),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ),
        ),
      ],
    );
  }

  String _formatDateTime(DateTime dt) {
    final local = dt.toLocal();
    final d = '${local.day.toString().padLeft(2, '0')}'
        '/${local.month.toString().padLeft(2, '0')}'
        '/${local.year}';
    final t = '${local.hour.toString().padLeft(2, '0')}'
        ':${local.minute.toString().padLeft(2, '0')}';
    return '$d $t';
  }

  Future<void> _exportFeedbackJson() async {
    final entries = await _feedbackService.getAll();
    if (entries.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No feedback entries saved yet.')),
      );
      return;
    }

    final now = DateTime.now();
    final payload = {
      'exported_at': now.toIso8601String(),
      'total_entries': entries.length,
      'entries': entries.map((e) => e.toJson()).toList(),
    };
    final jsonString = const JsonEncoder.withIndent('  ').convert(payload);

    final dir = await getTemporaryDirectory();
    final file = File(
        '${dir.path}/shesafe_feedback_${now.millisecondsSinceEpoch}.json');
    await file.writeAsString(jsonString);

    await _feedbackService.recordExport();
    await _loadFeedbackStats();

    if (!mounted) return;
    await Share.shareXFiles(
      [XFile(file.path, mimeType: 'application/json')],
      subject: 'SheSafe Feedback Export (JSON)',
      text:
          'SheSafe feedback — ${entries.length} entr${entries.length == 1 ? 'y' : 'ies'}.',
    );
  }

  Future<void> _exportFeedbackCsv() async {
    final entries = await _feedbackService.getAll();
    if (entries.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No feedback entries saved yet.')),
      );
      return;
    }

    // RFC 4180 CSV escaping
    String csvEscape(String s) {
      if (s.contains(',') || s.contains('"') || s.contains('\n')) {
        return '"${s.replaceAll('"', '""')}';
      }
      return s;
    }

    final buf = StringBuffer();
    buf.writeln(
        'Numeric Rating (1-5),Star Display,Category,Comment,Submitted At (ISO 8601),App Version,Platform,Source Screen');
    for (final e in entries) {
      final stars = '${'★' * e.rating}${'☆' * (5 - e.rating)}';
      buf.writeln([
        '${e.rating}',
        csvEscape(stars),
        csvEscape(e.category?.label ?? ''),
        csvEscape(e.comment),
        e.timestamp.toIso8601String(),
        csvEscape(e.appVersion),
        csvEscape(e.platform),
        csvEscape(e.screenName),
      ].join(','));
    }

    final now = DateTime.now();
    final dir = await getTemporaryDirectory();
    final file = File(
        '${dir.path}/shesafe_feedback_${now.millisecondsSinceEpoch}.csv');
    await file.writeAsString(buf.toString());

    await _feedbackService.recordExport();
    await _loadFeedbackStats();

    if (!mounted) return;
    await Share.shareXFiles(
      [XFile(file.path, mimeType: 'text/csv')],
      subject: 'SheSafe Feedback Export (CSV)',
      text:
          'SheSafe feedback — ${entries.length} entr${entries.length == 1 ? 'y' : 'ies'}.',
    );
  }

  Future<void> _clearFeedback() async {
    if (_feedbackCount == 0) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No feedback entries to clear.')),
      );
      return;
    }

    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear all feedback?'),
        content: Text(
          'This will permanently delete all $_feedbackCount stored feedback '
          'entr${_feedbackCount == 1 ? 'y' : 'ies'} from this device. '
          'This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;

    await _feedbackService.clearAll();
    await _loadFeedbackStats();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('All feedback cleared.')),
    );
  }
}
