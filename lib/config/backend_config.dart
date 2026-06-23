// Single place to configure the backend URL.
//
// How to set up for your device type:
//   Android emulator  → use EMULATOR_HOST  (10.0.2.2)
//   Physical phone    → use your PC's LAN IP (run `ipconfig` on Windows)
//   iOS simulator     → use SIMULATOR_HOST  (localhost / 127.0.0.1)
//
// Your current LAN IP: 10.5.5.253
// If the phone is on your PC's hotspot the IP is: 192.168.137.1

class BackendConfig {
  BackendConfig._();

  // ── Change this one line to switch environments ──────────────────────────

  /// Set to whichever address your running device can reach.
  ///   'http://10.0.2.2:8000'        ← Android emulator
  ///   'http://10.5.5.253:8000'      ← physical device on same WiFi as your PC
  ///   'http://192.168.137.1:8000'   ← physical device via PC hotspot
  static const String baseUrl = 'http://10.5.5.253:8000';

  // ── Google Directions API key ─────────────────────────────────────────────
  // Enable this to get real Google Maps walking routes (3 genuinely different
  // road-network alternatives, exactly as Google Maps shows them).
  //
  // Setup:
  //   1. Go to https://console.cloud.google.com/
  //   2. Enable the "Directions API" for your project.
  //   3. Copy your API key and paste it below (replace the placeholder).
  //
  // If left as the placeholder, the app will fall back to OSRM routes.
  static const String googleDirectionsApiKey = 'YOUR_GOOGLE_DIRECTIONS_API_KEY';

  // ── Derived helpers (don't edit below) ───────────────────────────────────
  static const String healthEndpoint    = '$baseUrl/health';
  static const String routeSafest       = '$baseUrl/route/safest';
  static const String safeWordVerify    = '$baseUrl/safeword/verify';
  static const String safeWordConfig    = '$baseUrl/safeword/config';
  static const String panicEscalate     = '$baseUrl/panic/escalate';
  static const String motionPredict     = '$baseUrl/motion/predict';
  static const String locationCheck     = '$baseUrl/location/check';
}
