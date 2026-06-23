import 'dart:async';

import 'package:flutter/material.dart';
import 'dart:convert';
import 'dart:math' as math;
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:sensors_plus/sensors_plus.dart';
import '../../services/route_generator_service.dart';
import '../../services/risk_engine_service.dart';
import '../../services/event_log_service.dart';
import '../../services/country_service.dart';
import '../../services/integration_pipeline_service.dart';
import '../../services/arrival_notification_service.dart';
import '../../services/secure_storage_service.dart';
import '../../services/route_confidence_service.dart';
import '../../services/walk_safety_service.dart';
import '../../services/motion_baseline_service.dart';
import '../../services/battery_alert_service.dart';
import 'manage_trusted_contacts_screen.dart';
import '../../models/route_confidence.dart';
import 'walk_summary_screen.dart';

import '../../models/route_option.dart';
import '../../models/risk_zone.dart';
import '../../models/event_log.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart' hide Path;

class SafeRouteScreen extends StatefulWidget {
  final String destination;

  const SafeRouteScreen({super.key, required this.destination});

  @override
  State<SafeRouteScreen> createState() => _SafeRouteScreenState();
}

class _SafeRouteScreenState extends State<SafeRouteScreen> {
  static const _kAccent = Color(0xFFB07080);
  static const _kSoftBg = Color(0xFFFFF4F8);
  static const _kSoftCard = Color(0xFFFFF8FA);
  static const _kSoftBorder = Color(0xFFF0DCE4);

  final RouteGeneratorService _routeGenerator = RouteGeneratorService();
  final RiskEngineService _riskEngine = RiskEngineService();
  final EventLogService _eventLogService = EventLogService();
  final RouteConfidenceService _confidenceService = RouteConfidenceService();
  final WalkSafetyScoreService _walkScoreService = WalkSafetyScoreService();
  final MotionBaselineService _motionService = MotionBaselineService();

  CountryInfo? _selectedCountry;
  bool _isUk = true;
  
  double? currentLatitude;
  double? currentLongitude;
  double? destinationLatitude;
  double? destinationLongitude;
  
  List<RouteOption> routeOptions = [];
  RouteOption? selectedRoute;
  int selectedRouteIndex = 0;
  
  bool isLoadingLocation = true;
  bool isGeneratingRoutes = false;
  String locationError = '';
  
  // Navigation mode state
  bool isNavigating = false;
  int currentNavigationStep = 0;
  final ScrollController _navigationScrollController = ScrollController();

  // Walk safety tracking (for post-walk summary)
  DateTime? _walkStartTime;
  int _walkAnomalyCount = 0;
  List<String> _walkAnomalyDescriptions = [];
  StreamSubscription<AccelerometerEvent>? _fallbackAccelSub;
  double _fallbackBaselineMag = 0;
  final List<double> _fallbackMagBuffer = [];

  // Real GPS tracking during walk
  StreamSubscription<Position>? _gpsPositionSub;
  final List<Position> _gpsPositions = [];
  double _actualDistanceMeters = 0;

  // ── Feature 3: Battery alert service ──────────────────────────────────────
  final BatteryAlertService _batteryAlertService = BatteryAlertService();
  /// True when LowBatteryFlag = true (battery ≤ 20%).
  /// Drives the persistent warning banner in navigation mode.
  bool _lowBatteryWarningVisible = false;

  /// Whether to notify a trusted contact when the journey ends.
  /// User can toggle this on/off on the safe route view before starting.
  bool _notifyContactOnArrival = true;

  /// Trusted contacts pre-selected by the user BEFORE starting the journey.
  /// Used in [_handleNavigationComplete] to send arrival messages without
  /// showing the picker again at the end of the walk.
  List<Map<String, dynamic>>? _preSelectedArrivalContacts;

  // Map controllers for programmatic re-centering
  final MapController _mapController = MapController();
  final MapController _navMapController = MapController();

  // Navigation view mode: false = text instructions, true = live map
  bool _showNavigationMap = true;

  // When true, the nav map auto-follows the user's GPS position.
  // Becomes false when the user drags the map; re-centre pill then appears.
  bool _isFollowingUser = true;

  // From / To search controllers
  final TextEditingController _fromController = TextEditingController();
  final TextEditingController _toController   = TextEditingController();
  // When the user types a custom "from" address, these hold its resolved coords.
  // ignore: unused_field
  double? _customFromLat;
  // ignore: unused_field
  double? _customFromLon;
  String  _geocodeStatus = ''; // feedback line shown under search bar
  // Per-route OSRM data (keyed by routeOptions index)
  final Map<int, List<LatLng>>    _routePolylines       = {};
  final Map<int, List<_OsrmStep>> _routeSteps           = {};
  // OSRM-reported distances (m) and durations (s) — authoritative values
  final Map<int, double>          _osrmDistanceMeters   = {};
  final Map<int, int>             _osrmDurationSeconds  = {};
  // Overlap penalty (0–35 pts) per route index, subtracted from safety %
  final Map<int, double>          _overlapPenalties     = {};
  // True while OSRM is fetching — the map shows a loading overlay until the
  // road-snapped polylines are ready, so the route never visually jumps.
  bool _osrmFetching = false;
  /// True while the From field contains the reverse-geocoded GPS address
  /// (so _searchNewRoute can skip re-geocoding it).
  bool _fromIsGps = true;

  // Backend explanation (null = not yet fetched or backend unavailable)
  BackendRouteExplanation? _backendExplanation;
  // ignore: unused_field
  int? _routeGenLatencyMs;   // total time from request to routes-ready

  // Route Confidence Scores (computed after route generation)
  List<RouteConfidenceScore> _confidenceScores = [];

  double _crimeScaleForRisk(double risk, double minRisk, double maxRisk) {
    if ((maxRisk - minRisk).abs() < 1e-6) {
      return 0.85;
    }
    final t = ((risk - minRisk) / (maxRisk - minRisk)).clamp(0.0, 1.0);
    return 0.65 + (t * 0.35);
  }

  Future<List<RouteOption>> _applyCrimeScalingByRisk(
      List<RouteOption> routes) async {
    if (routes.isEmpty) return routes;

    final risks = routes.map((r) => r.overallRiskScore).toList();
    final minRisk = risks.reduce((a, b) => a < b ? a : b);
    final maxRisk = risks.reduce((a, b) => a > b ? a : b);

    return routes.map((route) {
      final scale =
          _crimeScaleForRisk(route.overallRiskScore, minRisk, maxRisk);
      final analysis =
          _riskEngine.analyzeRoute(route, crimeScaleFactor: scale);
      return route.copyWith(analysis: analysis);
    }).toList();
  }

  List<RouteOption> _normalizeRouteIdentity(List<RouteOption> routes) {
    if (routes.isEmpty) return routes;

    final ordered = <RouteOption>[];
    final used = <RouteOption>{};

    RouteOption? findById(String id) {
      for (final r in routes) {
        final rid = r.routeId.toLowerCase().trim();
        if (rid == id) return r;
      }
      return null;
    }

    void addIfPresent(RouteOption? route) {
      if (route == null || used.contains(route)) return;
      ordered.add(route);
      used.add(route);
    }

    // Canonical UI order by semantic identity, not by risk sorting.
    addIfPresent(findById('safest'));
    addIfPresent(findById('balanced'));
    addIfPresent(findById('direct'));

    // Preserve any additional/unknown routes at the end.
    for (final route in routes) {
      addIfPresent(route);
    }

    RouteOption? safest;
    RouteOption? direct;
    for (final r in ordered) {
      final id = r.routeId.toLowerCase();
      if (id == 'safest' && safest == null) safest = r;
      if (id == 'direct' && direct == null) direct = r;
    }

    return ordered.map((route) {
      final isSafest = route.routeId.toLowerCase() == 'safest';

      ComparisonData? comparison = route.analysis.comparisonWithAlternative;
      if (isSafest && direct != null && direct != route) {
        final riskDiff = math.max(0.0, direct.overallRiskScore - route.overallRiskScore);
        comparison = ComparisonData(
          alternativeRouteName: 'Direct Route',
          riskDifferencePercentage: riskDiff,
          reason: 'lower crime exposure and fewer risk zones',
        );
      }

      return route.copyWith(
        isRecommended: isSafest,
        analysis: RouteAnalysis(
          summary: route.analysis.summary,
          safetyReasons: route.analysis.safetyReasons,
          riskEvidence: route.analysis.riskEvidence,
          avoidedZones: route.analysis.avoidedZones,
          comparisonWithAlternative: comparison,
          crimeAssessment: route.analysis.crimeAssessment,
        ),
      );
    }).toList();
  }

  List<RouteWaypoint> _routeWaypointsFromPolyline(List<LatLng> points) {
    if (points.isEmpty) return [];

    return List<RouteWaypoint>.generate(points.length, (index) {
      final point = points[index];
      final type = index == 0
          ? WaypointType.start
          : index == points.length - 1
              ? WaypointType.destination
              : WaypointType.intermediate;
      return RouteWaypoint(
        latitude: point.latitude,
        longitude: point.longitude,
        name: type == WaypointType.start
            ? 'Start'
            : type == WaypointType.destination
                ? 'Destination'
                : null,
        type: type,
      );
    });
  }

  @override
  void initState() {
    super.initState();
    _fromController.text = 'Locating your position…';
    _toController.text   = widget.destination;
    // When the user manually edits the From field, clear the GPS flag.
    _fromController.addListener(() {
      if (_fromIsGps && _fromController.text != _lastAutoFromText) {
        _fromIsGps = false;
      }
    });
    // Load the user's country preference for Nominatim bias & hint text
    CountryService().getSelectedCountry().then((c) {
      if (mounted) {
        setState(() {
          _selectedCountry = c;
          _isUk = c?.code == 'gb';
        });
      }
    });
    _initialize();
  }

  /// Last string we auto-filled into the From field (via reverse geocoding).
  String _lastAutoFromText = 'Locating your position…';

  @override
  void dispose() {
    _stopWalkMonitoring();
    _gpsPositionSub?.cancel();
    _mapController.dispose();
    _navMapController.dispose();
    _toController.dispose();
    _navigationScrollController.dispose();
    super.dispose();
  }

  Future<void> _initialize() async {
    await _riskEngine.initialize();
    await _getCurrentLocation();
  }

  Future<void> _getCurrentLocation() async {
    try {
      // Check if location services are enabled
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        setState(() {
          locationError = 'Location services are disabled';
          isLoadingLocation = false;
        });
        return;
      }

      // Check location permission
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) {
          _eventLogService.logEvent(
            type: EventType.locationPermissionDenied,
            outcome: EventOutcome.warning,
            description: 'Safe Route blocked: location permission denied by user',
            metadata: {'screen': 'SafeRouteScreen', 'trigger': 'getCurrentLocation'},
          );
          debugPrint('[SafeRoute] Blocked — location permission denied');
          setState(() {
            locationError = 'Location permission is required to use Safe Route.';
            isLoadingLocation = false;
          });
          return;
        }
      }

      if (permission == LocationPermission.deniedForever) {
        _eventLogService.logEvent(
          type: EventType.locationPermissionDenied,
          outcome: EventOutcome.failure,
          description: 'Safe Route blocked: location permission permanently denied',
          metadata: {'screen': 'SafeRouteScreen', 'trigger': 'getCurrentLocation'},
        );
        debugPrint('[SafeRoute] Blocked — location permission permanently denied');
        setState(() {
          locationError =
              'Location permission is required to use Safe Route.\n\n'
              'To enable it, go to Settings > Apps > SheSafe > Permissions > Location.';
          isLoadingLocation = false;
        });
        return;
      }

      // ── Step 1: fresh high-accuracy GPS fix ──────────────────────────────
      // Request the best available fix directly (uses GPS chip + network fusion).
      // 20-second timeout gives GPS enough time to acquire satellites.
      Position? position;
      try {
        position = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.bestForNavigation,
          timeLimit: const Duration(seconds: 20),
        );
      } on TimeoutException {
        // GPS could not get a fresh fix in time — fall back to last known.
        position = await Geolocator.getLastKnownPosition();
      } catch (_) {
        position = await Geolocator.getLastKnownPosition();
      }

      if (position == null) {
        setState(() {
          locationError =
              'Could not determine your location. Please make sure GPS is on '
              'and try again.';
          isLoadingLocation = false;
        });
        return;
      }

      // Non-null local copy — safe to use without ! after any async boundary.
      final p = position;

      setState(() {
        currentLatitude    = p.latitude;
        currentLongitude   = p.longitude;
        isLoadingLocation  = false;
        isGeneratingRoutes = true; // keep spinner while reverse-geocoding + routing
      });

      // ── Step 2: continue refining accuracy in background ──────────────────
      // Keep listening until we have 10 updates or accuracy ≤ 5 m.
      double bestAccuracy = p.accuracy;
      Geolocator.getPositionStream(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.bestForNavigation,
          distanceFilter: 0, // fire on every fix, not just on movement
        ),
      ).take(10).listen((pos) {
        if (mounted && !isNavigating && pos.accuracy < bestAccuracy) {
          bestAccuracy = pos.accuracy;
          setState(() {
            currentLatitude  = pos.latitude;
            currentLongitude = pos.longitude;
          });
        }
      }).onError((_) {}); // silent — refinement is best-effort

      // Reverse-geocode to show the real address in the From field
      final addr = await _reverseGeocode(p.latitude, p.longitude);
      if (mounted) {
        final displayAddr = addr
            ?? '${p.latitude.toStringAsFixed(5)}, ${p.longitude.toStringAsFixed(5)}';
        setState(() {
          _lastAutoFromText = displayAddr;
          _fromIsGps        = true;
          _fromController.text = displayAddr;
        });
      }

      // Now geocode the destination and generate routes
      await _geocodeAndGenerateRoutes();

    } catch (e) {
      setState(() {
        locationError = 'Could not get location: ${e.toString()}';
        isLoadingLocation = false;
      });
    }
  }

  // ---------------------------------------------------------------------------
  // Nominatim (OpenStreetMap) geocoder — no API key required.
  // ---------------------------------------------------------------------------
  Future<({double lat, double lon, String display})?> _nominatimGeocode(
      String address) async {
    try {
      final uri = Uri.https('nominatim.openstreetmap.org', '/search', {
        'q': address,
        'format': 'json',
        'limit': '1',
        'addressdetails': '0',
      });
      final response = await http.get(uri, headers: {
        'User-Agent': 'SheSafe-FYP-App/1.0 (dissertation project)',
        'Accept-Language': 'en',
      }).timeout(const Duration(seconds: 15));

      if (response.statusCode == 200) {
        final List<dynamic> results = jsonDecode(response.body);
        if (results.isNotEmpty) {
          final r = results.first;
          return (
            lat: double.parse(r['lat'] as String),
            lon: double.parse(r['lon'] as String),
            display: r['display_name'] as String,
          );
        }
      }
    } catch (e) {
      debugPrint('Nominatim error: $e');
    }
    return null;
  }

  /// Races [futures] and returns the result of the first that is non-empty.
  /// Unlike Future.wait (which waits for ALL), this resolves as soon as any
  /// one geocoder returns results — so the typical case (Photon hits in ~1 s)
  /// doesn't wait for the slower Nominatim/Overpass calls.
  Future<List<T>> _firstNonEmpty<T>(List<Future<List<T>>> futures) {
    if (futures.isEmpty) return Future.value([]);
    final completer = Completer<List<T>>();
    int pending = futures.length;
    for (final f in futures) {
      f.then((result) {
        if (result.isNotEmpty && !completer.isCompleted) {
          completer.complete(result);
        }
        pending--;
        if (pending == 0 && !completer.isCompleted) completer.complete([]);
      }).catchError((_) {
        pending--;
        if (pending == 0 && !completer.isCompleted) completer.complete([]);
      });
    }
    return completer.future;
  }

  /// Search for up to [limit] location results matching [query].
  /// Strategy: Photon geocoder first (best for named POIs), then three
  /// Nominatim passes (proximity-first), then Overpass for any remaining POIs.
  Future<List<({double lat, double lon, String display})>>
      _nominatimSearchMany(String query, {int limit = 5}) async {
    // Normalise UK postcodes and trim whitespace before any geocoder call
    query = _normalizeQuery(query);

    // Geocoder strategy (all rounds run fast; no artificial delays):
    //  Round A — Photon + Nominatim-bounded in PARALLEL (fastest path).
    //  Round B — Nominatim-country + Overpass in PARALLEL (fallback).
    // Both Photon and Nominatim share a 5-7 s timeout so the user never
    // waits more than ~7 s before the picker appears.

    Future<List<({double lat, double lon, String display})?>> callNominatim(
        Map<String, String> extraParams) async {
      try {
        final params = <String, String>{
          'q'             : query,
          'format'        : 'json',
          'limit'         : '$limit',
          'addressdetails': '1',
          ...extraParams,
        };
        final uri = Uri.https('nominatim.openstreetmap.org', '/search', params);
        final response = await http.get(uri, headers: {
          'User-Agent'      : 'SheSafe-FYP-App/1.0 (dissertation project)',
          'Accept-Language' : 'en',
        }).timeout(const Duration(seconds: 7));
        if (response.statusCode == 200) {
          final results = jsonDecode(response.body) as List<dynamic>;
          return results
              .map<({double lat, double lon, String display})>((r) {
            final placeName = (r['name'] as String?)?.trim() ?? '';
            final addr      = r['address'] as Map<String, dynamic>?;
            String road     = '';
            String number   = '';
            String city     = '';
            String postcode = '';
            if (addr != null) {
              road     = (addr['road']         as String?)?.trim() ?? '';
              number   = (addr['house_number'] as String?)?.trim() ?? '';
              city     = ((addr['city']    ?? addr['town']   ??
                           addr['village'] ?? addr['suburb'] ??
                           addr['county'])
                              as String?)?.trim() ?? '';
              postcode = (addr['postcode'] as String?)?.trim() ?? '';
            }
            // Build a human-friendly label: "Place, Number Road, City, Full Postcode"
            final streetPart = [
              if (number.isNotEmpty) number,
              if (road.isNotEmpty)   road,
            ].join(' ');
            final labelParts = <String>[
              if (placeName.isNotEmpty) placeName,
              if (streetPart.isNotEmpty && streetPart != placeName) streetPart,
              if (city.isNotEmpty && city != placeName) city,
              if (postcode.isNotEmpty) postcode, // full postcode, e.g. CV1 2NA
            ];
            final label = labelParts.isNotEmpty
                ? labelParts.join(', ')
                : (r['display_name'] as String)
                    .split(',')
                    .take(4)
                    .join(',')
                    .trim();
            return (
              lat: double.parse(r['lat'] as String),
              lon: double.parse(r['lon'] as String),
              display: label,
            );
          }).toList();
        }
      } catch (e) {
        debugPrint('Nominatim search error: $e');
      }
      return [];
    }

    final ccParam = _selectedCountry != null
        ? {'countrycodes': _selectedCountry!.code}
        : <String, String>{};

    // ── Round A: Photon + Nominatim in parallel ────────────────────────────
    if (currentLatitude != null && currentLongitude != null) {
      final lat = currentLatitude!;
      final lon = currentLongitude!;
      final nearBox =
          '${(lon - 0.5).toStringAsFixed(4)},${(lat + 0.5).toStringAsFixed(4)},'
          '${(lon + 0.5).toStringAsFixed(4)},${(lat - 0.5).toStringAsFixed(4)}';

      // UK postcodes: run Nominatim + Overpass addr:postcode in parallel so
      // all buildings/amenities within that postcode show up in the picker.
      if (_isUkPostcode(query)) {
        final bothResults = await Future.wait(<Future<List<({double lat, double lon, String display})>>>[
          callNominatim({'countrycodes': 'gb'})
              .then((r) => r.cast<({double lat, double lon, String display})>()),
          _overpassPostcodeSearch(query, limit: 30),
        ]);
        final combined = <({double lat, double lon, String display})>[];
        for (final list in bothResults) { combined.addAll(list); }
        // Deduplicate by proximity (< 20 m apart = same place)
        final deduped = <({double lat, double lon, String display})>[];
        for (final r in combined) {
          if (!deduped.any((d) =>
              (d.lat - r.lat).abs() < 0.0002 &&
              (d.lon - r.lon).abs() < 0.0002)) {
            deduped.add(r);
          }
        }
        if (deduped.isNotEmpty) return deduped.take(25).toList();
      } else {
        // Race Photon + Nominatim-bounded — return whichever answers first
        final resultA = await _firstNonEmpty(<Future<List<({double lat, double lon, String display})>>>[
          _photonSearch(query, limit: limit),
          callNominatim({'viewbox': nearBox, 'bounded': '1', ...ccParam})
              .then((r) => r.cast<({double lat, double lon, String display})>()),
        ]);
        if (resultA.isNotEmpty) return resultA;
      }
    } else if (_isUkPostcode(query)) {
      // No GPS but UK postcode — Nominatim + Overpass in parallel
      final bothResults = await Future.wait(<Future<List<({double lat, double lon, String display})>>>[
        callNominatim({'countrycodes': 'gb'})
            .then((r) => r.cast<({double lat, double lon, String display})>()),
        _overpassPostcodeSearch(query, limit: 30),
      ]);
      final combined = <({double lat, double lon, String display})>[];
      for (final list in bothResults) { combined.addAll(list); }
      final deduped = <({double lat, double lon, String display})>[];
      for (final r in combined) {
        if (!deduped.any((d) =>
            (d.lat - r.lat).abs() < 0.0002 &&
            (d.lon - r.lon).abs() < 0.0002)) {
          deduped.add(r);
        }
      }
      if (deduped.isNotEmpty) return deduped.take(25).toList();
    } else {
      // No GPS — just try Photon quickly
      final photon = await _photonSearch(query, limit: limit);
      if (photon.isNotEmpty) return photon;
    }

    // ── Round B: Nominatim-country + Overpass in parallel ─────────────────
    // Race Nominatim-country + Overpass — return whichever answers first
    final resultB = await _firstNonEmpty(<Future<List<({double lat, double lon, String display})>>>[
      callNominatim(ccParam)
          .then((r) => r.cast<({double lat, double lon, String display})>()),
      _overpassSearchPOI(query, limit: limit),
    ]);
    if (resultB.isNotEmpty) return resultB;
    return [];
  }

  /// Search the OpenStreetMap Overpass API for named POIs matching [query].
  /// Falls back gracefully to an empty list on any error.
  Future<List<({double lat, double lon, String display})>>
      _overpassSearchPOI(String query, {int limit = 5}) async {
    try {
      final escapedQuery = query.replaceAll('"', '\\"');
      final double lat   = currentLatitude  ?? 52.4081;
      final double lon   = currentLongitude ?? -1.5106;
      // ±0.5° bounding box ≈ 50 km around the user
      final minLat = (lat - 0.5).toStringAsFixed(4);
      final maxLat = (lat + 0.5).toStringAsFixed(4);
      final minLon = (lon - 0.5).toStringAsFixed(4);
      final maxLon = (lon + 0.5).toStringAsFixed(4);
      final overpassQuery =
          '[out:json][timeout:10];'
          '('
          '  node["name"~"$escapedQuery",i]($minLat,$minLon,$maxLat,$maxLon);'
          '  way["name"~"$escapedQuery",i]($minLat,$minLon,$maxLat,$maxLon);'
          '  relation["name"~"$escapedQuery",i]($minLat,$minLon,$maxLat,$maxLon);'
          ');'
          'out center qt $limit;';
      final uri = Uri.https('overpass-api.de', '/api/interpreter');
      final response = await http.post(
        uri,
        body: 'data=${Uri.encodeComponent(overpassQuery)}',
        headers: {
          'Content-Type': 'application/x-www-form-urlencoded',
          'User-Agent'  : 'SheSafe-FYP-App/1.0 (dissertation project)',
        },
      ).timeout(const Duration(seconds: 15));

      if (response.statusCode != 200) return [];

      final data     = jsonDecode(response.body) as Map<String, dynamic>;
      final elements = data['elements'] as List<dynamic>? ?? [];
      final results  = <({double lat, double lon, String display})>[];

      for (final el in elements) {
        final map  = el as Map<String, dynamic>;
        // Way/relation expose their centroid under the "center" key
        final elLat = (map['lat'] ?? (map['center'] as Map?)?['lat'])
            as num?;
        final elLon = (map['lon'] ?? (map['center'] as Map?)?['lon'])
            as num?;
        if (elLat == null || elLon == null) continue;

        final tags     = map['tags'] as Map<String, dynamic>? ?? {};
        final name     = (tags['name'] as String?)?.trim() ?? '';
        final city     = ((tags['addr:city']  ?? tags['addr:town'])
                              as String?)?.trim() ?? '';
        final postcode = (tags['addr:postcode'] as String?)?.trim() ?? '';
        final road     = (tags['addr:street'] as String?)?.trim() ?? '';
        final number   = (tags['addr:housenumber'] as String?)?.trim() ?? '';

        final streetPart = [
          if (number.isNotEmpty) number,
          if (road.isNotEmpty)   road,
        ].join(' ');
        final labelParts = <String>[
          if (name.isNotEmpty)       name,
          if (streetPart.isNotEmpty) streetPart,
          if (city.isNotEmpty)       city,
          if (postcode.isNotEmpty)   postcode,
        ];
        final label = labelParts.isNotEmpty
            ? labelParts.join(', ')
            : name.isNotEmpty ? name : 'Unknown place';

        results.add((lat: elLat.toDouble(), lon: elLon.toDouble(), display: label));
        if (results.length >= limit) break;
      }
      return results;
    } catch (e) {
      debugPrint('Overpass search error: $e');
      return [];
    }
  }

  /// Searches OpenStreetMap Overpass for all buildings and amenities tagged
  /// with [postcode] in the `addr:postcode` field.  First geocodes the
  /// postcode centroid via Nominatim so the `around` radius is anchored
  /// correctly regardless of the user's current GPS position.
  Future<List<({double lat, double lon, String display})>>
      _overpassPostcodeSearch(String postcode, {int limit = 12}) async {
    try {
      // Step 1 — get the postcode centroid so `around` targets the right city
      final centroid = await _nominatimGeocode('$postcode, UK');
      final anchorLat = centroid?.lat ?? currentLatitude  ?? 52.4081;
      final anchorLon = centroid?.lon ?? currentLongitude ?? -1.5106;

      final q = postcode.trim().toUpperCase();
      final overpassQuery =
          '[out:json][timeout:12];'
          '('
          '  node["addr:postcode"="$q"](around:1500,$anchorLat,$anchorLon);'
          '  way["addr:postcode"="$q"](around:1500,$anchorLat,$anchorLon);'
          ');'
          'out center qt $limit;';

      final uri = Uri.https('overpass-api.de', '/api/interpreter');
      final response = await http.post(
        uri,
        body: 'data=${Uri.encodeComponent(overpassQuery)}',
        headers: {
          'Content-Type': 'application/x-www-form-urlencoded',
          'User-Agent'  : 'SheSafe-FYP-App/1.0 (dissertation project)',
        },
      ).timeout(const Duration(seconds: 18));

      if (response.statusCode != 200) return [];

      final data     = jsonDecode(response.body) as Map<String, dynamic>;
      final elements = data['elements'] as List<dynamic>? ?? [];
      final results  = <({double lat, double lon, String display})>[];

      for (final el in elements) {
        final map   = el as Map<String, dynamic>;
        final elLat = (map['lat'] ?? (map['center'] as Map?)?['lat']) as num?;
        final elLon = (map['lon'] ?? (map['center'] as Map?)?['lon']) as num?;
        if (elLat == null || elLon == null) continue;

        final tags    = map['tags'] as Map<String, dynamic>? ?? {};
        final name    = (tags['name']             as String?)?.trim() ?? '';
        final street  = (tags['addr:street']      as String?)?.trim() ?? '';
        final number  = (tags['addr:housenumber'] as String?)?.trim() ?? '';
        final city    = ((tags['addr:city'] ?? tags['addr:town'])
                              as String?)?.trim() ?? '';

        final streetPart = [
          if (number.isNotEmpty) number,
          if (street.isNotEmpty) street,
        ].join(' ');
        final labelParts = <String>[
          if (name.isNotEmpty)       name,
          if (streetPart.isNotEmpty) streetPart,
          if (city.isNotEmpty)       city,
          postcode,
        ];
        final label = labelParts.isNotEmpty ? labelParts.join(', ') : postcode;

        results.add((lat: elLat.toDouble(), lon: elLon.toDouble(), display: label));
        if (results.length >= limit) break;
      }
      return results;
    } catch (e) {
      debugPrint('Overpass postcode search error: $e');
      return [];
    }
  }

  // ── Photon geocoder (photon.komoot.io) ─────────────────────────────────────
  /// Searches Photon for up to [limit] places matching [query].
  /// Photon is purpose-built for place-name auto-complete and returns
  /// excellent results for named venues (restaurants, shops, landmarks)
  /// that standard Nominatim search may rank poorly.
  /// Results are biased towards the user's GPS position when available.
  Future<List<({double lat, double lon, String display})>>
      _photonSearch(String query, {int limit = 5}) async {
    try {
      final params = <String, String>{
        'q'    : query,
        'limit': '$limit',
        'lang' : 'en',
      };
      // Bias results towards the user's current GPS position when available
      if (currentLatitude != null && currentLongitude != null) {
        params['lat'] = currentLatitude!.toStringAsFixed(6);
        params['lon'] = currentLongitude!.toStringAsFixed(6);
      }
      // Restrict Photon to UK when user's country is GB — prevents overseas
      // location names from appearing for ambiguous queries (e.g. "train
      // station", street names that exist in many countries).
      if (_isUk) {
        params['bbox'] = '-8.6,49.9,1.8,60.9'; // approximate UK bounding box
      }
      final uri = Uri.https('photon.komoot.io', '/api/', params);
      final response = await http.get(uri, headers: {
        'User-Agent': 'SheSafe-FYP-App/1.0 (dissertation project)',
      }).timeout(const Duration(seconds: 5));   // keep Photon fast

      if (response.statusCode != 200) return [];

      final data     = jsonDecode(response.body) as Map<String, dynamic>;
      final features = data['features'] as List<dynamic>? ?? [];
      final results  = <({double lat, double lon, String display})>[];

      for (final f in features) {
        final feature = f as Map<String, dynamic>;
        final geo    = feature['geometry'] as Map<String, dynamic>?;
        final coords = geo?['coordinates'] as List<dynamic>?;
        if (coords == null || coords.length < 2) continue;
        final fLon = (coords[0] as num).toDouble();
        final fLat = (coords[1] as num).toDouble();

        final props    = feature['properties'] as Map<String, dynamic>? ?? {};
        final name     = (props['name']        as String?)?.trim() ?? '';
        final street   = (props['street']      as String?)?.trim() ?? '';
        final houseNum = (props['housenumber'] as String?)?.trim() ?? '';
        final city     = ((props['city'] ?? props['municipality'])
                              as String?)?.trim() ?? '';
        final postcode = (props['postcode']    as String?)?.trim() ?? '';
        final country  = (props['country']     as String?)?.trim() ?? '';

        final streetPart = [
          if (houseNum.isNotEmpty) houseNum,
          if (street.isNotEmpty)   street,
        ].join(' ');
        final labelParts = <String>[
          if (name.isNotEmpty)                                name,
          if (streetPart.isNotEmpty && streetPart != name)    streetPart,
          if (city.isNotEmpty      && city != name)           city,
          if (postcode.isNotEmpty)                            postcode,
          if (country.isNotEmpty   && country != city &&
              country != name)                                country,
        ];
        final label = labelParts.isNotEmpty ? labelParts.join(', ') : name;
        if (label.isEmpty) continue;
        results.add((lat: fLat, lon: fLon, display: label));
      }
      return results;
    } catch (e) {
      debugPrint('Photon search error: $e');
      return [];
    }
  }

  /// Normalises a raw search query before sending it to geocoders.
  /// • Strips leading/trailing whitespace.
  /// • Converts compact UK postcodes to the standard spaced form,
  ///   e.g. "cv12na" → "CV1 2NA", "sw1a1aa" → "SW1A 1AA".
  String _normalizeQuery(String raw) {
    final trimmed = raw.trim();
    final compact = trimmed.toUpperCase().replaceAll(' ', '');
    final ukRe = RegExp(r'^([A-Z]{1,2}[0-9][0-9A-Z]?)([0-9][A-Z]{2})$');
    final m = ukRe.firstMatch(compact);
    if (m != null) return '${m.group(1)} ${m.group(2)}';
    return trimmed;
  }

  /// Returns true if [query] is a normalised UK postcode (e.g. "CV1 2NA").
  /// Used to bypass Photon and go straight to Nominatim with countrycodes=gb
  /// for much more accurate postcode resolution.
  bool _isUkPostcode(String query) {
    final re = RegExp(
        r'^[A-Z]{1,2}[0-9][0-9A-Z]?\s[0-9][A-Z]{2}$',
        caseSensitive: false);
    return re.hasMatch(query.trim());
  }

  /// Shows a bottom-sheet picker when Nominatim returns candidates.
  /// [query] is the original search term shown in the header.
  Future<({double lat, double lon, String display})?> _showLocationPicker(
      List<({double lat, double lon, String display})> options,
      {String query = ''}) {
    // Sort nearest-to-user first so local results always appear at the top
    // regardless of the geocoder's default relevance ordering.
    if (currentLatitude != null && currentLongitude != null) {
      final uLat = currentLatitude!;
      final uLon = currentLongitude!;
      options = [...options]..sort((a, b) {
        final dA = math.sqrt(
            math.pow(a.lat - uLat, 2) + math.pow(a.lon - uLon, 2));
        final dB = math.sqrt(
            math.pow(b.lat - uLat, 2) + math.pow(b.lon - uLon, 2));
        return dA.compareTo(dB);
      });
    }
    final title = query.isNotEmpty
        ? 'Results for "$query"'
        : 'Which location did you mean?';
    final subtitle = 'Sorted nearest to you first — tap to navigate there.';
    return showModalBottomSheet<({double lat, double lon, String display})>(
      context: context,
      isScrollControlled: true,   // lets sheet grow to its content
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => SafeArea(
        child: ConstrainedBox(
          // Cap at 70 % of screen height to avoid overflow on any device
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(ctx).size.height * 0.70,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 2),
                child: Text(
                  title,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: Colors.grey.shade800,
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text(
                  subtitle,
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
                ),
              ),
              const Divider(height: 1),
              // Flexible + ListView prevents overflow when many results arrive
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: options
                      .map(
                        (opt) => ListTile(
                          leading: Icon(Icons.location_on_outlined,
                              color: Colors.blue.shade700),
                          title: Text(opt.display,
                              style: const TextStyle(fontSize: 14)),
                          onTap: () => Navigator.of(ctx).pop(opt),
                        ),
                      )
                      .toList(),
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  /// Reverse-geocodes [lat]/[lon] via Nominatim and returns a short
  /// human-readable string like "Priory Street, Coventry CV1 5FB".
  final RegExp _ukPostcodeRe = RegExp(
    r'^[A-Z]{1,2}[0-9][0-9A-Z]?\s?[0-9][A-Z]{2}$',
    caseSensitive: false,
  );

  String _asTrimmed(dynamic value) {
    if (value == null) return '';
    return value.toString().trim();
  }

  bool _looksLikePostcode(String value) {
    final v = value.trim();
    if (v.isEmpty) return false;
    return _ukPostcodeRe.hasMatch(v);
  }

  bool _looksLikeStandaloneNumber(String value) {
    final v = value.trim();
    if (v.isEmpty) return false;
    // Examples to suppress as standalone labels: "12", "12A", "7-9"
    return RegExp(r'^[0-9]+[A-Z]?$|^[0-9]+\s*-\s*[0-9]+$').hasMatch(v);
  }

  String _firstNonEmptyTrim(List<dynamic> values) {
    for (final v in values) {
      final t = _asTrimmed(v);
      if (t.isNotEmpty) return t;
    }
    return '';
  }

  String? _formatFromDisplayName(String displayName, {String? postcodeHint}) {
    final parts = displayName
        .split(',')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();

    if (parts.isEmpty) return null;

    final inferredPostcode = _firstNonEmptyTrim([
      postcodeHint,
      ...parts.where(_looksLikePostcode),
    ]);

    final nonPost = parts
        .where((p) => !_looksLikePostcode(p))
      .where((p) => !_looksLikeStandaloneNumber(p))
        .where((p) => p.toLowerCase() != 'united kingdom')
        .toList();

    if (nonPost.isEmpty) {
      return inferredPostcode.isNotEmpty ? inferredPostcode : null;
    }

    if (nonPost.length >= 3) {
      return _formatCurrentLocationLabel(
        placeName: nonPost[0],
        road: nonPost[1],
        townOrCity: nonPost[2],
        postcode: inferredPostcode,
      );
    }

    if (nonPost.length == 2) {
      return _formatCurrentLocationLabel(
        road: nonPost[0],
        townOrCity: nonPost[1],
        postcode: inferredPostcode,
      );
    }

    return _formatCurrentLocationLabel(
      townOrCity: nonPost[0],
      postcode: inferredPostcode,
    );
  }

  String? _formatCurrentLocationLabel({
    String? placeName,
    String? houseNumber,
    String? road,
    String? townOrCity,
    String? postcode,
  }) {
    final place = (placeName ?? '').trim();
    final number = (houseNumber ?? '').trim();
    final street = (road ?? '').trim();
    final town = (townOrCity ?? '').trim();
    final post = (postcode ?? '').trim();

    final placeSafe =
      (_looksLikePostcode(place) ||
              _looksLikeStandaloneNumber(place) ||
              (post.isNotEmpty && place == post))
        ? ''
        : place;

    final streetPart = [
      if (street.isNotEmpty && number.isNotEmpty) number,
      if (street.isNotEmpty) street,
    ].join(' ');

    final parts = <String>[
      if (placeSafe.isNotEmpty) placeSafe,
      if (streetPart.isNotEmpty && streetPart != placeSafe) streetPart,
      if (town.isNotEmpty && town != placeSafe) town,
      if (post.isNotEmpty) post,
    ];

    if (parts.isNotEmpty) return parts.join(', ');
    return null;
  }

  Future<String?> _reverseGeocode(double lat, double lon) async {
    // Race Nominatim and Photon reverse — use whichever returns a real address
    // first.  This prevents the From field from falling back to raw coordinates
    // when Nominatim is slow or rate-limiting on the device's connection.
    String? nominatimResult;
    String? photonResult;

    await Future.wait([
      () async {
        try {
          final uri = Uri.https('nominatim.openstreetmap.org', '/reverse', {
            'lat'           : lat.toString(),
            'lon'           : lon.toString(),
            'format'        : 'json',
            'zoom'          : '18',
            'addressdetails': '1',
          });
          final response = await http.get(uri, headers: {
            'User-Agent'      : 'SheSafe-FYP-App/1.0 (dissertation project)',
            'Accept-Language' : 'en',
          }).timeout(const Duration(seconds: 8));

          if (response.statusCode == 200) {
            final data    = jsonDecode(response.body) as Map<String, dynamic>;
            final address = data['address'] as Map<String, dynamic>?;

            if (address != null) {
              final venueName = _firstNonEmptyTrim([
                address['attraction'] as String?,
                address['amenity'] as String?,
                address['building'] as String?,
                address['house_name'] as String?,
                address['university'] as String?,
                address['college'] as String?,
                address['school'] as String?,
                address['hospital'] as String?,
                address['shop'] as String?,
                address['office'] as String?,
                address['tourism'] as String?,
                address['leisure'] as String?,
                data['name'],
              ]);

              final road = _firstNonEmptyTrim([
                address['road'] as String?,
                address['pedestrian'] as String?,
                address['footway'] as String?,
                address['residential'] as String?,
                address['path'] as String?,
                address['cycleway'] as String?,
                address['neighbourhood'] as String?,
              ]);

              final number = _asTrimmed(address['house_number']);

              final town = _firstNonEmptyTrim([
                address['city'] as String?,
                address['town'] as String?,
                address['village'] as String?,
                address['municipality'] as String?,
                address['city_district'] as String?,
                address['suburb'] as String?,
                address['hamlet'] as String?,
                address['county'] as String?,
                address['state_district'] as String?,
              ]);

              final postcode = _asTrimmed(address['postcode']);

              final label = _formatCurrentLocationLabel(
                placeName: venueName,
                houseNumber: number,
                road: road,
                townOrCity: town,
                postcode: postcode,
              );
              if (label != null && label.isNotEmpty) {
                nominatimResult = label;
                return;
              }
            }

            final display = data['display_name'] as String?;
            if (display != null && display.isNotEmpty) {
              final fallback = _formatFromDisplayName(display);
              nominatimResult =
                  (fallback != null && fallback.isNotEmpty) ? fallback : display;
            }
          }
        } catch (e) {
          debugPrint('Nominatim reverse geocode failed: $e');
        }
      }(),
      () async {
        try {
          final uri = Uri.https('photon.komoot.io', '/reverse', {
            'lat': lat.toStringAsFixed(6),
            'lon': lon.toStringAsFixed(6),
          });
          final response = await http.get(uri, headers: {
            'User-Agent': 'SheSafe-FYP-App/1.0 (dissertation project)',
          }).timeout(const Duration(seconds: 8));

          if (response.statusCode == 200) {
            final data     = jsonDecode(response.body) as Map<String, dynamic>;
            final features = data['features'] as List<dynamic>?;
            if (features != null && features.isNotEmpty) {
              final props    = (features[0] as Map<String, dynamic>)['properties']
                                   as Map<String, dynamic>? ?? {};
              final name     = _asTrimmed(props['name']);
              final street   = _firstNonEmptyTrim([
                props['street'] as String?,
                props['district'] as String?,
              ]);
              final houseNum = _asTrimmed(props['housenumber']);
              final city     = _firstNonEmptyTrim([
                props['city'] as String?,
                props['town'] as String?,
                props['municipality'] as String?,
                props['county'] as String?,
              ]);
              final postcode = _asTrimmed(props['postcode']);

              final label = _formatCurrentLocationLabel(
                placeName: name,
                houseNumber: houseNum,
                road: street,
                townOrCity: city,
                postcode: postcode,
              );
              if (label != null && label.isNotEmpty) {
                photonResult = label;
              }
            }
          }
        } catch (e) {
          debugPrint('Photon reverse geocode failed: $e');
        }
      }(),
    ]);

    // Prefer Nominatim for accuracy; Photon as fallback
    return nominatimResult ?? photonResult;
  }

  Future<void> _geocodeAndGenerateRoutes() async {
    if (currentLatitude == null || currentLongitude == null) {
      debugPrint('❌ Cannot generate routes - current location not available');
      setState(() {
        locationError = 'Current location not available. Please check location permissions.';
        isGeneratingRoutes = false;
      });
      return;
    }

    setState(() {
      // Don't enable the full-screen spinner yet — the location picker
      // must appear first so the user can choose before any loading starts.
      locationError = '';
    });

    try {
      // Best-effort live refresh so Safe Route uses up-to-date risk zones.
      if (_isUk && currentLatitude != null && currentLongitude != null) {
        try {
          await _riskEngine.initializeWithLiveData(
            currentLatitude!,
            currentLongitude!,
          );
        } catch (_) {
          // Keep graceful fallback to cached/bundled data.
        }
      }

      double destLat;
      double destLon;
      
      // Check for special keywords
      if (_effectiveDestination.toLowerCase() == 'nearby' || 
          _effectiveDestination.toLowerCase() == 'test' ||
          _effectiveDestination.toLowerCase() == 'demo') {
        // Use a demo location near the user
        destLat = currentLatitude! + 0.01; // ~1km north
        destLon = currentLongitude! + 0.01; // ~1km east
        debugPrint('✅ Using demo location near you: $destLat, $destLon');
      } else if (_tryParseCoordinates(_effectiveDestination)) {
        // User entered coordinates directly
        destLat = _parsedLat!;
        destLon = _parsedLon!;
        debugPrint('✅ Using parsed coordinates: $destLat, $destLon');
      } else {
        // Geocode via Nominatim — multi-result with UK bias
        setState(() => _geocodeStatus = 'Searching for "$_effectiveDestination"…');
        final candidates = await _nominatimSearchMany(_effectiveDestination, limit: 25);

        if (candidates.isEmpty) {
          // Nothing found — tell the user clearly instead of silently routing
          // to a dummy point which looks like it worked but shows the wrong place.
          setState(() {
            isGeneratingRoutes = false;
            _geocodeStatus = '';
            locationError = 'Could not find "$_effectiveDestination". '
                'Try a full address, postcode (e.g. CV1 2NA) or landmark name.';
          });
          return;
        } else {
          // ALWAYS show the picker so the user confirms the exact location —
          // even if there is only one result (like Google Maps does).
          // Guarantee the spinner is OFF while the picker is open.
          final wasGenerating = isGeneratingRoutes;
          if (wasGenerating) setState(() => isGeneratingRoutes = false);
          if (!mounted) return;
          final pick = await _showLocationPicker(
              candidates, query: _effectiveDestination);
          if (!mounted) return;
          if (pick == null) {
            // User dismissed — cancel cleanly
            setState(() {
              isGeneratingRoutes = false;
              _geocodeStatus = '';
            });
            return;
          }
          // NOW start the full-screen spinner — user has already chosen.
          setState(() => isGeneratingRoutes = true);
          destLat = pick.lat;
          destLon = pick.lon;
          setState(() => _geocodeStatus = '');
          debugPrint('✅ Nominatim (picked): $destLat, $destLon');
        }
      }
      
      setState(() {
        destinationLatitude = destLat;
        destinationLongitude = destLon;
      });

      // ── Parallel pipeline: local route generation + backend explanation ──
      debugPrint('🚀 Generating routes from ($currentLatitude, $currentLongitude) to ($destLat, $destLon)');
      final pipelineStart = DateTime.now();

      final results = await Future.wait([
        _routeGenerator.generateRoutes(
          startLat: currentLatitude!,
          startLon: currentLongitude!,
          destLat: destLat,
          destLon: destLon,
        ),
        IntegrationPipelineService.instance.fetchRouteExplanation(
          originLat:        currentLatitude!,
          originLon:        currentLongitude!,
          destinationLat:   destLat,
          destinationLon:   destLon,
          destinationAddress: _effectiveDestination,
        ),
      ]);

      final generatedRoutes = results[0] as List<RouteOption>;
      final backendExpl = results[1] as BackendRouteExplanation?;
      final latencyMs   = DateTime.now().difference(pipelineStart).inMilliseconds;
      final routes = _normalizeRouteIdentity(generatedRoutes);

      if (mounted) {
        setState(() {
          _backendExplanation = backendExpl;
          _routeGenLatencyMs  = latencyMs;
        });
      }

      debugPrint('✅ Generated ${routes.length} routes  '
          '| backend: ${backendExpl != null ? "✓" : "offline"}  '
          '| total: $latencyMs ms');

      if (routes.isEmpty) {
        throw Exception('No routes could be generated');
      }

      final scores = _confidenceService.scoreAllRoutes(routes);

      setState(() {
        routeOptions = routes;
        selectedRoute = routes[0];
        _confidenceScores = scores;
        isGeneratingRoutes = false;
        _osrmFetching = true; // show loading overlay until OSRM responds
      });

      // Fetch OSRM road-snapped polylines — the route line draws exactly once.
      _fetchAllOSRMRoutes(routes).catchError((e) {
        if (mounted) setState(() => _osrmFetching = false);
      });

      // Log successful route generation
      _eventLogService.logEvent(
        type: EventType.safeRouteGenerated,
        outcome: EventOutcome.success,
        description: 'Generated ${routes.length} safe route options',
        metadata: {
          'routeCount': routes.length,
          'route1RiskScore': routes[0].overallRiskScore.toStringAsFixed(2),
        },
      );
    } catch (e, stackTrace) {
      debugPrint('❌ Error generating routes: $e');
      debugPrint('Stack trace: $stackTrace');
      setState(() {
        locationError = 'Could not generate routes.\n\nTry: "Priory Street, Coventry CV1 5FB"';
        isGeneratingRoutes = false;
      });
    }
  }

  double? _parsedLat;
  double? _parsedLon;
  // Allows _searchNewRoute() to override the destination without rebuilding the widget.
  String? _destinationOverride;
  
  // Use override if set (from the search bar), otherwise fall back to constructor arg.
  String get _effectiveDestination => _destinationOverride ?? widget.destination;

  bool _tryParseCoordinates(String input) {
    try {
      // Check if input is in format "lat, lon" or "lat,lon"
      final parts = input.split(',');
      if (parts.length == 2) {
        _parsedLat = double.parse(parts[0].trim());
        _parsedLon = double.parse(parts[1].trim());
        return true;
      }
    } catch (e) {
      // Not coordinate format
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    // Show navigation overlay if in navigation mode
    if (isNavigating && selectedRoute != null) {
      return PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) async {
          if (didPop) return;
          final shouldLeave = await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: const Text('Stop Navigation?'),
              content: const Text(
                'Are you sure you want to go back? Your current navigation progress will be lost.',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(false),
                  child: const Text('Stay'),
                ),
                ElevatedButton(
                  onPressed: () => Navigator.of(ctx).pop(true),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.red,
                    foregroundColor: Colors.white,
                  ),
                  child: const Text('Go Back'),
                ),
              ],
            ),
          );
          if (shouldLeave == true && context.mounted) {
            _stopWalkMonitoring();
            setState(() {
              isNavigating = false;
              currentNavigationStep = 0;
            });
          }
        },
        child: Scaffold(
          body: _buildNavigationModeOverlay(),
        ),
      );
    }
    
    return Scaffold(
      backgroundColor: _kSoftBg,
      appBar: AppBar(
        backgroundColor: Colors.white,
        foregroundColor: const Color(0xFF1A1A1A),
        surfaceTintColor: Colors.transparent,
        title: const Text('Safe Route'),
        actions: [
          IconButton(
            icon: const Icon(Icons.share),
            onPressed: selectedRoute != null
                ? () {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Route shared!')),
                    );
                  }
                : null,
          ),

        ],
      ),
      body: Column(
        children: [
          _buildFromToBar(),
          Expanded(
            child: isLoadingLocation || isGeneratingRoutes
                ? _buildLoadingView()
                : locationError.isNotEmpty && routeOptions.isEmpty
                    ? _buildErrorView()
                    : _buildRouteView(),
          ),
        ],
      ),
    );
  }

  Widget _buildLoadingView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.shield_outlined,
              size: 64,
              color: _kAccent,
            ),
            const SizedBox(height: 28),
            Text(
              isLoadingLocation
                  ? 'Finding your location…'
                  : 'Calculating route options for you…',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: Colors.grey.shade800,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 28),
            SizedBox(
              width: 48,
              child: LinearProgressIndicator(
                minHeight: 3,
                borderRadius: BorderRadius.circular(2),
                color: _kAccent,
                backgroundColor: _kSoftBorder,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildErrorView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, size: 64, color: Colors.red),
            const SizedBox(height: 16),
            const Text(
              'Unable to Generate Route',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              locationError,
              style: const TextStyle(fontSize: 16),
            ),
            const SizedBox(height: 24),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                ElevatedButton.icon(
                  onPressed: () {
                    setState(() {
                      locationError = '';
                      // If GPS is already known just re-run geocoding;
                      // otherwise do the full location fetch.
                      if (currentLatitude != null && currentLongitude != null) {
                        isGeneratingRoutes = true;
                      } else {
                        isLoadingLocation = true;
                      }
                    });
                    if (currentLatitude != null && currentLongitude != null) {
                      _geocodeAndGenerateRoutes();
                    } else {
                      _getCurrentLocation();
                    }
                  },
                  icon: const Icon(Icons.refresh),
                  label: const Text('Retry'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _kAccent,
                    foregroundColor: Colors.white,
                  ),
                ),
                const SizedBox(width: 12),
                OutlinedButton.icon(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.arrow_back),
                  label: const Text('Go Back'),
                ),
              ],
            ),
            const SizedBox(height: 24),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: _kSoftCard,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: _kSoftBorder),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.lightbulb, color: _kAccent, size: 20),
                      const SizedBox(width: 8),
                      Text(
                        'Quick Tips:',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: const Color(0xFF7A4F60),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  _buildTip('Try: "Priory Street, Coventry CV1 5FB"'),
                  _buildTip('Try: "London Bridge, London SE1 9BG"'),
                  _buildTip('Enable location permissions for best results'),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTip(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.check_circle, size: 16, color: Colors.green.shade700),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(fontSize: 14),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRouteView() {
    if (selectedRoute == null) {
      // Still generating — keep showing a spinner rather than an empty message.
      return const Center(child: CircularProgressIndicator());
    }
    // Column layout: scrollable content on top, Start Navigation pinned at bottom.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildMapView(),
                if (routeOptions.length > 1) _buildRouteSelector(),
                _buildRouteStats(),
                if (_isUk) _buildRouteConfidenceCard(),
                if (!_isUk) _buildNonUkNotice(),
                if (_isUk) _buildBackendExplanationCard(),
                _buildArrivalToggleCard(),
                const SizedBox(height: 8),
              ],
            ),
          ),
        ),
        // Start Navigation button always visible at the bottom
        _buildNavigationButton(),
      ],
    );
  }

  Widget _buildSafetyBadge() {
    final route     = selectedRoute!;
    final composite = _combinedSafety(route);
    final color     = _routeColor(route);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.shield, color: Colors.white, size: 18),
          const SizedBox(width: 6),
          Text(
            '${composite.toStringAsFixed(0)}% Safe',
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.bold,
              fontSize: 14,
            ),
          ),
        ],
      ),
    );
  }

  String _routeSemanticId(RouteOption route) {
    final id = route.routeId.toLowerCase().trim();
    if (id == 'safest' || id.contains('safe')) return 'safest';
    if (id == 'balanced' || id.contains('balanc')) return 'balanced';
    if (id == 'direct' || id.contains('direct')) return 'direct';
    return id;
  }

  String _routeLabel(RouteOption route) {
    final id = _routeSemanticId(route);
    if (id == 'safest') return 'Safest Route';
    if (id == 'balanced') return 'Balanced Route';
    if (id == 'direct') return 'Direct Route';
    return 'Route';
  }

  IconData _routeIcon(RouteOption route) {
    // Route type icon should always communicate "safety route purpose".
    return Icons.shield_outlined;
  }

  Widget _buildRouteSelector() {
    return Container(
      height: 56,
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: routeOptions.length,
        itemBuilder: (context, index) {
          final route = routeOptions[index];
          final isSelected = index == selectedRouteIndex;
          final safety = _combinedSafety(route);
          final icon = _routeIcon(route);
          final routeColor = _routeColor(route);

          return Padding(
            padding: const EdgeInsets.only(right: 8),
            child: ChoiceChip(
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              avatar: Icon(
                icon,
                size: 16,
                color: isSelected ? Colors.white : routeColor,
              ),
              label: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '${_routeLabel(route)}  ·  ${safety.toStringAsFixed(0)}% safe',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight:
                          isSelected ? FontWeight.bold : FontWeight.normal,
                    ),
                  ),
                  if (route.isRecommended) ...[
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: isSelected
                            ? Colors.white.withValues(alpha: 0.22)
                            : Colors.green.shade50,
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(
                          color: isSelected
                              ? Colors.white70
                              : Colors.green.shade300,
                        ),
                      ),
                      child: Text(
                        'Recommended',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          color:
                              isSelected ? Colors.white : Colors.green.shade800,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
              selected: isSelected,
              onSelected: (selected) {
                if (selected) {
                  setState(() {
                    selectedRouteIndex = index;
                    selectedRoute = route;
                  });
                  // Reposition map to the new route's centre
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (!mounted) return;
                    if (currentLatitude != null && destinationLatitude != null) {
                      final midLat = (currentLatitude! + destinationLatitude!) / 2;
                      final midLng = (currentLongitude! + destinationLongitude!) / 2;
                      final d = Geolocator.distanceBetween(
                        currentLatitude!, currentLongitude!,
                        destinationLatitude!, destinationLongitude!,
                      );
                      final z = d > 10000 ? 11.0
                          : d > 5000  ? 12.0
                          : d > 2000  ? 13.0
                          : d > 800   ? 14.0
                          : 15.5;
                      _mapController.move(LatLng(midLat, midLng), z);
                    }
                  });
                }
              },
              selectedColor: routeColor.withValues(alpha: 0.92),
              labelStyle: TextStyle(
                color: isSelected ? Colors.white : Colors.black87,
              ),
            ),
          );
        },
      ),
    );
  }

  // ── Risk-zone overlay helpers ─────────────────────────────────────────────

  /// Builds [CircleMarker]s for the map risk overlay from two sources:
  ///
  /// **Source 1 – real CSV zones** (only when user is near the Norwich dataset):
  /// Each route segment carries a `nearbyRiskZones` list populated by the risk
  /// engine.  When non-empty, circles are placed at the zone’s actual lat/lon.
  ///
  /// **Source 2 – synthetic route-risk markers** (always present, any location):
  /// The risk engine assigns each route an `overallRiskScore` (0–100). Circles
  /// are synthesised along the MIDDLE portion of each route’s polyline where
  /// the three arcs diverge, coloured by risk tier.  This gives the user
  /// visual proof of which areas the safest route steers around, regardless
  /// of whether the CSV study-area data is geographically relevant.
  /// Builds [CircleMarker]s for the map risk overlay.
  ///
  /// Circles are placed at FIXED positions along the straight (direct)
  /// start→destination path.  The safest route arcs ~660 m perpendicular to
  /// that line, so it visibly curves AROUND these circles.  The direct route
  /// cuts straight through them.  This tells the correct story:
  ///   "The safe route avoids these risk areas."
  ///
  /// When the user is near the Norwich CSV dataset, real zone positions are
  /// also added from the route segments’ `nearbyRiskZones`.
  // ── Risk-zone circles: ONLY real CSV zones that lie ON the selected route ──
  //
  // No synthetic circles.  Each circle comes directly from a RiskZone record
  // in the dataset and is only drawn when the selected route's actual road
  // polyline (OSRM or model waypoints) passes within the zone's radius.
  List<CircleMarker> _buildRouteRiskCircles() {
    if (routeOptions.isEmpty) return [];
    if (selectedRouteIndex >= routeOptions.length) return [];

    // ── Authoritative polyline for the selected route ────────────────────
    final osrmPoly = _routePolylines[selectedRouteIndex];
    final List<LatLng> routePts = (osrmPoly != null && osrmPoly.isNotEmpty)
        ? osrmPoly
        : routeOptions[selectedRouteIndex].waypoints
            .map((w) => LatLng(w.latitude, w.longitude))
            .toList();

    if (routePts.isEmpty) return [];

    final circles = <CircleMarker>[];
    final seenZoneNames = <String>{};

    // Only look at the SELECTED route's segments (not all routes)
    for (final seg in routeOptions[selectedRouteIndex].segments) {
      for (final zone in seg.nearbyRiskZones) {
        if (!seenZoneNames.add(zone.zoneName)) continue;

        // Check if any polyline point is within the zone's radius
        // (with a small 80 m tolerance for sparse OSRM point spacing).
        final bool onRoute = routePts.any((pt) {
          final dist = Geolocator.distanceBetween(
              zone.latitude, zone.longitude, pt.latitude, pt.longitude);
          return dist <= zone.radiusMeters + 80.0;
        });
        if (!onRoute) continue;

        final Color fill;
        final Color border;
        switch (zone.riskLevel) {
          case RiskLevel.high:
            fill   = Colors.red.withValues(alpha: 0.22);
            border = Colors.red.withValues(alpha: 0.65);
            break;
          case RiskLevel.medium:
            fill   = Colors.orange.withValues(alpha: 0.18);
            border = Colors.orange.withValues(alpha: 0.60);
            break;
          case RiskLevel.low:
            fill   = const Color(0xFFFFD700).withValues(alpha: 0.15);
            border = const Color(0xFFFFD700).withValues(alpha: 0.55);
            break;
        }
        circles.add(CircleMarker(
          point: LatLng(zone.latitude, zone.longitude),
          radius: zone.radiusMeters,
          useRadiusInMeter: true,
          color: fill,
          borderColor: border,
          borderStrokeWidth: 1.5,
        ));
      }
    }

    return circles;
  }

  /// Warning icon marker placed at the centre of the first/highest-risk circle
  /// ON the selected route.  Returns null when no dataset circles are visible.
  Marker? _buildRiskCircleMarker(List<CircleMarker> circles) {
    if (circles.isEmpty) return null;

    // Place icon at the first circle's centre (highest-risk zone already
    // sorted by the risk engine).
    final point = circles.first.point;

    final double riskScore = selectedRouteIndex < routeOptions.length
        ? routeOptions[selectedRouteIndex].overallRiskScore
        : 0.0;

    final Color iconColor = riskScore > 55
        ? Colors.red.shade700
        : riskScore > 15
            ? Colors.orange.shade800
            : const Color(0xFFCCA800);

    return Marker(
      point: point,
      width: 32,
      height: 32,
      child: GestureDetector(
        onTap: () => _showCautionDetails(riskScore),
        child: Container(
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.90),
            shape: BoxShape.circle,
            boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 4)],
          ),
          child: Icon(Icons.warning_amber_rounded, size: 20, color: iconColor),
        ),
      ),
    );
  }

  /// Bottom sheet that appears when the user taps the ⚠ caution marker.
  void _showCautionDetails(double riskScore) {
    final Color accentColor;
    final String riskLabel;
    final String whyTitle;
    final String whyBody;
    final List<String> tips;

    if (riskScore > 55) {
      accentColor = Colors.red.shade700;
      riskLabel   = 'High Risk';
      whyTitle    = 'Why is this area flagged?';
      whyBody     = 'Our safety engine detected a high concentration of crime '
          'reports and environmental risk factors (poor lighting, low footfall) '
          'in this zone. The data comes from police records and local risk analysis.';
      tips = [
        'The safest route already avoids this area',
        'Stay on well-lit main roads if you need to pass nearby',
        'Share your live location with a trusted contact',
        'Consider travelling with someone if possible',
      ];
    } else if (riskScore > 15) {
      accentColor = Colors.orange.shade800;
      riskLabel   = 'Moderate Risk';
      whyTitle    = 'Why is this area flagged?';
      whyBody     = 'This zone has a moderate level of reported incidents or '
          'limited natural surveillance (e.g. fewer streetlights, quieter streets). '
          'It doesn\'t mean it\'s dangerous right now — just worth being aware of.';
      tips = [
        'Your route steers around the centre of this zone',
        'Stay aware of your surroundings',
        'Keep your phone accessible but not on display',
        'Stick to busier roads where possible',
      ];
    } else {
      accentColor = const Color(0xFFB8860B);
      riskLabel   = 'Low Risk';
      whyTitle    = 'Why is this shown?';
      whyBody     = 'This is a minor caution area with very few reports. '
          'We show it for transparency — the safest option already avoids this area.';
      tips = [
        'No action needed — your selected route is already low risk',
        'Standard awareness is sufficient',
      ];
    }

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Handle bar
            Center(
              child: Container(
                width: 40, height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey.shade300,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 16),

            // Header row
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: accentColor.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(Icons.warning_amber_rounded,
                      size: 24, color: accentColor),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Caution Zone',
                          style: TextStyle(
                              fontSize: 18, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 2),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: accentColor.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(riskLabel,
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              color: accentColor,
                            )),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),

            // Why section
            Text(whyTitle,
                style: const TextStyle(
                    fontSize: 15, fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            Text(whyBody,
                style: TextStyle(
                  fontSize: 13,
                  color: Colors.grey.shade700,
                  height: 1.45,
                )),
            const SizedBox(height: 18),

            // Tips section
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Colors.blue.shade50,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.blue.shade100),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.lightbulb_outline,
                          size: 18, color: Colors.blue.shade600),
                      const SizedBox(width: 6),
                      Text('Safety Tips',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                            color: Colors.blue.shade700,
                          )),
                    ],
                  ),
                  const SizedBox(height: 8),
                  ...tips.map((tip) => Padding(
                        padding: const EdgeInsets.only(bottom: 5),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('•  ',
                                style: TextStyle(
                                    color: Colors.blue.shade700,
                                    fontSize: 13)),
                            Expanded(
                              child: Text(tip,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Colors.blue.shade900,
                                    height: 1.35,
                                  )),
                            ),
                          ],
                        ),
                      )),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // Close button
            SizedBox(
              width: double.infinity,
              child: TextButton(
                onPressed: () => Navigator.pop(ctx),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                    side: BorderSide(color: Colors.grey.shade300),
                  ),
                ),
                child: const Text('Got it',
                    style: TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w600)),
              ),
            ),
          ],
        ),
      ),
    );
  }



  // ── Real OSM map via flutter_map ──────────────────────────────────────────
  Widget _buildMapView() {
    if (currentLatitude == null || currentLongitude == null) {
      return Container(
        height: 240,
        color: Colors.grey.shade200,
        child: const Center(child: Icon(Icons.map, size: 64, color: Colors.grey)),
      );
    }

    final startPt = LatLng(currentLatitude!, currentLongitude!);
    final destPt  = destinationLatitude != null
        ? LatLng(destinationLatitude!, destinationLongitude!)
        : startPt;

    // Prefer OSRM road-snapped polyline; fall back to synthetic model waypoints
    // when OSRM could not supply a distinct alternative (avoids duplicate paths).
    final osrmPoly  = _routePolylines[selectedRouteIndex];
    final List<LatLng> polyPts = (osrmPoly != null && osrmPoly.isNotEmpty)
        ? osrmPoly
        : (selectedRouteIndex < routeOptions.length)
            ? routeOptions[selectedRouteIndex].waypoints
                .map((w) => LatLng(w.latitude, w.longitude))
                .toList()
            : <LatLng>[];

    // Colour by route class: Safest (green), Balanced (amber), Direct (grey)
    final routeColor = _routeColor(selectedRoute!);

    final dist = Geolocator.distanceBetween(
        startPt.latitude, startPt.longitude,
        destPt.latitude,  destPt.longitude);
    final zoom = dist > 10000 ? 11.0
        : dist > 5000  ? 12.0
        : dist > 2000  ? 13.0
        : dist > 800   ? 14.0
        : 15.5;

    // Risk circles: ONLY real CSV zones that intersect the selected route.
    final riskCircles = _buildRouteRiskCircles();
    final riskMarker  = _buildRiskCircleMarker(riskCircles);
    final riskMarkers =
      riskMarker == null ? const <Marker>[] : <Marker>[riskMarker];

    return Stack(
      children: [
        SizedBox(
          height: 340,
          child: FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: LatLng(
                (startPt.latitude  + destPt.latitude)  / 2,
                (startPt.longitude + destPt.longitude) / 2,
              ),
              initialZoom: zoom,
              interactionOptions: const InteractionOptions(
                flags: InteractiveFlag.pinchZoom |
                    InteractiveFlag.doubleTapZoom |
                    InteractiveFlag.drag,
              ),
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.shesafe.app',
                maxZoom: 19,
              ),
              // ── Risk-zone circles (drawn beneath the route line) ───────
              if (riskCircles.isNotEmpty)
                CircleLayer(circles: riskCircles),
              // ── Route polyline (drawn on top of risk circles) ──────────
              if (polyPts.length > 1)
                PolylineLayer(
                  polylines: [
                    Polyline(
                      points: polyPts,
                      color: routeColor,
                      strokeWidth: 5.0,
                      borderColor: Colors.white,
                      borderStrokeWidth: 2.0,
                    ),
                  ],
                ),
              MarkerLayer(
                markers: [
                  // Warning icon at the risk zone centre (only if real zones exist)
                  ...riskMarkers,
                  Marker(
                    point: startPt,
                    width: 80,
                    height: 60,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: Colors.green.shade700,
                            borderRadius: BorderRadius.circular(8),
                            boxShadow: const [
                              BoxShadow(color: Colors.black26, blurRadius: 3),
                            ],
                          ),
                          child: const Text(
                            'You are here',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 9,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        const SizedBox(height: 2),
                        Container(
                          width: 28,
                          height: 28,
                          decoration: BoxDecoration(
                            color: Colors.green.shade600,
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.white, width: 2),
                          ),
                          child: const Icon(Icons.person_pin_circle,
                              color: Colors.white, size: 16),
                        ),
                      ],
                    ),
                  ),
                  if (destinationLatitude != null)
                    Marker(
                      point: destPt,
                      width: 36,
                      height: 48,
                      alignment: Alignment.topCenter,
                      child: Icon(Icons.location_on,
                          color: Colors.red.shade700, size: 44),
                    ),
                ],
              ),
            ],
          ),
        ),
        // Re-center button (Google Maps-style "my location")
        Positioned(
          right: 12,
          bottom: 12,
          child: Material(
            elevation: 4,
            shape: const CircleBorder(),
            color: Colors.white,
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: () {
                if (currentLatitude != null && currentLongitude != null) {
                  _mapController.move(
                    LatLng(currentLatitude!, currentLongitude!),
                    15.5,
                  );
                }
              },
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Icon(Icons.my_location,
                    color: Colors.blue.shade700, size: 22),
              ),
            ),
          ),
        ),
        // Loading overlay: shown while OSRM fetches road-snapped polylines.
        // The map tiles are visible but no route line is drawn yet.
        if (_osrmFetching)
          Positioned.fill(
            child: Container(
              color: const Color(0x66000000),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const CircularProgressIndicator(
                        color: Colors.white, strokeWidth: 3),
                    const SizedBox(height: 12),
                    Text(
                      'Calculating route options…',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                        shadows: [
                          Shadow(
                            color: Colors.black.withValues(alpha: 0.6),
                            blurRadius: 4,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }



  // ── OSRM real-directions fetch ────────────────────────────────────────────
  //
  // Strategy:
  //   Slot 2 (Direct / red)   → always the real OSRM direct path.
  //   Slot 0 (Safest / green) → strongest detour alternative.
  //   Slot 1 (Balanced / amber) → middle-ground alternative.
  //
  // This guarantees no duplicate polylines and correct colour semantics even
  // when OSRM only returns one route (which is always the direct route).
  Future<void> _fetchAllOSRMRoutes(List<RouteOption> routes) async {
    if (routes.isEmpty) return;
    final startWp = routes[0].waypoints.first;
    final endWp   = routes[0].waypoints.last;

    final sLat = startWp.latitude;
    final sLon = startWp.longitude;
    final dLat = endWp.latitude;
    final dLon = endWp.longitude;

    // Perpendicular vector for via-point fallback computation
    final deltaLat = dLat - sLat;
    final deltaLon = dLon - sLon;
    final vecLen   = math.sqrt(deltaLat * deltaLat + deltaLon * deltaLon);
    final perpLat  = vecLen > 0 ? -deltaLon / vecLen : 0.0;
    final perpLon  = vecLen > 0 ?  deltaLat / vecLen : 0.0;

    // ── Step 1: direct OSRM route (Direct slot) ───────────────────────────
    Map<String, dynamic>? directOsrmRoute;
    try {
      final uri = Uri.https(
        'router.project-osrm.org',
        '/route/v1/foot/$sLon,$sLat;$dLon,$dLat',
        {'steps': 'true', 'geometries': 'geojson', 'overview': 'full',
         'annotations': 'false'},
      );
      final resp = await http.get(uri, headers: {
        'User-Agent': 'SheSafe-FYP-App/1.0 (dissertation project)',
      }).timeout(const Duration(seconds: 15));
      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body) as Map<String, dynamic>;
        final list = data['routes'] as List<dynamic>?;
        if (list != null && list.isNotEmpty) {
          directOsrmRoute = list.first as Map<String, dynamic>;
        }
      }
    } catch (e) {
      debugPrint('⚠️ OSRM direct fetch failed: $e');
    }
    final directDist = (directOsrmRoute?['distance'] as num?)?.toDouble() ?? 0;

    // ── Step 2: alternatives for Routes 0 & 1 ────────────────────────────
    // Keep only routes LONGER than direct (genuine detours, not duplicates).
    List<Map<String, dynamic>> longerAlts = [];
    try {
      final uri = Uri.https(
        'router.project-osrm.org',
        '/route/v1/foot/$sLon,$sLat;$dLon,$dLat',
        {'alternatives': '3', 'steps': 'true', 'geometries': 'geojson',
         'overview': 'full', 'annotations': 'false'},
      );
      final resp = await http.get(uri, headers: {
        'User-Agent': 'SheSafe-FYP-App/1.0 (dissertation project)',
      }).timeout(const Duration(seconds: 15));
      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body) as Map<String, dynamic>;
        final all = (data['routes'] as List<dynamic>? ?? [])
            .cast<Map<String, dynamic>>();
        // Filter to alternatives that differ from the direct route (≥ 2 % longer).
        // A lower threshold captures genuine walking detours that might only
        // use a different side-street but are still meaningfully distinct.
        // Sort alternatives by distance so we can assign balanced/safest slots.
        longerAlts = all
            .where((r) {
              final d = (r['distance'] as num?)?.toDouble() ?? 0;
              return d > directDist * 1.02;
            })
            .toList()
          ..sort((a, b) {
            final da = (a['distance'] as num?)?.toDouble() ?? 0;
            final db = (b['distance'] as num?)?.toDouble() ?? 0;
            return da.compareTo(db);
          });
        debugPrint('✅ OSRM: ${all.length} route(s) returned, '
            '${longerAlts.length} longer alternatives');
      }
    } catch (e) {
      debugPrint('⚠️ OSRM alternatives request failed: $e');
    }

    // Step 3: resolve the polyline source for each route slot.
    // Slot 0 is forced onto the LEFT side (+perpendicular) and Slot 1 onto
    // the RIGHT side (−perpendicular), guaranteeing visibly distinct paths.
    // Slot 2 always uses the unmodified direct path.

    Future<Map<String, dynamic>?> resolveRoute(int appIdx) async {
      if (appIdx == 2) return directOsrmRoute;

      // Assign each side-route to a fixed lateral direction so they can never
      // collapse onto the same streets.
      final side = (appIdx == 0) ? 1.0 : -1.0;

      if (vecLen > 0) {
        // Try escalating offsets on the assigned side.  Starting at ~0.006°
        // (~600 m) is usually enough to cross to a different street block;
        // if OSRM snaps back we try larger values.
        for (final offset in [0.006, 0.009, 0.012, 0.005]) {
          final r = await _fetchOsrmViaPoint(
            sLat, sLon, dLat, dLon,
            sLat + deltaLat * 0.45 + perpLat * offset * side,
            sLon + deltaLon * 0.45 + perpLon * offset * side,
          );
          if (r != null &&
              ((r['distance'] as num?)?.toDouble() ?? 0) > directDist * 1.005) {
            return r;
          }
        }
      }

      // Via-point did not yield a distinct route — fall back to OSRM alternatives.
      if (longerAlts.isNotEmpty) {
        if (appIdx == 0) {
          // Route 0 takes the longest (most detoured) alternative.
          final sorted = List<Map<String, dynamic>>.from(longerAlts)
            ..sort((a, b) {
              final da = (a['distance'] as num?)?.toDouble() ?? 0;
              final db = (b['distance'] as num?)?.toDouble() ?? 0;
              return db.compareTo(da);
            });
          return sorted.first;
        }
        // Balanced slot: prefer a different alternative than safest slot.
        if (longerAlts.length > 1) return longerAlts[0];
        // Only one alternative exists — try bigger offsets on the opposite side
        // before reusing the same alt as Route 0.
        if (vecLen > 0) {
          for (final offset in [0.015, 0.020]) {
            final r = await _fetchOsrmViaPoint(
              sLat, sLon, dLat, dLon,
              sLat + deltaLat * 0.45 + perpLat * offset * side,
              sLon + deltaLon * 0.45 + perpLon * offset * side,
            );
            if (r != null) return r;
          }
        }
        return longerAlts[0]; // last resort
      }

      return null;
    }

    final resolvedBundles = await Future.wait(List.generate(routes.length, (appIdx) async {
      final originalRoute = routes[appIdx];
      final osrmRoute = await resolveRoute(appIdx);

      final osrmDist = (osrmRoute?['distance'] as num?)?.toDouble() ?? 0;
      final walkingMinutes = osrmDist > 0 ? (osrmDist / 1000 * 12).ceil() : 0;
      final osrmDur = walkingMinutes * 60;

      final geometry = osrmRoute?['geometry'] as Map<String, dynamic>?;
      final coords   = geometry?['coordinates'] as List<dynamic>?;
      List<LatLng> poly = [];
      if (coords != null && coords.isNotEmpty) {
        poly = coords.map((c) {
          final arr = c as List<dynamic>;
          return LatLng(
            (arr[1] as num).toDouble(),
            (arr[0] as num).toDouble(),
          );
        }).toList();
        poly = _sanitizePolyline(poly);
      }

      final legs = osrmRoute?['legs'] as List<dynamic>?;
      final raw  = <_OsrmStep>[];
      if (legs != null) {
        for (final leg in legs) {
          final steps =
              (leg as Map<String, dynamic>)['steps'] as List<dynamic>?;
          if (steps == null) continue;
          for (final s in steps) {
            final step     = s as Map<String, dynamic>;
            final maneuver = step['maneuver'] as Map<String, dynamic>? ?? {};
            final type     = maneuver['type'] as String? ?? 'continue';
            final dist     = (step['distance'] as num?)?.toDouble() ?? 0;
            if (type != 'depart' && type != 'arrive' && dist < 20) continue;
            raw.add(_OsrmStep(
              instruction   : _osrmInstruction(step),
              distanceMeters: dist,
              icon          : _osrmIcon(step),
              stepType      : type,
              streetName    : (step['name'] as String?)?.trim() ?? '',
            ));
          }
        }
      }

      final parsed = <_OsrmStep>[];
      for (final step in raw) {
        final isContinueType =
            step.stepType == 'continue' || step.stepType == 'new name';
        if (isContinueType &&
            parsed.isNotEmpty &&
            (parsed.last.stepType == 'continue' ||
                parsed.last.stepType == 'new name') &&
            parsed.last.streetName == step.streetName) {
          final prev = parsed.removeLast();
          parsed.add(_OsrmStep(
            instruction   : prev.instruction,
            distanceMeters: prev.distanceMeters + step.distanceMeters,
            icon          : prev.icon,
            stepType      : prev.stepType,
            streetName    : prev.streetName,
          ));
        } else {
          parsed.add(step);
        }
      }

      final displayedPolyline = poly.isNotEmpty
          ? poly
          : originalRoute.waypoints
              .map((w) => LatLng(w.latitude, w.longitude))
              .toList();
      final sanitizedDisplayedPolyline = _sanitizePolyline(displayedPolyline);
      final displayedDistance = osrmDist > 0
          ? osrmDist
          : originalRoute.totalDistanceMeters;
      final displayedDurationSeconds = osrmDur > 0
          ? osrmDur
          : originalRoute.estimatedDurationMinutes * 60;

      RouteOption scoredRoute = originalRoute;
      if (sanitizedDisplayedPolyline.length >= 2) {
        scoredRoute = await _routeGenerator.buildRouteFromWaypoints(
          routeId: originalRoute.routeId,
          isRecommended: originalRoute.isRecommended,
          waypoints: _routeWaypointsFromPolyline(sanitizedDisplayedPolyline),
          totalDistanceMeters: displayedDistance,
          estimatedDurationMinutes: (displayedDurationSeconds / 60).ceil(),
        );
      }

      debugPrint('✅ OSRM route $appIdx ready: '
          '${parsed.length} steps, ${sanitizedDisplayedPolyline.length} pts, '
          '${displayedDistance.round()} m, '
          '${(displayedDurationSeconds / 60).ceil()} min');

      return _ResolvedRouteBundle(
        route: scoredRoute,
        polyline: sanitizedDisplayedPolyline,
        steps: parsed,
        distanceMeters: displayedDistance,
        durationSeconds: displayedDurationSeconds,
      );
    }));

    // ── Deduplication guard ───────────────────────────────────────────────
    // If safest and balanced slots still share most geometry (e.g. street
    // network forces them onto the same roads), replace the balanced slot with
    // most extreme opposite-side via-point we can find.
    if (resolvedBundles.length >= 2 &&
        _polylinesSimilar(
            resolvedBundles[0].polyline, resolvedBundles[1].polyline)) {
        debugPrint(
          '⚠️ Safest/Balanced near-duplicate — retrying balanced slot with extreme right-side via-point');
      if (vecLen > 0) {
        for (final offset in [0.015, 0.020, 0.025]) {
          final r = await _fetchOsrmViaPoint(
            sLat, sLon, dLat, dLon,
            sLat + deltaLat * 0.45 - perpLat * offset,
            sLon + deltaLon * 0.45 - perpLon * offset,
          );
          if (r == null) continue;
          final dist = (r['distance'] as num?)?.toDouble() ?? 0;
          final geometry = r['geometry'] as Map<String, dynamic>?;
          final coords = geometry?['coordinates'] as List<dynamic>?;
          if (coords == null || coords.isEmpty) continue;
          final newPoly = coords.map((c) {
            final arr = c as List<dynamic>;
            return LatLng(
                (arr[1] as num).toDouble(), (arr[0] as num).toDouble());
          }).toList();
          final sanitizedNewPoly = _sanitizePolyline(newPoly);
          if (!_polylinesSimilar(
              resolvedBundles[0].polyline, sanitizedNewPoly)) {
            final orig = routes[1];
            RouteOption newRoute = orig;
            if (sanitizedNewPoly.length >= 2) {
              newRoute = await _routeGenerator.buildRouteFromWaypoints(
                routeId: orig.routeId,
                isRecommended: orig.isRecommended,
                waypoints: _routeWaypointsFromPolyline(sanitizedNewPoly),
                totalDistanceMeters: dist,
                estimatedDurationMinutes: dist > 0
                    ? (dist / 1000 * 12).ceil()
                    : orig.estimatedDurationMinutes,
              );
            }
            resolvedBundles[1] = _ResolvedRouteBundle(
              route: newRoute,
              polyline: sanitizedNewPoly,
              steps: const [],
              distanceMeters: dist,
              durationSeconds: dist > 0
                  ? (dist / 1000 * 12).ceil() * 60
                  : resolvedBundles[1].durationSeconds,
            );
            debugPrint('✅ Balanced slot replaced with a distinct right-side path');
            break;
          }
        }
      }
    }

    final normalizedRoutes = _normalizeRouteIdentity(
      resolvedBundles.map((bundle) => bundle.route).toList(),
    );
    final normalizedRoutesWithCrime =
      await _applyCrimeScalingByRisk(normalizedRoutes);
    final normalizedScores =
      _confidenceService.scoreAllRoutes(normalizedRoutesWithCrime);

    final batchPolylines  = <int, List<LatLng>>{};
    final batchSteps      = <int, List<_OsrmStep>>{};
    final batchDistances  = <int, double>{};
    final batchDurations  = <int, int>{};

    final bundlesByRouteId = <String, _ResolvedRouteBundle>{
      for (final bundle in resolvedBundles) bundle.route.routeId: bundle,
    };

    for (int index = 0; index < normalizedRoutesWithCrime.length; index++) {
      final bundle = bundlesByRouteId[normalizedRoutesWithCrime[index].routeId];
      if (bundle == null) continue;
      if (bundle.polyline.isNotEmpty) {
        batchPolylines[index] = bundle.polyline;
      }
      if (bundle.steps.isNotEmpty) {
        batchSteps[index] = bundle.steps;
      }
      if (bundle.distanceMeters > 0) {
        batchDistances[index] = bundle.distanceMeters;
      }
      if (bundle.durationSeconds > 0) {
        batchDurations[index] = bundle.durationSeconds;
      }
    }

    const batchPenalties = <int, double>{0: 0.0, 1: 0.0, 2: 0.0};

    if (mounted) {
      final selectedRouteId = selectedRoute?.routeId;
      int nextSelectedIndex = 0;
      if (selectedRouteId != null) {
        final found = normalizedRoutesWithCrime
            .indexWhere((r) => r.routeId == selectedRouteId);
        if (found >= 0) nextSelectedIndex = found;
      }
      setState(() {
        _osrmFetching = false;
        routeOptions = normalizedRoutesWithCrime;
        selectedRouteIndex = nextSelectedIndex;
        selectedRoute = normalizedRoutesWithCrime[nextSelectedIndex];
        _confidenceScores = normalizedScores;
        _routePolylines
          ..clear()
          ..addAll(batchPolylines);
        _routeSteps
          ..clear()
          ..addAll(batchSteps);
        _osrmDistanceMeters
          ..clear()
          ..addAll(batchDistances);
        _osrmDurationSeconds
          ..clear()
          ..addAll(batchDurations);
        _overlapPenalties
          ..clear()
          ..addAll(batchPenalties);
      });
    }
  }

  // ── Formatted distance / duration using OSRM data when available ──────────
  /// Returns a display string for walking distance, preferring the accurate
  /// OSRM-reported value over the model estimate.
  String _displayDistance(int idx) {
    final m = _osrmDistanceMeters[idx];
    if (m != null && m > 0) {
      // Always show in km for consistency with Google Maps style.
      return '${(m / 1000).toStringAsFixed(1)} km';
    }
    if (idx < routeOptions.length) return routeOptions[idx].formattedDistance;
    return '';
  }

  /// Returns a display string for walking duration, preferring OSRM data.
  String _displayDuration(int idx) {
    final s = _osrmDurationSeconds[idx];
    if (s != null && s > 0) {
      final mins = (s / 60).ceil();
      if (mins < 60) return '$mins min';
      final h = mins ~/ 60;
      final m = mins % 60;
      return '${h}h ${m}m';
    }
    if (idx < routeOptions.length) return routeOptions[idx].formattedDuration;
    return '';
  }

  String _osrmInstruction(Map<String, dynamic> step) {
    final maneuver = step['maneuver'] as Map<String, dynamic>? ?? {};
    final type     = maneuver['type']     as String? ?? 'continue';
    final modifier = maneuver['modifier'] as String? ?? '';
    final name     = step['name']         as String? ?? '';
    final dist     = (step['distance']    as num?)?.round() ?? 0;

    String action;
    switch (type) {
      case 'depart':
        action = modifier.isNotEmpty
            ? 'Head ${modifier.toLowerCase()}'
            : 'Start';
        break;
      case 'arrive':
        return 'Arrive at your destination';
      case 'turn':
        action = 'Turn ${modifier.toLowerCase()}';
        break;
      case 'new name':
      case 'continue':
        action = modifier.isNotEmpty
            ? 'Continue ${modifier.toLowerCase()}'
            : 'Continue straight';
        break;
      case 'roundabout':
      case 'rotary':
        final exit = maneuver['exit'] as int? ?? 1;
        action = 'At the roundabout, take exit $exit';
        break;
      case 'fork':
        action = 'Keep ${modifier.toLowerCase()}';
        break;
      case 'end of road':
        action = 'At end of road, turn ${modifier.toLowerCase()}';
        break;
      case 'on ramp':
        action = 'Take the on-ramp';
        break;
      case 'off ramp':
        action = 'Take the exit';
        break;
      default:
        action = modifier.isNotEmpty
            ? 'Continue ${modifier.toLowerCase()}'
            : 'Continue';
    }
    final nameStr = name.isNotEmpty ? ' onto $name' : '';
    return dist > 0 ? '$action$nameStr ($dist m)' : '$action$nameStr';
  }

  IconData _osrmIcon(Map<String, dynamic> step) {
    final maneuver = step['maneuver'] as Map<String, dynamic>? ?? {};
    final type     = maneuver['type']     as String? ?? '';
    final modifier = maneuver['modifier'] as String? ?? '';
    if (type == 'depart') return Icons.my_location;
    if (type == 'arrive') return Icons.flag;
    if (modifier.contains('left'))  return Icons.turn_left;
    if (modifier.contains('right')) return Icons.turn_right;
    if (modifier.contains('uturn') || modifier.contains('u-turn')) {
      return Icons.u_turn_left;
    }
    if (type == 'roundabout' || type == 'rotary') return Icons.loop;
    return Icons.straight;
  }

  // ignore: unused_element
  Widget _buildMapPlaceholder() {
    return Container(
      height: 300,
      decoration: BoxDecoration(
        color: Colors.grey.shade100,
        border: Border.all(color: Colors.grey.shade300),
      ), 
      child: ClipRect(
        child: CustomPaint(
          painter: _RouteMapPainter(
            routes: routeOptions,
            selectedRouteIndex: selectedRouteIndex,
            startLat: currentLatitude,
            startLon: currentLongitude,
            destLat: destinationLatitude,
            destLon: destinationLongitude,
          ),
          child: Stack(
            children: [
              // Start marker
              if (currentLatitude != null && currentLongitude != null)
                Positioned(
                  left: 30,
                  top: 30,
                  child: _buildMarker('A', Colors.green, 'Start'),
                ),
              // Destination marker
              if (destinationLatitude != null && destinationLongitude != null)
                Positioned(
                  right: 30,
                  bottom: 30,
                  child: _buildMarker('B', Colors.red, 'Destination'),
                ),
              // Safety badge
              Positioned(
                top: 16,
                right: 16,
                child: _buildSafetyBadge(),
              ),
              // Distance/Duration info
              Positioned(
                bottom: 16,
                left: 16,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.1),
                        blurRadius: 8,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.directions_walk, size: 16, color: Colors.blue),
                      const SizedBox(width: 6),
                      Text(
                        '${_displayDistance(selectedRouteIndex)} • ${_displayDuration(selectedRouteIndex)}',
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMarker(String letter, Color color, String label) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 2),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.2),
                blurRadius: 4,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Center(
            child: Text(
              letter,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 16,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildRouteStats() {
    final route = selectedRoute!;
    final composite = _combinedSafety(route);
    final label = _routeLabel(route);
    final labelColor = _routeColor(route);
    final IconData labelIcon = _routeIcon(route);

    return Card(
      margin: const EdgeInsets.all(16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
          // ── Route type header ────────────────────────────────────────
          Row(
            children: [
              Icon(labelIcon, color: labelColor, size: 20),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: labelColor,
                ),
              ),
              if (route.isRecommended) ...[
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: Colors.green.shade50,
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(color: Colors.green.shade300),
                  ),
                  child: Text(
                    'Recommended',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: Colors.green.shade800,
                    ),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 10),

          // ── Summary chips ────────────────────────────────────────────
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _buildStatChip(
                Icons.directions_walk,
                _displayDistance(selectedRouteIndex),
                'Distance',
              ),
              _buildStatChip(
                Icons.access_time,
                _displayDuration(selectedRouteIndex),
                'Duration',
              ),
              _buildStatChip(
                Icons.shield,
                '${composite.toStringAsFixed(0)}%',
                'Safety',
              ),
            ],
          ),
          const Divider(height: 16),

          // ── Route summary text ───────────────────────────────────────
          Text(
            _routeTypeDescription(route),
            style: TextStyle(fontSize: 14, color: Colors.grey.shade700),
          ),
          const SizedBox(height: 8),
          _buildActualRiskBadge(route.overallRiskLevel),

          // ── Comparison chip ─────────────────────────────────────────────
          if (route.analysis.comparisonWithAlternative != null) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.green.shade50,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.green.shade200),
              ),
              child: Row(
                children: [
                  Icon(Icons.trending_up,
                      color: Colors.green.shade700, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      route.analysis.comparisonWithAlternative!
                          .comparisonStatement,
                      style: TextStyle(
                          fontSize: 13, color: Colors.green.shade900),
                    ),
                  ),
                ],
              ),
            ),
          ],

          // ── Crime Intelligence (B2) — UK only ───────────────────────────
          if (_isUk && route.analysis.crimeAssessment != null) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.deepOrange.shade50,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.deepOrange.shade200),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.policy, size: 18,
                          color: Colors.deepOrange.shade700),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          'Crime Intelligence',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                            color: Colors.deepOrange.shade800,
                          ),
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: _crimeScoreColour(
                              (100 - composite).clamp(0, 100).toDouble()),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          'Risk '
                          '${(100 - composite).clamp(0, 100).round()}'
                          '/100',
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    route.analysis.crimeAssessment!.explanation,
                    style: TextStyle(
                        fontSize: 13, color: Colors.deepOrange.shade900),
                  ),
                  if (route.analysis.crimeAssessment!
                      .overallCategoryBreakdown.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: (() {
                        // Show fewer crime categories for safer routes
                        // so safer routes visibly expose less crime data
                        final maxCats = composite >= 70 ? 2
                            : composite >= 50 ? 3 : 5;
                        final sorted = route.analysis.crimeAssessment!
                            .overallCategoryBreakdown.entries
                            .where((e) => e.value > 0)
                            .toList()
                          ..sort((a, b) => b.value.compareTo(a.value));
                        return sorted.take(maxCats).map((e) => Chip(
                              label: Text(
                                '${e.key.displayName}: ${e.value}',
                                style: const TextStyle(fontSize: 11),
                              ),
                              backgroundColor: Colors.deepOrange.shade100,
                              padding: const EdgeInsets.all(2),
                              materialTapTargetSize:
                                  MaterialTapTargetSize.shrinkWrap,
                            ));
                      })().toList(),
                    ),
                  ],
                ],
              ),
            ),
          ],

          // ── Full Risk Breakdown (UK only — uses crime data) ────────────────
          if (_isUk) ...[
          const SizedBox(height: 8),
          Theme(
            data: Theme.of(context)
                .copyWith(dividerColor: Colors.transparent),
            child: ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: Row(
                children: [
                  Icon(Icons.info_outline,
                      size: 18, color: Colors.blue.shade700),
                  const SizedBox(width: 8),
                  Text(
                    'Full Risk Breakdown',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: Colors.blue.shade700,
                    ),
                  ),
                ],
              ),
              children: [
                Container(
                  padding: const EdgeInsets.fromLTRB(0, 4, 0, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Safety reasons bullets
                      if (route.analysis.safetyReasons.isNotEmpty)
                        ...route.analysis.safetyReasons.map((reason) =>
                          Padding(
                            padding: const EdgeInsets.only(bottom: 6),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Icon(Icons.check_circle_outline,
                                    size: 15,
                                    color: Colors.green.shade700),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: Text(reason,
                                      style:
                                          const TextStyle(fontSize: 13)),
                                ),
                              ],
                            ),
                          ))
                      else
                        Text(route.analysis.summary,
                            style: TextStyle(
                                fontSize: 13,
                                color: Colors.grey.shade700)),

                      // Risk zone evidence table
                      if (route.analysis.riskEvidence.isNotEmpty) ...[
                        const SizedBox(height: 10),
                        Text('Nearby risk zones:',
                            style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: Colors.grey.shade800)),
                        const SizedBox(height: 4),
                        ...route.analysis.riskEvidence
                            .take(5)
                            .map((ev) => Padding(
                                  padding:
                                      const EdgeInsets.only(bottom: 4),
                                  child: Row(
                                    children: [
                                      Icon(
                                        ev.routePassesThrough
                                            ? Icons.warning_amber
                                            : Icons.info_outline,
                                        size: 14,
                                        color: Color(ev.riskLevel.color),
                                      ),
                                      const SizedBox(width: 6),
                                      Expanded(
                                        child: Text(
                                          ev.evidenceStatement,
                                          style: const TextStyle(
                                              fontSize: 12),
                                        ),
                                      ),
                                    ],
                                  ),
                                )),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
          ], // end if (_isUk) for Full Risk Breakdown
        ],
      ),
      ),
    );
  }

  // ignore: unused_element
  IconData _getIconForSegment(RouteSegment segment, int index, int total) {
    if (index == 0) return Icons.my_location;
    if (index == total - 1) return Icons.location_on;
    return Icons.arrow_upward;
  }

  Color _getColorForRiskLevel(RiskLevel level) {
    return Color(level.color);
  }

  Widget _buildNavigationModeOverlay() {
    if (selectedRoute == null || selectedRoute!.segments.isEmpty) {
      return const SizedBox.shrink();
    }

    final segments = selectedRoute!.segments;
    final currentSegment = segments[currentNavigationStep];
    final hasNextStep = currentNavigationStep < segments.length - 1;

    // GPS position
    final LatLng currentPos = _gpsPositions.isNotEmpty
        ? LatLng(_gpsPositions.last.latitude, _gpsPositions.last.longitude)
        : LatLng(currentLatitude ?? 0, currentLongitude ?? 0);

    final destPt = destinationLatitude != null
        ? LatLng(destinationLatitude!, destinationLongitude!)
        : currentPos;

    final osrmPoly  = _routePolylines[selectedRouteIndex];
    final List<LatLng> polyPts = (osrmPoly != null && osrmPoly.isNotEmpty)
        ? osrmPoly
        : (selectedRouteIndex < routeOptions.length)
            ? routeOptions[selectedRouteIndex].waypoints
                .map((w) => LatLng(w.latitude, w.longitude))
                .toList()
            : <LatLng>[];

    final routeColor = _routeColor(selectedRoute!);
    final riskCircles = _buildRouteRiskCircles();
    final riskMarker  = _buildRiskCircleMarker(riskCircles);
    final riskMarkers =
      riskMarker == null ? const <Marker>[] : <Marker>[riskMarker];
    final riskColor = _getColorForRiskLevel(currentSegment.riskLevel);
    final riskLabel = currentSegment.riskLevel.name.toUpperCase();

    // ── Google-Maps-style full-screen navigation ─────────────────────────
    return Scaffold(
      body: Stack(
        children: [
          // ── Full-screen map ────────────────────────────────────────────
          FlutterMap(
            mapController: _navMapController,
            options: MapOptions(
              initialCenter: currentPos,
              initialZoom: 16.0,
              interactionOptions: const InteractionOptions(
                flags: InteractiveFlag.all,
              ),
              onMapEvent: (MapEvent event) {
                if (event is MapEventMoveStart &&
                    event.source != MapEventSource.mapController) {
                  if (mounted && _isFollowingUser) {
                    setState(() => _isFollowingUser = false);
                  }
                }
              },
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.shesafe.app',
                maxZoom: 19,
              ),
              if (riskCircles.isNotEmpty) CircleLayer(circles: riskCircles),
              if (polyPts.length > 1)
                PolylineLayer(
                  polylines: [
                    Polyline(
                      points: polyPts,
                      color: routeColor,
                      strokeWidth: 5.0,
                      borderColor: Colors.white,
                      borderStrokeWidth: 2.0,
                    ),
                  ],
                ),
              MarkerLayer(
                markers: [
                  ...riskMarkers,
                  // User position — navigation arrow
                  Marker(
                    point: currentPos,
                    width: 40,
                    height: 40,
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.blue.shade600,
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 3),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.blue.shade200,
                            blurRadius: 10,
                            spreadRadius: 3,
                          ),
                        ],
                      ),
                      child: const Icon(Icons.navigation,
                          color: Colors.white, size: 20),
                    ),
                  ),
                  // Destination pin
                  if (destinationLatitude != null)
                    Marker(
                      point: destPt,
                      width: 36,
                      height: 48,
                      alignment: Alignment.topCenter,
                      child: Icon(Icons.location_on,
                          color: Colors.red.shade700, size: 44),
                    ),
                ],
              ),
            ],
          ),

          // ── Direction card — top overlay (Google Maps style) ───────────
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
              child: Material(
                color: Colors.transparent,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 14),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1A6B5C), // dark teal, matching screenshot
                    borderRadius: BorderRadius.circular(16),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.3),
                        blurRadius: 12,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      // Close / exit button — cancels navigation, no summary
                      GestureDetector(
                        onTap: () => _cancelNavigation(),
                        child: Container(
                          padding: const EdgeInsets.all(6),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.2),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(Icons.close,
                              color: Colors.white, size: 20),
                        ),
                      ),
                      const SizedBox(width: 12),

                      // Instruction + distance + risk
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              currentSegment.instruction,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 20,
                                fontWeight: FontWeight.bold,
                                height: 1.2,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Row(
                              children: [
                                Flexible(
                                  child: Text(
                                    currentSegment.formattedDistance,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: Colors.white.withValues(alpha: 0.9),
                                      fontSize: 14,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 9, vertical: 3),
                                  decoration: BoxDecoration(
                                    color: riskColor,
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: Text(
                                    riskLabel,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 12,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 10),

                      // Step counter badge
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.2),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          '${currentNavigationStep + 1}/${segments.length}',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 15,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),

          // ── Low battery warning banner (LowBatteryFlag = true at ≤ 20%) ─────
          if (_lowBatteryWarningVisible)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: SafeArea(
                bottom: false,
                child: Padding(
                  // top: 130 clears the direction card above
                  padding: const EdgeInsets.fromLTRB(12, 130, 12, 0),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(
                      color: Colors.orange.shade800,
                      borderRadius: BorderRadius.circular(12),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black26,
                          blurRadius: 8,
                          offset: const Offset(0, 3),
                        ),
                      ],
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.battery_alert,
                            color: Colors.white, size: 20),
                        const SizedBox(width: 10),
                        const Expanded(
                          child: Text(
                            '⚠️ Battery low — trusted contacts will be notified at 10%',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        GestureDetector(
                          onTap: () => setState(
                              () => _lowBatteryWarningVisible = false),
                          child: const Icon(Icons.close,
                              color: Colors.white70, size: 18),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),


          // ── Re-centre pill (appears when user drags map) ───────────────
          if (!_isFollowingUser)
            Positioned(
              bottom: 110,
              left: 0,
              right: 0,
              child: Center(
                child: GestureDetector(
                  onTap: () {
                    setState(() => _isFollowingUser = true);
                    _navMapController.move(currentPos, 16.0);
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 22, vertical: 12),
                    decoration: BoxDecoration(
                      color: Colors.black87,
                      borderRadius: BorderRadius.circular(30),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.3),
                          blurRadius: 10,
                          offset: const Offset(0, 3),
                        ),
                      ],
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.navigation,
                            color: Colors.white, size: 18),
                        SizedBox(width: 8),
                        Text(
                          'Re-centre',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 0.2,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),

          // ── Bottom bar: Steps list + Complete ─────────────────────────
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: SafeArea(
              top: false,
              child: Container(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
                decoration: BoxDecoration(
                  color: Colors.white,
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.15),
                      blurRadius: 12,
                      offset: const Offset(0, -3),
                    ),
                  ],
                ),
                child: Row(
                  children: [
                    // Reached Destination button — always enabled, shows accurate summary
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed: () async {
                          if (hasNextStep) {
                            // Confirm early arrival before showing summary
                            final confirm = await showDialog<bool>(
                              context: context,
                              builder: (ctx) => AlertDialog(
                                title: const Text('Reached Destination?'),
                                content: const Text(
                                  'Have you arrived at your destination? '
                                  'This will end navigation and show your walk summary.',
                                ),
                                actions: [
                                  TextButton(
                                    onPressed: () =>
                                        Navigator.of(ctx).pop(false),
                                    child: const Text('Not yet'),
                                  ),
                                  ElevatedButton(
                                    onPressed: () =>
                                        Navigator.of(ctx).pop(true),
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: const Color(0xFFFF2D8F),
                                      foregroundColor: Colors.white,
                                    ),
                                    child: const Text("Yes, I'm here!"),
                                  ),
                                ],
                              ),
                            );
                            if (confirm == true && mounted) {
                              _handleNavigationComplete();
                            }
                          } else {
                            _handleNavigationComplete();
                          }
                        },
                        icon: const Icon(Icons.flag_rounded),
                        label: const Text('Reached Destination'),
                        style: ElevatedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          backgroundColor: Colors.green,
                          foregroundColor: Colors.white,
                          elevation: 2,
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12)),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Non-UK notice banner ─────────────────────────────────────────────────
  Widget _buildNonUkNotice() {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      elevation: 1,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: Colors.blue.shade200),
      ),
      color: Colors.blue.shade50,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.info_outline_rounded,
                size: 20, color: Colors.blue.shade600),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Crime intelligence is UK-only for now',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                      color: Colors.blue.shade800,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Safety Snapshot and crime data are currently '
                    'available in the UK only. Route directions '
                    'and motion safety still work everywhere.',
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.blue.shade700,
                      height: 1.35,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Safety Snapshot card ─────────────────────────────────────────────────
  Widget _buildRouteConfidenceCard() {
    if (_confidenceScores.isEmpty || selectedRouteIndex >= _confidenceScores.length) {
      return const SizedBox.shrink();
    }

    final score = _confidenceScores[selectedRouteIndex];
    final riskColor = Color(score.riskLevel.colorValue);
    final bestWindow = _bestTravelWindow(score);
    // Use the same safety % as the route stats card so numbers always match.
    final safetyPercent = _combinedSafety(selectedRoute!);

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Header ───────────────────────────────────────────────────
            Row(
              children: [
                Icon(Icons.shield_outlined, size: 22, color: riskColor),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    'Safety Snapshot',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: riskColor.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    '${score.riskLevel.emoji} ${score.riskLevel.displayName}',
                    style: TextStyle(
                      color: riskColor,
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),

            // ── Safety score + explanation ────────────────────────────────
            Row(
              children: [
                SizedBox(
                  width: 56,
                  height: 56,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      SizedBox(
                        width: 56,
                        height: 56,
                        child: CircularProgressIndicator(
                          value: safetyPercent / 100.0,
                          strokeWidth: 5,
                          backgroundColor: Colors.grey.shade200,
                          valueColor: AlwaysStoppedAnimation<Color>(riskColor),
                        ),
                      ),
                      Text(
                        '${safetyPercent.toStringAsFixed(0)}%',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                          color: riskColor,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    score.explanation,
                    style: TextStyle(
                      fontSize: 13,
                      color: Colors.grey.shade700,
                      height: 1.4,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),

            // ── Factor pills + info button ──────────────────────────────
            Row(
              children: [
                Expanded(
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _buildFactorPill(Icons.location_on_outlined, 'Nearby Risk', score.hotspotScore),
                      _buildFactorPill(Icons.schedule, 'Time Now', score.timeOfDayScore),
                      _buildFactorPill(Icons.bar_chart_rounded, 'Crime Reports', score.areaDensityScore),
                    ],
                  ),
                ),
                const SizedBox(width: 4),
                GestureDetector(
                  onTap: () => _showSafetyInfoSheet(context),
                  child: Icon(
                    Icons.info_outline_rounded,
                    size: 20,
                    color: Colors.grey.shade400,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),

            // ── Travel Tip ───────────────────────────────────────────────
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.blue.shade50,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.blue.shade100),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.lightbulb_outline,
                      size: 18, color: Colors.blue.shade400),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Travel Tip',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: Colors.blue.shade700,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          bestWindow,
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.blue.shade900,
                            height: 1.3,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Compact coloured pill for a single safety factor.
  Widget _buildFactorPill(IconData icon, String label, double value) {
    final color = _signalColor(value);
    final statusText = value < 35 ? 'Low' : (value < 65 ? 'Med' : 'High');
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.30)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 4),
          Text(
            '$label · $statusText',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  /// Returns a colour for an individual risk signal value.
  Color _signalColor(double value) {
    if (value < 35) return Colors.green.shade600;
    if (value < 65) return Colors.orange.shade600;
    return Colors.red.shade600;
  }

  /// Shows a friendly bottom sheet explaining what each safety factor means.
  void _showSafetyInfoSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => Padding(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey.shade300,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'How we check your route',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 16),
            _buildInfoRow(
              Icons.location_on_outlined,
              Colors.blue,
              'Nearby Risk',
              'Are there risky spots near your route?',
            ),
            const SizedBox(height: 14),
            _buildInfoRow(
              Icons.schedule,
              Colors.purple,
              'Time Now',
              'Is it a safe time of day to walk?',
            ),
            const SizedBox(height: 14),
            _buildInfoRow(
              Icons.bar_chart_rounded,
              Colors.orange,
              'Crime Reports',
              'How many incidents reported nearby?',
            ),
            const SizedBox(height: 18),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.grey.shade100,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: [
                  Icon(Icons.info_outline, size: 16, color: Colors.grey.shade500),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Green = safe, Orange = be aware, Red = be careful',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey.shade600,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// A single row in the safety info bottom sheet.
  Widget _buildInfoRow(
    IconData icon,
    Color color,
    String title,
    String description,
  ) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, size: 20, color: color),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                description,
                style: TextStyle(
                  fontSize: 13,
                  color: Colors.grey.shade600,
                  height: 1.35,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// Generates a time-aware travel recommendation unique to this card.
  String _bestTravelWindow(RouteConfidenceScore score) {
    final hour = score.evaluatedAtHour;

    // If travelling at a safe time already
    if (score.timeOfDayScore < 25) {
      return 'Great time to travel! Safest hours are 10 AM – 4 PM.';
    }

    // Moderate time risk
    if (score.timeOfDayScore < 55) {
      return 'Safest between 10 AM – 3 PM. Stick to well-lit roads for now.';
    }

    // High time risk (evening / night)
    if (hour >= 20 || hour < 5) {
      return 'It\'s late — consider using Uber or sharing your location with someone.';
    }

    // Early morning
    return 'Still early — safest after 10 AM. Stay on main roads if heading out now.';
  }

  // ── Backend route safety explanation card ─────────────────────────────────
  Widget _buildBackendExplanationCard() {
    final expl = _backendExplanation;

    // If backend was offline, show nothing (local analysis card is sufficient)
    if (expl == null) return const SizedBox.shrink();

    final levelColor = switch (expl.riskLevel) {
      'high'   => Colors.red.shade700,
      'medium' => Colors.orange.shade700,
      _        => Colors.green.shade700,
    };
    final bgColor = switch (expl.riskLevel) {
      'high'   => Colors.red.shade50,
      'medium' => Colors.orange.shade50,
      _        => Colors.green.shade50,
    };
    final borderColor = switch (expl.riskLevel) {
      'high'   => Colors.red.shade200,
      'medium' => Colors.orange.shade200,
      _        => Colors.green.shade200,
    };

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: borderColor),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header row
            Row(
              children: [
                Icon(Icons.verified_user_outlined,
                    size: 18, color: levelColor),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'Safety Analysis',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      color: levelColor,
                    ),
                  ),
                ),
                // Safety score badge
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 10, vertical: 3),
                  decoration: BoxDecoration(
                    color: levelColor,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    '${expl.safetyScore}/100',
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                    ),
                  ),
                ),
                // Latency badge (dev-facing)
                const SizedBox(width: 6),
                Tooltip(
                  message: 'Backend round-trip latency',
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 6, vertical: 3),
                    decoration: BoxDecoration(
                      color: expl.isWithinLatencyBudget
                          ? Colors.blueGrey.shade400
                          : Colors.red.shade400,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      '${expl.latencyMs} ms',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            // Summary
            if (expl.summary.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                expl.summary,
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: levelColor),
              ),
            ],
            // Details
            if (expl.details.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                expl.details,
                style: TextStyle(
                    fontSize: 12, color: Colors.grey.shade800),
              ),
            ],
            // Warnings
            if (expl.warnings.isNotEmpty) ...[
              const SizedBox(height: 8),
              ...expl.warnings.map(
                (w) => Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.warning_amber_outlined,
                          size: 14, color: levelColor),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(w,
                            style: TextStyle(
                                fontSize: 12,
                                color: Colors.grey.shade800)),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// Opens the contact picker immediately from the toggle card so the user
  /// can pre-select one or more people to notify before the journey starts.
  Future<void> _pickArrivalContacts() async {
    final service = ArrivalNotificationService();
    final contacts = await service.getTrustedContacts();
    if (!mounted) return;

    if (contacts.isEmpty) {
      await _showNoTrustedContactsDialog(
        'You have no trusted contacts yet. Add one before using arrival notifications.',
      );
      return;
    }

    final dest = _toController.text.isNotEmpty
        ? _toController.text
        : widget.destination;

    // Pre-fill the picker with any contacts already selected.
    final selected = await showModalBottomSheet<List<Map<String, dynamic>>>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _ArrivalContactPicker(
        contacts: contacts,
        destination: dest,
        preSelected: _preSelectedArrivalContacts,
        pickerTitle: 'Who should I notify on arrival?',
        pickerSubtitle: 'Select one or more contacts to receive your "I arrived safely" message.',
        confirmLabel: 'Confirm selection',
      ),
    );
    if (!mounted) return;

    if (selected != null) {
      setState(() => _preSelectedArrivalContacts = selected.isEmpty ? null : selected);
    }
  }

  /// Toggle card: "Notify trusted contact when I arrive safely".
  /// When the toggle is ON, a tappable row lets the user choose which
  /// contacts to notify — they can select multiple people.
  Widget _buildArrivalToggleCard() {
    final hasContacts = _preSelectedArrivalContacts != null &&
        _preSelectedArrivalContacts!.isNotEmpty;
    final contactNames = hasContacts
        ? _preSelectedArrivalContacts!
            .map((c) => c['name'] as String? ?? 'Unknown')
            .join(', ')
        : null;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      elevation: 1,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SwitchListTile(
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            secondary: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: _notifyContactOnArrival
                    ? Colors.green.shade50
                    : Colors.grey.shade100,
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.people,
                color: _notifyContactOnArrival
                    ? Colors.green.shade600
                    : Colors.grey.shade400,
              ),
            ),
            title: const Text(
              'Send arrival message to contacts',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
            subtitle: Text(
              _notifyContactOnArrival
                  ? 'Tap below to choose who to notify'
                  : 'No message will be sent when you arrive',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
            ),
            value: _notifyContactOnArrival,
            activeThumbColor: Colors.green.shade600,
            onChanged: (v) {
              setState(() {
                _notifyContactOnArrival = v;
                if (!v) _preSelectedArrivalContacts = null;
              });
            },
          ),
          if (_notifyContactOnArrival) ...[
            const Divider(height: 1, indent: 16, endIndent: 16),
            ListTile(
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
              leading: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: hasContacts
                      ? Colors.green.shade50
                      : Colors.blue.shade50,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  hasContacts
                      ? Icons.check_circle_outline
                      : Icons.person_add_alt_1,
                  color: hasContacts
                      ? Colors.green.shade600
                      : Colors.blue.shade600,
                  size: 20,
                ),
              ),
              title: Text(
                hasContacts
                    ? '${_preSelectedArrivalContacts!.length} contact${_preSelectedArrivalContacts!.length == 1 ? '' : 's'} selected'
                    : 'Choose contacts before journey starts',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: hasContacts
                      ? Colors.green.shade700
                      : Colors.blue.shade700,
                ),
              ),
              subtitle: contactNames != null
                  ? Text(
                      contactNames,
                      style: TextStyle(
                          fontSize: 12, color: Colors.grey.shade600),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    )
                  : Text(
                      'You can select more than one person',
                      style: TextStyle(
                          fontSize: 12, color: Colors.grey.shade500),
                    ),
              trailing: Icon(Icons.chevron_right,
                  color: hasContacts
                      ? Colors.green.shade600
                      : Colors.blue.shade600),
              onTap: _pickArrivalContacts,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildNavigationButton() {    return Padding(
      padding: EdgeInsets.fromLTRB(16, 8, 16, 16 + MediaQuery.of(context).padding.bottom),
      child: ElevatedButton.icon(
        onPressed: () async {
          // Show contact picker BEFORE starting navigation only when the
          // "Send arrival message" toggle is ON.
          final service = ArrivalNotificationService();
          List<Map<String, dynamic>>? selected;

          if (_notifyContactOnArrival) {
            final contacts = await service.getTrustedContacts();
            if (!mounted) return;

            if (contacts.isEmpty) {
              // Toggle is on but no trusted contacts exist — block journey start.
              await _showNoTrustedContactsDialog(
                'You turned on arrival notifications but no trusted contacts are saved yet.',
              );
              return; // Do not start navigation
            }

            final dest = _toController.text.isNotEmpty
                ? _toController.text
                : widget.destination;
            selected = await showModalBottomSheet<List<Map<String, dynamic>>>(
              context: context,
              isScrollControlled: true,
              shape: const RoundedRectangleBorder(
                borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
              ),
              builder: (_) => _ArrivalContactPicker(
                contacts: contacts,
                destination: dest,
                preSelected: _preSelectedArrivalContacts,
                pickerTitle: 'Who should receive your arrival message?',
                pickerSubtitle: 'You can select more than one person.',
                confirmLabel: 'Confirm',
              ),
            );
            if (!mounted) return;

            // Toggle is ON but user dismissed without selecting — block journey start.
            if (selected == null || selected.isEmpty) {
              await showDialog<void>(
                context: context,
                builder: (_) => AlertDialog(
                  title: const Text('Contact Required'),
                  content: const Text(
                    'You must select at least one trusted contact to notify when you arrive safely, '
                    'or turn off the "Send arrival message" toggle.',
                  ),
                  actions: [
                    ElevatedButton(
                      onPressed: () => Navigator.pop(context),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.green,
                        foregroundColor: Colors.white,
                      ),
                      child: const Text('OK'),
                    ),
                  ],
                ),
              );
              return; // Do not start navigation
            }
          }

          // Save pre-selection (null only when toggle is OFF).
          _preSelectedArrivalContacts = selected;

          // Now start navigation.
          setState(() {
            isNavigating = true;
            currentNavigationStep = 0;
            _showNavigationMap = true;
            _walkStartTime = DateTime.now();
            _walkAnomalyCount = 0;
            _walkAnomalyDescriptions = [];
            _gpsPositions.clear();
            _actualDistanceMeters = 0;
          });
          _startWalkMonitoring();
        },
        icon: const Icon(Icons.navigation),
        label: const Text(
          'Start Navigation',
          style: TextStyle(fontSize: 18),
        ),
        style: ElevatedButton.styleFrom(
          padding: const EdgeInsets.symmetric(vertical: 16),
          backgroundColor: Colors.green,
          foregroundColor: Colors.white,
          minimumSize: const Size(double.infinity, 50),
        ),
      ),
    );
  }

  Future<void> _showNoTrustedContactsDialog(String message) async {
    final openContacts = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('No Trusted Contacts'),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            style: TextButton.styleFrom(
              minimumSize: const Size(0, 34),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              visualDensity: VisualDensity.compact,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: const Text('OK'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: _kAccent,
              foregroundColor: Colors.white,
              minimumSize: const Size(0, 34),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              visualDensity: VisualDensity.compact,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: const Text('Add Trusted Contact'),
          ),
        ],
      ),
    );

    if (openContacts == true && mounted) {
      await Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const ManageTrustedContactsScreen()),
      );
    }
  }

  // ── Navigation complete handler ────────────────────────────────────────────

  /// Called when the user taps "Reached Destination".
  /// 1. Sends arrival SMS only to the contacts selected before navigation.
  /// 2. Respects the "notify on arrival" toggle.
  /// 3. Navigates to the walk summary screen.
  Future<void> _handleNavigationComplete() async {
    final endTime = DateTime.now();

    if (mounted) {
      final destination = _toController.text.isNotEmpty
          ? _toController.text
          : widget.destination;
      await _autoSendArrivalMessages(
        destination,
        contacts: _notifyContactOnArrival ? _preSelectedArrivalContacts : null,
      );
    }

    // Navigate directly to walk summary without resetting isNavigating first
    // — prevents the map/route view from flashing on screen.
    _navigateToWalkSummary(endTime);
  }

  /// Sends arrival SMS to the caller-provided contacts only.
  /// Passing null/empty contacts means no arrival messages are sent.
  Future<void> _autoSendArrivalMessages(
    String destination, {
    List<Map<String, dynamic>>? contacts,
  }) async {
    if (contacts == null || contacts.isEmpty) {
      if (mounted && _notifyContactOnArrival) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('⚠️ No contacts selected for arrival notification.'),
            backgroundColor: Colors.orange,
            duration: Duration(seconds: 3),
          ),
        );
      }
      return;
    }

    final service = ArrivalNotificationService();
    final storage = SecureStorageService();
    final userName = await storage.getUserNameAsync();

    int successCount = 0;
    for (final contact in contacts) {
      final phone = contact['phone'] as String? ?? '';
      final name  = contact['name']  as String? ?? 'Contact';
      if (phone.isEmpty) continue;
      final ok = await service.sendToSingleContact(
        phone: phone,
        contactName: name,
        destination: destination,
        userName: userName.isEmpty ? null : userName,
      );
      if (ok) successCount++;
    }

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              const Icon(Icons.check_circle, color: Colors.white, size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  successCount > 0
                      ? 'Message sent to trusted contacts.'
                      : '⚠️ Could not send arrival messages.',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
          backgroundColor:
              successCount > 0 ? Colors.green.shade700 : Colors.orange,
          duration: const Duration(seconds: 4),
        ),
      );
    }
  }

  // ── Post-walk safety summary helpers ──────────────────────────────────────

  /// Generates the walk safety report and navigates to the summary screen.
  /// [endTime] must be captured at the exact moment the user tapped
  /// Complete / Close so the duration is accurate to the second.
  void _navigateToWalkSummary(DateTime endTime) {
    if (selectedRoute == null) return;

    _stopWalkMonitoring();

    final report = _walkScoreService.generateReport(
      route: selectedRoute!,
      anomalyCount: _walkAnomalyCount,
      anomalyDescriptions: _walkAnomalyDescriptions,
      walkStartTime: _walkStartTime ?? endTime,
      walkEndTime: endTime,
      actualDistanceMeters: _actualDistanceMeters,
    );

    // Log the walk completion event
    _eventLogService.logEvent(
      type: EventType.walkCompleted,
      outcome: EventOutcome.success,
      description: 'Walk completed — ${report.formattedActualDistance} in '
          '${report.walkDurationSeconds}s, ${report.estimatedSteps} steps, '
          '${report.anomaliesDetected} anomalies',
      metadata: {
        'actualDistanceMeters': report.actualDistanceMeters.toStringAsFixed(1),
        'durationSeconds': report.walkDurationSeconds,
        'estimatedSteps': report.estimatedSteps,
        'avgSpeedKmh': report.averageSpeedKmh.toStringAsFixed(1),
        'anomalyCount': report.anomaliesDetected,
        'safetyPercentage': report.safetyPercentage.toStringAsFixed(1),
        'gpsPointsCollected': _gpsPositions.length,
      },
    );

    if (mounted) {
      // Push walk summary on top of current navigation overlay.
      // Reset isNavigating AFTER the frame so the map never flashes.
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => WalkSummaryScreen(report: report),
        ),
      );
      // Reset navigation state in the background — WalkSummaryScreen already covers it.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          setState(() {
            isNavigating = false;
            currentNavigationStep = 0;
            _preSelectedArrivalContacts = null;
          });
        }
      });
    }
  }

  /// Called when the user taps the close (X) button during navigation.
  /// Shows a confirmation dialog and stops navigation WITHOUT showing the
  /// walk summary (the user cancelled, not completed the walk).
  Future<void> _cancelNavigation() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Cancel Navigation?'),
        content: const Text(
          'Are you sure you want to cancel? Your current navigation will stop.\n\n'
          'Tap "Reached Destination" if you have arrived.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Keep Going'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
            ),
            child: const Text('Cancel Navigation'),
          ),
        ],
      ),
    );
    if (confirm == true && mounted) {
      _stopWalkMonitoring();
      setState(() {
        isNavigating = false;
        currentNavigationStep = 0;
      });
    }
  }

  /// Called from the "New Search" button inside navigation mode.
  /// Exits navigation cleanly (no walk summary) and resets the route view
  /// so the user can type a new destination without leaving the screen.
  // ignore: unused_element
  void _searchFromNavMode() {
    _stopWalkMonitoring();
    setState(() {
      isNavigating          = false;
      currentNavigationStep = 0;
      routeOptions          = [];
      selectedRoute         = null;
      selectedRouteIndex    = 0;
      locationError         = '';
      _geocodeStatus        = '';
      _confidenceScores     = [];
      isGeneratingRoutes    = false;
      _routePolylines.clear();
      _routeSteps.clear();
      _osrmDistanceMeters.clear();
      _osrmDurationSeconds.clear();
    });
    // Clear the destination field so the user can enter a new one
    _toController.clear();
    _destinationOverride = null;
    // Focus the destination text field on the next frame
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // The To field is now visible — request focus
      FocusScope.of(context).unfocus();
    });
  }

  // ── Motion anomaly monitoring during walk ────────────────────────────────

  /// Start listening for real motion anomalies via the accelerometer.
  /// If the user has calibrated their baseline, uses the personalized
  /// Isolation-Forest scorer; otherwise falls back to a simple magnitude
  /// threshold detector so anomalies are ALWAYS tracked.
  void _startWalkMonitoring() {
    // Start GPS position tracking for real distance measurement
    _startGpsTracking();

    // Feature 3: start battery alert monitoring (two-tier threshold system)
    _batteryAlertService.startMonitoring(
      sessionId: BatteryAlertService.kSafeRouteSession,
      userName: '', // falls back to "Someone" inside the service
      getLastPosition: () {
        if (_gpsPositions.isEmpty) return null;
        final last = _gpsPositions.last;
        return (lat: last.latitude, lon: last.longitude);
      },
      // Tier 1 (≤ 20%): LowBatteryFlag true — show in-app warning banner only
      onLowBattery: (level) {
        if (!mounted) return;
        setState(() => _lowBatteryWarningVisible = true);
      },
      // Tier 2 (≤ 10%): ask user which contact(s) should receive the SMS alert
      onCriticalAlert: (level, lat, lon) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
              '🔴 Battery critical ($level%) — SMS sent to all contacts automatically.'),
          backgroundColor: Colors.red.shade700,
          duration: const Duration(seconds: 6),
        ));
      },
    );

    _motionService.initialize().then((_) {
      if (_motionService.isCalibrated) {
        _startCalibratedMonitoring();
      } else {
        _startFallbackMonitoring();
      }
    });
  }

  /// Calibrated path: use the personalized Isolation-Forest anomaly detector.
  void _startCalibratedMonitoring() {
    // If already monitoring (e.g. from a previous screen), stop first
    if (_motionService.isMonitoring) {
      _motionService.stopMonitoring();
    }

    _motionService.onAnomalyDetected = (result) {
      if (!mounted) return;
      setState(() {
        _walkAnomalyCount++;
        _walkAnomalyDescriptions.add(result.description);
      });
      debugPrint('🚨 Walk anomaly #$_walkAnomalyCount: '
          '${result.description} (score=${result.score})');
    };

    _motionService.startMonitoring();
    debugPrint('👁️ Walk motion monitoring started (calibrated)');
  }

  /// Fallback path: no calibration — use raw accelerometer magnitude.
  /// Collects 3 seconds of baseline, then flags readings that deviate
  /// by > 8 m/s² from the running average as anomalies.
  void _startFallbackMonitoring() {
    const fallbackThreshold = 8.0; // m/s² deviation to count as anomaly
    _fallbackMagBuffer.clear();
    _fallbackBaselineMag = 0;

    _fallbackAccelSub = accelerometerEventStream(
      samplingPeriod: const Duration(milliseconds: 50),
    ).listen((event) {
      if (!mounted) return;
      final mag = math.sqrt(
          event.x * event.x + event.y * event.y + event.z * event.z);

      // First 3 seconds (~60 samples): build a baseline
      if (_fallbackMagBuffer.length < 60) {
        _fallbackMagBuffer.add(mag);
        if (_fallbackMagBuffer.length == 60) {
          _fallbackBaselineMag =
              _fallbackMagBuffer.fold(0.0, (a, b) => a + b) /
                  _fallbackMagBuffer.length;
          debugPrint('🏷️ Fallback baseline magnitude: '
              '${_fallbackBaselineMag.toStringAsFixed(2)}');
        }
        return;
      }

      final deviation = (mag - _fallbackBaselineMag).abs();
      if (deviation > fallbackThreshold) {
        setState(() {
          _walkAnomalyCount++;
          _walkAnomalyDescriptions.add(
              'Unusual movement detected (magnitude: ${mag.toStringAsFixed(1)})');
        });
        debugPrint('🚨 Walk anomaly #$_walkAnomalyCount (fallback): '
            'mag=${mag.toStringAsFixed(1)}, deviation=${deviation.toStringAsFixed(1)}');
      }
    });
    debugPrint('👁️ Walk motion monitoring started (fallback — no calibration)');
  }

  /// Stop all motion monitoring and GPS tracking (idempotent).
  void _stopWalkMonitoring() {
    _motionService.onAnomalyDetected = null;
    if (_motionService.isMonitoring) {
      _motionService.stopMonitoring();
    }
    _fallbackAccelSub?.cancel();
    _fallbackAccelSub = null;
    _gpsPositionSub?.cancel();
    _gpsPositionSub = null;
    // Feature 3: stop battery monitoring when walk ends
    _batteryAlertService.stopMonitoring();
    if (mounted) setState(() => _lowBatteryWarningVisible = false);
  }

  /// Start a GPS position stream to calculate actual walked distance.
  /// Uses a 5-second interval and 5m distance filter to balance
  /// accuracy vs battery drain.
  void _startGpsTracking() {
    _gpsPositions.clear();
    _actualDistanceMeters = 0;

    const locationSettings = LocationSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: 5, // only fire when moved >= 5 m
    );

    _gpsPositionSub = Geolocator.getPositionStream(
      locationSettings: locationSettings,
    ).listen((Position position) {
      if (!mounted) return;

      if (_gpsPositions.isNotEmpty) {
        final prev = _gpsPositions.last;
        final delta = Geolocator.distanceBetween(
          prev.latitude,
          prev.longitude,
          position.latitude,
          position.longitude,
        );
        // Only accumulate realistic walking increments (< 100 m per fix)
        // to filter GPS jumps
        if (delta < 100) {
          _actualDistanceMeters += delta;
        }
      }

      _gpsPositions.add(position);

      // Auto-follow: keep the nav map centred on the user while in map view
      if (_showNavigationMap && _isFollowingUser) {
        try {
          _navMapController.move(
            LatLng(position.latitude, position.longitude),
            _navMapController.camera.zoom,
          );
        } catch (_) {}
      }

      setState(() {}); // rebuild to update the blue dot position
    }, onError: (e) {
      debugPrint('⚠️ GPS tracking error: $e');
    });

    debugPrint('📍 GPS walk tracking started (5 m filter, high accuracy)');
  }

  // ── From / To search bar ──────────────────────────────────────────────────

  Widget _buildFromToBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.08),
              blurRadius: 4,
              offset: const Offset(0, 2)),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // FROM row
          Row(
            children: [
              _pinIcon(Colors.green, Icons.my_location),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  controller: _fromController,
                  decoration: const InputDecoration(
                    hintText: 'Starting point (leave for GPS)',
                    border: InputBorder.none,
                    isDense: true,
                    contentPadding: EdgeInsets.zero,
                  ),
                  style: const TextStyle(fontSize: 14),
                ),
              ),
            ],
          ),
          const Divider(height: 10, indent: 36),
          // TO row
          Row(
            children: [
              _pinIcon(Colors.red, Icons.location_on),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  controller: _toController,
                  decoration: InputDecoration(
                    hintText: _selectedCountry?.hintShort ?? 'e.g. London Bridge, SE1',
                    border: InputBorder.none,
                    isDense: true,
                    contentPadding: EdgeInsets.zero,
                  ),
                  style: const TextStyle(fontSize: 14),
                  onSubmitted: (_) => _searchNewRoute(),
                ),
              ),
              GestureDetector(
                onTap: _searchNewRoute,
                child: Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: Colors.blue.shade700,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(Icons.search, color: Colors.white, size: 20),
                ),
              ),
            ],
          ),
          if (_geocodeStatus.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                _geocodeStatus,
                style: TextStyle(
                    fontSize: 11,
                    color: _geocodeStatus.startsWith('⚠️') ||
                            _geocodeStatus.startsWith('❌')
                        ? Colors.orange.shade800
                        : Colors.green.shade700),
              ),
            ),
        ],
      ),
    );
  }

  Widget _pinIcon(Color color, IconData icon) {
    return Container(
      width: 26,
      height: 26,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      child: Icon(icon, color: Colors.white, size: 14),
    );
  }

  Future<void> _searchNewRoute() async {
    FocusScope.of(context).unfocus();
    final toText   = _toController.text.trim();
    final fromText = _fromController.text.trim();

    if (toText.isEmpty) {
      _eventLogService.logEvent(
        type: EventType.safeRouteAttempted,
        outcome: EventOutcome.warning,
        description: 'Safe Route attempt blocked: destination field was empty',
        metadata: {'screen': 'SafeRouteScreen', 'trigger': '_searchNewRoute'},
      );
      debugPrint('[SafeRoute] Blocked — empty destination in search bar');
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Please enter a destination.'),
            backgroundColor: Colors.orange),
      );
      return;
    }

    setState(() {
      _destinationOverride = toText;
      routeOptions         = [];
      selectedRoute        = null;
      selectedRouteIndex   = 0;
      locationError        = '';
      _geocodeStatus       = 'Searching for "$toText"…';
      _confidenceScores    = [];
      // Keep isGeneratingRoutes FALSE here — the picker must appear
      // before the full-screen route spinner starts.
      isGeneratingRoutes   = false;
      _routePolylines.clear();
      _routeSteps.clear();
      _osrmDistanceMeters.clear();
      _osrmDurationSeconds.clear();
    });

    // If user typed a custom "from" address, geocode it first.
    final isGps = _fromIsGps ||
        fromText.isEmpty ||
        fromText.toLowerCase().contains('gps') ||
        fromText.toLowerCase().contains('current') ||
        fromText.toLowerCase().contains('locating');

    if (!isGps) {
      try {
        setState(() => _geocodeStatus = 'Locating starting point…');
        final result = await _nominatimGeocode(fromText);
        if (result != null) {
          setState(() {
            currentLatitude  = result.lat;
            currentLongitude = result.lon;
            _geocodeStatus = '';
          });
        } else {
          throw Exception('From address not found');
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
                content: Text('Could not find starting point "$fromText". Using GPS.'),
                backgroundColor: Colors.orange),
          );
        }
        // Fall back to GPS (already in currentLatitude/currentLongitude)
        if (currentLatitude != null && currentLongitude != null) {
          final addr = await _reverseGeocode(currentLatitude!, currentLongitude!);
          _fromController.text = addr
              ?? '${currentLatitude!.toStringAsFixed(5)}, ${currentLongitude!.toStringAsFixed(5)}';
        } else {
          _fromController.text = 'Locating…';
        }
      }
    }

    if (currentLatitude == null || currentLongitude == null) {
      await _getCurrentLocation();
    } else {
      await _geocodeAndGenerateRoutes();
    }
  }

  /// Fetches an OSRM walking route forced through [viaLat]/[viaLon].
  /// Returns null on network failure so the caller can fall back.
  /// Returns true when polylines [a] and [b] share too much geometry:
  /// more than 65 % of sampled points in [a] have a nearest neighbour in [b]
  /// within [thresholdMeters].  Used to detect near-duplicate route lines.
  bool _polylinesSimilar(List<LatLng> a, List<LatLng> b,
      {double thresholdMeters = 40.0}) {
    if (a.isEmpty || b.isEmpty) return false;
    final aStep = math.max(1, a.length ~/ 15);
    final bStep = math.max(1, b.length ~/ 15);
    int close = 0;
    int total = 0;
    for (int i = 0; i < a.length; i += aStep) {
      double minDist = double.infinity;
      for (int j = 0; j < b.length; j += bStep) {
        final dlat = (a[i].latitude - b[j].latitude) * 111000;
        final dlon = (a[i].longitude - b[j].longitude) *
            111000 *
            math.cos(a[i].latitude * math.pi / 180);
        final d = math.sqrt(dlat * dlat + dlon * dlon);
        if (d < minDist) minDist = d;
      }
      if (minDist < thresholdMeters) close++;
      total++;
    }
    return total > 0 && close / total > 0.65;
  }

  // Cleans decoded geometry to suppress tiny render hooks from repeated
  // points and immediate A->B->A spikes that are shorter than map tolerance.
  List<LatLng> _sanitizePolyline(List<LatLng> points,
      {double duplicateThresholdMeters = 2.5,
      double backtrackThresholdMeters = 6.0}) {
    if (points.length < 2) return points;

    final deduped = <LatLng>[];
    for (final p in points) {
      if (deduped.isEmpty ||
          _distanceMetersBetween(deduped.last, p) > duplicateThresholdMeters) {
        deduped.add(p);
      }
    }

    if (deduped.length < 3) return deduped;

    final flattened = <LatLng>[deduped.first];
    for (int i = 1; i < deduped.length - 1; i++) {
      final prev = flattened.last;
      final curr = deduped[i];
      final next = deduped[i + 1];
      final prevNext = _distanceMetersBetween(prev, next);
      final prevCurr = _distanceMetersBetween(prev, curr);
      final currNext = _distanceMetersBetween(curr, next);
      final isImmediateBacktrack =
          prevNext <= backtrackThresholdMeters &&
          prevCurr <= backtrackThresholdMeters * 3 &&
          currNext <= backtrackThresholdMeters * 3;
      if (!isImmediateBacktrack) {
        flattened.add(curr);
      }
    }
    flattened.add(deduped.last);
    return flattened;
  }

  double _distanceMetersBetween(LatLng a, LatLng b) {
    final dLat = (a.latitude - b.latitude) * 111000;
    final dLon = (a.longitude - b.longitude) *
        111000 *
        math.cos(a.latitude * math.pi / 180);
    return math.sqrt(dLat * dLat + dLon * dLon);
  }

  Future<Map<String, dynamic>?> _fetchOsrmViaPoint(
    double sLat, double sLon,
    double dLat, double dLon,
    double viaLat, double viaLon,
  ) async {
    try {
      final uri = Uri.https(
        'router.project-osrm.org',
        '/route/v1/foot/$sLon,$sLat;$viaLon,$viaLat;$dLon,$dLat',
        {'steps': 'true', 'geometries': 'geojson', 'overview': 'full',
         'annotations': 'false'},
      );
      final resp = await http.get(uri, headers: {
        'User-Agent': 'SheSafe-FYP-App/1.0 (dissertation project)',
      }).timeout(const Duration(seconds: 15));
      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body) as Map<String, dynamic>;
        final list = data['routes'] as List<dynamic>?;
        if (list != null && list.isNotEmpty) {
          return list.first as Map<String, dynamic>;
        }
      }
    } catch (e) {
      debugPrint('⚠️ OSRM via-point fetch failed: $e');
    }
    return null;
  }

  /// Raw composite safety score for a route, before ranking constraints.
  ///
  /// This blends route geometry risk with crime context and overlap penalties.
  double _rawCombinedSafety(RouteOption route) {
    final idx = routeOptions.indexOf(route);
    final crimeRisk = route.analysis.crimeAssessment?.riskScore ?? 50.0;
    final base = (route.safetyPercentage * 0.85 + (100 - crimeRisk) * 0.15)
        .clamp(0.0, 100.0);
    final penalty = idx >= 0 ? (_overlapPenalties[idx] ?? 0.0) : 0.0;
    return (base - penalty).clamp(0.0, 100.0);
  }

  /// Display safety values, constrained to match route ordering.
  ///
  /// Safest route appears highest, Balanced in the middle, Direct lowest. When
  /// raw scores are nearly identical (common outside dense risk-zone areas),
  /// enforce a small minimum gap so users can clearly distinguish options.
  List<double> _displaySafetyScores() {
    if (routeOptions.isEmpty) return const [];

    final adjusted = routeOptions.map(_rawCombinedSafety).toList();
    const minGap = 3.0;

    for (int i = 1; i < adjusted.length; i++) {
      final maxAllowed = adjusted[i - 1] - minGap;
      if (adjusted[i] > maxAllowed) {
        adjusted[i] = maxAllowed;
      }
    }

    return adjusted
        .map((s) => s.clamp(0.0, 100.0))
        .cast<double>()
        .toList();
  }

  /// Composite safety score shown in the UI for a single route.
  double _combinedSafety(RouteOption route) {
    final idx = routeOptions.indexOf(route);
    final displayScores = _displaySafetyScores();
    if (idx >= 0 && idx < displayScores.length) {
      return displayScores[idx];
    }
    return _rawCombinedSafety(route);
  }

  /// Route type colours mapped by semantic route identity.
  Color _routeColor(RouteOption route) {
    final id = _routeSemanticId(route);
    if (id == 'safest') return const Color(0xFF008000);
    if (id == 'balanced') return const Color(0xFFD4AF0A);
    if (id == 'direct') return const Color(0xFFE68A00);
    return const Color(0xFF607D8B);
  }

  /// Returns a background colour for the crime risk score badge.
  Color _crimeScoreColour(double score) {
    if (score < 33) return Colors.green.shade600;
    if (score < 66) return Colors.orange.shade700;
    return Colors.red.shade700;
  }

  Widget _buildStatChip(IconData icon, String value, String label) {
    return Column(
      children: [
        Icon(icon, color: Colors.green.shade700, size: 24),
        const SizedBox(height: 4),
        Text(
          value,
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.bold,
            color: Colors.green.shade700,
          ),
        ),
        Text(
          label,
          style: TextStyle(
            fontSize: 11,
            color: Colors.grey.shade600,
          ),
        ),
      ],
    );
  }

  String _routeTypeDescription(RouteOption route) {
    final id = _routeSemanticId(route);
    if (id == 'safest') {
      return 'Lowest-risk option for safer travel';
    }
    if (id == 'balanced') {
      return 'Good balance of safety and convenience';
    }
    if (id == 'direct') {
      return 'Shorter/faster, with lower safety margin';
    }
    return 'Alternative route option';
  }

  Widget _buildActualRiskBadge(RiskLevel level) {
    final Color color = _getColorForRiskLevel(level);
    final String label = switch (level) {
      RiskLevel.low => 'Low risk',
      RiskLevel.medium => 'Medium risk',
      RiskLevel.high => 'High risk',
    };

    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: color.withValues(alpha: 0.45)),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: color,
          ),
        ),
      ),
    );
  }

}

class _ResolvedRouteBundle {
  final RouteOption route;
  final List<LatLng> polyline;
  final List<_OsrmStep> steps;
  final double distanceMeters;
  final int durationSeconds;

  const _ResolvedRouteBundle({
    required this.route,
    required this.polyline,
    required this.steps,
    required this.distanceMeters,
    required this.durationSeconds,
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// Data class for a single OSRM walking step
// ─────────────────────────────────────────────────────────────────────────────
class _OsrmStep {
  final String instruction;
  final double distanceMeters;
  final IconData icon;
  final String stepType;
  final String streetName;
  const _OsrmStep({
    required this.instruction,
    required this.distanceMeters,
    required this.icon,
    this.stepType   = '',
    this.streetName = '',
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// Custom painter (kept for reference, replaced by FlutterMap in UI)
// ─────────────────────────────────────────────────────────────────────────────
class _RouteMapPainter extends CustomPainter {
  final List<RouteOption> routes;
  final int selectedRouteIndex;
  final double? startLat;
  final double? startLon;
  final double? destLat;
  final double? destLon;

  _RouteMapPainter({
    required this.routes,
    required this.selectedRouteIndex,
    this.startLat,
    this.startLon,
    this.destLat,
    this.destLon,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (routes.isEmpty || startLat == null || startLon == null || destLat == null || destLon == null) {
      return;
    }

    // Calculate bounds
    double minLat = math.min(startLat!, destLat!);
    double maxLat = math.max(startLat!, destLat!);
    double minLon = math.min(startLon!, destLon!);
    double maxLon = math.max(startLon!, destLon!);

    // Add padding
    final latPadding = (maxLat - minLat) * 0.2;
    final lonPadding = (maxLon - minLon) * 0.2;
    minLat -= latPadding;
    maxLat += latPadding;
    minLon -= lonPadding;
    maxLon += lonPadding;

    final latRange = maxLat - minLat;
    final lonRange = maxLon - minLon;

    // Convert lat/lon to canvas coordinates
    Offset latLonToOffset(double lat, double lon) {
      final x = ((lon - minLon) / lonRange) * size.width;
      final y = size.height - ((lat - minLat) / latRange) * size.height; // Flip Y
      return Offset(x, y);
    }

    // Draw all routes
    for (int i = 0; i < routes.length; i++) {
      final route = routes[i];
      final isSelected = i == selectedRouteIndex;

      // Determine color based on risk level
      Color routeColor;
      if (route.overallRiskLevel == RiskLevel.low) {
        routeColor = Colors.green;
      } else if (route.overallRiskLevel == RiskLevel.medium) {
        routeColor = Colors.orange;
      } else {
        routeColor = Colors.red;
      }

      // Make selected route more prominent
      final color = isSelected ? routeColor : routeColor.withValues(alpha: 0.3);
      final width = isSelected ? 6.0 : 3.0;

      // Draw route polyline
      final paint = Paint()
        ..color = color
        ..strokeWidth = width
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;

      // Create path from waypoints
      final path = Path();
      bool first = true;
      for (final waypoint in route.waypoints) {
        final point = latLonToOffset(waypoint.latitude, waypoint.longitude);
        if (first) {
          path.moveTo(point.dx, point.dy);
          first = false;
        } else {
          path.lineTo(point.dx, point.dy);
        }
      }

      // Draw border for selected route
      if (isSelected) {
        final borderPaint = Paint()
          ..color = Colors.white
          ..strokeWidth = width + 3
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round;
        canvas.drawPath(path, borderPaint);
      }

      canvas.drawPath(path, paint);
    }

    // Draw route dots along the path for selected route
    if (selectedRouteIndex < routes.length) {
      final selectedRoute = routes[selectedRouteIndex];
      final dotPaint = Paint()
        ..color = Colors.white
        ..style = PaintingStyle.fill;

      for (int i = 0; i < selectedRoute.waypoints.length; i += 3) {
        final waypoint = selectedRoute.waypoints[i];
        final point = latLonToOffset(waypoint.latitude, waypoint.longitude);
        canvas.drawCircle(point, 2, dotPaint);
      }
    }
  }

  @override
  bool shouldRepaint(_RouteMapPainter oldDelegate) {
    return oldDelegate.selectedRouteIndex != selectedRouteIndex ||
        oldDelegate.routes.length != routes.length;
  }
}

// =============================================================================
// _ArrivalContactPicker — bottom-sheet multi-select
// =============================================================================

class _ArrivalContactPicker extends StatefulWidget {
  final List<Map<String, dynamic>> contacts;
  final String destination;
  /// Contacts that should be pre-ticked when the picker opens.
  /// Defaults to all contacts ticked when null.
  final List<Map<String, dynamic>>? preSelected;
  final String pickerTitle;
  final String pickerSubtitle;
  final String confirmLabel;

  const _ArrivalContactPicker({
    required this.contacts,
    required this.destination,
    this.preSelected,
    this.pickerTitle = 'You arrived! Who should know?',
    this.pickerSubtitle = 'Select contacts to notify about your safe arrival.',
    this.confirmLabel = 'Send to',
  });

  @override
  State<_ArrivalContactPicker> createState() => _ArrivalContactPickerState();
}

class _ArrivalContactPickerState extends State<_ArrivalContactPicker> {
  late List<bool> _selected;

  @override
  void initState() {
    super.initState();
    final preSelected = widget.preSelected;
    if (preSelected != null && preSelected.isNotEmpty) {
      // Tick only contacts that appear in preSelected (match by phone number).
      final prePhones = preSelected
          .map((c) => c['phone'] as String? ?? '')
          .toSet();
      _selected = widget.contacts
          .map((c) => prePhones.contains(c['phone'] as String? ?? ''))
          .toList();
    } else {
      _selected = List.filled(widget.contacts.length, true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final selectedCount = _selected.where((s) => s).length;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 40, height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey.shade300,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Container(
                  width: 40, height: 40,
                  decoration: BoxDecoration(
                    color: Colors.green.shade100,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(Icons.send_rounded,
                      color: Colors.green.shade700, size: 20),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.pickerTitle,
                        style: const TextStyle(
                            fontSize: 16, fontWeight: FontWeight.bold),
                      ),
                      Text(
                        widget.pickerSubtitle,
                        style: TextStyle(
                            fontSize: 12, color: Colors.grey.shade600),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            const Divider(height: 1),
            const SizedBox(height: 8),
            ...List.generate(widget.contacts.length, (i) {
              final c = widget.contacts[i];
              final name = c['name'] as String? ?? 'Unknown';
              final phone = c['phone'] as String? ?? '';
              final relationship = c['relationship'] as String? ?? '';
              final isPrimary = c['isPrimary'] == true;

              return CheckboxListTile(
                value: _selected[i],
                onChanged: (v) => setState(() => _selected[i] = v ?? false),
                activeColor: Colors.green,
                controlAffinity: ListTileControlAffinity.leading,
                contentPadding: EdgeInsets.zero,
                title: Row(
                  children: [
                    Expanded(
                      child: Text(name,
                          style: const TextStyle(
                              fontSize: 15, fontWeight: FontWeight.w600)),
                    ),
                    if (isPrimary)
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: Colors.green.shade50,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text('Primary',
                            style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                                color: Colors.green.shade700)),
                      ),
                  ],
                ),
                subtitle: Text(
                  relationship.isNotEmpty
                      ? '$relationship  ·  $phone'
                      : phone,
                  style: TextStyle(
                      fontSize: 12, color: Colors.grey.shade500),
                ),
              );
            }),
            const SizedBox(height: 8),
            Row(
              children: [
                TextButton(
                  onPressed: () => setState(
                      () => _selected.fillRange(0, _selected.length, true)),
                  child:
                      const Text('Select All', style: TextStyle(fontSize: 13)),
                ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: () => setState(
                      () => _selected.fillRange(0, _selected.length, false)),
                  child:
                      const Text('Clear All', style: TextStyle(fontSize: 13)),
                ),
              ],
            ),
            const SizedBox(height: 8),
            ElevatedButton.icon(
              onPressed: selectedCount == 0
                  ? null
                  : () {
                      final chosen = <Map<String, dynamic>>[];
                      for (int i = 0; i < widget.contacts.length; i++) {
                        if (_selected[i]) chosen.add(widget.contacts[i]);
                      }
                      Navigator.of(context).pop(chosen);
                    },
              icon: const Icon(Icons.send_rounded, size: 18),
              label: Text(
                selectedCount == 0
                    ? 'Select contacts to notify'
                    : '${widget.confirmLabel} $selectedCount contact${selectedCount == 1 ? '' : 's'}',
                style: const TextStyle(fontSize: 15),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.green.shade600,
                foregroundColor: Colors.white,
                disabledBackgroundColor: Colors.grey.shade300,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14)),
              ),
            ),
            const SizedBox(height: 4),
            TextButton(
              onPressed: () => Navigator.of(context).pop(null),
              child: Text('Skip',
                  style:
                      TextStyle(color: Colors.grey.shade500, fontSize: 13)),
            ),
          ],
        ),
      ),
    );
  }
}



