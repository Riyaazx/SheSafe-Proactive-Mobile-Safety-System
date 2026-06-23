import 'package:flutter/material.dart';

/// Professional "Data Coverage" bottom sheet.
///
/// Shows what data SheSafe uses, current UK-only coverage status,
/// and a forward-looking note about future expansion.
///
/// Open it via:
/// ```dart
/// showDataCoverageSheet(context);
/// ```
void showDataCoverageSheet(BuildContext context) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (_) => const DataCoverageSheet(),
  );
}

class DataCoverageSheet extends StatelessWidget {
  const DataCoverageSheet({super.key});

  static const _accent = Color(0xFFB07A96);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 14, 24, 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Drag handle
              Container(
                width: 40, height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey.shade300,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 22),

              // Title row
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: _accent.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(Icons.verified_user_outlined,
                        color: _accent, size: 22),
                  ),
                  const SizedBox(width: 14),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Data Coverage',
                            style: TextStyle(
                                fontSize: 18, fontWeight: FontWeight.w700)),
                        SizedBox(height: 2),
                        Text('What data SheSafe uses in your region',
                            style: TextStyle(
                                fontSize: 13, color: Colors.grey)),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 22),

              // UK card
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  color: _accent.withValues(alpha: 0.06),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: _accent.withValues(alpha: 0.2)),
                ),
                child: Row(
                  children: [
                    const Text('🇬🇧', style: TextStyle(fontSize: 36)),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('United Kingdom',
                              style: TextStyle(
                                  fontSize: 16, fontWeight: FontWeight.w700)),
                          const SizedBox(height: 4),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 3),
                            decoration: BoxDecoration(
                              color: _accent,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: const Text('Full Coverage',
                                style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600)),
                          ),
                        ],
                      ),
                    ),
                    const Icon(Icons.check_circle,
                        color: _accent, size: 24),
                  ],
                ),
              ),
              const SizedBox(height: 18),

              // Coverage details
              _coverageRow(Icons.shield_outlined, 'Crime intelligence',
                  'Real UK Police crime data powering risk zones'),
              _coverageRow(Icons.phone_in_talk_outlined, 'Helplines',
                  'Refuge, Women\'s Aid, Childline & more'),
              _coverageRow(Icons.route_outlined, 'Route navigation',
                  'Turn-by-turn directions via OSRM'),
              _coverageRow(Icons.sensors_outlined, 'Motion safety',
                  'Fall detection & anomaly alerts'),
              const SizedBox(height: 18),

              // Future expansion note
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: const Color(0xFFF8D7E3),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.info_outline_rounded,
                        size: 20, color: Color(0xFFB07A96)),
                    SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'More regions planned for future releases — '
                        'route navigation and motion safety already '
                        'work worldwide.',
                        style: TextStyle(
                          fontSize: 12.5,
                          color: Color(0xFF8A4070),
                          height: 1.4,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static Widget _coverageRow(
      IconData icon, String title, String subtitle) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          Container(
            width: 38, height: 38,
            decoration: BoxDecoration(
              color: _accent.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: _accent, size: 18),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: const TextStyle(
                        fontSize: 13.5, fontWeight: FontWeight.w600)),
                Text(subtitle,
                    style: TextStyle(
                        fontSize: 11.5, color: Colors.grey.shade600)),
              ],
            ),
          ),
          const Icon(Icons.check_circle_outline,
              color: _accent, size: 20),
        ],
      ),
    );
  }
}
