
import 'package:flutter/material.dart';

import '../../services/country_service.dart';
import '../../services/motion_baseline_service.dart';
import '../../services/secure_storage_service.dart';
import '../motion_dataset/motion_dataset_screen.dart';
import '../onboarding/screens/motion_baseline_calibration_screen.dart';
import 'change_safe_word_screen.dart';
import 'guidance_assistant_screen.dart';
import 'manage_trusted_contacts_screen.dart';
import '../../widgets/data_coverage_sheet.dart';

import 'debug_evaluation_screen.dart';
import 'safety_guidance_screen.dart';

// Accent colour used throughout the screen
const _kAccent = Color(0xFFB07080); // dusty rose

class SafetyProfileScreen extends StatefulWidget {
  const SafetyProfileScreen({super.key});

  @override
  State<SafetyProfileScreen> createState() => _SafetyProfileScreenState();
}

class _SafetyProfileScreenState extends State<SafetyProfileScreen> {
  final _storage = SecureStorageService();
  final _motionService = MotionBaselineService();

  String? _safeWord;
  // ignore: unused_field
  CountryInfo? _country;
  List<Map<String, dynamic>> _contacts = [];
  bool _motionCalibrated = false;
  double _motionSensitivityThreshold = 0.7;
  bool _isLoading = true;
  String _userName = '';

  // Hidden debug trigger state
  int _versionTapCount = 0;
  DateTime? _firstVersionTapTime;

  @override
  void initState() {
    super.initState();
    _loadAll();
  }

  // ---------------------------------------------------------------------------
  // Data loading
  // ---------------------------------------------------------------------------

  void _handleVersionTap() {
    final now = DateTime.now();
    if (_firstVersionTapTime == null ||
        now.difference(_firstVersionTapTime!) > const Duration(seconds: 2)) {
      _versionTapCount = 1;
      _firstVersionTapTime = now;
    } else {
      _versionTapCount++;
    }
    if (_versionTapCount >= 5) {
      _versionTapCount = 0;
      _firstVersionTapTime = null;
      if (!mounted) return;
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const DebugEvaluationScreen()),
      );
    }
  }

  Future<void> _loadAll() async {
    await _motionService.initialize();
    final results = await Future.wait([
      _storage.getSafeWord(),
      _storage.getTrustedContacts(),
      _storage.getUserNameAsync(),
    ]);
    final country = await CountryService().getSelectedCountry();

    if (!mounted) return;
    setState(() {
      _safeWord = results[0] as String?;
      _contacts = results[1] as List<Map<String, dynamic>>;
      _userName = results[2] as String;
      _country = country;
      _motionCalibrated = _motionService.isCalibrated;
      _motionSensitivityThreshold = _motionService.anomalyThreshold;
      _isLoading = false;
    });
  }

  // ---------------------------------------------------------------------------
  // Setup completeness helpers
  // ---------------------------------------------------------------------------

  bool get _hasIncompleteSetup {
    final noSafeWord = _safeWord == null || _safeWord!.isEmpty;
    final noContacts = _contacts.isEmpty;
    final noMotion = !_motionCalibrated;
    return noSafeWord || noContacts || noMotion;
  }

  int get _missingCount {
    int n = 0;
    if (_safeWord == null || _safeWord!.isEmpty) n++;
    if (_contacts.isEmpty) n++;
    if (!_motionCalibrated) n++;
    return n;
  }

  Widget _buildIncompleteSetupBanner() {
    final items = <Map<String, dynamic>>[];
    if (_contacts.isEmpty) {
      items.add({
        'icon': Icons.people_outline,
        'label': 'Trusted Contacts',
        'desc': 'Add people to alert in emergencies',
        'color': const Color(0xFF00796B),
        'onTap': () async {
          await Navigator.push(
              context,
              MaterialPageRoute(
                  builder: (_) => const ManageTrustedContactsScreen()));
          _loadAll();
        },
      });
    }
    if (_safeWord == null || _safeWord!.isEmpty) {
      items.add({
        'icon': Icons.lock_outline,
        'label': 'Safe Word',
        'desc': 'Set a voice-activated panic trigger',
        'color': _kAccent,
        'onTap': () async {
          await Navigator.push(context,
              MaterialPageRoute(builder: (_) => const ChangeSafeWordScreen()));
          _loadAll();
        },
      });
    }
    if (!_motionCalibrated) {
      items.add({
        'icon': Icons.sensors,
        'label': 'Motion AI Calibration',
        'desc': 'Calibrate walking-anomaly detection',
        'color': Colors.orange.shade700,
        'onTap': () async {
          await Navigator.push(
              context,
              MaterialPageRoute(
                  builder: (_) => const MotionBaselineCalibrationScreen()));
          _loadAll();
        },
      });
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [Colors.pink.shade50, Colors.purple.shade50],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.pink.shade200),
        ),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: Colors.pink.shade100,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(Icons.checklist_rounded,
                        color: Colors.pink.shade700, size: 18),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Finish Your Setup',
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            color: Colors.pink.shade900,
                          ),
                        ),
                        Text(
                          '$_missingCount item${_missingCount == 1 ? '' : 's'} skipped during onboarding',
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.pink.shade700,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              ...items.map((item) => Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Material(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(10),
                      child: InkWell(
                        onTap: item['onTap'] as VoidCallback,
                        borderRadius: BorderRadius.circular(10),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 10),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                                color: (item['color'] as Color)
                                    .withAlpha(50)),
                          ),
                          child: Row(
                            children: [
                              Icon(item['icon'] as IconData,
                                  size: 20,
                                  color: item['color'] as Color),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      item['label'] as String,
                                      style: TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w600,
                                        color: Colors.grey.shade800,
                                      ),
                                    ),
                                    Text(
                                      item['desc'] as String,
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: Colors.grey.shade500,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              Icon(Icons.chevron_right,
                                  size: 18,
                                  color: Colors.grey.shade400),
                            ],
                          ),
                        ),
                      ),
                    ),
                  )),
            ],
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Country info (UK-only — no picker needed)
  // ---------------------------------------------------------------------------

  // ── Build ───────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFFFF0F5),
      appBar: AppBar(
        backgroundColor: Colors.white,
        foregroundColor: const Color(0xFF1A1A1A),
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        centerTitle: false,
        title: const Text(
          'My Safety Profile',
          style: TextStyle(
            fontWeight: FontWeight.w700,
            fontSize: 20,
            color: Color(0xFF1A1A1A),
          ),
        ),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator(color: _kAccent))
          : RefreshIndicator(
              color: _kAccent,
              onRefresh: _loadAll,
              child: SingleChildScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // ── Top identity strip ─────────────────────────────────
                    _buildIdentityStrip(),

                    // ── Incomplete-setup banner (if anything was skipped) ──
                    if (_hasIncompleteSetup) _buildIncompleteSetupBanner(),

                    // ── Security Settings ──────────────────────────────────
                    _sectionHeader('Security Settings'),
                    _buildSafeWordRow(),
                    _buildRowDivider(),
                    _buildCountryRow(),
                    _buildRowDivider(),
                    _buildContactsRow(),
                    _buildRowDivider(),
                    _buildMotionRow(),
                    _buildRowDivider(),
                    _buildSensitivityRow(),
                    const SizedBox(height: 8),

                    // ── Features ───────────────────────────────────────────
                    _sectionHeader('Features'),
                    _buildFeatureRow(
                      icon: Icons.support_agent_outlined,
                      label: 'Safety Assistant',
                      subtitle: 'Chat-style safety guidance',
                      onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (_) => const GuidanceAssistantScreen())),
                    ),
                    _buildRowDivider(),
                    _buildFeatureRow(
                      icon: Icons.shield_outlined,
                      label: 'Safety Guidance',
                      subtitle: 'Browse tips by category',
                      onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (_) => const SafetyGuidanceScreen())),
                    ),
                    _buildRowDivider(),
                    _buildFeatureRow(
                      icon: Icons.sensors,
                      label: 'Motion Dataset',
                      subtitle: 'Collect & evaluate anomaly data',
                      onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (_) => const MotionDatasetScreen())),
                    ),

                    const SizedBox(height: 32),
                    // Hidden debug trigger — tap 5× within 2 s to open eval screen
                    GestureDetector(
                      onTap: _handleVersionTap,
                      behavior: HitTestBehavior.opaque,
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 24),
                        child: Text(
                          'App Version 1.0.0',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.grey.shade400,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
    );
  }

  // ── Identity strip ──────────────────────────────────────────────────────────

  Widget _buildIdentityStrip() {
    return Container(
      width: double.infinity,
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(24, 28, 24, 28),
      child: Column(
        children: [
          Container(
            width: 80,
            height: 80,
            decoration: BoxDecoration(
              color: const Color(0xFFF8D7E3),
              shape: BoxShape.circle,
              border: Border.all(color: const Color(0xFFF0B8CF), width: 2),
            ),
            child: const Icon(Icons.shield_outlined, color: _kAccent, size: 38),
          ),
          const SizedBox(height: 14),
          Text(
            _userName.isEmpty ? 'Your personal safety profile' : _userName,
            style: TextStyle(
              fontSize: _userName.isEmpty ? 14 : 18,
              fontWeight: _userName.isEmpty ? FontWeight.normal : FontWeight.w700,
              color: _userName.isEmpty ? const Color(0xFF7A8A85) : const Color(0xFF1A1A1A),
              letterSpacing: 0.2,
            ),
          ),
          const SizedBox(height: 8),
          TextButton.icon(
            onPressed: _editUserName,
            icon: const Icon(Icons.edit_outlined, size: 16),
            label: Text(_userName.isEmpty ? 'Add your name' : 'Change name'),
            style: TextButton.styleFrom(
              foregroundColor: _kAccent,
              textStyle: const TextStyle(fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _editUserName() async {
    final ctrl = TextEditingController(text: _userName);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Your Name'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(
            hintText: 'e.g. Emma',
            labelText: 'Display name',
          ),
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            style: ElevatedButton.styleFrom(
              backgroundColor: _kAccent,
              foregroundColor: Colors.white,
            ),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (result != null && mounted) {
      await _storage.saveUserName(result);
      setState(() => _userName = result);
    }
  }

  // ── Section header ──────────────────────────────────────────────────────────

  Widget _sectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 8),
      child: Text(
        title.toUpperCase(),
        style: TextStyle(
          fontSize: 11.5,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.0,
          color: Colors.grey.shade500,
        ),
      ),
    );
  }

  Widget _buildRowDivider() => const Padding(
        padding: EdgeInsets.symmetric(horizontal: 20),
        child: Divider(height: 1, thickness: 0.6, color: Color(0xFFEEEEEE)),
      );

  // ── Safe Word row ───────────────────────────────────────────────────────────

  Widget _buildSafeWordRow() {
    final hasWord = _safeWord != null && _safeWord!.isNotEmpty;
    return _settingsRow(
      icon: Icons.lock_outline_rounded,
      iconBg: const Color(0xFFE8F3EF),
      iconColor: _kAccent,
      title: 'Safe Word',
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (hasWord)
            Text(
              '●' * (_safeWord!.length.clamp(0, 8)),
              style: const TextStyle(
                  letterSpacing: 2,
                  color: Color(0xFF555555),
                  fontSize: 12),
            )
          else
            Text('Not set',
                style: TextStyle(
                    fontSize: 13, color: Colors.grey.shade400)),
          const SizedBox(width: 6),
          Icon(Icons.chevron_right,
              color: Colors.grey.shade400, size: 20),
        ],
      ),
      onTap: () async {
        await Navigator.push(context,
            MaterialPageRoute(
                builder: (_) => const ChangeSafeWordScreen()));
        _loadAll();
      },
    );
  }

  // ── Country row ─────────────────────────────────────────────────────────────

  Widget _buildCountryRow() {
    return _settingsRow(
      icon: Icons.verified_user_outlined,
      iconBg: const Color(0xFFE3F0FB),
      iconColor: const Color(0xFF1565C0),
      title: 'Data Coverage',
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('🇬🇧', style: TextStyle(fontSize: 18)),
          const SizedBox(width: 6),
          Text('UK — Full',
              style: TextStyle(
                  fontSize: 13, color: Colors.grey.shade600)),
          const SizedBox(width: 6),
          Icon(Icons.chevron_right,
              color: Colors.grey.shade400, size: 20),
        ],
      ),
      onTap: () => _showDataCoverageSheet(context),
    );
  }

  void _showDataCoverageSheet(BuildContext ctx) {
    showDataCoverageSheet(ctx);
  }

  // ── Contacts row ────────────────────────────────────────────────────────────

  Widget _buildContactsRow() {
    final count = _contacts.length;
    return _settingsRow(
      icon: Icons.people_outline_rounded,
      iconBg: const Color(0xFFE0F4F1),
      iconColor: const Color(0xFF00796B),
      title: 'Trusted Contacts',
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (count > 0) ...[
            SizedBox(
              width: count == 1 ? 24 : (count == 2 ? 38 : 52),
              height: 24,
              child: Stack(
                children: _contacts.take(3).toList().asMap().entries.map((e) {
                  final initials =
                      (e.value['name'] as String? ?? '?')[0].toUpperCase();
                  return Positioned(
                    left: e.key * 14.0,
                    child: CircleAvatar(
                      radius: 12,
                      backgroundColor: const Color(0xFF00796B),
                      child: Text(initials,
                          style: const TextStyle(
                              fontSize: 10,
                              color: Colors.white,
                              fontWeight: FontWeight.w700)),
                    ),
                  );
                }).toList(),
              ),
            ),
            const SizedBox(width: 6),
            Text('$count added',
                style: TextStyle(
                    fontSize: 13, color: Colors.grey.shade600)),
          ] else
            Text('None added',
                style: TextStyle(
                    fontSize: 13, color: Colors.red.shade400)),
          const SizedBox(width: 6),
          Icon(Icons.chevron_right,
              color: Colors.grey.shade400, size: 20),
        ],
      ),
      onTap: () async {
        await Navigator.push(
            context,
            MaterialPageRoute(
                builder: (_) => const ManageTrustedContactsScreen()));
        _loadAll();
      },
    );
  }

  // ── Motion row ──────────────────────────────────────────────────────────────

  Widget _buildMotionRow() {
    final calibrated = _motionCalibrated;
    return _settingsRow(
      icon: Icons.sensors_rounded,
      iconBg:
          calibrated ? const Color(0xFFE8F3EF) : const Color(0xFFFFF3E0),
      iconColor: calibrated ? _kAccent : Colors.orange.shade700,
      title: 'Motion AI Baseline',
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
            decoration: BoxDecoration(
              color: calibrated
                  ? const Color(0xFFE8F3EF)
                  : Colors.orange.shade50,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: calibrated ? _kAccent : Colors.orange.shade600,
                  ),
                ),
                const SizedBox(width: 5),
                Text(
                  calibrated ? 'Calibrated' : 'Not set',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: calibrated ? _kAccent : Colors.orange.shade700,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 6),
          Icon(Icons.chevron_right,
              color: Colors.grey.shade400, size: 20),
        ],
      ),
      onTap: () async {
        await Navigator.push(
            context,
            MaterialPageRoute(
                builder: (_) =>
                    const MotionBaselineCalibrationScreen()));
        _loadAll();
      },
    );
  }

  // ── Motion Sensitivity row ───────────────────────────────────────────────

  // Map threshold value → label string
  String _sensitivityLabel(double t) {
    if (t <= 0.61) return 'High';
    if (t >= 0.79) return 'Low';
    return 'Normal';
  }

  Widget _buildSensitivityRow() {
    final label = _sensitivityLabel(_motionSensitivityThreshold);
    return Material(
      color: Colors.white,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: const Color(0xFFFCE4EC),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(Icons.tune_rounded,
                  color: _kAccent, size: 20),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Text(
                        'Motion AI Sensitivity',
                        style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w500,
                            color: Color(0xFF1A1A1A)),
                      ),
                      const SizedBox(width: 6),
                      Tooltip(
                        message:
                            'Requires a completed Motion AI Baseline calibration.\nWithout it, anomaly detection remains inactive.',
                        triggerMode: TooltipTriggerMode.tap,
                        showDuration: const Duration(seconds: 4),
                        decoration: BoxDecoration(
                          color: const Color(0xFF2C2C3E),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        textStyle: const TextStyle(
                          fontSize: 12.5,
                          color: Colors.white,
                          height: 1.5,
                        ),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 10),
                        child: Icon(Icons.info_outline_rounded,
                            size: 16, color: _kAccent),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    label == 'High'
                        ? 'Alerts on subtle movements (e.g. dark alley)'
                        : label == 'Low'
                            ? 'Fewer alerts for bumpy rides or jogging'
                            : 'Balanced detection (default)',
                    style:
                        TextStyle(fontSize: 12, color: Colors.grey.shade500),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      _sensitivityChip(
                        label: 'High',
                        threshold: 0.6,
                        selected: label == 'High',
                        color: Colors.red.shade400,
                      ),
                      const SizedBox(width: 8),
                      _sensitivityChip(
                        label: 'Normal',
                        threshold: 0.7,
                        selected: label == 'Normal',
                        color: _kAccent,
                      ),
                      const SizedBox(width: 8),
                      _sensitivityChip(
                        label: 'Low',
                        threshold: 0.8,
                        selected: label == 'Low',
                        color: Colors.teal.shade600,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sensitivityChip({
    required String label,
    required double threshold,
    required bool selected,
    required Color color,
  }) {
    return GestureDetector(
      onTap: () async {
        await _motionService.setAnomalyThreshold(threshold);
        if (mounted) {
          setState(() => _motionSensitivityThreshold = threshold);
        }
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding:
            const EdgeInsets.symmetric(horizontal: 18, vertical: 7),
        decoration: BoxDecoration(
          color: selected ? color : Colors.grey.shade100,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
              color: selected ? color : Colors.grey.shade300, width: 1.5),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: selected ? Colors.white : Colors.grey.shade600,
          ),
        ),
      ),
    );
  }

  // ── Feature row ─────────────────────────────────────────────────────────────

  Widget _buildFeatureRow({
    required IconData icon,
    required String label,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return _settingsRow(
      icon: icon,
      iconBg: const Color(0xFFF0F0F0),
      iconColor: Colors.grey.shade600,
      title: label,
      subtitle: subtitle,
      trailing: Icon(Icons.chevron_right,
          color: Colors.grey.shade400, size: 20),
      onTap: onTap,
    );
  }

  // ── Generic settings row ────────────────────────────────────────────────────

  Widget _settingsRow({
    required IconData icon,
    required Color iconBg,
    required Color iconColor,
    required String title,
    String? subtitle,
    required Widget trailing,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.white,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding:
              const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          child: Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: iconBg,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, color: iconColor, size: 20),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w500,
                          color: Color(0xFF1A1A1A)),
                    ),
                    if (subtitle != null) ...[
                      const SizedBox(height: 2),
                      Text(subtitle,
                          style: TextStyle(
                              fontSize: 12,
                              color: Colors.grey.shade500)),
                    ],
                  ],
                ),
              ),
              trailing,
            ],
          ),
        ),
      ),
    );
  }
}
