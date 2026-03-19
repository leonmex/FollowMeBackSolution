import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';
import '../../../core/config/app_config.dart';

/// Server implementation for the unified WebRTC TURN & Signaling Service v1.
class ApiV1WebRTCServer {
  static String get _apiKeyParam {
    final apiKey = AppConfig.useApiV1Webrtc ? AppConfig.apiV1ApiKey : AppConfig.followMeBackApiKey;
    return 'apiKey=$apiKey';
  }

  static Map<String, String> get _headers => {
        'Content-Type': 'application/json',
      };

  /// Fetches dynamic TURN credentials from the v1 metered endpoint
  static Future<Map<String, dynamic>> fetchIceServers({String? sessionId}) async {
    try {
      final url = sessionId != null 
          ? '${AppConfig.apiV1BaseUrl}/turn/metered?$_apiKeyParam&session_uuid=$sessionId'
          : '${AppConfig.apiV1BaseUrl}/turn/metered?$_apiKeyParam';
      final response = await http
          .get(
            Uri.parse(url),
            headers: _headers,
          )
          .timeout(const Duration(seconds: AppConfig.signalingTimeoutSeconds));

      if (response.statusCode == 200) {
        return jsonDecode(response.body);
      } else {
        debugPrint('ApiV1 Fetch ICE error response: ${response.body}');
        throw Exception(
          'Failed to fetch API v1 TURN credentials: ${response.statusCode}',
        );
      }
    } catch (e) {
      debugPrint('Error fetching API v1 Credentials: $e');
      return {
        'sessionId': sessionId ?? '',
        'iceServers': [
          {'urls': 'stun:stun.l.google.com:19302'},
          {'urls': 'stun:stun1.l.google.com:19302'},
        ],
      };
    }
  }

  /// Hits the /api/v1/turn/refresh endpoint with the extracted peer_uuid
  static Future<Map<String, dynamic>> refreshIceServers({required String peerUuid}) async {
    try {
      final url = '${AppConfig.apiV1BaseUrl}/turn/refresh?uuid=$peerUuid&$_apiKeyParam';
      final response = await http
          .get(
            Uri.parse(url),
            headers: _headers,
          )
          .timeout(const Duration(seconds: AppConfig.signalingTimeoutSeconds));

      if (response.statusCode == 200) {
        final List<dynamic> array = jsonDecode(response.body);
        return {'ice_servers': array};
      } else {
        debugPrint('ApiV1 Refresh ICE error response: ${response.statusCode} - ${response.body}');
        return {};
      }
    } catch (e) {
      debugPrint('Error refreshing API v1 Credentials: $e');
      return {};
    }
  }

  /// Sends the SDP tracking offer or answer
  static Future<bool> postReconnectionData({
    required String sessionUuid,
    required String peerUuid,
    required String role,
    required Map<String, dynamic> iceData,
  }) async {
    try {
      final response = await http
          .post(
            Uri.parse('${AppConfig.apiV1BaseUrl}/signaling?$_apiKeyParam'),
            headers: _headers,
            body: jsonEncode({
              'session_uuid': sessionUuid,
              'peer_uuid': peerUuid,
              'role': role,
              'iceData': iceData,
            }),
          )
          .timeout(const Duration(seconds: AppConfig.signalingTimeoutSeconds));
      if (response.statusCode != 200 && response.statusCode != 201) {
        debugPrint('ApiV1 POST signaling error: ${response.statusCode} - ${response.body}');
        return false;
      }
      return true;
    } catch (e) {
      debugPrint('ApiV1 Error posting reconnection data: $e');
      if (e is SocketException || e.toString().contains('SocketException') || e is TimeoutException) {
        rethrow;
      }
      return false;
    }
  }

  /// Polls the API for the peer's SDP
  static Future<String?> pollReconnectionData({
    required String sessionUuid,
    required String role,
  }) async {
    try {
      final response = await http
          .get(
            Uri.parse(
              '${AppConfig.apiV1BaseUrl}/signaling?session_uuid=$sessionUuid&role=$role&$_apiKeyParam',
            ),
            headers: _headers,
          )
          .timeout(const Duration(seconds: AppConfig.signalingTimeoutSeconds));

      if (response.statusCode == 200) {
        final Map<String, dynamic> data = jsonDecode(response.body);
        return jsonEncode(data['iceData']);
      }
      return null; // 204 No Content handling
    } catch (e) {
      debugPrint('ApiV1 Error polling reconnection data: $e');
      if (e is SocketException || e.toString().contains('SocketException') || e is TimeoutException) {
        rethrow;
      }
      return null;
    }
  }

  /// Registers the Session UUID on the backend
  static Future<bool> initializeSession({
    required String sessionUuid,
    required String peerUuid,
    required String role,
  }) async {
    try {
      final response = await http
          .post(
            Uri.parse('${AppConfig.apiV1BaseUrl}/signaling/handShake?$_apiKeyParam'),
            headers: _headers,
            body: jsonEncode({
              'session_uuid': sessionUuid,
              'peer_uuid': peerUuid,
              'role': role,
            }),
          )
          .timeout(const Duration(seconds: AppConfig.signalingTimeoutSeconds));
      if (response.statusCode != 200) {
        debugPrint('ApiV1 POST handshake error: ${response.statusCode} - ${response.body}');
        return false;
      }
      return true;
    } catch (e) {
      debugPrint('ApiV1 Error initializing session: $e');
      return false;
    }
  }
}
