import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../models/safety_guidance.dart';

/// Service that loads and queries the safety-guidance dataset (B3).
///
/// Provides contextual, calm, evidence-based advice drawn from reputable
/// sources (police, university research, women's safety organisations).
class SafetyGuidanceService {
  // ---------------------------------------------------------------------------
  // Singleton
  // ---------------------------------------------------------------------------
  static final SafetyGuidanceService _instance =
      SafetyGuidanceService._internal();
  factory SafetyGuidanceService() => _instance;
  SafetyGuidanceService._internal();

  // ---------------------------------------------------------------------------
  // State
  // ---------------------------------------------------------------------------
  List<SafetyGuidance> _entries = [];
  bool _isInitialized = false;
  final _random = math.Random();

  // ---------------------------------------------------------------------------
  // Initialisation
  // ---------------------------------------------------------------------------

  Future<void> initialize() async {
    if (_isInitialized) return;

    try {
      final csvData =
          await rootBundle.loadString('assets/safety_guidance.csv');
      _entries = _parseCsv(csvData);
      _isInitialized = true;
      debugPrint(
          '✅ SafetyGuidanceService initialised with ${_entries.length} entries');
    } catch (e) {
      debugPrint('❌ Error loading safety guidance: $e');
      _entries = [];
      _isInitialized = true;
    }
  }

  // ---------------------------------------------------------------------------
  // CSV parsing
  // ---------------------------------------------------------------------------

  List<SafetyGuidance> _parseCsv(String csvData) {
    final results = <SafetyGuidance>[];
    final lines = const LineSplitter().convert(csvData);

    for (var i = 1; i < lines.length; i++) {
      final line = lines[i].trim();
      if (line.isEmpty) continue;

      try {
        final fields = _splitCsvLine(line);
        if (fields.length >= 5) {
          results.add(SafetyGuidance.fromCsvRow(fields));
        }
      } catch (e) {
        debugPrint('Warning: Could not parse guidance CSV line $i: $e');
      }
    }
    return results;
  }

  List<String> _splitCsvLine(String line) {
    final fields = <String>[];
    final buf = StringBuffer();
    var inQuotes = false;

    for (var i = 0; i < line.length; i++) {
      final ch = line[i];
      if (ch == '"') {
        inQuotes = !inQuotes;
      } else if (ch == ',' && !inQuotes) {
        fields.add(buf.toString().trim());
        buf.clear();
      } else {
        buf.write(ch);
      }
    }
    fields.add(buf.toString().trim());
    return fields;
  }

  // ---------------------------------------------------------------------------
  // Public queries
  // ---------------------------------------------------------------------------

  /// Return all entries.
  List<SafetyGuidance> get allEntries => List.unmodifiable(_entries);

  /// Filter by one or more categories.
  List<SafetyGuidance> getByCategories(List<GuidanceCategory> categories) {
    return _entries
        .where((e) => categories.contains(e.category))
        .toList();
  }

  /// Get a single random guidance entry (for reassurance cards).
  SafetyGuidance? getRandomTip() {
    if (_entries.isEmpty) return null;
    return _entries[_random.nextInt(_entries.length)];
  }

  /// Get a random tip from the specified categories.
  SafetyGuidance? getRandomTipFor(List<GuidanceCategory> categories) {
    final filtered = getByCategories(categories);
    if (filtered.isEmpty) return null;
    return filtered[_random.nextInt(filtered.length)];
  }

  /// Get guidance relevant to route planning.
  List<SafetyGuidance> getRouteGuidance() {
    return getByCategories([
      GuidanceCategory.routeSafety,
      GuidanceCategory.awareness,
      GuidanceCategory.preparedness,
    ]);
  }

  /// Get guidance relevant to an active safety/panic situation.
  List<SafetyGuidance> getThreatGuidance() {
    return getByCategories([
      GuidanceCategory.threatResponse,
      GuidanceCategory.awareness,
    ]);
  }

  /// Get guidance relevant to transport (bus stop, ride-share, etc.).
  List<SafetyGuidance> getTransportGuidance() {
    return getByCategories([GuidanceCategory.transportSafety]);
  }

  // ── Stop words filtered before keyword matching ──────────────────────────
  static const _stopWords = {
    'i', 'im', 'am', 'me', 'my', 'a', 'an', 'the', 'is', 'are', 'was',
    'be', 'been', 'being', 'to', 'of', 'and', 'or', 'in', 'on', 'at',
    'by', 'for', 'with', 'this', 'that', 'it', 'do', 'did', 'have',
    'has', 'had', 'not', 'no', 'so', 'if', 'but', 'can', 'will', 'would',
    'should', 'get', 'got', 'go', 'going', 'there', 'here', 'what', 'when',
    'how', 'who', 'its', 'they', 'them', 'their', 'we', 'us', 'he', 'she',
    'you', 'your', 'from', 'about', 'very', 'just', 'also', 'some', 'feel',
    'feels', 'feeling', 'think', 'someone', 'something', 'really',
  };

  // ── Synonym/alias map: user word → words to match in dataset ─────────────
  static const _synonyms = <String, List<String>>{
    'followed':   ['followed', 'following', 'follow'],
    'following':  ['followed', 'following', 'follow'],
    'stalked':    ['followed', 'following', 'stalker'],
    'stalking':   ['followed', 'following', 'stalker'],
    'scared':     ['threat', 'uncomfortable', 'unsafe', 'worry'],
    'unsafe':     ['threat', 'uncomfortable', 'unsafe'],
    'afraid':     ['threat', 'uncomfortable', 'unsafe'],
    'dark':       ['night', 'lit', 'lighting'],
    'night':      ['night', 'dark', 'lit'],
    'alone':      ['alone', 'isolated', 'solo'],
    'attacked':   ['threat', 'assault', 'attack'],
    'attack':     ['threat', 'assault', 'attack'],
    'assaulted':  ['threat', 'assault', 'attack'],
    'grabbed':    ['kidnap', 'grabbed', 'forcibly', 'assault', 'attack', 'threat'],
    'run':        ['running', 'jog', 'jogging', 'exercise'],
    'running':    ['running', 'jogging', 'exercise'],
    'jogging':    ['running', 'jogging', 'exercise'],
    'bus':        ['transport', 'bus', 'travel'],
    'train':      ['transport', 'travel'],
    'tube':       ['transport', 'travel'],
    'cab':        ['ride', 'taxi', 'uber', 'transport'],
    'taxi':       ['ride', 'taxi', 'transport'],
    'uber':       ['ride-share', 'ride', 'transport'],
    'rideshare':  ['ride-share', 'ride', 'transport'],
    'drink':      ['drink', 'spiking', 'alcohol'],
    'spiked':     ['drink', 'spiking'],
    'drugged':    ['drink', 'spiking'],
    'home':       ['home', 'door', 'arriving'],
    'door':       ['home', 'door', 'arriving'],
    'keys':       ['home', 'door', 'arriving', 'keys'],
    'wifi':       ['wi-fi', 'wifi', 'internet'],
    'internet':   ['wi-fi', 'wifi', 'internet', 'digital'],
    'phone':      ['phone', 'mobile', 'battery'],
    'battery':    ['battery', 'phone', 'charge'],
    'atm':        ['atm', 'cash', 'money'],
    'cash':       ['atm', 'cash', 'money', 'financial'],
    'park':       ['park', 'alley', 'shortcut', 'route'],
    'alley':      ['alley', 'shortcut', 'route', 'dark'],
    'shortcut':   ['shortcut', 'route', 'alley'],
    'headphones': ['headphones', 'earphone', 'music', 'aware'],
    'earphones':  ['headphones', 'earphone', 'music', 'aware'],
    'dog':        ['dog', 'walking', 'route'],
    'aggressive': ['aggressive', 'group', 'threat', 'behaving'],
    'group':      ['group', 'aggressive', 'crowd'],
    'uncomfortable': ['uncomfortable', 'threat', 'unsafe'],
    'carpark':    ['car park', 'parking', 'transport'],
    'parking':    ['car park', 'parking', 'transport'],
    // social safety
    'date':       ['online', 'meeting', 'dating', 'first'],
    'dating':     ['online', 'meeting', 'dating', 'first'],
    'tinder':     ['online', 'meeting', 'dating'],
    'bumble':     ['online', 'meeting', 'dating'],
    'online':     ['online', 'meeting', 'internet', 'digital'],
    'stranger':   ['online', 'meeting', 'unfamiliar'],
    'harassed':   ['harassment', 'unwanted', 'uncomfortable'],
    'harassment': ['harassment', 'unwanted', 'uncomfortable'],
    'stalker':    ['followed', 'harassment', 'unwanted', 'messages'],
    'messages':   ['messages', 'contact', 'harassment'],
    'texts':      ['messages', 'contact', 'harassment'],
    'photo':      ['photograph', 'filmed', 'consent', 'image'],
    'photos':     ['photograph', 'filmed', 'consent', 'image'],
    'filmed':     ['filmed', 'photograph', 'consent', 'image'],
    'recorded':   ['filmed', 'photograph', 'consent', 'image'],
    'pressure':   ['pressure', 'peer', 'uncomfortable', 'unsafe'],
    'pressured':  ['pressure', 'peer', 'forced', 'unsafe'],
    'forced':     ['pressure', 'peer', 'unsafe', 'threat'],
    'party':      ['social', 'event', 'nightlife', 'drink'],
    'nightclub':  ['nightlife', 'social', 'drink', 'party'],
    'club':       ['nightlife', 'social', 'drink', 'party'],
    'address':    ['address', 'personal', 'sharing', 'information'],
    'personal':   ['personal', 'information', 'details', 'sharing'],
    'blocked':    ['block', 'messages', 'contact', 'harassment'],
    'block':      ['block', 'messages', 'contact', 'harassment'],
    // kidnapping / abduction
    'kidnapped':  ['kidnap', 'grabbed', 'forcibly', 'taken', 'abduct'],
    'kidnapping': ['kidnap', 'grabbed', 'forcibly', 'taken', 'abduct'],
    'abducted':   ['kidnap', 'grabbed', 'forcibly', 'taken', 'abduct'],
    'abduction':  ['kidnap', 'grabbed', 'forcibly', 'taken', 'abduct'],
    'dragged':    ['kidnap', 'grabbed', 'forcibly', 'taken'],
    'taken':      ['kidnap', 'grabbed', 'forcibly', 'taken'],
    'van':        ['kidnap', 'grabbed', 'forcibly', 'taken', 'transport'],
    'car':        ['kidnap', 'grabbed', 'forcibly', 'transport'],
    // emotional / stress / lost
    'panic':      ['panic', 'panicking', 'overwhelmed', 'scared', 'crisis'],
    'panicking':  ['panic', 'overwhelmed', 'crisis', 'scared'],
    'anxious':    ['anxious', 'anxiety', 'stressed', 'overwhelmed', 'worried'],
    'anxiety':    ['anxious', 'anxiety', 'stressed', 'overwhelmed'],
    'stressed':   ['stressed', 'anxious', 'overwhelmed', 'worried'],
    'stress':     ['stressed', 'anxious', 'overwhelmed'],
    'overwhelmed':['overwhelmed', 'panic', 'anxious', 'stressed'],
    'worried':    ['worried', 'anxious', 'unsafe', 'scared'],
    'lost':       ['lost', 'unfamiliar', 'unsure', 'surroundings'],
    'confused':   ['confused', 'lost', 'unsure', 'surroundings'],
    'help':       ['help', 'unsafe', 'danger', 'emergency', 'call'],
    'emergency':  ['emergency', 'danger', 'help', '999', 'call'],
    'police':     ['police', '999', 'call', 'report'],
    'crying':     ['overwhelmed', 'distressed', 'panicked'],
    'upset':      ['overwhelmed', 'distressed', 'uncomfortable'],
    'watched':    ['watched', 'followed', 'instinct', 'wrong'],
    'watching':   ['watched', 'followed', 'instinct', 'wrong'],
    // bullying
    'bully':      ['bully', 'bullying', 'harassment', 'abuse'],
    'bullied':    ['bully', 'bullying', 'harassment', 'abuse'],
    'bullying':   ['bully', 'bullying', 'harassment', 'abuse'],
    'cyberbully': ['cyberbullying', 'online', 'messages', 'abuse'],
    'mean':       ['bully', 'bullying', 'uncomfortable', 'harassment'],
    'threats':    ['threat', 'bully', 'harassment', 'unsafe'],
  };

  /// Tokenized keyword search — splits query into meaningful words,
  /// expands synonyms, then returns entries scored by how many keywords
  /// match across situation, advice, and why fields.
  List<SafetyGuidance> search(String query) {
    // 1. Tokenise
    final raw = query
        .toLowerCase()
        .replaceAll(RegExp(r"[^a-z0-9 ]"), ' ')
        .split(RegExp(r'\s+'))
        .where((w) => w.length > 2 && !_stopWords.contains(w))
        .toList();

    if (raw.isEmpty) return [];

    // 2. Expand synonyms
    final keywords = <String>{};
    for (final word in raw) {
      keywords.add(word);
      final aliases = _synonyms[word];
      if (aliases != null) keywords.addAll(aliases);
    }

    // 3. Score each entry
    final scored = <({SafetyGuidance entry, int score})>[];
    for (final e in _entries) {
      final haystack =
          '${e.situation} ${e.advice} ${e.why} ${e.category.name}'
              .toLowerCase();
      int score = 0;
      for (final kw in keywords) {
        if (haystack.contains(kw)) score++;
      }
      if (score > 0) scored.add((entry: e, score: score));
    }

    // 4. Sort by relevance descending
    scored.sort((a, b) => b.score.compareTo(a.score));
    return scored.map((r) => r.entry).toList();
  }

  bool get isInitialized => _isInitialized;
}
