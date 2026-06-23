/// B3 — Safety Guidance data model.
///
/// Each entry represents a single piece of safety advice grounded in a
/// reputable source. The triple "situation → advice → why" provides
/// reassurance to the user during Safety Mode and route planning.
class SafetyGuidance {
  /// The scenario or situation this advice applies to.
  final String situation;

  /// The actionable advice itself — short, calm, ethical.
  final String advice;

  /// A brief explanation of *why* this advice works.
  final String why;

  /// Attribution — the reputable source the guidance is drawn from.
  final String source;

  /// Category tag used to filter advice contextually.
  final GuidanceCategory category;

  const SafetyGuidance({
    required this.situation,
    required this.advice,
    required this.why,
    required this.source,
    required this.category,
  });

  /// Parse a single CSV row (after header) into a [SafetyGuidance].
  factory SafetyGuidance.fromCsvRow(List<String> fields) {
    return SafetyGuidance(
      situation: fields[0],
      advice: fields[1],
      why: fields[2],
      source: fields[3],
      category: _parseCategory(fields[4]),
    );
  }

  static GuidanceCategory _parseCategory(String raw) {
    switch (raw.trim().toLowerCase()) {
      case 'route_safety':
        return GuidanceCategory.routeSafety;
      case 'threat_response':
        return GuidanceCategory.threatResponse;
      case 'preparedness':
        return GuidanceCategory.preparedness;
      case 'transport_safety':
        return GuidanceCategory.transportSafety;
      case 'awareness':
        return GuidanceCategory.awareness;
      case 'home_safety':
        return GuidanceCategory.homeSafety;
      case 'exercise_safety':
        return GuidanceCategory.exerciseSafety;
      case 'financial_safety':
        return GuidanceCategory.financialSafety;
      case 'social_safety':
        return GuidanceCategory.socialSafety;
      case 'digital_safety':
        return GuidanceCategory.digitalSafety;
      default:
        return GuidanceCategory.general;
    }
  }

  @override
  String toString() => 'SafetyGuidance($category: "$situation")';
}

/// Categories used to filter guidance contextually.
enum GuidanceCategory {
  routeSafety(displayName: 'Route Safety'),
  threatResponse(displayName: 'Threat Response'),
  preparedness(displayName: 'Preparedness'),
  transportSafety(displayName: 'Transport Safety'),
  awareness(displayName: 'Awareness'),
  homeSafety(displayName: 'Home Safety'),
  exerciseSafety(displayName: 'Exercise Safety'),
  financialSafety(displayName: 'Financial Safety'),
  socialSafety(displayName: 'Social Safety'),
  digitalSafety(displayName: 'Digital Safety'),
  general(displayName: 'General');

  final String displayName;
  const GuidanceCategory({required this.displayName});
}
