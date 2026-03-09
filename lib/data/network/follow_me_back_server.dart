import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';
import '../../core/config/app_config.dart';

class FollowMeBackServer {
  /// Fetches dynamic TURN credentials from the FollowMeBack.io REST API
  static Future<List<Map<String, dynamic>>> fetchIceServers() async {
    try {
      final response = await http.get(
        Uri.parse(
          '${AppConfig.followMeBackRestUrl}?apiKey=${AppConfig.followMeBackApiKey}',
        ),
      );

      if (response.statusCode == 200) {
        final List<dynamic> data = jsonDecode(response.body);
        // Cast to the format expected by flutter_webrtc
        return data.map((e) => Map<String, dynamic>.from(e)).toList();
      } else {
        throw Exception(
          'Failed to fetch TURN credentials: ${response.statusCode}',
        );
      }
    } catch (e) {
      // In case of HTTP/Network failure, return a fallback STUN server
      // so the WebRTC connection can at least attempt a local P2P connection.
      debugPrint('Error fetching FollowMeBack.io API credentials: $e');
      return [
        {'urls': 'stun:stun.l.google.com:19302'},
        {'urls': 'stun:stun1.l.google.com:19302'},
      ];
    }
  }

  /// Sends the new SDP Offer or Answer to the Cloud Function to help re-establish connection
  static Future<bool> postReconnectionData({
    required String uuid,
    required String role,
    required String iceData,
  }) async {
    try {
      final response = await http.post(
        Uri.parse(AppConfig.restablishCommunicationUrl),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'uuid': uuid, 'role': role, 'iceData': iceData}),
      );
      return response.statusCode == 200 || response.statusCode == 201;
    } catch (e) {
      debugPrint('Error posting reconnection data: $e');
      return false;
    }
  }

  /// Polls the Cloud Function for the peer's new SDP
  static Future<String?> pollReconnectionData({
    required String uuid,
    required String targetRole,
  }) async {
    try {
      final response = await http.get(
        Uri.parse(
          '${AppConfig.restablishCommunicationUrl}?uuid=$uuid&role=$targetRole',
        ),
      );
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['iceData'] != null && data['iceData'].toString().isNotEmpty) {
          return data['iceData'];
        }
      }
      return null;
    } catch (e) {
      debugPrint('Error polling reconnection data: $e');
      return null;
    }
  }

  /// Registers the Session UUID on the backend to allow future reconnections
  static Future<bool> initializeSession(String uuid) async {
    try {
      final response = await http.post(
        Uri.parse('${AppConfig.restablishCommunicationUrl}/handShake'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'uuid': uuid}),
      );
      return response.statusCode == 200;
    } catch (e) {
      debugPrint('Error initializing session on backend: $e');
      return false;
    }
  }
}
