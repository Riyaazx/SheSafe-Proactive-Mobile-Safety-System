/// Risk detection sensitivity level.
///
/// Controls how aggressively the app flags anomalies based on the
/// user's own baseline — higher sensitivity means earlier alerts.
enum RiskSensitivity {
  /// Fewer alerts; only clear deviations are flagged.
  low,

  /// Balanced default — recommended for most users.
  medium,

  /// Frequent alerts; any small deviation triggers a notification.
  high,
}

/// Non-sensitive user preferences stored in SharedPreferences.
///
/// These settings do not contain personally identifiable information and
/// therefore live in plain SharedPreferences rather than encrypted storage.
class UserPreferences {
  /// Radius (in metres) around the user's position used to look up risk zones.
  /// Default 500 m gives roughly a 5-minute walking buffer.
  final double riskRadiusMeters;

  /// How sensitive anomaly detection should be relative to the user's baseline.
  final RiskSensitivity sensitivity;

  /// Whether local push notifications are enabled.
  final bool notificationsEnabled;

  /// Whether background motion/location monitoring runs when app is backgrounded.
  final bool backgroundMonitoringEnabled;

  /// Minimum confidence score (0–1) required before a safe-word detection is
  /// accepted as genuine.
  final double safeWordConfidenceThreshold;

  const UserPreferences({
    this.riskRadiusMeters = 500.0,
    this.sensitivity = RiskSensitivity.medium,
    this.notificationsEnabled = true,
    this.backgroundMonitoringEnabled = true,
    this.safeWordConfidenceThreshold = 0.75,
  });

  // -------------------------------------------------------------------------
  // Serialisation
  // -------------------------------------------------------------------------

  Map<String, dynamic> toJson() => {
        'riskRadiusMeters': riskRadiusMeters,
        'sensitivity': sensitivity.name,
        'notificationsEnabled': notificationsEnabled,
        'backgroundMonitoringEnabled': backgroundMonitoringEnabled,
        'safeWordConfidenceThreshold': safeWordConfidenceThreshold,
      };

  factory UserPreferences.fromJson(Map<String, dynamic> json) =>
      UserPreferences(
        riskRadiusMeters: (json['riskRadiusMeters'] as num?)?.toDouble() ?? 500.0,
        sensitivity: RiskSensitivity.values.firstWhere(
          (e) => e.name == json['sensitivity'],
          orElse: () => RiskSensitivity.medium,
        ),
        notificationsEnabled: json['notificationsEnabled'] as bool? ?? true,
        backgroundMonitoringEnabled:
            json['backgroundMonitoringEnabled'] as bool? ?? true,
        safeWordConfidenceThreshold:
            (json['safeWordConfidenceThreshold'] as num?)?.toDouble() ?? 0.75,
      );

  // -------------------------------------------------------------------------
  // Utility
  // -------------------------------------------------------------------------

  UserPreferences copyWith({
    double? riskRadiusMeters,
    RiskSensitivity? sensitivity,
    bool? notificationsEnabled,
    bool? backgroundMonitoringEnabled,
    double? safeWordConfidenceThreshold,
  }) =>
      UserPreferences(
        riskRadiusMeters: riskRadiusMeters ?? this.riskRadiusMeters,
        sensitivity: sensitivity ?? this.sensitivity,
        notificationsEnabled: notificationsEnabled ?? this.notificationsEnabled,
        backgroundMonitoringEnabled:
            backgroundMonitoringEnabled ?? this.backgroundMonitoringEnabled,
        safeWordConfidenceThreshold:
            safeWordConfidenceThreshold ?? this.safeWordConfidenceThreshold,
      );

  @override
  String toString() =>
      'UserPreferences(radius: ${riskRadiusMeters}m, sensitivity: $sensitivity, '
      'notifications: $notificationsEnabled, background: $backgroundMonitoringEnabled)';
}
