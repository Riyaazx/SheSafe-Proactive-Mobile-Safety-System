// Incident report model for in-app safety reporting.
//
// Users can log incidents directly in the app. Reports are stored
// locally and can be exported/shared as evidence or submitted to
// external authorities via the built-in links.

import 'dart:convert';

/// Category of the reported incident.
enum IncidentCategory {
  harassment(displayName: 'Harassment', icon: 'person_off'),
  assault(displayName: 'Assault', icon: 'warning'),
  theft(displayName: 'Theft / Robbery', icon: 'shopping_bag'),
  stalking(displayName: 'Stalking', icon: 'visibility'),
  spiking(displayName: 'Drink Spiking', icon: 'local_bar'),
  verbalAbuse(displayName: 'Verbal Abuse', icon: 'record_voice_over'),
  cyberBullying(displayName: 'Cyberbullying', icon: 'phone_android'),
  unsafeLighting(displayName: 'Poor Lighting / Unsafe Area', icon: 'lightbulb'),
  other(displayName: 'Other', icon: 'info');

  final String displayName;
  final String icon;
  const IncidentCategory({required this.displayName, required this.icon});
}

/// Urgency level for triage.
enum IncidentUrgency {
  low(displayName: 'Low — for the record'),
  medium(displayName: 'Medium — should be looked into'),
  high(displayName: 'High — urgent / ongoing threat');

  final String displayName;
  const IncidentUrgency({required this.displayName});
}

/// Status of the report within the app.
enum ReportStatus {
  draft,
  submitted,
  exported,
}

/// A single incident report created by the user.
class IncidentReport {
  /// Unique identifier (millisecondsSinceEpoch at creation).
  final String id;

  /// What kind of incident.
  final IncidentCategory category;

  /// Free-text description of what happened.
  final String description;

  /// When the incident occurred.
  final DateTime incidentDate;

  /// Latitude where the incident occurred (null if location unavailable).
  final double? latitude;

  /// Longitude where the incident occurred.
  final double? longitude;

  /// Human-readable address / location description.
  final String? locationDescription;

  /// How urgent is this report.
  final IncidentUrgency urgency;

  /// Whether the user wants to remain anonymous.
  final bool isAnonymous;

  /// Current status.
  final ReportStatus status;

  /// When the report was created in the app.
  final DateTime createdAt;

  const IncidentReport({
    required this.id,
    required this.category,
    required this.description,
    required this.incidentDate,
    this.latitude,
    this.longitude,
    this.locationDescription,
    required this.urgency,
    this.isAnonymous = false,
    this.status = ReportStatus.submitted,
    required this.createdAt,
  });

  /// Serialise to a JSON-compatible map for local storage.
  Map<String, dynamic> toJson() => {
        'id': id,
        'category': category.name,
        'description': description,
        'incidentDate': incidentDate.toIso8601String(),
        'latitude': latitude,
        'longitude': longitude,
        'locationDescription': locationDescription,
        'urgency': urgency.name,
        'isAnonymous': isAnonymous,
        'status': status.name,
        'createdAt': createdAt.toIso8601String(),
      };

  /// Deserialise from a JSON-compatible map.
  factory IncidentReport.fromJson(Map<String, dynamic> json) {
    return IncidentReport(
      id: json['id'] as String,
      category: IncidentCategory.values.firstWhere(
        (c) => c.name == json['category'],
        orElse: () => IncidentCategory.other,
      ),
      description: json['description'] as String,
      incidentDate: DateTime.parse(json['incidentDate'] as String),
      latitude: json['latitude'] as double?,
      longitude: json['longitude'] as double?,
      locationDescription: json['locationDescription'] as String?,
      urgency: IncidentUrgency.values.firstWhere(
        (u) => u.name == json['urgency'],
        orElse: () => IncidentUrgency.medium,
      ),
      isAnonymous: json['isAnonymous'] as bool? ?? false,
      status: ReportStatus.values.firstWhere(
        (s) => s.name == json['status'],
        orElse: () => ReportStatus.submitted,
      ),
      createdAt: DateTime.parse(json['createdAt'] as String),
    );
  }

  /// Human-readable text block for sharing / exporting.
  String toShareText() {
    final buf = StringBuffer();
    buf.writeln('═══ SheSafe Incident Report ═══');
    buf.writeln('Report ID: $id');
    buf.writeln('Category:  ${category.displayName}');
    buf.writeln('Urgency:   ${urgency.displayName}');
    buf.writeln('Date:      ${_formatDate(incidentDate)}');
    if (locationDescription != null && locationDescription!.isNotEmpty) {
      buf.writeln('Location:  $locationDescription');
    }
    if (latitude != null && longitude != null) {
      buf.writeln('Coords:    $latitude, $longitude');
    }
    buf.writeln('');
    buf.writeln('Description:');
    buf.writeln(description);
    buf.writeln('');
    buf.writeln('Anonymous: ${isAnonymous ? "Yes" : "No"}');
    buf.writeln('Submitted: ${_formatDate(createdAt)}');
    buf.writeln('═══════════════════════════════');
    return buf.toString();
  }

  static String _formatDate(DateTime dt) {
    final d = dt.day.toString().padLeft(2, '0');
    final m = dt.month.toString().padLeft(2, '0');
    final y = dt.year;
    final h = dt.hour.toString().padLeft(2, '0');
    final min = dt.minute.toString().padLeft(2, '0');
    return '$d/$m/$y at $h:$min';
  }

  /// Quick encode to JSON string.
  String encode() => jsonEncode(toJson());

  /// Quick decode from JSON string.
  static IncidentReport decode(String source) =>
      IncidentReport.fromJson(jsonDecode(source) as Map<String, dynamic>);
}
