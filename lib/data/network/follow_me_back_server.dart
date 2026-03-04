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
}
