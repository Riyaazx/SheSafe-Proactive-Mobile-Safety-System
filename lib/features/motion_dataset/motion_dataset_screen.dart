import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import '../../models/labeled_motion_sample.dart';
import '../../models/motion_baseline.dart';
import '../../services/motion_baseline_service.dart';
import '../../services/motion_dataset_service.dart';
import 'collection_session_screen.dart';

/// Main screen for the B1 motion dataset feature.
///
/// Allows the researcher to:
///  • Collect labeled windows for each of the 5 motion classes
///  • See sample counts per class
///  • Run in-app evaluation (recall / precision / latency) once the
///    user's motion baseline is calibrated
///  • Export the full dataset as CSV (Share sheet)
///  • Clear the in-memory dataset
class MotionDatasetScreen extends StatefulWidget {
  const MotionDatasetScreen({super.key});

  @override
  State<MotionDatasetScreen> createState() => _MotionDatasetScreenState();
}

class _MotionDatasetScreenState extends State<MotionDatasetScreen> {
  final _datasetService = MotionDatasetService();
  final _baselineService = MotionBaselineService();
  DatasetEvaluation? _evaluation;
  bool _baselineReady = false;
  bool _showHowTo = false;

  @override
  void initState() {
    super.initState();
    _checkBaseline();
  }

  Future<void> _checkBaseline() async {
    await _baselineService.initialize();
    setState(() => _baselineReady = _baselineService.isCalibrated);
  }

  // ── Navigation ────────────────────────────────────────────────────────────

  Future<void> _openSession(MotionLabel label) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => CollectionSessionScreen(label: label),
      ),
    );

    // ── Link: Normal Walk → auto-calibrate Motion AI Baseline ────────────
    // If the user just collected Normal Walk samples, use them to calibrate
    // (or update) the motion baseline so they don't need to do it separately.
    if (label == MotionLabel.normalWalk) {
      final walkFeatures = _datasetService.samples
          .where((s) => s.label == MotionLabel.normalWalk)
          .map((s) => s.features)
          .toList();
      if (walkFeatures.length >= MotionBaseline.minCalibrationWindows) {
        final updated =
            await _baselineService.calibrateFromFeatures(walkFeatures);
        if (updated && mounted) {
          setState(() => _baselineReady = true);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: const Text(
                  '✅ Motion AI Baseline also updated from your walk samples'),
              backgroundColor: const Color(0xFFE91E63),
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
      }
    }

    // Refresh counts after returning
    setState(() {});
  }

  // ── Evaluation ────────────────────────────────────────────────────────────

  void _runEvaluation() {
    if (!_baselineReady) {
      _showSnack('Calibrate motion baseline first (Settings → Motion Baseline)',
          Colors.orange);
      return;
    }
    if (_datasetService.totalSamples == 0) {
      _showSnack('Collect at least one class before evaluating', Colors.orange);
      return;
    }

    final eval = _datasetService.evaluate();
    if (eval == null) {
      _showSnack('Evaluation failed — is baseline calibrated?', Colors.red);
      return;
    }

    setState(() => _evaluation = eval);
    _showEvaluationDialog(eval);
  }

  void _showEvaluationDialog(DatasetEvaluation eval) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Evaluation Results'),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${eval.totalSamples} samples  ·  '
                  'evaluated ${_fmtTime(eval.evaluatedAt)}',
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
                const SizedBox(height: 12),

                // Per-class table
                _MetricsTable(metrics: eval.perClass),

                const Divider(height: 28),
                const Text('Overall',
                    style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 6),
                _MetricRow('Precision',
                    '${(eval.overall.precision * 100).toStringAsFixed(1)} %'),
                _MetricRow('Recall (priority)',
                    '${(eval.overall.recall * 100).toStringAsFixed(1)} %',
                    highlight: true),
                _MetricRow('F1-score',
                    '${(eval.overall.f1 * 100).toStringAsFixed(1)} %'),
                _MetricRow('Avg feature-extraction latency',
                    '${eval.overall.avgLatencyMs.toStringAsFixed(2)} ms'),
                const SizedBox(height: 8),
                const Text(
                  'Tip: Export CSV for full offline analysis with the Python script.',
                  style: TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
          ElevatedButton.icon(
            onPressed: () {
              Navigator.pop(context);
              _exportCsv();
            },
            icon: const Icon(Icons.share),
            label: const Text('Export CSV'),
          ),
        ],
      ),
    );
  }

  // ── Export ────────────────────────────────────────────────────────────────

  Future<void> _exportCsv() async {
    if (_datasetService.totalSamples == 0) {
      _showSnack('No samples to export', Colors.orange);
      return;
    }
    final csv = _datasetService.exportCsv();
    final fileName =
        'SheSafe_motion_dataset_${DateTime.now().millisecondsSinceEpoch}.csv';

    try {
      // share_plus FileProvider only grants access to <cache>/share_plus/
      final cacheDir = await getTemporaryDirectory();
      final shareDir = Directory('${cacheDir.path}/share_plus');
      if (!await shareDir.exists()) {
        await shareDir.create(recursive: true);
      }
      final file = File('${shareDir.path}/$fileName');
      await file.writeAsString(csv);

      final length = await file.length();
      debugPrint('[CSV Export] Written $length bytes to ${file.path}');

      await Share.shareXFiles(
        [XFile(file.path, mimeType: 'text/csv', name: fileName)],
        subject: fileName,
      );
    } catch (e, st) {
      debugPrint('[CSV Export] shareXFiles failed: $e\n$st');
      // Fallback: share as plain text (works everywhere)
      try {
        await Share.share(csv, subject: fileName);
      } catch (e2) {
        debugPrint('[CSV Export] Share.share also failed: $e2');
        if (!mounted) return;
        showDialog(
          context: context,
          builder: (_) => AlertDialog(
            title: const Text('Export Error'),
            content: SelectableText('$e\n\nFallback also failed: $e2'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('OK'),
              ),
            ],
          ),
        );
      }
    }
  }

  // ── Clear ─────────────────────────────────────────────────────────────────

  void _confirmClear() {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Clear Dataset?'),
        content: Text('This will delete all '
            '${_datasetService.totalSamples} collected samples. '
            'This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              _datasetService.clearDataset();
              setState(() => _evaluation = null);
              Navigator.pop(context);
              _showSnack('Dataset cleared', Colors.grey);
            },
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Clear', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final total = _datasetService.totalSamples;
    final readyToEval = _baselineReady && total > 0;

    return Scaffold(
      backgroundColor: const Color(0xFFFFF8FA),
      body: CustomScrollView(
        slivers: [
          // ── Gradient header ────────────────────────────────────────────
          SliverAppBar(
            expandedHeight: 150,
            pinned: true,
            stretch: true,
            backgroundColor: const Color(0xFFB07080),
            leading: IconButton(
              icon: const Icon(Icons.arrow_back, color: Colors.white),
              onPressed: () => Navigator.of(context).pop(),
            ),
            actions: [
              if (total > 0)
                IconButton(
                  icon: const Icon(Icons.delete_outline, color: Colors.white70),
                  tooltip: 'Clear dataset',
                  onPressed: _confirmClear,
                ),
            ],
            flexibleSpace: FlexibleSpaceBar(
              background: Container(
                  decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [Color(0xFF8D6E63), Color(0xFF665B64)],
                  ),
                ),
                child: SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 48, 20, 16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        const Text(
                          'Motion Dataset',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 24,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 0.2,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                                            _headerBadge(
                              '$total sample${total == 1 ? '' : 's'}',
                              total > 0
                                  ? Colors.greenAccent
                                  : Colors.white38,
                            ),
                            const SizedBox(width: 8),
                            _headerBadge(
                              _baselineReady
                                  ? 'Baseline ready'
                                  : 'Baseline needed',
                              _baselineReady
                                  ? Colors.greenAccent
                                  : Colors.orangeAccent,
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),

          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Calibration banner removed per user preference

                  // Section label
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Text(
                      'Motion Classes',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: Colors.grey.shade600,
                        letterSpacing: 0.8,
                      ),
                    ),
                  ),

                  // Class cards
                  ...MotionLabel.values.map(_buildClassCard),

                  const SizedBox(height: 20),

                  // Evaluate + Export row
                  Row(
                    children: [
                      _miniButton(
                        label: total > 0 ? 'Evaluate · $total' : 'Evaluate',
                        icon: Icons.analytics_outlined,
                        enabled: readyToEval,
                        onTap: readyToEval ? _runEvaluation : null,
                      ),
                      const SizedBox(width: 10),
                      _miniButton(
                        label: 'Export CSV',
                        icon: Icons.ios_share_rounded,
                        enabled: total > 0,
                        onTap: total > 0 ? _exportCsv : null,
                      ),
                    ],
                  ),

                  // Last evaluation
                  if (_evaluation != null) ...[
                    const SizedBox(height: 24),
                    _buildLastEvalSummary(_evaluation!),
                  ],

                  const SizedBox(height: 24),
                  _buildHowToCard(),
                  const SizedBox(height: 32),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Mini action button ────────────────────────────────────────────────────
  Widget _miniButton({
    required String label,
    required IconData icon,
    required bool enabled,
    VoidCallback? onTap,
  }) {
    return Expanded(
      child: ElevatedButton.icon(
        onPressed: enabled ? onTap : null,
        icon: Icon(icon, size: 15),
        label: Text(label, style: const TextStyle(fontSize: 12.5)),
        style: ElevatedButton.styleFrom(
          padding: const EdgeInsets.symmetric(vertical: 12),
          backgroundColor: const Color(0xFFB07080),
          foregroundColor: Colors.white,
          disabledBackgroundColor: const Color(0xFFEEE5DF),
          disabledForegroundColor: const Color(0xFFBCAA9E),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          elevation: 0,
        ),
      ),
    );
  }

  // ── Header badge ──────────────────────────────────────────────────────────
  Widget _headerBadge(String text, Color _) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.22),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withValues(alpha: 0.55)),
      ),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: Colors.white,
        ),
      ),
    );
  }

  // ── Motion class card ─────────────────────────────────────────────────────
  Widget _buildClassCard(MotionLabel label) {
    final count    = _datasetService.countFor(label);
    final color    = _labelColor(label);
    final progress = (count / 10.0).clamp(0.0, 1.0);
    final isDone   = count >= 10;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => _openSession(label),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              // Icon box
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(11),
                ),
                child: Center(
                  child: Icon(_labelIcon(label),
                      color: color, size: 20),
                ),
              ),
              const SizedBox(width: 12),

              // Name + progress bar
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          label.displayName,
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            color: Color(0xFF1A1A2E),
                          ),
                        ),
                        Text(
                          isDone ? '✓  $count / 10' : '$count / 10',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: isDone
                                ? Colors.green.shade700
                                : Colors.orange.shade700,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(3),
                      child: LinearProgressIndicator(
                        value: progress,
                        minHeight: 4,
                        backgroundColor: color.withValues(alpha: 0.12),
                        valueColor: AlwaysStoppedAnimation(
                          isDone ? Colors.green.shade600 : color,
                        ),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      label.isAnomaly
                          ? 'Anomaly class — triggers alert'
                          : 'Normal class — baseline reference',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: label.isAnomaly
                            ? Colors.red.shade400
                            : Colors.green.shade600,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      label.shortDescription,
                      style: TextStyle(
                        fontSize: 11,
                        color: Colors.grey.shade600,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 6),

              // Record button
              Material(
                color: color.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(10),
                child: InkWell(
                  borderRadius: BorderRadius.circular(10),
                  onTap: () => _openSession(label),
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Icon(Icons.fiber_manual_record,
                        color: color, size: 18),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Last evaluation summary ───────────────────────────────────────────────
  Widget _buildLastEvalSummary(DatasetEvaluation eval) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.bar_chart_rounded,
                  size: 18, color: Colors.indigo.shade600),
              const SizedBox(width: 8),
              Text(
                'Last Evaluation',
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 14,
                  color: Colors.indigo.shade700,
                ),
              ),
              const Spacer(),
              Text(
                _fmtTime(eval.evaluatedAt),
                style: TextStyle(
                  fontSize: 11,
                  color: Colors.grey.shade400,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              _statChip('Recall',
                  '${(eval.overall.recall * 100).toStringAsFixed(0)}%',
                  Colors.indigo),
              const SizedBox(width: 8),
              _statChip('Precision',
                  '${(eval.overall.precision * 100).toStringAsFixed(0)}%',
                  Colors.teal),
              const SizedBox(width: 8),
              _statChip(
                  'F1',
                  '${(eval.overall.f1 * 100).toStringAsFixed(0)}%',
                  Colors.purple),
            ],
          ),
          const SizedBox(height: 14),
          _MetricsTable(metrics: eval.perClass),
        ],
      ),
    );
  }

  Widget _statChip(String label, String value, MaterialColor color) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: color.shade50,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: color.shade100),
        ),
        child: Column(
          children: [
            Text(
              value,
              style: TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: 17,
                color: color.shade700,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                color: color.shade400,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── How-to card ───────────────────────────────────────────────────────────
  Widget _buildHowToCard() {
    const steps = [
      ('1', 'Tap Normal Walk first and walk around for 15 seconds — this also calibrates your Motion AI Baseline automatically.'),
      ('2', 'Tap each other class card and perform the matching motion during the recording.'),
      ('3', 'Aim for at least 10 samples per class. Each 15 s session gives you roughly 15 samples.'),
      ('4', 'Once all classes are collected, tap Evaluate to check how well the detector works for you.'),
      ('5', 'Export CSV to save your data and review it offline.'),
    ];
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header row — tap the ⓘ icon to toggle steps
          InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: () => setState(() => _showHowTo = !_showHowTo),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                children: [
                  Icon(Icons.info_outline_rounded,
                      size: 16, color: Colors.blueGrey.shade400),
                  const SizedBox(width: 6),
                  Text(
                    'How to collect data',
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 13,
                      color: Colors.blueGrey.shade700,
                    ),
                  ),
                  const Spacer(),
                  Icon(
                    _showHowTo
                        ? Icons.keyboard_arrow_up_rounded
                        : Icons.keyboard_arrow_down_rounded,
                    size: 18,
                    color: Colors.blueGrey.shade400,
                  ),
                ],
              ),
            ),
          ),
          // Steps — only visible when expanded
          if (_showHowTo) ...
            [
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
                child: Column(
                  children: steps
                      .map(
                        (s) => Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Container(
                                width: 20,
                                height: 20,
                                decoration: BoxDecoration(
                                  color: Colors.blueGrey.shade50,
                                  shape: BoxShape.circle,
                                ),
                                child: Center(
                                  child: Text(
                                    s.$1,
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w700,
                                      color: Colors.blueGrey.shade600,
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  s.$2,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Colors.blueGrey.shade700,
                                    height: 1.4,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      )
                      .toList(),
                ),
              ),
            ],
        ],
      ),
    );
  }

  // ── Utilities ─────────────────────────────────────────────────────────────

  Color _labelColor(MotionLabel label) => const Color(0xFFB07080);

  /// Returns a clean Material icon for each motion class.
  IconData _labelIcon(MotionLabel label) {
    switch (label) {
      case MotionLabel.normalWalk: return Icons.directions_walk_rounded;
      case MotionLabel.suddenStop: return Icons.pan_tool_rounded;
      case MotionLabel.fastTurn:   return Icons.rotate_90_degrees_ccw_rounded;
      case MotionLabel.shortRun:   return Icons.directions_run_rounded;
      case MotionLabel.phoneShake: return Icons.vibration_rounded;
    }
  }

  void _showSnack(String msg, Color bg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: bg),
    );
  }

  String _fmtTime(DateTime dt) =>
      '${dt.hour.toString().padLeft(2, '0')}:'
      '${dt.minute.toString().padLeft(2, '0')}';
}

// ── Action button widget (reusable) ──────────────────────────────────────────
class _ActionButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool enabled;
  final bool filled;
  final VoidCallback? onTap;

  const _ActionButton({
    required this.label,
    required this.icon,
    required this.enabled,
    required this.filled,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    const primary = Color(0xFFE91E63); // pink primary to match theme
    if (filled) {
      return SizedBox(
        width: double.infinity,
        child: ElevatedButton.icon(
          onPressed: enabled ? onTap : null,
          icon: Icon(icon, size: 20),
          label: Text(label, style: const TextStyle(fontSize: 15)),
          style: ElevatedButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 15),
            backgroundColor: primary,
            foregroundColor: Colors.white,
            disabledBackgroundColor: Colors.grey.shade100,
            disabledForegroundColor: Colors.grey.shade400,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14)),
            elevation: 0,
          ),
        ),
      );
    }
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton.icon(
        onPressed: enabled ? onTap : null,
        icon: Icon(icon, size: 20),
        label: Text(label, style: const TextStyle(fontSize: 15)),
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(vertical: 15),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14)),
          side: BorderSide(
            color: enabled ? primary : Colors.grey.shade300,
            width: 1.5,
          ),
          foregroundColor: enabled ? primary : Colors.grey.shade400,
        ),
      ),
    );
  }
}

// ── Shared metric widgets ──────────────────────────────────────────────────

class _MetricsTable extends StatelessWidget {
  final List<ClassMetrics> metrics;
  const _MetricsTable({required this.metrics});

  @override
  Widget build(BuildContext context) {
    return Table(
      border: TableBorder.all(
        color: Colors.grey.shade300,
        borderRadius: BorderRadius.circular(6),
      ),
      columnWidths: const {
        0: FlexColumnWidth(2.2),
        1: FlexColumnWidth(1),
        2: FlexColumnWidth(1.1),
        3: FlexColumnWidth(1),
      },
      children: [
        // Header
        TableRow(
          decoration: BoxDecoration(color: Colors.grey.shade100),
          children: ['Class', 'Recall', 'Precision', 'F1']
              .map((h) => _cell(h, bold: true))
              .toList(),
        ),
        for (final m in metrics)
          TableRow(children: [
            _cell(m.labelName),
            _cell('${(m.recall * 100).toStringAsFixed(0)} %',
                color: _recallColor(m.recall)),
            _cell('${(m.precision * 100).toStringAsFixed(0)} %'),
            _cell('${(m.f1 * 100).toStringAsFixed(0)} %'),
          ]),
      ],
    );
  }

  static Widget _cell(String text,
      {bool bold = false, Color? color}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 6),
      child: Text(text,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 12,
            fontWeight: bold ? FontWeight.bold : FontWeight.normal,
            color: color,
          )),
    );
  }

  static Color? _recallColor(double recall) {
    if (recall >= 0.8) return Colors.green.shade700;
    if (recall >= 0.6) return Colors.orange;
    return Colors.red;
  }
}

class _MetricRow extends StatelessWidget {
  final String label;
  final String value;
  final bool highlight;

  const _MetricRow(this.label, this.value, {this.highlight = false});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(fontSize: 13)),
          Text(value,
              style: TextStyle(
                fontSize: 13,
                fontWeight: highlight ? FontWeight.bold : FontWeight.w600,
                color: highlight ? Colors.indigo : null,
              )),
        ],
      ),
    );
  }
}
