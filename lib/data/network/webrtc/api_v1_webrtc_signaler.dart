import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'webrtc_signaler.dart';
import 'api_v1_webrtc_server.dart';
import '../../../core/config/app_config.dart';

/// WebRTC signaler implementation for the new API v1.
/// Maps domain actions to the `/api/v1` REST endpoints.
class ApiV1WebRTCSignaler extends WebRTCSignaler {
  const ApiV1WebRTCSignaler();

  @override
  Future<void> initializeSession({
    required String uuid,
    required String peerId,
    required String role,
  }) async {
    await throttle();
    final success = await ApiV1WebRTCServer.initializeSession(
      sessionUuid: uuid,
      peerUuid: peerId,
      role: role,
    );
    if (!success) {
      throw Exception('Failed to initialize signaling session on API v1');
    }
  }

  @override
  Future<bool> postData({
    required String uuid,
    required String role,
    required String data,
    required String peerId,
  }) async {
    await throttle();
    
    Map<String, dynamic> iceData;
    try {
      iceData = jsonDecode(data);
    } catch (e) {
      debugPrint('ApiV1WebRTCSignaler: Error decoding payload data: $e');
      return false;
    }

    return await ApiV1WebRTCServer.postReconnectionData(
      sessionUuid: uuid,
      peerUuid: peerId,
      role: role,
      iceData: iceData,
    );
  }

  @override
  Future<String?> pollData({
    required String uuid,
    required String targetRole,
    required String peerId,
  }) async {
    await throttle();
    return await ApiV1WebRTCServer.pollReconnectionData(
      sessionUuid: uuid,
      role: targetRole,
    );
  }

  @override
  Future<TurnResponse> fetchIceServers({String? sessionId}) async {
    await throttle();
    final data = await ApiV1WebRTCServer.fetchIceServers(sessionId: sessionId);
    return _parseTurnResponse(data, sessionId);
  }

  @override
  Future<TurnResponse> refreshIceServers({required String peerUuid}) async {
    await throttle();
    try {
      final data = await ApiV1WebRTCServer.refreshIceServers(peerUuid: peerUuid);
      return _parseTurnResponse(data, null);
    } catch (e) {
      // Refresh endpoint failed (network transition: WiFi→5G gap, server error).
      // Fall back to a full fresh credential fetch so we always get TURN relay.
      debugPrint('ApiV1: refreshIceServers failed ($e) — falling back to fetchIceServers.');
      return fetchIceServers();
    }
  }

  TurnResponse _parseTurnResponse(Map<String, dynamic> data, String? fallbackSessionId) {
    List<Map<String, dynamic>> serversList = [];
    String extractedPeerUuid = '';

    if (data['ice_servers'] != null) {
      final List<dynamic> servers = data['ice_servers'];
      serversList = servers.map((e) => Map<String, dynamic>.from(e)).toList();

      if (serversList.isNotEmpty) {
        for (var i = 0; i < serversList.length; i++) {
          final server = serversList[i];
          
          // Temporary Patch: Replace backend placeholder domain with active server IP.
          // Remove once the Go backend config.json has the correct TurnPublicHostname.
          if (server['urls'] != null) {
            final String urlStr = server['urls'].toString();
            if (urlStr.contains('yourdomain.com')) {
              final String? hostname = AppConfig.turnPublicHostname;
              if (hostname == null || hostname.isEmpty) {
                throw Exception(
                  'TURN server URL contains placeholder "yourdomain.com" but '
                  'AppConfig.turnPublicHostname is not configured.',
                );
              }
              server['urls'] = urlStr.replaceAll('yourdomain.com', hostname);
              serversList[i] = server;
            }
          }

          if (server['username'] != null) {
            final String username = server['username'].toString();
            if (username.contains(':')) {
               extractedPeerUuid = username.split(':')[0];
               break;
            }
          }
        }
      }
    }
    return TurnResponse(
      sessionId: data['session_uuid'] ?? data['sessionId'] ?? fallbackSessionId ?? '',
      peerUuid: extractedPeerUuid,
      iceServers: serversList,
    );
  }
}
