import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../models/risk_zone.dart';

// =============================================================================
// UkPoliceApiService — live crime data → clustered RiskZone objects
// =============================================================================
//
// Calls the public UK Police street-level crimes endpoint:
//   https://data.police.uk/api/crimes-street/all-crime?lat=&lng=&date=
//
// The API returns all recorded street crimes within ~1 mile of the given
// coordinates for the requested month.  Because the dataset is published
// with a ~2-month lag, we try months going back until we receive data.
//
// Crime incidents are clustered into ~110 m grid cells.  Each cell with
// enough incidents becomes a RiskZone whose risk level and score are
// based on incident count and crime-category severity weights.
//
// On any network or parse failure the method returns an empty list so the
// caller falls back to its local CSV or cached data gracefully.
// =============================================================================

class UkPoliceApiService {
  static final UkPoliceApiService _instance = UkPoliceApiService._internal();
  factory UkPoliceApiService() => _instance;
  UkPoliceApiService._internal();

  // ── Crime-category severity weights ────────────────────────────────────────
  // Higher weight → more influence on the cluster's final risk score.
  static const Map<String, double> _severity = {
    'violent-crime':             3.0,
    'robbery':                   3.0,
    'possession-of-weapons':     2.5,
    'public-order':              2.5,
    'criminal-damage-arson':     2.0,
    'drugs':                     2.0,
    'burglary':                  2.0,
    'vehicle-crime':             1.5,
    'other-theft':               1.2,
    'bicycle-theft':             1.0,
    'shoplifting':               1.0,
    'anti-social-behaviour':     1.0,
    'other-crime':               1.0,
  };

  /// Grid-cell size in decimal degrees.
  /// At UK latitudes (~52°) this is roughly 111 m (lat) × 68 m (lon).
  static const double _gridDeg = 0.001;

  /// Minimum weighted severity score for a cluster to become a RiskZone.
  /// Clusters below this threshold are considered too sparse to be notable.
  static const double _minWeight = 3.0;

  /// Maximum number of zones returned — keeps the in-memory list bounded.
  static const int _maxZones = 60;

  // ── Public API ──────────────────────────────────────────────────────────────

  /// Fetch risk zones near [lat], [lon] using the UK Police street-crimes API.
  ///
  /// Returns an empty list when the device is offline, the API is unavailable,
  /// or no usable data is returned for the area.
  Future<List<RiskZone>> fetchRiskZonesNearby(double lat, double lon) async {
    debugPrint('🔍 [PoliceAPI] Fetching live crimes near ($lat, $lon)…');
    try {
      final crimes = await _fetchCrimes(lat, lon);
      if (crimes.isEmpty) {
        debugPrint('⚠️ [PoliceAPI] No crime records received — '
            'returning empty list (caller will use cached/CSV data)');
        return [];
      }
      final zones = _clusterIntoZones(crimes);
      debugPrint(
        '✅ [PoliceAPI] Clustered ${crimes.length} crimes into '
        '${zones.length} risk zones',
      );
      return zones;
    } on SocketException {
      debugPrint('🔴 [PoliceAPI] Network unavailable — cannot fetch live data');
      return [];
    } on TimeoutException {
      debugPrint('⏱️ [PoliceAPI] Request timed out — returning empty list');
      return [];
    } catch (e) {
      debugPrint('❌ [PoliceAPI] Unexpected error: $e');
      return [];
    }
  }

  // ── Private: HTTP fetch ─────────────────────────────────────────────────────

  /// Try months going back from 2 to 5 months ago (API has ~2-month lag).
  /// Returns the first non-empty list of crime records found.
  Future<List<Map<String, dynamic>>> _fetchCrimes(
      double lat, double lon) async {
    final now = DateTime.now();

    for (int monthsBack = 2; monthsBack <= 5; monthsBack++) {
      // DateTime handles month wrap-around correctly (e.g. month 0 → December
      // of the previous year).
      final target = DateTime(now.year, now.month - monthsBack, 1);
      final monthStr =
          '${target.year}-${target.month.toString().padLeft(2, '0')}';

      final uri = Uri.https(
        'data.police.uk',
        '/api/crimes-street/all-crime',
        {
          'lat': lat.toStringAsFixed(6),
          'lng': lon.toStringAsFixed(6),
          'date': monthStr,
        },
      );

      debugPrint('🌐 [PoliceAPI] GET crimes for $monthStr…');

      try {
        final response = await http.get(
          uri,
          headers: {'User-Agent': 'SheSafe-FYP-App/1.0 (dissertation project)'},
        ).timeout(const Duration(seconds: 20));

        if (response.statusCode == 200) {
          final body = response.body.trim();
          if (body.isEmpty || body == '[]') {
            debugPrint(
                '⚠️ [PoliceAPI] Empty body for $monthStr — trying earlier month');
            continue;
          }
          final data = jsonDecode(body) as List<dynamic>;
          debugPrint(
              '✅ [PoliceAPI] Received ${data.length} crime records for $monthStr');
          return data.cast<Map<String, dynamic>>();
        } else if (response.statusCode == 404) {
          debugPrint(
              '⚠️ [PoliceAPI] 404 for $monthStr — trying earlier month');
          continue;
        } else {
          debugPrint(
              '⚠️ [PoliceAPI] HTTP ${response.statusCode} for $monthStr');
        }
      } on TimeoutException {
        debugPrint('⏱️ [PoliceAPI] Timed out for $monthStr — aborting retries');
        break;
      } on SocketException {
        debugPrint('🔴 [PoliceAPI] Network error for $monthStr — aborting');
        rethrow; // handled in fetchRiskZonesNearby
      } catch (e) {
        debugPrint('❌ [PoliceAPI] Error for $monthStr: $e');
        break;
      }
    }

    debugPrint('⚠️ [PoliceAPI] No data found across all attempted months');
    return [];
  }

  // ── Private: clustering ─────────────────────────────────────────────────────

  /// Group crime points into ~110 m grid cells and convert each qualifying
  /// cluster into a [RiskZone].
  List<RiskZone> _clusterIntoZones(List<Map<String, dynamic>> crimes) {
    final Map<String, List<Map<String, dynamic>>> grid = {};

    for (final crime in crimes) {
      final loc = crime['location'] as Map<String, dynamic>?;
      if (loc == null) continue;
      final latStr = loc['latitude']  as String?;
      final lonStr = loc['longitude'] as String?;
      if (latStr == null || lonStr == null) continue;
      final cLat = double.tryParse(latStr);
      final cLon = double.tryParse(lonStr);
      if (cLat == null || cLon == null) continue;

      // Round to grid — identical keys group nearby crimes together.
      final key =
          '${(cLat / _gridDeg).round()}:${(cLon / _gridDeg).round()}';
      grid.putIfAbsent(key, () => []).add({
        ...crime,
        '__lat': cLat,
        '__lon': cLon,
      });
    }

    final zones = <RiskZone>[];

    for (final clusterCrimes in grid.values) {
      // ── Centroid ──────────────────────────────────────────────────────────
      var sumLat = 0.0, sumLon = 0.0;
      for (final c in clusterCrimes) {
        sumLat += c['__lat'] as double;
        sumLon += c['__lon'] as double;
      }
      final centLat = sumLat / clusterCrimes.length;
      final centLon = sumLon / clusterCrimes.length;

      // ── Weighted severity ─────────────────────────────────────────────────
      var weighted = 0.0;
      for (final c in clusterCrimes) {
        final cat = c['category'] as String? ?? 'other-crime';
        weighted += _severity[cat] ?? 1.0;
      }
      if (weighted < _minWeight) continue;

      // ── Risk level ────────────────────────────────────────────────────────
      final RiskLevel level;
      if (weighted >= 15.0) {
        level = RiskLevel.high;
      } else if (weighted >= 7.0) {
        level = RiskLevel.medium;
      } else {
        level = RiskLevel.low;
      }

      // ── Risk score 0–100 (capped at weighted value of 30 = 100) ──────────
      final score = (weighted / 30.0 * 100.0).clamp(0.0, 100.0);

      // ── Radius: 80 m base + 10 m per 5 incidents, capped at 200 m ────────
      final radius =
          (80.0 + (clusterCrimes.length / 5.0) * 10.0).clamp(80.0, 200.0);

      // ── Zone name from first incident's street name ───────────────────────
      final street = _streetName(clusterCrimes.first);
      final zoneName = street.isNotEmpty ? street : '${level.displayName} Area';

      // ── Description: top 3 crime categories ──────────────────────────────
      final catCounts = <String, int>{};
      for (final c in clusterCrimes) {
        final cat = c['category'] as String? ?? 'other-crime';
        catCounts[cat] = (catCounts[cat] ?? 0) + 1;
      }
      final top = catCounts.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      final topDesc = top
          .take(3)
          .map((e) => '${e.value}× ${_humanCategory(e.key)}')
          .join(', ');
      final desc = '$topDesc (${clusterCrimes.length} incidents)';

      zones.add(RiskZone(
        latitude:     centLat,
        longitude:    centLon,
        radiusMeters: radius,
        riskLevel:    level,
        riskScore:    score,
        severity:     level == RiskLevel.high ? 4 : (level == RiskLevel.medium ? 3 : 2),
        zoneName:     zoneName,
        description:  desc,
      ));
    }

    // Return top zones sorted by risk score.
    zones.sort((a, b) => b.riskScore.compareTo(a.riskScore));
    return zones.take(_maxZones).toList();
  }

  // ── Helpers ─────────────────────────────────────────────────────────────────

  String _streetName(Map<String, dynamic> crime) {
    try {
      final loc    = crime['location'] as Map<String, dynamic>?;
      final street = loc?['street']   as Map<String, dynamic>?;
      final name   = street?['name']  as String? ?? '';
      // Strip the "On or near " prefix the API prepends.
      return name
          .replaceFirst(RegExp(r'^On or near ', caseSensitive: false), '')
          .trim();
    } catch (_) {
      return '';
    }
  }

  String _humanCategory(String category) => category
      .replaceAll('-', ' ')
      .split(' ')
      .map((w) => w.isEmpty ? '' : '${w[0].toUpperCase()}${w.substring(1)}')
      .join(' ');
}
