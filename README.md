# SheSafe - Personal Safety App

SheSafe is my final-year dissertation project at Coventry University. It's a Flutter Android app built around personal safety — live risk-aware route planning, motion anomaly detection, safe-word emergency dispatch, and incident recording, all running directly on your phone with no cloud backend required.

🎥 Project Demo

▶ Watch the SheSafe application demo - https://youtu.be/clXPXkwmGTI

1. Scope and Objectives

## 1. Scope and Objectives

### What SheSafe does
- Helps users stay safe during solo travel and walking sessions.
- Assesses route risk using synthetically generated bundled datasets (Latin Hypercube sampling over Norwich, UK coordinates) plus optional live UK Police API data.
- Escalates emergencies automatically via manual SOS, motion anomaly detection, safe-word speech recognition, and low-battery triggers.
- Notifies trusted contacts and logs incidents locally on the device.

### What it doesn't do
- It does not dispatch police or emergency services directly.
- It is not a certified fall-detection medical device.
- Background location tracking is not guaranteed across all Android OEM variants.

## 2. Functional Specification

| Capability | Trigger/Input | Processing | Output/Result | Failure Behavior |
|---|---|---|---|---|
| Risk map and route intelligence | User location, route destination, risk datasets | Risk scoring over route segments using `RiskEngineService` + `CrimeEvidenceService` | Routes labeled by relative safety and evidence summary | Falls back to synthetically generated bundled CSV assets (`risk_zones.csv`, `crime_evidence.csv`) when live fetch is unavailable |
| Safety mode motion monitoring | Accelerometer stream during active walk session | Window scoring against baseline profile (service layer) | Escalation trigger events and walk safety summary | Session continues with conservative defaults if baseline is missing |
| Panic escalation | Manual SOS tap, motion anomaly, or safe-word match | Stage-based escalation pipeline (`PanicEscalationService`) | Contact alert dispatch and event log entries | User can cancel during check-in/countdown states |
| Silent safe-word listener | Mic permission + configured safe word | Speech recognition + verification (`SilentSafeWordService`, `SafeWordVerificationService`) | Background emergency SMS attempt, optional panic screen navigation | Retries listening loop; local fallback phrase match used on verification errors |
| Low battery alert | Battery polling while safety sessions are active | Threshold logic in `BatteryAlertService` | Warning state at <=20%, critical dispatch at <=10% | Fire-once guards prevent contact spam in a session |
| Offline resilience | Network loss events | Connectivity state stream + local cache reuse | Offline banner and continued core operation on cached assets | No live refresh until connectivity returns |
| Incident reporting | User-submitted incident form fields | Structured serialization + export/share flow | Portable report artefact for evidence workflows | Validation blocks incomplete required fields |

## 3. Non-Functional Targets

| Quality Attribute | Target | Current Implementation Basis |
|---|---|---|
| Availability offline | Core safety workflows remain usable without internet | Bundled `assets/risk_zones.csv` (synthetic), `assets/crime_evidence.csv` (synthetic), `assets/safety_guidance.csv` plus cached live zones in `SharedPreferences`. Note: bundled risk and crime CSVs are synthetically generated using Latin Hypercube sampling over Norwich, UK — they are not real reported crime records. Real crime data is fetched from the UK Police API when online. |
| Startup determinism | Critical services initialized before first interactive session | `main.dart` initializes storage, event logging, connectivity seed, risk/guidance preload, and quick action notifications before `runApp()` |
| Auditability | Safety-relevant actions are observable post-session | `EventLogService` persists structured events (capped storage with tests) |
| Accessibility | TalkBack-friendly controls and minimum touch target sizes | Material theme and semantics-first UI patterns in app layer |
| Privacy-first local operation | No proprietary backend required for baseline operation | Local storage and platform intents used for core features |

## 4. What You Need to Run It

- Flutter SDK 3.24 or later (I tested it on 3.27)
- Dart SDK ^3.10.8 (pinned in `pubspec.yaml`)
- Android 8.0+ phone (API 26 or higher)
- A real physical Android device — emulators don't work well for GPS, mic, sensors, and audio together

## 5. API and Backend Configuration

### TL;DR — do you need API keys?
**No.** For basic testing you don't need to set up anything extra.
- The UK Police crime data endpoint is completely public and free.
- Maps use OpenStreetMap tiles — no key needed.
- Geocoding uses Nominatim — also free and keyless.

### Feature dependency matrix

| Feature area | Works in baseline mode (no local backend, no Google key) | Needs local backend (`app.py`) | Needs Google Directions API key |
|---|---|---|---|
| App launch, onboarding, storage, permissions | Yes | No | No |
| Risk map with bundled/cached data | Yes | No | No |
| UK Police live enrichment (best effort) | Yes (public API) | No | No |
| Safe route generation and route display | Yes (fallback path) | No | No |
| Backend route explanation integration (`/route/safest`) | No | Yes | No |
| Backend panic escalation acknowledgement (`/panic/escalate`) | No | Yes | No |
| Backend safe-word verification endpoints | Degrades to local fallback behavior | Yes for full endpoint flow | No |
| Google Directions-powered alternatives | Optional only | No | Yes |

### Local backend setup (only needed for optional advanced features)

The backend is a small FastAPI server I wrote for this project. It lives in this repo as `app.py` — you don't need it for basic testing.

Minimum backend runtime requirements:
- Python 3.9 or later (the backend uses modern type-hint syntax such as `list[float]`).
- Model files present at project root: `isolation_forest_model.pkl` and `scaler.pkl`.
- CSV data present at `assets/risk_zones.csv`.
- Required Python packages: `fastapi`, `uvicorn`, `numpy`, `pandas`, `joblib`, `pydantic`.

From the project root:

```bash
pip install fastapi uvicorn numpy pandas joblib pydantic
uvicorn app:app --host 0.0.0.0 --port 8000
```

If you want to make sure your backend environment exactly matches what I tested with, you can pin your dependencies like this:

```bash
pip install fastapi uvicorn numpy pandas joblib pydantic
pip freeze > requirements-backend.lock.txt
```

Then on any other machine:

```bash
pip install -r requirements-backend.lock.txt
```

Then set `BackendConfig.baseUrl` in `lib/config/backend_config.dart` so your device can reach that server.

Recommended values:
- Android emulator: `http://10.0.2.2:8000`
- Physical Android device on same Wi-Fi as host machine: `http://<your-lan-ip>:8000`
- Physical Android device via host hotspot: `http://192.168.137.1:8000` (if that is your host hotspot gateway)

### How to get a Google Directions API key (optional)

You only need this if you want the Google Maps-powered route alternatives. If you skip it, the app just uses fallback routing and still works fine.

1. Go to `https://console.cloud.google.com/` and sign in.
2. Create a new project (or use an existing one).
3. Search for "Directions API" and enable it.
4. Go to APIs and Services > Credentials > Create Credentials > API key.
5. (Recommended) Restrict the key to the Directions API only.
6. Copy the key and paste it into `BackendConfig.googleDirectionsApiKey` in `lib/config/backend_config.dart`.

### Step-by-step for someone running this for the first time
1. Clone the repo and run `flutter pub get`.
2. Decide what you want to test:
   - Just the app itself: skip backend and API key setup entirely.
   - Backend-connected features: start `app.py` first and update `BackendConfig.baseUrl`.
3. Optionally add a Google Directions key if you want to see Google route alternatives.
4. Plug in a real Android phone and run `flutter run -d <device-id>`.

### What happens if something isn't configured
- UK Police API fails or is offline → app uses the bundled crime CSV instead, no crash.
- Backend not running → only the optional backend-enhanced flows are affected, the rest of the app works normally.
- Google Directions key missing → the app falls back to the alternative routing path, routes still appear.

## 6. Quick Start

```bash
git clone https://github.coventry.ac.uk/aktarr4/sheSafe.git
cd sheSafe
flutter pub get
flutter devices
flutter run -d <device-id>
```

That's it for basic testing. You don't need to touch any config unless you specifically want the optional backend features.

### How do you know it's working? (first 60 seconds)
1. App opens — no immediate red crash screen.
2. If first run: you'll see the onboarding welcome screen with a `Get Started` button.
3. Tap `Get Started` and it should move to the permissions explanation screen.
4. Once onboarding is done (or on a returning run), you land on the home map screen.
5. Even with no internet, the app should still open and show the map using offline/cached data.

### Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `flutter run` cannot find device | Android debugging not enabled or no authorized device | Run `flutter devices`, enable USB debugging, accept device authorization prompt, retry `flutter run -d <device-id>` |
| Map/home does not show expected live backend behavior | `BackendConfig.baseUrl` not reachable from device | Set `baseUrl` in `lib/config/backend_config.dart` to a host/IP reachable by that device and verify backend is running on port 8000 |
| Backend integration calls fail | Backend not started or wrong environment dependencies | Start backend with `uvicorn app:app --host 0.0.0.0 --port 8000`, ensure `.pkl` model files exist at repo root, reinstall backend packages |
| Safe route still works but no Google alternatives | Google Directions key missing/placeholder | Add a valid key to `BackendConfig.googleDirectionsApiKey` or keep fallback mode intentionally |
| App blocked during route/location features | Location permission denied or denied forever | Re-enable Location permission in Android app settings and restart the app |
| Safe-word verification endpoint unreachable | Optional backend endpoint unavailable | Keep baseline flow (local fallback behavior), or run backend and confirm `/safeword/verify` endpoint availability |

## 7. Architecture Overview

The app is structured around a service layer — all business logic lives in singleton services that get initialised once at startup, and the UI screens just call into them. I deliberately kept it simple and readable for a dissertation project rather than over-engineering it.

- `lib/main.dart` — app entry point, boots all services, decides onboarding vs home
- `lib/app_navigator.dart` — global navigator key and SOS overlay visibility
- `lib/features/*` — onboarding flow, home/map, panic mode, walk history, motion dataset
- `lib/services/*` — all business logic: routing, risk scoring, escalation, storage, battery, safe word, notifications, etc.
- `lib/models/*` — typed data structures for routes, risk zones, events, and user profiles

### How risk data is loaded
1. First tries previously-fetched live risk zones (cached locally from last online session).
2. Falls back to the CSV file bundled in the app.
3. Keeps whatever is already in memory if a live refresh fails mid-session.

This means route intelligence always works even with no internet.

## 8. Onboarding Flow

First-time users go through a 10-step setup flow in `lib/features/onboarding`.

1. Welcome
2. Profile setup (optional fields)
3. Permission rationale
4. Permission request
5. Motion baseline calibration (optional)
6. Safe-word setup (optional but recommended)
7. Safe-word test
8. Region selection
9. Trusted contacts
10. Review and complete

When the user finishes, `SecureStorageService` stores a completion flag so they go straight to the home map on future launches.

Edge case handled: if SharedPreferences gets wiped (e.g. during a debug reinstall) but the safe word is still in encrypted storage, the app restores the completion flag automatically so the user doesn't get stuck in onboarding again.

## 9. Security and Privacy

### What gets stored and where
- Encrypted secure storage: safe word, sensitive profile fields.
- Shared preferences: lightweight flags like onboarding status and cached risk zone pointers.
- Bundled local assets: the crime and guidance datasets shipped with the app.

### Crypto
- Safe word has two storage paths: raw value for active verification flows, and a PBKDF2-HMAC-SHA256 hashed version in the user profile service. Both exist simultaneously — this is a known piece of technical debt I've noted for future cleanup.

### What leaves the device
- SMS and email use Android's built-in intent system — no third-party relay.
- UK Police API calls are the only outbound network requests for data.
- Nothing requires a SheSafe-specific remote server for the app to work.

## 10. Feature Acceptance Criteria

| Feature | Acceptance Criteria |
|---|---|
| Routing safety labels | Given at least one valid destination, app renders candidate routes with relative safety explanations and risk evidence summaries |
| Panic escalation | Manual SOS must transition escalation state and generate an emergency dispatch attempt with event logging |
| Safe-word monitoring | If configured safe word is detected, service must trigger dispatch flow and emit a user-visible alert notification |
| Battery safety alert | While monitoring is active, app must set warning state at <=20% and attempt critical dispatch path at <=10% once per session |
| Offline mode | On connectivity loss, app must continue operation with bundled/cached datasets and present offline status indicator |
| Onboarding persistence | After completion, relaunch must open home screen unless user data is intentionally reset |

## 11. Dependency Map (Key Packages)

| Package | Responsibility |
|---|---|
| `flutter_map`, `latlong2` | OSM map rendering and geometry primitives |
| `geolocator`, `geocoding` | GPS updates and geospatial conversion |
| `sensors_plus` | Accelerometer stream for motion analysis |
| `speech_to_text` | Safe-word listening pipeline |
| `flutter_tts`, `audioplayers` | Fake call voice + ringtone simulation |
| `battery_plus` | Battery telemetry for low-power alerting |
| `connectivity_plus` | Online/offline state detection |
| `flutter_local_notifications` | Persistent quick-action notifications |
| `flutter_secure_storage` | Sensitive local data protection |
| `shared_preferences` | Lightweight flags and cache pointers |
| `permission_handler` | Runtime permission workflow |
| `http` | UK Police API requests |
| `provider` | Onboarding controller state management |
| `share_plus`, `path_provider` | Incident report export/sharing |
| `crypto`, `uuid`, `intl`, `package_info_plus` | Hashing, identifiers, formatting, app metadata |

## 12. Running the Tests

### Unit and widget tests
```bash
flutter test
```

### Integration test: onboarding critical path
Needs a real device connected:
```bash
flutter test integration_test/onboarding_flow_test.dart -d <device-id>
```

This test checks:
- Welcome screen renders and `Get Started` is tappable
- Permissions rationale screen appears with the right copy
- Transition into the permissions request step
- Safe-word entry and save completes without a crash

### Test evidence files already in the repo
- `test_results_evidence.txt` — full captured test run output
- `run_log.txt` — session run log (UTF-16 encoded)
- `test_output.txt` — additional captured output (UTF-16 encoded)

## 13. Reproducibility Checklist

If you're reproducing results for evaluation or marking:

1. Use a physical Android device running API 26 or above.
2. Make sure the device has location, microphone, and notification permissions ready to grant.
3. Run `flutter clean` then `flutter pub get` to start from a clean state.
4. Run `flutter test` and save the output.
5. Run the onboarding integration test on real hardware.
6. Note down the Flutter and Dart SDK versions you used — worth including in any write-up.

## 14. Known Limitations

Being honest about what doesn't work perfectly:

- The UK Police API rate-limits heavy requests — the app handles this by falling back to cached data, but live enrichment may sometimes be unavailable.
- The bundled risk and crime CSVs (`risk_zones.csv`, `crime_evidence.csv`) are synthetically generated (Latin Hypercube sampling over Norwich, UK) and are intended as structural placeholders — they do not represent real historical crime records. The app is designed to replace them with live UK Police API data when online.
- Motion anomaly detection has two paths: the in-app service uses the user's own calibrated walking baseline from onboarding, while the optional backend Isolation Forest model supports prototype-level anomaly analysis. For dissertation evaluation, the motion evidence reported in the study is based on a small personalised dataset collected through controlled sessions for this project. The evaluation therefore supports bounded prototype-level claims under controlled conditions rather than generalisable real-world detection performance.
- `assets/motion_features.csv` in the repo is a sample of motion window data exported from the app's own Motion Dataset screen — it is not a training dataset for the model.
- Background GPS and service persistence varies quite a lot between Android OEM brands due to aggressive battery management — Samsung and Xiaomi are the worst offenders.
- I only validated this on Android. The iOS code is partially scaffolded but I never tested it properly.
- A couple of log files in the repo are UTF-16 encoded from capture — you'll need to handle that if you try to parse them programmatically.

## 15. Sending Feedback

There's a feedback button (speech bubble icon) in the floating icon strip on the home map screen. Tapping it opens a pre-filled email draft with your app version and device context already attached — makes it easy to send useful bug reports for the research.

## 16. Licence

This is a university research project — see `LICENSE` for the full terms. Not intended for commercial use.
