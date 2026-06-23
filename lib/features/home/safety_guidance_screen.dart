import 'package:flutter/material.dart';
import '../../services/safety_guidance_service.dart';
import '../../models/safety_guidance.dart';

// ── Theme colours — matches Safety Profile/settings screen ─────────────────
const _kAccent = Color(0xFFB07080);
const _kBg = Color(0xFFFFF0F5);
const _kBanner = Color(0xFFFFF5F8);
const _kBorder = Color(0xFFF2D5E2);

/// Safety Guidance screen (B3) — displays evidence-based safety advice.
/// Visual theme matches the Safety Assistant screen.
class SafetyGuidanceScreen extends StatefulWidget {
  const SafetyGuidanceScreen({super.key});

  @override
  State<SafetyGuidanceScreen> createState() => _SafetyGuidanceScreenState();
}

class _SafetyGuidanceScreenState extends State<SafetyGuidanceScreen> {
  final SafetyGuidanceService _service = SafetyGuidanceService();
  GuidanceCategory? _selectedCategory;
  List<SafetyGuidance> _displayedGuidance = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    await _service.initialize();
    if (!mounted) return;
    setState(() {
      _displayedGuidance = _service.allEntries;
      _isLoading = false;
    });
  }

  void _filterByCategory(GuidanceCategory? category) {
    setState(() {
      _selectedCategory = category;
      _displayedGuidance = category == null
          ? _service.allEntries
          : _service.getByCategories([category]);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _kBg,
      appBar: AppBar(
        backgroundColor: Colors.white,
        foregroundColor: const Color(0xFF1A1A1A),
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: const Row(
          children: [
            Icon(Icons.menu_book_outlined, color: _kAccent),
            SizedBox(width: 8),
            Text('Safety Guidance'),
          ],
        ),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator(color: _kAccent))
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildDisclaimerBanner(),
                _buildCategoryFilter(),
                Expanded(child: _buildGuidanceList()),
              ],
            ),
    );
  }

  // ── Disclaimer banner ────────────────────────────────────────────────────

  Widget _buildDisclaimerBanner() {
    return Container(
      width: double.infinity,
      color: _kBanner,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.info_outline, size: 16, color: _kAccent),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Evidence-based tips from UK Police, Suzy Lamplugh Trust, and Women\'s Aid. '
              'In an emergency, call 999.',
              style: TextStyle(
                fontSize: 11.5,
                color: const Color(0xFF7A3552),
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Category filter ──────────────────────────────────────────────────────

  Widget _buildCategoryFilter() {
    return Container(
      color: _kBg,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
        child: Row(
          children: [
            _buildCategoryChip('All', null),
            const SizedBox(width: 8),
            ...GuidanceCategory.values.map((cat) => Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: _buildCategoryChip(cat.displayName, cat),
                )),
          ],
        ),
      ),
    );
  }

  // ── Guidance list ────────────────────────────────────────────────────────

  Widget _buildGuidanceList() {
    if (_displayedGuidance.isEmpty) {
      return Center(
        child: Text(
          'No guidance available',
          style: const TextStyle(color: Color(0xFFA77B95)),
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 20),
      itemCount: _displayedGuidance.length,
      itemBuilder: (context, index) =>
          _buildGuidanceCard(_displayedGuidance[index]),
    );
  }

  Widget _buildCategoryChip(String label, GuidanceCategory? category) {
    final isSelected = _selectedCategory == category;
    return FilterChip(
      label: Text(label),
      selected: isSelected,
      onSelected: (_) => _filterByCategory(category),
      backgroundColor: Colors.white,
      selectedColor: _kAccent,
      checkmarkColor: Colors.white,
      side: BorderSide(
        color: isSelected ? _kAccent : _kBorder,
      ),
      labelStyle: TextStyle(
        fontSize: 12.5,
        color: isSelected ? Colors.white : const Color(0xFF7A3552),
        fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 0),
    );
  }

  Widget _buildGuidanceCard(SafetyGuidance guidance) {
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      elevation: 0,
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: _kBorder),
      ),
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        collapsedShape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        leading: Container(
          padding: const EdgeInsets.all(7),
          decoration: BoxDecoration(
            color: _kBg,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(
            _getCategoryIcon(guidance.category),
            size: 18,
            color: _kAccent,
          ),
        ),
        title: Text(
          guidance.situation,
          style: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.bold,
            color: Color(0xFF7A3552),
          ),
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Text(
            guidance.category.displayName,
            style: TextStyle(fontSize: 11, color: Colors.grey.shade700),
          ),
        ),
        children: [
          const Divider(height: 1, color: _kBorder),
          const SizedBox(height: 12),
          _advisoryRow(
            icon: Icons.check_circle,
            iconColor: _kAccent,
            label: 'What to do',
            text: guidance.advice,
          ),
          const SizedBox(height: 12),
          _advisoryRow(
            icon: Icons.info_outline,
            iconColor: const Color(0xFFA77B95),
            label: 'Why this works',
            text: guidance.why,
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: _kBanner,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: _kBorder),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.verified, size: 14, color: Colors.brown.shade400),
                const Icon(Icons.verified, size: 14, color: _kAccent),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'Source: ${guidance.source}',
                    style: TextStyle(
                      fontSize: 11,
                      color: const Color(0xFF7A3552),
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _advisoryRow({
    required IconData icon,
    required Color iconColor,
    required String label,
    required String text,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18, color: iconColor),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '$label:',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: Colors.grey.shade700,
                ),
              ),
              const SizedBox(height: 2),
              Text(text, style: const TextStyle(fontSize: 13, height: 1.45)),
            ],
          ),
        ),
      ],
    );
  }

  IconData _getCategoryIcon(GuidanceCategory category) {
    switch (category) {
      case GuidanceCategory.routeSafety:
        return Icons.map_outlined;
      case GuidanceCategory.threatResponse:
        return Icons.warning_amber_outlined;
      case GuidanceCategory.preparedness:
        return Icons.checklist_rounded;
      case GuidanceCategory.transportSafety:
        return Icons.directions_bus_outlined;
      case GuidanceCategory.awareness:
        return Icons.visibility_outlined;
      case GuidanceCategory.homeSafety:
        return Icons.home_outlined;
      case GuidanceCategory.exerciseSafety:
        return Icons.directions_run_rounded;
      case GuidanceCategory.financialSafety:
        return Icons.account_balance_outlined;
      case GuidanceCategory.socialSafety:
        return Icons.people_outline;
      case GuidanceCategory.digitalSafety:
        return Icons.shield_outlined;
      case GuidanceCategory.general:
        return Icons.info_outline;
    }
  }
}
