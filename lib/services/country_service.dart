import 'package:shared_preferences/shared_preferences.dart';

/// Metadata for a supported country.
class CountryInfo {
  final String code;          // ISO 3166-1 alpha-2, e.g. 'gb'
  final String name;          // Human-readable, e.g. 'United Kingdom'
  final String flag;          // Emoji flag, e.g. '🇬🇧'
  final String hintShort;     // Search bar hint, e.g. 'e.g. London Bridge, SE1'
  final List<String> examples; // 3 bullet-point address examples shown in tips

  const CountryInfo({
    required this.code,
    required this.name,
    required this.flag,
    required this.hintShort,
    required this.examples,
  });
}

/// Stores and retrieves the user's selected country using SharedPreferences.
///
/// **Design decision (UK-only scope):**
/// SheSafe's crime data comes from UK police datasets, risk zones are
/// calibrated for UK geography, and the helplines (Refuge, Women's Aid, etc.)
/// are UK-specific. Rather than offering a misleading multi-country picker
/// with no real data behind it, the app is intentionally scoped to the UK.
/// Accurate, locally-grounded data is more valuable than broad-but-empty
/// international coverage. Route directions and motion safety still work
/// globally via OSRM and the device accelerometer.
class CountryService {
  static final CountryService _instance = CountryService._internal();
  factory CountryService() => _instance;
  CountryService._internal();

  static const String _prefKey = 'selected_country_code';

  // ─── Supported country (UK only — see design rationale above) ─────────────
  static const CountryInfo uk = CountryInfo(
    code: 'gb', name: 'United Kingdom', flag: '🇬🇧',
    hintShort: 'e.g. London Bridge, SE1',
    examples: [
      'Priory Street, Coventry CV1 5FB',
      'London Bridge, London SE1 9BG',
      'Manchester Piccadilly M1 2QF',
    ],
  );

  /// Kept as a list for backward-compatibility with existing code that
  /// iterates `CountryService.countries`.
  static const List<CountryInfo> countries = [uk];

  // ─── Persistence ─────────────────────────────────────────────────────────

  /// Returns `true` if the user has already acknowledged the region step.
  Future<bool> isCountrySet() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.containsKey(_prefKey);
  }

  /// Returns the UK [CountryInfo]. Persists it automatically if not yet set.
  Future<CountryInfo?> getSelectedCountry() async {
    final prefs = await SharedPreferences.getInstance();
    if (!prefs.containsKey(_prefKey)) {
      await prefs.setString(_prefKey, uk.code);
    }
    return uk;
  }

  /// Persists [country] as the user's choice (always UK).
  Future<void> setSelectedCountry(CountryInfo country) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefKey, country.code);
  }

  /// Always `true` — the app is UK-scoped.
  Future<bool> isUkSelected() async => true;
}
