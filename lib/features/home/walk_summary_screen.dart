import 'package:flutter/material.dart';
import '../../models/walk_safety_report.dart';

/// Full-screen post-walk summary with real GPS-tracked stats and safety
/// analysis cards.
class WalkSummaryScreen extends StatelessWidget {
  final WalkSafetyReport report;

  const WalkSummaryScreen({super.key, required this.report});

  @override
  Widget build(BuildContext context) {
    final hasGps = report.actualDistanceMeters > 0;

    return Scaffold(
      backgroundColor: const Color(0xFFF5F6FA),
      body: CustomScrollView(
        slivers: [
          // ── Gradient app bar ─────────────────────────────────────────
          SliverAppBar(
            expandedHeight: 220,
            pinned: true,
            stretch: true,
            backgroundColor: _badgeColor,
            leading: IconButton(
              icon: const Icon(Icons.close, color: Colors.white),
              onPressed: () => Navigator.of(context).pop(),
            ),
            flexibleSpace: FlexibleSpaceBar(
              background: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [_badgeColor, _badgeColor.withValues(alpha: 0.7)],
                  ),
                ),
                child: SafeArea(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const SizedBox(height: 24),
                      // Safety percentage ring
                      _SafetyBadge(
                        safetyPercentage: report.safetyPercentage,
                        color: Colors.white,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        _safetyLabel,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.3,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),

          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
              child: Column(
                children: [
                  // ── Stats grid ───────────────────────────────────────
                  _StatsGrid(report: report, hasGps: hasGps),
                  const SizedBox(height: 20),

                  // ── Summary card ─────────────────────────────────────
                  _SummaryCard(text: report.aiSummary),
                  const SizedBox(height: 16),

                  // ── Safety analysis cards ────────────────────────────
                  ...report.feedbackItems.map((item) => Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: _FeedbackCard(item: item),
                      )),

                  const SizedBox(height: 20),

                  // ── Done button ──────────────────────────────────────
                  SizedBox(
                    width: double.infinity,
                    height: 54,
                    child: ElevatedButton.icon(
                      onPressed: () =>
                          Navigator.of(context)
                              .popUntil((route) => route.isFirst),
                      icon: const Icon(Icons.check_rounded, size: 22),
                      label: const Text(
                        'Done',
                        style: TextStyle(
                            fontSize: 17, fontWeight: FontWeight.w700),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _badgeColor,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                        elevation: 0,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Color get _badgeColor {
    if (report.safetyPercentage >= 70) return const Color(0xFF2E7D32);
    if (report.safetyPercentage >= 40) return Colors.orange.shade700;
    return Colors.red.shade700;
  }

  String get _safetyLabel {
    if (report.safetyPercentage >= 80) return 'Excellent Safety';
    if (report.safetyPercentage >= 60) return 'Good Safety';
    if (report.safetyPercentage >= 40) return 'Moderate Safety';
    return 'Low Safety';
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Compact safety badge (white ring on gradient background)
// ─────────────────────────────────────────────────────────────────────────────

class _SafetyBadge extends StatefulWidget {
  final double safetyPercentage;
  final Color color;
  const _SafetyBadge({required this.safetyPercentage, required this.color});

  @override
  State<_SafetyBadge> createState() => _SafetyBadgeState();
}

class _SafetyBadgeState extends State<_SafetyBadge>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _anim;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );
    _anim = Tween<double>(begin: 0, end: widget.safetyPercentage / 100)
        .animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOutCubic));
    _ctrl.forward();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _anim,
      builder: (_, _) => SizedBox(
        width: 110,
        height: 110,
        child: Stack(
          alignment: Alignment.center,
          children: [
            SizedBox(
              width: 110,
              height: 110,
              child: CircularProgressIndicator(
                value: _anim.value,
                strokeWidth: 8,
                backgroundColor: Colors.white.withValues(alpha: 0.25),
                valueColor:
                    const AlwaysStoppedAnimation(Colors.white),
              ),
            ),
            Text(
              '${(_anim.value * 100).round()}%',
              style: const TextStyle(
                fontSize: 30,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 2x2 stats grid
// ─────────────────────────────────────────────────────────────────────────────

class _StatsGrid extends StatelessWidget {
  final WalkSafetyReport report;
  final bool hasGps;
  const _StatsGrid({required this.report, required this.hasGps});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.06),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        children: [
          // Top row
          IntrinsicHeight(
            child: Row(
              children: [
                Expanded(
                  child: _StatCell(
                    icon: Icons.straighten_rounded,
                    iconColor: const Color(0xFF3949AB),
                    value: hasGps
                        ? report.formattedActualDistance
                        : _formatPlannedDistance(report.distanceMeters),
                    label: hasGps ? 'GPS Distance' : 'Planned Route',
                  ),
                ),
                Container(width: 0.5, color: Colors.grey.shade200),
                Expanded(
                  child: _StatCell(
                    icon: Icons.timer_rounded,
                    iconColor: const Color(0xFF00796B),
                    value: _formatDuration(report.walkDurationSeconds),
                    label: 'Duration',
                  ),
                ),
              ],
            ),
          ),
          Container(height: 0.5, color: Colors.grey.shade200),
          // Bottom row
          IntrinsicHeight(
            child: Row(
              children: [
                Expanded(
                  child: _StatCell(
                    icon: Icons.directions_walk_rounded,
                    iconColor: const Color(0xFFE65100),
                    value: report.estimatedSteps > 0
                        ? _formatSteps(report.estimatedSteps)
                        : _formatSteps((report.walkDurationSeconds / 60 * 95).round()),
                    label: 'Steps',
                  ),
                ),
                Container(width: 0.5, color: Colors.grey.shade200),
                Expanded(
                  child: _StatCell(
                    icon: Icons.speed_rounded,
                    iconColor: const Color(0xFF1565C0),
                    value: hasGps ? report.formattedSpeed : '—',
                    label: 'Avg Speed',
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _formatPlannedDistance(double meters) {
    if (meters < 1000) return '${meters.round()} m';
    return '${(meters / 1000).toStringAsFixed(1)} km';
  }

  String _formatDuration(int totalSeconds) {
    if (totalSeconds < 60) return '${totalSeconds}s';
    final m = totalSeconds ~/ 60;
    final s = totalSeconds % 60;
    if (m < 60) return s > 0 ? '${m}m ${s}s' : '${m}m';
    final h = m ~/ 60;
    final rm = m % 60;
    return rm > 0 ? '${h}h ${rm}m' : '${h}h';
  }

  String _formatSteps(int steps) {
    if (steps >= 10000) return '${(steps / 1000).toStringAsFixed(1)}k';
    return '$steps';
  }
}

class _StatCell extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String value;
  final String label;
  const _StatCell({
    required this.icon,
    required this.iconColor,
    required this.value,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 12),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: iconColor.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: iconColor, size: 20),
          ),
          const SizedBox(height: 10),
          Text(
            value,
            style: const TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w800,
              color: Color(0xFF1A1A2E),
            ),
          ),
          const SizedBox(height: 3),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              color: Colors.grey.shade500,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.2,
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Summary analysis card
// ─────────────────────────────────────────────────────────────────────────────

class _SummaryCard extends StatelessWidget {
  final String text;
  const _SummaryCard({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: Colors.deepPurple.shade50,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(Icons.auto_awesome,
                color: Colors.deepPurple.shade400, size: 20),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Safety Analysis',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: Colors.deepPurple.shade400,
                    letterSpacing: 0.5,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  text,
                  style: TextStyle(
                    fontSize: 14,
                    color: Colors.grey.shade700,
                    height: 1.5,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Feedback card widget
// ─────────────────────────────────────────────────────────────────────────────

class _FeedbackCard extends StatelessWidget {
  final WalkFeedbackItem item;
  const _FeedbackCard({required this.item});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
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
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: _iconColor.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(11),
            ),
            child: Icon(_icon, color: _iconColor, size: 20),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.label,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF1A1A2E),
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  item.detail,
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.grey.shade500,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  IconData get _icon {
    switch (item.type) {
      case WalkFeedbackType.anomaly:
        return item.label.startsWith('No')
            ? Icons.check_circle_rounded
            : Icons.warning_amber_rounded;
      case WalkFeedbackType.avoidedZones:
        return Icons.shield_rounded;
      case WalkFeedbackType.safetyScore:
        return Icons.verified_user_rounded;
      case WalkFeedbackType.duration:
        return Icons.timer_outlined;
      case WalkFeedbackType.distance:
        return Icons.straighten;
      case WalkFeedbackType.steps:
        return Icons.directions_walk_rounded;
      case WalkFeedbackType.speed:
        return Icons.speed_rounded;
    }
  }

  Color get _iconColor {
    switch (item.type) {
      case WalkFeedbackType.anomaly:
        return item.label.startsWith('No')
            ? const Color(0xFF2E7D32)
            : const Color(0xFFE65100);
      case WalkFeedbackType.avoidedZones:
        return const Color(0xFF1565C0);
      case WalkFeedbackType.safetyScore:
        return const Color(0xFF6A1B9A);
      case WalkFeedbackType.duration:
        return const Color(0xFF00796B);
      case WalkFeedbackType.distance:
        return const Color(0xFF3949AB);
      case WalkFeedbackType.steps:
        return const Color(0xFFE65100);
      case WalkFeedbackType.speed:
        return const Color(0xFF1565C0);
    }
  }
}
