import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';
import '../config/backend_config.dart';

/// Service for verifying safe word with backend API
/// Implements confidence thresholding and multi-match verification
class SafeWordVerificationService {
  // URL comes from BackendConfig — change the URL there, not here.
  
  /// Verify safe word against backend API
  /// 
  /// Parameters:
  /// - sessionId: Unique session identifier (can be user ID + timestamp)
  /// - phrase: The recognized phrase from speech-to-text
  /// - confidence: Confidence score from speech recognition (0.0 to 1.0)
  /// - storedSafeWord: The user's stored safe word
  /// 
  /// Returns a verification result with detection status and reason
  static Future<SafeWordVerificationResult> verifySafeWord({
    required String sessionId,
    required String phrase,
    required double confidence,
    required String storedSafeWord,
  }) async {
    try {
      // Hard 1-second timeout so Panic Mode latency budget is never exceeded.
      final response = await http.post(
        Uri.parse(BackendConfig.safeWordVerify),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'session_id': sessionId,
          'phrase': phrase,
          'confidence': confidence,
          'stored_safe_word': storedSafeWord,
          'timestamp': DateTime.now().toIso8601String(),
        }),
      ).timeout(const Duration(seconds: 1));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        
        debugPrint('🔐 Safe Word Verification Response: $data');
        
        return SafeWordVerificationResult(
          detected: data['detected'] ?? false,
          confidence: (data['confidence'] ?? 0.0).toDouble(),
          reasonCode: data['reason_code'] ?? 'UNKNOWN',
          message: data['message'] ?? '',
          matchCount: data['match_count'] ?? 0,
          requiresMoreMatches: data['requires_more_matches'] ?? false,
          matchesNeeded: data['matches_needed'] ?? 0,
        );
      } else {
        debugPrint('❌ Safe Word Verification API error: ${response.statusCode}');
        return SafeWordVerificationResult.error(
          'API error: ${response.statusCode}',
        );
      }
    } on TimeoutException {
      debugPrint('⏰ Safe Word Verification timed out (>1 s) – falling back to local match');
      return SafeWordVerificationResult.error('Timeout – local fallback');
    } catch (e) {
      debugPrint('❌ Safe Word Verification network error: $e');
      return SafeWordVerificationResult.error(
        'Network error: $e',
      );
    }
  }

  /// Get current verification configuration from API
  static Future<SafeWordConfig?> getConfig() async {
    try {
      final response = await http.get(
        Uri.parse(BackendConfig.safeWordConfig),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return SafeWordConfig.fromJson(data);
      }
      return null;
    } catch (e) {
      debugPrint('❌ Failed to get safe word config: $e');
      return null;
    }
  }
}

/// Result of safe word verification
class SafeWordVerificationResult {
  final bool detected;
  final double confidence;
  final String reasonCode;
  final String message;
  final int matchCount;
  final bool requiresMoreMatches;
  final int matchesNeeded;
  final bool isError;

  SafeWordVerificationResult({
    required this.detected,
    required this.confidence,
    required this.reasonCode,
    required this.message,
    required this.matchCount,
    required this.requiresMoreMatches,
    this.matchesNeeded = 0,
    this.isError = false,
  });

  factory SafeWordVerificationResult.error(String message) {
    return SafeWordVerificationResult(
      detected: false,
      confidence: 0.0,
      reasonCode: 'ERROR',
      message: message,
      matchCount: 0,
      requiresMoreMatches: false,
      isError: true,
    );
  }

  /// Check if this is a successful verification
  bool get isVerified => detected && reasonCode == 'VERIFIED';

  /// Check if we need to try again
  bool get shouldRetry => requiresMoreMatches && !isError;

  /// Get user-friendly status message
  String get statusMessage {
    switch (reasonCode) {
      case 'VERIFIED':
        return '✅ Safe word verified! ($matchCount matches)';
      case 'INSUFFICIENT_MATCHES':
        return '⏳ Say safe word $matchesNeeded more time(s)';
      case 'LOW_CONFIDENCE':
        return '🎤 Speak more clearly';
      case 'PHRASE_MISMATCH':
        return '❌ Safe word not recognized';
      case 'ERROR':
        return '⚠️ Verification error';
      default:
        return message;
    }
  }
}

/// Safe word verification configuration
class SafeWordConfig {
  final double confidenceThreshold;
  final int verificationWindowSeconds;
  final int requiredMatches;
  final double minMatchScore;

  SafeWordConfig({
    required this.confidenceThreshold,
    required this.verificationWindowSeconds,
    required this.requiredMatches,
    required this.minMatchScore,
  });

  factory SafeWordConfig.fromJson(Map<String, dynamic> json) {
    return SafeWordConfig(
      confidenceThreshold: (json['confidence_threshold'] ?? 0.75).toDouble(),
      verificationWindowSeconds: json['verification_window_seconds'] ?? 30,
      requiredMatches: json['required_matches'] ?? 2,
      minMatchScore: (json['min_match_score'] ?? 0.65).toDouble(),
    );
  }

  @override
  String toString() {
    return 'SafeWordConfig(confidence: $confidenceThreshold, '
        'window: ${verificationWindowSeconds}s, '
        'matches: $requiredMatches, '
        'minScore: $minMatchScore)';
  }
}
