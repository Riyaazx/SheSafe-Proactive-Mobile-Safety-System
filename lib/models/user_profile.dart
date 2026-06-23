import 'trusted_contact.dart';
import 'user_preferences.dart';

// =============================================================================
// Sub-models
// =============================================================================

/// The user's typical walking speed characterised from calibration.
///
/// Stored in encrypted secure storage because it describes personalised
/// behavioural patterns that could be used to identify the user.
class WalkingPaceProfile {
  /// Mean step rate measured during calibration (steps per second).
  final double meanStepsPerSecond;

  /// One standard-deviation spread of step-rate measurements.
  final double stdStepsPerSecond;

  /// Estimated typical walking speed (m/s) derived from step rate and stride.
  final double typicalSpeedMs;

  /// Low end of the user's comfortable speed range (m/s).
  final double minSpeedMs;

  /// High end of the user's comfortable speed range (m/s).
  final double maxSpeedMs;

  /// When this calibration snapshot was taken.
  final DateTime calibratedAt;

  const WalkingPaceProfile({
    required this.meanStepsPerSecond,
    required this.stdStepsPerSecond,
    required this.typicalSpeedMs,
    required this.minSpeedMs,
    required this.maxSpeedMs,
    required this.calibratedAt,
  });

  // -------------------------------------------------------------------------
  // Convenience
  // -------------------------------------------------------------------------

  /// Typical speed converted to km/h for display purposes.
  double get typicalSpeedKmh => typicalSpeedMs * 3.6;

  /// Returns true when the supplied speed (m/s) falls within the user's
  /// comfortable walking range (with a 20 % tolerance band).
  bool isWithinNormalRange(double speedMs, {double toleranceFactor = 0.2}) {
    final lower = minSpeedMs * (1 - toleranceFactor);
    final upper = maxSpeedMs * (1 + toleranceFactor);
    return speedMs >= lower && speedMs <= upper;
  }

  // -------------------------------------------------------------------------
  // Serialisation
  // -------------------------------------------------------------------------

  Map<String, dynamic> toJson() => {
        'meanStepsPerSecond': meanStepsPerSecond,
        'stdStepsPerSecond': stdStepsPerSecond,
        'typicalSpeedMs': typicalSpeedMs,
        'minSpeedMs': minSpeedMs,
        'maxSpeedMs': maxSpeedMs,
        'calibratedAt': calibratedAt.toIso8601String(),
      };

  factory WalkingPaceProfile.fromJson(Map<String, dynamic> json) =>
      WalkingPaceProfile(
        meanStepsPerSecond: (json['meanStepsPerSecond'] as num).toDouble(),
        stdStepsPerSecond: (json['stdStepsPerSecond'] as num).toDouble(),
        typicalSpeedMs: (json['typicalSpeedMs'] as num).toDouble(),
        minSpeedMs: (json['minSpeedMs'] as num).toDouble(),
        maxSpeedMs: (json['maxSpeedMs'] as num).toDouble(),
        calibratedAt: DateTime.parse(json['calibratedAt'] as String),
      );

  WalkingPaceProfile copyWith({
    double? meanStepsPerSecond,
    double? stdStepsPerSecond,
    double? typicalSpeedMs,
    double? minSpeedMs,
    double? maxSpeedMs,
    DateTime? calibratedAt,
  }) =>
      WalkingPaceProfile(
        meanStepsPerSecond: meanStepsPerSecond ?? this.meanStepsPerSecond,
        stdStepsPerSecond: stdStepsPerSecond ?? this.stdStepsPerSecond,
        typicalSpeedMs: typicalSpeedMs ?? this.typicalSpeedMs,
        minSpeedMs: minSpeedMs ?? this.minSpeedMs,
        maxSpeedMs: maxSpeedMs ?? this.maxSpeedMs,
        calibratedAt: calibratedAt ?? this.calibratedAt,
      );

  @override
  String toString() =>
      'WalkingPaceProfile(mean: ${meanStepsPerSecond.toStringAsFixed(2)} steps/s, '
      'typical: ${typicalSpeedKmh.toStringAsFixed(1)} km/h)';
}

// -----------------------------------------------------------------------------

/// A saved geographic location treated as the user's home.
///
/// Stored in encrypted secure storage — precise coordinates are sensitive PII.
class HomeLocation {
  /// WGS-84 latitude.
  final double latitude;

  /// WGS-84 longitude.
  final double longitude;

  /// Optional human-readable label (e.g. "Home", "Work").
  final String? label;

  /// When this location was saved.
  final DateTime savedAt;

  const HomeLocation({
    required this.latitude,
    required this.longitude,
    this.label,
    required this.savedAt,
  });

  // -------------------------------------------------------------------------
  // Serialisation
  // -------------------------------------------------------------------------

  Map<String, dynamic> toJson() => {
        'latitude': latitude,
        'longitude': longitude,
        'label': label,
        'savedAt': savedAt.toIso8601String(),
      };

  factory HomeLocation.fromJson(Map<String, dynamic> json) => HomeLocation(
        latitude: (json['latitude'] as num).toDouble(),
        longitude: (json['longitude'] as num).toDouble(),
        label: json['label'] as String?,
        savedAt: DateTime.parse(json['savedAt'] as String),
      );

  HomeLocation copyWith({
    double? latitude,
    double? longitude,
    String? label,
    DateTime? savedAt,
  }) =>
      HomeLocation(
        latitude: latitude ?? this.latitude,
        longitude: longitude ?? this.longitude,
        label: label ?? this.label,
        savedAt: savedAt ?? this.savedAt,
      );

  @override
  String toString() =>
      'HomeLocation(${label ?? "unnamed"}, lat: $latitude, lng: $longitude)';
}

// =============================================================================
// Main profile model
// =============================================================================

/// Aggregated personalisation record for a single enrolled user.
///
/// Design notes
/// ─────────────
/// • [userId] is a randomly-generated UUID created at first enrolment.
///   It scopes all secure-storage keys so that multiple enrolments on the
///   same device can coexist and individual profiles can be wiped cleanly.
///
/// • The safe word is **never** stored on this object in plaintext.
///   [UserProfileService] keeps only a PBKDF2-SHA256 hash + salt pair in
///   encrypted storage.  [hasSafeWord] simply tracks whether one has been set.
///
/// • [trustedContacts] are stored encrypted; this model holds the in-memory
///   representation only after they have been decrypted by the service.
///
/// Storage routing
/// ───────────────
/// | Field                | Storage                  | Encrypted |
/// |----------------------|--------------------------|-----------|
/// | userId               | SecureStorage            | Yes       |
/// | walkingPace          | SecureStorage            | Yes       |
/// | homeLocation         | SecureStorage            | Yes       |
/// | trustedContacts      | SecureStorage            | Yes       |
/// | hasSafeWord flag     | SecureStorage            | Yes       |
/// | safeWordHash + salt  | SecureStorage            | Yes       |
/// | preferences          | SharedPreferences        | No        |
class UserProfile {
  /// Unique identifier for this enrolment (UUID v4).
  final String userId;

  /// Calibrated walking pace data; null if the user skipped calibration.
  final WalkingPaceProfile? walkingPace;

  /// True when a safe word has been configured (the raw word is never held here).
  final bool hasSafeWord;

  /// Trusted emergency contacts; stored encrypted in secure storage.
  final List<TrustedContact> trustedContacts;

  /// Optional home/base location; stored encrypted in secure storage.
  final HomeLocation? homeLocation;

  /// Non-sensitive app preferences (risk radius, sensitivity, etc.).
  final UserPreferences preferences;

  /// When this profile was first created.
  final DateTime createdAt;

  /// When this profile was last modified.
  final DateTime updatedAt;

  const UserProfile({
    required this.userId,
    this.walkingPace,
    this.hasSafeWord = false,
    this.trustedContacts = const [],
    this.homeLocation,
    this.preferences = const UserPreferences(),
    required this.createdAt,
    required this.updatedAt,
  });

  // -------------------------------------------------------------------------
  // Derived helpers
  // -------------------------------------------------------------------------

  /// True when the minimum onboarding requirements have been met.
  bool get isFullyConfigured =>
      hasSafeWord && trustedContacts.isNotEmpty && walkingPace != null;

  /// The single primary contact, or the first contact if none is flagged.
  TrustedContact? get primaryContact {
    if (trustedContacts.isEmpty) return null;
    return trustedContacts.firstWhere(
      (c) => c.isPrimary,
      orElse: () => trustedContacts.first,
    );
  }

  // -------------------------------------------------------------------------
  // Serialisation — only non-sensitive fields are JSON-serialisable here.
  // Sensitive fields (walkingPace, homeLocation, trustedContacts) are
  // serialised individually by UserProfileService before encryption.
  // -------------------------------------------------------------------------

  Map<String, dynamic> toJson() => {
        'userId': userId,
        'hasSafeWord': hasSafeWord,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
      };

  factory UserProfile.fromJson(Map<String, dynamic> json) => UserProfile(
        userId: json['userId'] as String,
        hasSafeWord: json['hasSafeWord'] as bool? ?? false,
        createdAt: DateTime.parse(json['createdAt'] as String),
        updatedAt: DateTime.parse(json['updatedAt'] as String),
      );

  // -------------------------------------------------------------------------
  // copyWith
  // -------------------------------------------------------------------------

  UserProfile copyWith({
    WalkingPaceProfile? walkingPace,
    bool? hasSafeWord,
    List<TrustedContact>? trustedContacts,
    HomeLocation? homeLocation,
    UserPreferences? preferences,
    DateTime? updatedAt,
  }) =>
      UserProfile(
        userId: userId,
        walkingPace: walkingPace ?? this.walkingPace,
        hasSafeWord: hasSafeWord ?? this.hasSafeWord,
        trustedContacts: trustedContacts ?? this.trustedContacts,
        homeLocation: homeLocation ?? this.homeLocation,
        preferences: preferences ?? this.preferences,
        createdAt: createdAt,
        updatedAt: updatedAt ?? DateTime.now(),
      );

  @override
  String toString() =>
      'UserProfile(id: $userId, safeWord: $hasSafeWord, '
      'contacts: ${trustedContacts.length}, pace: $walkingPace, '
      'home: $homeLocation)';
}
