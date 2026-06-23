import 'package:flutter/material.dart';
import '../../services/battery_alert_service.dart';
import '../../services/event_log_service.dart';

class DebugBatteryTestScreen extends StatefulWidget {
  const DebugBatteryTestScreen({super.key});

  @override
  State<DebugBatteryTestScreen> createState() => _DebugBatteryTestScreenState();
}

class _DebugBatteryTestScreenState extends State<DebugBatteryTestScreen> {
  static const _kSessionId = 'debug_battery_test';

  final _svc = BatteryAlertService();
  final _eventLog = EventLogService();

  bool _warningActive = false;
  bool _criticalActive = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _registerSession();
  }

  void _registerSession() {
    _svc.startMonitoring(
      sessionId: _kSessionId,
      userName: 'DebugUser',
      getLastPosition: () => (lat: 52.627, lon: 1.300),
      onLowBattery: (level) {
        if (!mounted) return;
        setState(() => _warningActive = true);
      },
      onCriticalAlert: (level, lat, lon) {
        if (!mounted) return;
        setState(() => _criticalActive = true);
        _showCriticalDialog(level);
      },
    );
  }

  void _reset() {
    _svc.stopMonitoring(_kSessionId);
    _svc.resetThresholdFlags();
    setState(() {
      _warningActive = false;
      _criticalActive = false;
    });
    _registerSession();
  }

  Future<void> _simulate(int level) async {
    // Reset guards so we can fire the threshold again on each button tap.
    _svc.resetThresholdFlags();
    setState(() => _busy = true);
    await _svc.simulateBatteryLevel(
      level,
      userName: 'DebugUser',
      getLastPosition: () => (lat: 52.627, lon: 1.300),
    );
    if (mounted) setState(() => _busy = false);
  }

  void _showCriticalDialog(int level) {
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('🔴 Critical Battery Alert Triggered'),
        content: Text(
          'Battery at $level%.\n\nSMS has been sent automatically to all trusted contacts. No manual action needed.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _svc.stopMonitoring(_kSessionId);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Battery Alert Test')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ── Status panel ────────────────────────────────────────────────
            Container(
              decoration: BoxDecoration(
                color: Colors.grey.shade100,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.grey.shade300),
              ),
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Alert Status',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  _StatusRow(
                    label: 'Tier 1 Warning (≤ 20%)',
                    triggered: _warningActive,
                  ),
                  const SizedBox(height: 4),
                  _StatusRow(
                    label: 'Tier 2 Critical (≤ 10%)',
                    triggered: _criticalActive,
                  ),
                ],
              ),
            ),

            // ── Warning banner (mirrors the banner in Safety Mode / Safe Route) ─
            if (_warningActive) ...
              [
                const SizedBox(height: 12),
                Container(
                  decoration: BoxDecoration(
                    color: Colors.orange.shade50,
                    border: Border.all(color: Colors.orange.shade300),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  child: Row(
                    children: [
                      Icon(Icons.battery_alert,
                          color: Colors.orange.shade700, size: 18),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '⚠️ Low battery warning banner triggered',
                          style: TextStyle(
                              color: Colors.orange.shade800,
                              fontWeight: FontWeight.w600),
                        ),
                      ),
                    ],
                  ),
                ),
              ],

            const SizedBox(height: 24),

            // ── Simulation buttons ───────────────────────────────────────────
            const Text('Simulate battery levels:',
                style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 10),

            ElevatedButton.icon(
              icon: const Icon(Icons.battery_4_bar),
              label: const Text('Simulate 15% — Tier 1 Warning'),
              onPressed: _busy ? null : () => _simulate(15),
            ),
            const SizedBox(height: 10),
            ElevatedButton.icon(
              icon: const Icon(Icons.battery_1_bar),
              label: const Text('Simulate 8% — Tier 2 Critical'),
              style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.red.shade700,
                  foregroundColor: Colors.white),
              onPressed: _busy ? null : () => _simulate(8),
            ),

            const SizedBox(height: 16),
            OutlinedButton.icon(
              icon: const Icon(Icons.refresh),
              label: const Text('Reset (run another test)'),
              onPressed: _reset,
            ),

            const Divider(height: 36),

            // ── Event log ────────────────────────────────────────────────────
            ElevatedButton(
              onPressed: () async {
                final events = await _eventLog.getAllEvents();
                final lines =
                    events.map((e) => e.description).take(10).join('\n');
                if (!context.mounted) return;
                await showDialog<void>(
                  context: context,
                  builder: (_) => AlertDialog(
                    title: const Text('Recent Events'),
                    content: SingleChildScrollView(
                        child: Text(
                            lines.isEmpty ? 'No events logged yet' : lines)),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text('Close'))
                    ],
                  ),
                );
              },
              child: const Text('Show event log'),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusRow extends StatelessWidget {
  const _StatusRow({required this.label, required this.triggered});
  final String label;
  final bool triggered;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(
          triggered ? Icons.check_circle : Icons.radio_button_unchecked,
          size: 16,
          color: triggered ? Colors.green : Colors.grey,
        ),
        const SizedBox(width: 6),
        Text(label,
            style: TextStyle(
                color: triggered ? Colors.green.shade800 : Colors.grey)),
      ],
    );
  }
}
