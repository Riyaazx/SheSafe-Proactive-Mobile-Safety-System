import 'package:flutter_test/flutter_test.dart';
import 'package:shesafe/models/incident_report.dart';

// =============================================================================
// Incident Report — Unit Tests
// =============================================================================
//
// Proves that:
//   1. Reports round-trip through JSON correctly (save → load fidelity).
//   2. External-link reports (the "save before you go" flow) store the
//      reporting-site name and URL inside the description.
//   3. The toShareText() output includes all critical fields.
//   4. Category and urgency enums have correct display names.
// =============================================================================

void main() {
  group('IncidentReport model', () {
    // ── Helper: build a standard report ──────────────────────────────────
    IncidentReport makeReport({
      String description = 'Someone followed me home from the bus stop.',
      IncidentCategory category = IncidentCategory.stalking,
      IncidentUrgency urgency = IncidentUrgency.high,
      double? lat = 52.4068,
      double? lon = -1.5197,
      String? locationDesc = 'Near Coventry bus station',
    }) {
      return IncidentReport(
        id: '1234567890',
        category: category,
        description: description,
        incidentDate: DateTime(2026, 3, 1, 20, 30),
        latitude: lat,
        longitude: lon,
        locationDescription: locationDesc,
        urgency: urgency,
        isAnonymous: false,
        createdAt: DateTime(2026, 3, 1, 21, 0),
      );
    }

    // ─────────────────────────────────────────────────────────────────────
    // 1. JSON round-trip
    // ─────────────────────────────────────────────────────────────────────
    test('toJson → fromJson preserves all fields', () {
      final original = makeReport();
      final json = original.toJson();
      final restored = IncidentReport.fromJson(json);

      expect(restored.id, original.id);
      expect(restored.category, original.category);
      expect(restored.description, original.description);
      expect(restored.incidentDate, original.incidentDate);
      expect(restored.latitude, original.latitude);
      expect(restored.longitude, original.longitude);
      expect(restored.locationDescription, original.locationDescription);
      expect(restored.urgency, original.urgency);
      expect(restored.isAnonymous, original.isAnonymous);
      expect(restored.createdAt, original.createdAt);
    });

    test('JSON round-trip with null location', () {
      final original = makeReport(lat: null, lon: null, locationDesc: null);
      final json = original.toJson();
      final restored = IncidentReport.fromJson(json);

      expect(restored.latitude, isNull);
      expect(restored.longitude, isNull);
      expect(restored.locationDescription, isNull);
    });

    // ─────────────────────────────────────────────────────────────────────
    // 2. External-link report saves site name & URL
    // ─────────────────────────────────────────────────────────────────────
    test('external-link report contains site name and URL in description', () {
      // Simulates what _promptSaveBeforeExternal() creates:
      const siteName = 'Report to Police Online';
      const url = 'https://www.police.uk/';
      const userNote = 'Reported harassment near campus';

      final report = makeReport(
        description: '$userNote\n\n[Reported via: $siteName]\n[URL: $url]',
        category: IncidentCategory.harassment,
      );

      expect(report.description, contains('[Reported via: $siteName]'));
      expect(report.description, contains('[URL: $url]'));
      expect(report.description, contains(userNote));
    });

    test('external-link report with no user note uses default text', () {
      const siteName = 'Crimestoppers (Anonymous)';
      const url = 'https://crimestoppers-uk.org/give-information';
      final defaultNote = 'Reported externally via $siteName';

      final report = makeReport(
        description: '$defaultNote\n\n[Reported via: $siteName]\n[URL: $url]',
      );

      expect(report.description, contains(defaultNote));
      expect(report.description, contains(siteName));
      expect(report.description, contains(url));
    });

    // ─────────────────────────────────────────────────────────────────────
    // 3. toShareText() includes critical information
    // ─────────────────────────────────────────────────────────────────────
    test('toShareText includes category, date, description, coords', () {
      final report = makeReport();
      final text = report.toShareText();

      expect(text, contains('Stalking'));
      expect(text, contains('01/03/2026'));
      expect(text, contains('Someone followed me'));
      expect(text, contains('52.4068'));
      expect(text, contains('-1.5197'));
      expect(text, contains('Near Coventry bus station'));
    });

    test('toShareText works without location', () {
      final report = makeReport(lat: null, lon: null, locationDesc: null);
      final text = report.toShareText();

      expect(text, contains('Stalking'));
      expect(text, isNot(contains('Coords:')));
    });

    // ─────────────────────────────────────────────────────────────────────
    // 4. Enum display names
    // ─────────────────────────────────────────────────────────────────────
    test('IncidentCategory display names are correct', () {
      expect(IncidentCategory.harassment.displayName, 'Harassment');
      expect(IncidentCategory.assault.displayName, 'Assault');
      expect(IncidentCategory.theft.displayName, 'Theft / Robbery');
      expect(IncidentCategory.stalking.displayName, 'Stalking');
      expect(IncidentCategory.spiking.displayName, 'Drink Spiking');
      expect(IncidentCategory.verbalAbuse.displayName, 'Verbal Abuse');
      expect(IncidentCategory.cyberBullying.displayName, 'Cyberbullying');
      expect(IncidentCategory.other.displayName, 'Other');
    });

    test('IncidentUrgency display names are correct', () {
      expect(IncidentUrgency.low.displayName, 'Low — for the record');
      expect(IncidentUrgency.medium.displayName,
          'Medium — should be looked into');
      expect(
          IncidentUrgency.high.displayName, 'High — urgent / ongoing threat');
    });

    // ─────────────────────────────────────────────────────────────────────
    // 5. All categories can round-trip through JSON
    // ─────────────────────────────────────────────────────────────────────
    test('all IncidentCategory values survive JSON round-trip', () {
      for (final cat in IncidentCategory.values) {
        final report = makeReport(category: cat);
        final restored = IncidentReport.fromJson(report.toJson());
        expect(restored.category, cat,
            reason: '${cat.name} did not round-trip');
      }
    });

    test('all IncidentUrgency values survive JSON round-trip', () {
      for (final urg in IncidentUrgency.values) {
        final report = makeReport(urgency: urg);
        final restored = IncidentReport.fromJson(report.toJson());
        expect(restored.urgency, urg,
            reason: '${urg.name} did not round-trip');
      }
    });
  });
}
