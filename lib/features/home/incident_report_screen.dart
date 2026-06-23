import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../models/incident_report.dart';
import '../../services/incident_report_service.dart';
import 'helpline_contacts_screen.dart';

const _kAccent = Color(0xFFB07080);
const _kBg = Color(0xFFFFF0F5);
const _kSoft = Color(0xFFFFF5F8);
const _kBorder = Color(0xFFF2D5E2);

/// Full-screen incident reporting form + history list.
///
/// Accessible from the Guidance Assistant ("Report / Get Help" section).
/// Users can describe what happened, pick a category and urgency,
/// auto-attach their current GPS location, and save locally.
/// Past reports are shown below the form and can be shared or deleted.
class IncidentReportScreen extends StatefulWidget {
  const IncidentReportScreen({super.key});

  @override
  State<IncidentReportScreen> createState() => _IncidentReportScreenState();
}

class _IncidentReportScreenState extends State<IncidentReportScreen>
    with SingleTickerProviderStateMixin {
  final _formKey = GlobalKey<FormState>();
  final _descController = TextEditingController();
  final _locationController = TextEditingController();
  final _service = IncidentReportService();
  late final TabController _tabController;

  IncidentCategory _category = IncidentCategory.harassment;
  IncidentUrgency _urgency = IncidentUrgency.medium;
  int _formResetKey = 0;
  DateTime _incidentDate = DateTime.now();
  bool _isAnonymous = false;
  bool _attachLocation = true;
  bool _isSubmitting = false;
  bool _isLoading = true;

  double? _lat;
  double? _lon;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _init();
  }

  Future<void> _init() async {
    await _service.initialize();
    if (_attachLocation) await _fetchLocation();
    if (mounted) setState(() => _isLoading = false);
  }

  Future<void> _fetchLocation() async {
    try {
      final pos = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );
      _lat = pos.latitude;
      _lon = pos.longitude;
    } catch (_) {
      // Location not available — that's fine, user can type it.
    }
  }

  @override
  void dispose() {
    _tabController.dispose();
    _descController.dispose();
    _locationController.dispose();
    super.dispose();
  }

  // ── Submit ──────────────────────────────────────────────────────────────
  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _isSubmitting = true);

    final report = IncidentReport(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      category: _category,
      description: _descController.text.trim(),
      incidentDate: _incidentDate,
      latitude: _attachLocation ? _lat : null,
      longitude: _attachLocation ? _lon : null,
      locationDescription: _locationController.text.trim().isEmpty
          ? null
          : _locationController.text.trim(),
      urgency: _urgency,
      isAnonymous: _isAnonymous,
      createdAt: DateTime.now(),
    );

    await _service.addReport(report);
    _descController.clear();
    _locationController.clear();

    if (mounted) {
      setState(() {
        _isSubmitting = false;
        _category = IncidentCategory.harassment;
        _urgency = IncidentUrgency.medium;
        _incidentDate = DateTime.now();
        _isAnonymous = false;
        _formResetKey++; // forces dropdowns to reinitialise with reset values
      });
      // Switch to My Reports tab so user sees their saved report
      _tabController.animateTo(1);

      // Show the "Send to Police" bottom-sheet so the user can
      // actually forward it — a saved-only report doesn't reach anyone.
      _showSendToPoliceSheet(report);
    }
  }

  // ── Date picker ─────────────────────────────────────────────────────────
  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _incidentDate,
      firstDate: now.subtract(const Duration(days: 365)),
      lastDate: now,
    );
    if (picked != null && mounted) {
      final time = await showTimePicker(
        context: context,
        initialTime: TimeOfDay.fromDateTime(_incidentDate),
      );
      setState(() {
        _incidentDate = DateTime(
          picked.year,
          picked.month,
          picked.day,
          time?.hour ?? _incidentDate.hour,
          time?.minute ?? _incidentDate.minute,
        );
      });
    }
  }

  // ── Delete ──────────────────────────────────────────────────────────────
  Future<void> _deleteReport(String id) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete report?'),
        content:
            const Text('This will permanently remove the report from your device.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await _service.deleteReport(id);
      setState(() {});
    }
  }

  // ── Share single report ─────────────────────────────────────────────────
  void _shareReport(IncidentReport r) {
    Share.share(r.toShareText(), subject: 'SheSafe Incident Report');
  }

  // ── Email report to police ──────────────────────────────────────────────
  Future<void> _emailToPolice(IncidentReport r) async {
    final subject = Uri.encodeComponent(
      'Incident Report — ${r.category.displayName} (${_formatDateTime(r.incidentDate)})',
    );
    final body = Uri.encodeComponent(r.toShareText());
    final uri = Uri.parse('mailto:?subject=$subject&body=$body');
    try {
      final ok = await launchUrl(uri);
      if (!ok && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not open email app')),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not open email app')),
        );
      }
    }
  }

  // ── Call police ─────────────────────────────────────────────────────────
  Future<void> _callPolice({bool emergency = false}) async {
    final number = emergency ? '999' : '101';
    final uri = Uri.parse('tel:$number');
    try {
      await launchUrl(uri);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not open dialler for $number')),
        );
      }
    }
  }

  // ── Post-save: "Send to Police" bottom-sheet ───────────────────────────
  void _showSendToPoliceSheet(IncidentReport report) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Handle
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey.shade300,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 16),
              Icon(Icons.check_circle, size: 48, color: Colors.green.shade600),
              const SizedBox(height: 10),
              const Text(
                'Report Saved!',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 6),
              Text(
                'Your report is stored on your device.\n'
                'To make it reach the police, choose an option below:',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13,
                  color: Colors.grey.shade700,
                  height: 1.45,
                ),
              ),
              const SizedBox(height: 20),

              // ── Email to Police ──
              _policeActionTile(
                icon: Icons.email_outlined,
                color: _kAccent,
                title: 'Email Report to Police',
                subtitle:
                    'Opens your email app with the full report pre-filled — '
                    'just add the recipient and send.',
                onTap: () {
                  Navigator.pop(ctx);
                  _emailToPolice(report);
                },
              ),
              const SizedBox(height: 10),

              // ── Call 101 ──
              _policeActionTile(
                icon: Icons.phone,
                color: Colors.blue.shade700,
                title: 'Call 101 (Non-Emergency)',
                subtitle:
                    'Speak to local police. You can read your saved '
                    'report to the operator.',
                onTap: () {
                  Navigator.pop(ctx);
                  _callPolice();
                },
              ),
              const SizedBox(height: 10),

              // ── Report Online ──
              _policeActionTile(
                icon: Icons.language,
                color: Colors.teal.shade700,
                title: 'Report Online (police.uk)',
                subtitle:
                    'Opens the official police website where you can '
                    'file a report directly.',
                onTap: () async {
                  Navigator.pop(ctx);
                  await launchUrl(
                    Uri.parse('https://www.police.uk/'),
                    mode: LaunchMode.externalApplication,
                  );
                },
              ),
              const SizedBox(height: 10),

              // ── Share via WhatsApp / Text ──
              _policeActionTile(
                icon: Icons.share,
                color: _kAccent,
                title: 'Share via WhatsApp / Text',
                subtitle:
                    'Send the report to a trusted person, solicitor, '
                    'or support service.',
                onTap: () {
                  Navigator.pop(ctx);
                  _shareReport(report);
                },
              ),
              const SizedBox(height: 10),

              // ── Call 999 (emergency) ──
              _policeActionTile(
                icon: Icons.emergency,
                color: Colors.red.shade700,
                title: 'Call 999 (Emergency)',
                subtitle: 'Only if you are in immediate danger right now.',
                onTap: () {
                  Navigator.pop(ctx);
                  _callPolice(emergency: true);
                },
              ),

              const SizedBox(height: 16),
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text(
                  'Keep on file for now',
                  style: TextStyle(
                    fontSize: 13,
                    color: Colors.grey.shade500,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _policeActionTile({
    required IconData icon,
    required Color color,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withValues(alpha: 0.25)),
          color: color.withValues(alpha: 0.04),
        ),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, size: 20, color: color),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: color,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: 11,
                      color: Colors.grey.shade600,
                      height: 1.3,
                    ),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right, size: 20, color: color.withValues(alpha: 0.5)),
          ],
        ),
      ),
    );
  }

  // ── Export all ──────────────────────────────────────────────────────────
  void _exportAll() {
    Share.share(_service.exportAllAsText(),
        subject: 'SheSafe — All Incident Reports');
  }

  // ══════════════════════════════════════════════════════════════════════════
  // BUILD
  // ══════════════════════════════════════════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _kBg,
      appBar: AppBar(
        title: const Text('Report an Incident'),
        centerTitle: true,
        backgroundColor: Colors.white,
        foregroundColor: const Color(0xFF1A1A1A),
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        actions: [
          if (_service.count > 0)
            IconButton(
              icon: const Icon(Icons.ios_share),
              tooltip: 'Export all reports',
              onPressed: _exportAll,
            ),
        ],
        bottom: TabBar(
          controller: _tabController,
          labelColor: _kAccent,
          unselectedLabelColor: Colors.grey.shade500,
          indicatorColor: _kAccent,
          indicatorWeight: 3,
          labelStyle:
              const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
          unselectedLabelStyle: const TextStyle(fontSize: 14),
          tabs: [
            Tab(
              icon: Icon(Icons.edit_note, size: 20),
              text: 'New Report',
            ),
            Tab(
              icon: Badge(
                isLabelVisible: _service.count > 0,
                label: Text('${_service.count}',
                    style: const TextStyle(fontSize: 10)),
                child: Icon(Icons.folder_open, size: 20),
              ),
              text: 'My Reports',
            ),
          ],
        ),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : TabBarView(
              controller: _tabController,
              children: [
                // ── Tab 1: New Report form ──
                SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 20, vertical: 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildInfoBanner(),
                      const SizedBox(height: 16),
                      _buildForm(),
                      const SizedBox(height: 32),
                      _buildExternalLinks(),
                      const SizedBox(height: 24),
                    ],
                  ),
                ),
                // ── Tab 2: My Reports list ──
                _buildMyReportsTab(),
              ],
            ),
    );
  }

  // ── Info banner ─────────────────────────────────────────────────────────
  Widget _buildInfoBanner() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: _kSoft,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _kBorder),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.info_outline, size: 20, color: _kAccent),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Saving a report stores it on your device only — it does NOT '
              'automatically reach the police. After saving, you will be '
              'prompted to email, call, or report online so it actually '
              'gets to the authorities.',
              style: TextStyle(
                fontSize: 12,
                color: const Color(0xFF7A3552),
                height: 1.45,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Form ────────────────────────────────────────────────────────────────
  Widget _buildForm() {
    return Form(
      key: _formKey,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.04),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Section header
            Row(
              children: [
                const Icon(Icons.edit_note, size: 20, color: _kAccent),
                const SizedBox(width: 8),
                Text(
                  'New Report',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: const Color(0xFF7A3552),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),

            // ── Category
            _fieldLabel('What happened?'),
            const SizedBox(height: 6),
            DropdownButtonFormField<IncidentCategory>(
              key: ValueKey(('category', _formResetKey)),
              initialValue: _category,
              isExpanded: true,
              decoration: _inputDecoration(),
              items: IncidentCategory.values
                  .map((c) => DropdownMenuItem(
                        value: c,
                        child: Text(c.displayName,
                            style: const TextStyle(fontSize: 14)),
                      ))
                  .toList(),
              onChanged: (v) => setState(() => _category = v!),
            ),
            const SizedBox(height: 14),

            // ── Description
            _fieldLabel('Describe what happened'),
            const SizedBox(height: 6),
            TextFormField(
              controller: _descController,
              maxLines: 4,
              maxLength: 1000,
              decoration: _inputDecoration(
                hint: 'Include as much detail as you feel comfortable sharing…',
              ),
              style: const TextStyle(fontSize: 14),
              validator: (v) => (v == null || v.trim().isEmpty)
                  ? 'Please describe what happened'
                  : null,
            ),
            const SizedBox(height: 14),

            // ── Date / time
            _fieldLabel('When did it happen?'),
            const SizedBox(height: 6),
            InkWell(
              onTap: _pickDate,
              borderRadius: BorderRadius.circular(10),
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 14, vertical: 13),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.grey.shade300),
                ),
                child: Row(
                  children: [
                    Icon(Icons.calendar_today,
                        size: 16, color: Colors.grey.shade600),
                    const SizedBox(width: 10),
                    Text(
                      _formatDateTime(_incidentDate),
                      style: const TextStyle(fontSize: 14),
                    ),
                    const Spacer(),
                    Icon(Icons.edit, size: 14, color: Colors.grey.shade400),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 14),

            // ── Location (optional text)
            _fieldLabel('Location (optional)'),
            const SizedBox(height: 6),
            TextFormField(
              controller: _locationController,
              decoration: _inputDecoration(
                hint: 'e.g. "Bus stop on High Street" or leave blank',
              ),
              style: const TextStyle(fontSize: 14),
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                Checkbox(
                  value: _attachLocation,
                  onChanged: (v) => setState(() => _attachLocation = v!),
                  visualDensity: VisualDensity.compact,
                ),
                Expanded(
                  child: Text(
                    'Attach my current GPS coordinates',
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),

            // ── Urgency
            _fieldLabel('How urgent is this?'),
            const SizedBox(height: 6),
            DropdownButtonFormField<IncidentUrgency>(
              key: ValueKey(('urgency', _formResetKey)),
              initialValue: _urgency,
              isExpanded: true,
              decoration: _inputDecoration(),
              items: IncidentUrgency.values
                  .map((u) => DropdownMenuItem(
                        value: u,
                        child: Text(u.displayName,
                            style: const TextStyle(fontSize: 14)),
                      ))
                  .toList(),
              onChanged: (v) => setState(() => _urgency = v!),
            ),
            const SizedBox(height: 14),

            // ── Anonymous toggle
            SwitchListTile(
              title: const Text('Submit anonymously',
                  style: TextStyle(fontSize: 14)),
              subtitle: Text(
                'Your name won\'t appear on the exported report',
                style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
              ),
              value: _isAnonymous,
              onChanged: (v) => setState(() => _isAnonymous = v),
              contentPadding: EdgeInsets.zero,
            ),
            const SizedBox(height: 16),

            // ── Submit button
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _isSubmitting ? null : _submit,
                icon: _isSubmitting
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white),
                      )
                    : const Icon(Icons.send_rounded, size: 18),
                label: Text(_isSubmitting ? 'Saving…' : 'Submit Report'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _kAccent,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                  textStyle: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.bold),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── My Reports tab (full tab content) ────────────────────────────────
  Widget _buildMyReportsTab() {
    final saved = _service.reports;

    if (saved.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.folder_open,
                  size: 64, color: Colors.grey.shade300),
              const SizedBox(height: 16),
              Text(
                'No reports yet',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: Colors.grey.shade500,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'When you submit an incident report, it will appear here.\nYou can share or export reports at any time.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13,
                  color: Colors.grey.shade400,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 20),
              OutlinedButton.icon(
                onPressed: () => _tabController.animateTo(0),
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Create a Report'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: _kAccent,
                  side: const BorderSide(color: _kBorder),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                  padding: const EdgeInsets.symmetric(
                      horizontal: 20, vertical: 12),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      itemCount: saved.length + 1, // +1 for the header
      itemBuilder: (context, index) {
        if (index == 0) {
          // Header
          return Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Row(
              children: [
                Icon(Icons.folder_open,
                  size: 18, color: _kAccent),
                const SizedBox(width: 8),
                Text(
                  '${saved.length} report${saved.length == 1 ? '' : 's'} on file',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: Colors.grey.shade700,
                  ),
                ),
                const Spacer(),
                if (saved.length > 1)
                  TextButton.icon(
                    onPressed: _exportAll,
                    icon: const Icon(Icons.ios_share, size: 14),
                    label: const Text('Export All',
                        style: TextStyle(fontSize: 12)),
                    style: TextButton.styleFrom(
                      foregroundColor: _kAccent,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 4),
                      minimumSize: Size.zero,
                      tapTargetSize:
                          MaterialTapTargetSize.shrinkWrap,
                    ),
                  ),
              ],
            ),
          );
        }
        return _reportCard(saved[index - 1]);
      },
    );
  }

  Widget _reportCard(IncidentReport r) {
    final color = _urgencyColor(r.urgency);
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.3)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Top row: category badge + urgency badge
            Row(
              children: [
                _badge(r.category.displayName, _kSoft,
                  _kAccent),
                const SizedBox(width: 6),
                _badge(_urgencyLabel(r.urgency), color.withValues(alpha: 0.12),
                    color),
                const Spacer(),
                Text(
                  _formatDateTime(r.createdAt),
                  style:
                      TextStyle(fontSize: 11, color: Colors.grey.shade500),
                ),
              ],
            ),
            const SizedBox(height: 10),

            // Description
            Text(
              r.description,
              style:
                  TextStyle(fontSize: 13, color: Colors.grey.shade800, height: 1.4),
            ),

            // Location if present
            if (r.locationDescription != null &&
                r.locationDescription!.isNotEmpty) ...[
              const SizedBox(height: 6),
              Row(
                children: [
                  Icon(Icons.location_on,
                      size: 13, color: Colors.grey.shade500),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      r.locationDescription!,
                      style: TextStyle(
                          fontSize: 11, color: Colors.grey.shade500),
                      maxLines: 2,
                    ),
                  ),
                ],
              ),
            ],

            const SizedBox(height: 12),

            // ── Primary action: Send to Police ──
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: () => _showSendToPoliceSheet(r),
                icon: const Icon(Icons.local_police_outlined, size: 18),
                label: const Text('Send to Police'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _kAccent,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 11),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                  textStyle: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.bold),
                ),
              ),
            ),
            const SizedBox(height: 8),

            // ── Secondary actions ──
            Row(
              children: [
                Expanded(
                  child: _smallButton(
                    icon: Icons.share,
                    label: 'Share',
                    onTap: () => _shareReport(r),
                  ),
                ),
                const SizedBox(width: 8),
                _smallButton(
                  icon: Icons.delete_outline,
                  label: 'Delete',
                  color: Colors.red.shade400,
                  onTap: () => _deleteReport(r.id),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // ── After-submit guide + helpline link ─────────────────────────────────
  Widget _buildExternalLinks() {
    return Column(
      children: [
        // ── How your report reaches police ──
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: _kBorder),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.03),
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
                  const Icon(Icons.verified_user, size: 18, color: _kAccent),
                  const SizedBox(width: 8),
                  Text(
                    'How your report reaches police',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      color: const Color(0xFF7A3552),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              _guideStep('1', 'Fill in the form above and tap Submit.'),
              _guideStep('2', 'A menu appears — choose Email, Call 101,\nor Report Online to send it to police.'),
              _guideStep('3', 'Your report is also saved in My Reports\nso you always have a personal copy.'),
              const SizedBox(height: 6),
              Container(
                width: double.infinity,
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: _kSoft,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  'No account needed. Reports are stored securely\n'
                  'on your device and never shared without your action.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 11,
                    color: const Color(0xFF7A3552),
                    height: 1.4,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),

        // ── Need more help? → Helpline Contacts ──
        InkWell(
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(
                builder: (_) => const HelplineContactsScreen()),
          ),
          borderRadius: BorderRadius.circular(14),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: _kBorder),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.03),
                  blurRadius: 6,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Row(
              children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: _kSoft,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.support_agent,
                      size: 22, color: _kAccent),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Need help? View all helplines',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                          color: const Color(0xFF7A3552),
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        'Police, domestic abuse, stalking, fraud & more — all numbers and online reporting links in one place.',
                        style: TextStyle(
                          fontSize: 11,
                          color: Colors.grey.shade600,
                          height: 1.35,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Icon(Icons.arrow_forward_ios,
                    size: 16, color: _kAccent),
              ],
            ),
          ),
        ),
      ],
    );
  }

  // ignore: unused_element
  Widget _externalLink(String label, String url) {
    return InkWell(
      onTap: () => _promptSaveBeforeExternal(label, url),
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            const Icon(Icons.open_in_new, size: 12, color: _kAccent),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  color: _kAccent,
                  decoration: TextDecoration.underline,
                ),
              ),
            ),
            Text(
              'Opens in browser',
              style: TextStyle(fontSize: 10, color: Colors.grey.shade500),
            ),
          ],
        ),
      ),
    );
  }

  /// Shows a dialog before opening an external reporting website.
  /// Lets the user save a quick record so it appears in "My Reports".
  Future<void> _promptSaveBeforeExternal(String siteName, String url) async {
    final noteController = TextEditingController();
    final categoryNotifier = ValueNotifier<IncidentCategory>(IncidentCategory.other);

    final shouldSave = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            const Icon(Icons.save_outlined, size: 22, color: _kAccent),
            const SizedBox(width: 8),
            const Expanded(
              child: Text('Save a copy before you go?',
                  style: TextStyle(fontSize: 16)),
            ),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'You\'re about to report via "$siteName". '
                'Would you like to save a quick note in My Reports so you '
                'have a personal record of what you reported?',
                style: TextStyle(
                  fontSize: 13,
                  color: Colors.grey.shade700,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 16),

              // Category picker
              Text('Category',
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: Colors.grey.shade600)),
              const SizedBox(height: 4),
              ValueListenableBuilder<IncidentCategory>(
                valueListenable: categoryNotifier,
                builder: (_, cat, _) => DropdownButtonFormField<IncidentCategory>(
                  initialValue: cat,
                  isExpanded: true,
                  decoration: InputDecoration(
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10)),
                    isDense: true,
                  ),
                  items: IncidentCategory.values
                      .map((c) => DropdownMenuItem(
                            value: c,
                            child: Text(c.displayName,
                                style: const TextStyle(fontSize: 13)),
                          ))
                      .toList(),
                  onChanged: (v) {
                    if (v != null) categoryNotifier.value = v;
                  },
                ),
              ),
              const SizedBox(height: 12),

              // Quick description
              Text('Brief note (optional)',
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: Colors.grey.shade600)),
              const SizedBox(height: 4),
              TextField(
                controller: noteController,
                maxLines: 3,
                maxLength: 500,
                decoration: InputDecoration(
                  hintText: 'e.g. "Reported harassment near campus via police.uk"',
                  hintStyle: TextStyle(fontSize: 12, color: Colors.grey.shade400),
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10)),
                ),
                style: const TextStyle(fontSize: 13),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('Skip',
                style: TextStyle(color: Colors.grey.shade500, fontSize: 13)),
          ),
          ElevatedButton.icon(
            onPressed: () => Navigator.pop(ctx, true),
            icon: const Icon(Icons.save, size: 16),
            label: const Text('Save & Open Site'),
            style: ElevatedButton.styleFrom(
              backgroundColor: _kAccent,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
              textStyle: const TextStyle(fontSize: 13),
            ),
          ),
        ],
      ),
    );

    // Save a record if the user chose to
    if (shouldSave == true) {
      final note = noteController.text.trim().isEmpty
          ? 'Reported externally via $siteName'
          : noteController.text.trim();

      final report = IncidentReport(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        category: categoryNotifier.value,
        description: '$note\n\n[Reported via: $siteName]\n[URL: $url]',
        incidentDate: DateTime.now(),
        latitude: _lat,
        longitude: _lon,
        urgency: IncidentUrgency.medium,
        isAnonymous: false,
        createdAt: DateTime.now(),
      );

      await _service.addReport(report);
      if (mounted) {
        setState(() {});
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Row(
              children: [
                Icon(Icons.check_circle, color: Colors.white, size: 16),
                SizedBox(width: 8),
                Expanded(child: Text('Saved to My Reports')),
              ],
            ),
            backgroundColor: _kAccent,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10)),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    }

    noteController.dispose();
    categoryNotifier.dispose();

    // Open the external site regardless
    final uri = Uri.parse(url);
    try {
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!ok && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not open $url')),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not open $url')),
        );
      }
    }
  }

  Widget _guideStep(String number, String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 20, height: 20,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: _kAccent,
              shape: BoxShape.circle,
            ),
            child: Text(number,
                style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: Colors.white)),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text,
                style: TextStyle(
                  fontSize: 12,
                  color: const Color(0xFF7A3552),
                  height: 1.35,
                )),
          ),
        ],
      ),
    );
  }

  // ── Helper widgets ────────────────────────────────────────────────────
  Widget _fieldLabel(String text) {
    return Text(
      text,
      style: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w600,
        color: Colors.grey.shade700,
      ),
    );
  }

  InputDecoration _inputDecoration({String? hint}) {
    return InputDecoration(
      hintText: hint,
      hintStyle: TextStyle(fontSize: 13, color: Colors.grey.shade400),
      contentPadding:
          const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: Colors.grey.shade300),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: Colors.grey.shade300),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: _kAccent, width: 1.5),
      ),
    );
  }

  Color _urgencyColor(IncidentUrgency u) {
    switch (u) {
      case IncidentUrgency.low:
        return const Color(0xFF9A7C8A);
      case IncidentUrgency.medium:
        return const Color(0xFFB07080);
      case IncidentUrgency.high:
        return const Color(0xFFAE4B6D);
    }
  }

  String _urgencyLabel(IncidentUrgency u) {
    switch (u) {
      case IncidentUrgency.low:
        return 'Low';
      case IncidentUrgency.medium:
        return 'Medium';
      case IncidentUrgency.high:
        return 'High';
    }
  }

  Widget _badge(String text, Color bg, Color fg) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(text,
          style:
              TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: fg)),
    );
  }

  Widget _smallButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    Color? color,
  }) {
    final c = color ?? Colors.grey.shade600;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: c.withValues(alpha: 0.3)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: c),
            const SizedBox(width: 4),
            Text(label, style: TextStyle(fontSize: 12, color: c)),
          ],
        ),
      ),
    );
  }

  String _formatDateTime(DateTime dt) {
    final d = dt.day.toString().padLeft(2, '0');
    final m = dt.month.toString().padLeft(2, '0');
    final y = dt.year;
    final h = dt.hour.toString().padLeft(2, '0');
    final min = dt.minute.toString().padLeft(2, '0');
    return '$d/$m/$y $h:$min';
  }
}
