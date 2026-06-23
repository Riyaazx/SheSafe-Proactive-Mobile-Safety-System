// =============================================================================
// Country Code Model — E.164 Phone Number Validation
// =============================================================================
//
// Each country entry stores the ITU-T E.164 dial code and the set of valid
// national (subscriber) number lengths.  The full E.164 number is:
//
//     +<countryCode><nationalNumber>
//
// Total digits (country code + national number) must not exceed 15.
//
// Sources:
//   • ITU-T E.164 (11/2010) — International numbering plan
//   • National regulatory authority numbering plans
// =============================================================================

class CountryCode {
  /// ISO 3166-1 alpha-2 code (e.g. "GB", "US")
  final String isoCode;

  /// Country / territory name
  final String name;

  /// E.164 dial code WITHOUT the leading '+' (e.g. "44", "1")
  final String dialCode;

  /// Flag emoji derived from the ISO code
  final String flag;

  /// Set of valid national number lengths (digits after the country code).
  /// Most countries have a single length; some allow variable lengths.
  final List<int> nationalNumberLengths;

  const CountryCode({
    required this.isoCode,
    required this.name,
    required this.dialCode,
    required this.flag,
    required this.nationalNumberLengths,
  });

  /// Minimum accepted national number length for this country.
  int get minLength => nationalNumberLengths.reduce((a, b) => a < b ? a : b);

  /// Maximum accepted national number length for this country.
  int get maxLength => nationalNumberLengths.reduce((a, b) => a > b ? a : b);

  /// Returns `true` if [nationalNumber] has a valid length for this country.
  /// Accepts numbers with or without a trunk-prefix '0'.
  bool isValidLength(String nationalNumber) {
    var digits = nationalNumber.replaceAll(RegExp(r'\D'), '');
    // Strip trunk prefix '0' if doing so produces a valid length
    if (digits.startsWith('0') && nationalNumberLengths.contains(digits.length - 1)) {
      digits = digits.substring(1);
    }
    return nationalNumberLengths.contains(digits.length);
  }

  /// Full E.164 formatted number: +{dialCode}{nationalNumber}
  /// Automatically strips a single leading trunk-prefix '0' when present
  /// (e.g. UK "07911123456" → "+447911123456").
  String toE164(String nationalNumber) {
    var digits = nationalNumber.replaceAll(RegExp(r'\D'), '');
    // Strip trunk prefix '0' if the resulting number still meets min length
    if (digits.startsWith('0') && digits.length - 1 >= minLength) {
      digits = digits.substring(1);
    }
    return '+$dialCode$digits';
  }

  /// Human-readable display: "🇬🇧 +44"
  String get displayLabel => '$flag +$dialCode';

  @override
  String toString() => '$name (+$dialCode)';

  // ─────────────────────────────────────────────────────────────────────────
  // Master list — sorted alphabetically by country name.
  //
  // National number lengths sourced from each country's official numbering
  // plan / ITU-T E.164 assignment.
  // ─────────────────────────────────────────────────────────────────────────

  static const List<CountryCode> all = [
    CountryCode(isoCode: 'AF', name: 'Afghanistan', dialCode: '93', flag: '🇦🇫', nationalNumberLengths: [9]),
    CountryCode(isoCode: 'AL', name: 'Albania', dialCode: '355', flag: '🇦🇱', nationalNumberLengths: [9]),
    CountryCode(isoCode: 'DZ', name: 'Algeria', dialCode: '213', flag: '🇩🇿', nationalNumberLengths: [9]),
    CountryCode(isoCode: 'AR', name: 'Argentina', dialCode: '54', flag: '🇦🇷', nationalNumberLengths: [10, 11]),
    CountryCode(isoCode: 'AU', name: 'Australia', dialCode: '61', flag: '🇦🇺', nationalNumberLengths: [9]),
    CountryCode(isoCode: 'AT', name: 'Austria', dialCode: '43', flag: '🇦🇹', nationalNumberLengths: [10, 11, 12, 13]),
    CountryCode(isoCode: 'BD', name: 'Bangladesh', dialCode: '880', flag: '🇧🇩', nationalNumberLengths: [10]),
    CountryCode(isoCode: 'BE', name: 'Belgium', dialCode: '32', flag: '🇧🇪', nationalNumberLengths: [9]),
    CountryCode(isoCode: 'BR', name: 'Brazil', dialCode: '55', flag: '🇧🇷', nationalNumberLengths: [10, 11]),
    CountryCode(isoCode: 'BG', name: 'Bulgaria', dialCode: '359', flag: '🇧🇬', nationalNumberLengths: [8, 9]),
    CountryCode(isoCode: 'CM', name: 'Cameroon', dialCode: '237', flag: '🇨🇲', nationalNumberLengths: [9]),
    CountryCode(isoCode: 'CA', name: 'Canada', dialCode: '1', flag: '🇨🇦', nationalNumberLengths: [10]),
    CountryCode(isoCode: 'CL', name: 'Chile', dialCode: '56', flag: '🇨🇱', nationalNumberLengths: [9]),
    CountryCode(isoCode: 'CN', name: 'China', dialCode: '86', flag: '🇨🇳', nationalNumberLengths: [11]),
    CountryCode(isoCode: 'CO', name: 'Colombia', dialCode: '57', flag: '🇨🇴', nationalNumberLengths: [10]),
    CountryCode(isoCode: 'CD', name: 'Congo (DRC)', dialCode: '243', flag: '🇨🇩', nationalNumberLengths: [9]),
    CountryCode(isoCode: 'HR', name: 'Croatia', dialCode: '385', flag: '🇭🇷', nationalNumberLengths: [8, 9]),
    CountryCode(isoCode: 'CY', name: 'Cyprus', dialCode: '357', flag: '🇨🇾', nationalNumberLengths: [8]),
    CountryCode(isoCode: 'CZ', name: 'Czech Republic', dialCode: '420', flag: '🇨🇿', nationalNumberLengths: [9]),
    CountryCode(isoCode: 'DK', name: 'Denmark', dialCode: '45', flag: '🇩🇰', nationalNumberLengths: [8]),
    CountryCode(isoCode: 'EG', name: 'Egypt', dialCode: '20', flag: '🇪🇬', nationalNumberLengths: [10]),
    CountryCode(isoCode: 'ET', name: 'Ethiopia', dialCode: '251', flag: '🇪🇹', nationalNumberLengths: [9]),
    CountryCode(isoCode: 'FI', name: 'Finland', dialCode: '358', flag: '🇫🇮', nationalNumberLengths: [9, 10]),
    CountryCode(isoCode: 'FR', name: 'France', dialCode: '33', flag: '🇫🇷', nationalNumberLengths: [9]),
    CountryCode(isoCode: 'DE', name: 'Germany', dialCode: '49', flag: '🇩🇪', nationalNumberLengths: [10, 11]),
    CountryCode(isoCode: 'GH', name: 'Ghana', dialCode: '233', flag: '🇬🇭', nationalNumberLengths: [9]),
    CountryCode(isoCode: 'GR', name: 'Greece', dialCode: '30', flag: '🇬🇷', nationalNumberLengths: [10]),
    CountryCode(isoCode: 'HK', name: 'Hong Kong', dialCode: '852', flag: '🇭🇰', nationalNumberLengths: [8]),
    CountryCode(isoCode: 'HU', name: 'Hungary', dialCode: '36', flag: '🇭🇺', nationalNumberLengths: [9]),
    CountryCode(isoCode: 'IN', name: 'India', dialCode: '91', flag: '🇮🇳', nationalNumberLengths: [10]),
    CountryCode(isoCode: 'ID', name: 'Indonesia', dialCode: '62', flag: '🇮🇩', nationalNumberLengths: [10, 11, 12]),
    CountryCode(isoCode: 'IQ', name: 'Iraq', dialCode: '964', flag: '🇮🇶', nationalNumberLengths: [10]),
    CountryCode(isoCode: 'IE', name: 'Ireland', dialCode: '353', flag: '🇮🇪', nationalNumberLengths: [9]),
    CountryCode(isoCode: 'IL', name: 'Israel', dialCode: '972', flag: '🇮🇱', nationalNumberLengths: [9]),
    CountryCode(isoCode: 'IT', name: 'Italy', dialCode: '39', flag: '🇮🇹', nationalNumberLengths: [9, 10]),
    CountryCode(isoCode: 'JM', name: 'Jamaica', dialCode: '1876', flag: '🇯🇲', nationalNumberLengths: [7]),
    CountryCode(isoCode: 'JP', name: 'Japan', dialCode: '81', flag: '🇯🇵', nationalNumberLengths: [10]),
    CountryCode(isoCode: 'JO', name: 'Jordan', dialCode: '962', flag: '🇯🇴', nationalNumberLengths: [9]),
    CountryCode(isoCode: 'KE', name: 'Kenya', dialCode: '254', flag: '🇰🇪', nationalNumberLengths: [9]),
    CountryCode(isoCode: 'KR', name: 'South Korea', dialCode: '82', flag: '🇰🇷', nationalNumberLengths: [10, 11]),
    CountryCode(isoCode: 'KW', name: 'Kuwait', dialCode: '965', flag: '🇰🇼', nationalNumberLengths: [8]),
    CountryCode(isoCode: 'LB', name: 'Lebanon', dialCode: '961', flag: '🇱🇧', nationalNumberLengths: [7, 8]),
    CountryCode(isoCode: 'MY', name: 'Malaysia', dialCode: '60', flag: '🇲🇾', nationalNumberLengths: [9, 10]),
    CountryCode(isoCode: 'MX', name: 'Mexico', dialCode: '52', flag: '🇲🇽', nationalNumberLengths: [10]),
    CountryCode(isoCode: 'MA', name: 'Morocco', dialCode: '212', flag: '🇲🇦', nationalNumberLengths: [9]),
    CountryCode(isoCode: 'MZ', name: 'Mozambique', dialCode: '258', flag: '🇲🇿', nationalNumberLengths: [9]),
    CountryCode(isoCode: 'MM', name: 'Myanmar', dialCode: '95', flag: '🇲🇲', nationalNumberLengths: [8, 9, 10]),
    CountryCode(isoCode: 'NP', name: 'Nepal', dialCode: '977', flag: '🇳🇵', nationalNumberLengths: [10]),
    CountryCode(isoCode: 'NL', name: 'Netherlands', dialCode: '31', flag: '🇳🇱', nationalNumberLengths: [9]),
    CountryCode(isoCode: 'NZ', name: 'New Zealand', dialCode: '64', flag: '🇳🇿', nationalNumberLengths: [8, 9, 10]),
    CountryCode(isoCode: 'NG', name: 'Nigeria', dialCode: '234', flag: '🇳🇬', nationalNumberLengths: [10]),
    CountryCode(isoCode: 'NO', name: 'Norway', dialCode: '47', flag: '🇳🇴', nationalNumberLengths: [8]),
    CountryCode(isoCode: 'PK', name: 'Pakistan', dialCode: '92', flag: '🇵🇰', nationalNumberLengths: [10]),
    CountryCode(isoCode: 'PE', name: 'Peru', dialCode: '51', flag: '🇵🇪', nationalNumberLengths: [9]),
    CountryCode(isoCode: 'PH', name: 'Philippines', dialCode: '63', flag: '🇵🇭', nationalNumberLengths: [10]),
    CountryCode(isoCode: 'PL', name: 'Poland', dialCode: '48', flag: '🇵🇱', nationalNumberLengths: [9]),
    CountryCode(isoCode: 'PT', name: 'Portugal', dialCode: '351', flag: '🇵🇹', nationalNumberLengths: [9]),
    CountryCode(isoCode: 'QA', name: 'Qatar', dialCode: '974', flag: '🇶🇦', nationalNumberLengths: [8]),
    CountryCode(isoCode: 'RO', name: 'Romania', dialCode: '40', flag: '🇷🇴', nationalNumberLengths: [9]),
    CountryCode(isoCode: 'RU', name: 'Russia', dialCode: '7', flag: '🇷🇺', nationalNumberLengths: [10]),
    CountryCode(isoCode: 'SA', name: 'Saudi Arabia', dialCode: '966', flag: '🇸🇦', nationalNumberLengths: [9]),
    CountryCode(isoCode: 'SN', name: 'Senegal', dialCode: '221', flag: '🇸🇳', nationalNumberLengths: [9]),
    CountryCode(isoCode: 'SG', name: 'Singapore', dialCode: '65', flag: '🇸🇬', nationalNumberLengths: [8]),
    CountryCode(isoCode: 'ZA', name: 'South Africa', dialCode: '27', flag: '🇿🇦', nationalNumberLengths: [9]),
    CountryCode(isoCode: 'ES', name: 'Spain', dialCode: '34', flag: '🇪🇸', nationalNumberLengths: [9]),
    CountryCode(isoCode: 'LK', name: 'Sri Lanka', dialCode: '94', flag: '🇱🇰', nationalNumberLengths: [9]),
    CountryCode(isoCode: 'SD', name: 'Sudan', dialCode: '249', flag: '🇸🇩', nationalNumberLengths: [9]),
    CountryCode(isoCode: 'SE', name: 'Sweden', dialCode: '46', flag: '🇸🇪', nationalNumberLengths: [9]),
    CountryCode(isoCode: 'CH', name: 'Switzerland', dialCode: '41', flag: '🇨🇭', nationalNumberLengths: [9]),
    CountryCode(isoCode: 'TW', name: 'Taiwan', dialCode: '886', flag: '🇹🇼', nationalNumberLengths: [9]),
    CountryCode(isoCode: 'TZ', name: 'Tanzania', dialCode: '255', flag: '🇹🇿', nationalNumberLengths: [9]),
    CountryCode(isoCode: 'TH', name: 'Thailand', dialCode: '66', flag: '🇹🇭', nationalNumberLengths: [9]),
    CountryCode(isoCode: 'TR', name: 'Turkey', dialCode: '90', flag: '🇹🇷', nationalNumberLengths: [10]),
    CountryCode(isoCode: 'UG', name: 'Uganda', dialCode: '256', flag: '🇺🇬', nationalNumberLengths: [9]),
    CountryCode(isoCode: 'UA', name: 'Ukraine', dialCode: '380', flag: '🇺🇦', nationalNumberLengths: [9]),
    CountryCode(isoCode: 'AE', name: 'United Arab Emirates', dialCode: '971', flag: '🇦🇪', nationalNumberLengths: [9]),
    CountryCode(isoCode: 'GB', name: 'United Kingdom', dialCode: '44', flag: '🇬🇧', nationalNumberLengths: [10]),
    CountryCode(isoCode: 'US', name: 'United States', dialCode: '1', flag: '🇺🇸', nationalNumberLengths: [10]),
    CountryCode(isoCode: 'VN', name: 'Vietnam', dialCode: '84', flag: '🇻🇳', nationalNumberLengths: [9, 10]),
    CountryCode(isoCode: 'ZM', name: 'Zambia', dialCode: '260', flag: '🇿🇲', nationalNumberLengths: [9]),
    CountryCode(isoCode: 'ZW', name: 'Zimbabwe', dialCode: '263', flag: '🇿🇼', nationalNumberLengths: [9]),
  ];

  /// Look up a country by ISO code (case-insensitive).
  static CountryCode? findByIso(String isoCode) {
    final upper = isoCode.toUpperCase();
    try {
      return all.firstWhere((c) => c.isoCode == upper);
    } catch (_) {
      return null;
    }
  }

  /// Look up a country by dial code (without '+').  Returns the first match.
  static CountryCode? findByDialCode(String dialCode) {
    try {
      return all.firstWhere((c) => c.dialCode == dialCode);
    } catch (_) {
      return null;
    }
  }

  /// Default country — United Kingdom (most likely for this app's user base).
  static CountryCode get defaultCountry =>
      all.firstWhere((c) => c.isoCode == 'GB');

  /// Try to detect which country a full E.164 number belongs to.
  /// Returns null if no match is found.
  static CountryCode? detectFromE164(String e164Number) {
    String digits = e164Number.replaceAll(RegExp(r'\D'), '');
    // Try longest dial codes first (4, 3, 2, 1 digit codes)
    for (int len = 4; len >= 1; len--) {
      if (digits.length > len) {
        final prefix = digits.substring(0, len);
        final match = findByDialCode(prefix);
        if (match != null) return match;
      }
    }
    return null;
  }

  /// Extract the national number portion from a full E.164 number,
  /// given this country code's dial code.
  String extractNationalNumber(String e164Number) {
    String digits = e164Number.replaceAll(RegExp(r'\D'), '');
    if (digits.startsWith(dialCode)) {
      return digits.substring(dialCode.length);
    }
    return digits;
  }

  /// Validate a national number and return a human-readable error or null.
  /// Accepts numbers with or without the trunk-prefix '0'
  /// (e.g. UK "07911123456" = 11 digits is accepted just like "7911123456").
  String? validateNationalNumber(String nationalNumber) {
    var digits = nationalNumber.replaceAll(RegExp(r'\D'), '');

    if (digits.isEmpty) {
      return 'Phone number is required';
    }

    // Strip a single trunk-prefix '0' if doing so produces a valid length
    if (digits.startsWith('0') && nationalNumberLengths.contains(digits.length - 1)) {
      digits = digits.substring(1);
    }

    if (!nationalNumberLengths.contains(digits.length)) {
      if (nationalNumberLengths.length == 1) {
        return 'Must be ${nationalNumberLengths.first} digits (you entered ${digits.length})';
      } else {
        final lengths = nationalNumberLengths.join(' or ');
        return 'Must be $lengths digits (you entered ${digits.length})';
      }
    }

    // E.164 total length check: country code + national ≤ 15
    if (dialCode.length + digits.length > 15) {
      return 'Number exceeds E.164 maximum length (15 digits total)';
    }

    return null; // valid
  }
}
