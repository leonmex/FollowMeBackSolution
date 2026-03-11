import 'package:flutter/foundation.dart';
import '../../../core/config/app_config.dart';
import '../follow_me_back_server.dart';

/// Stateless wrapper for WebRTC-specific signaling operations via FollowMeBackServer.
/// Refactored as an instance-based class to support dependency injection in tests
/// and state-based throttling.
class WebRTCSignaler {
  const WebRTCSignaler();

  static DateTime? _lastRequestTime;

  /// Enforces a minimum 1-second delay between requests to prevent DDoS-like behavior.
  Future<void> _throttle() async {
    if (_lastRequestTime == null) {
      _lastRequestTime = DateTime.now();
      return;
    }

    final diff = DateTime.now().difference(_lastRequestTime!);
    if (diff < Duration(seconds: AppConfig.signalingMinimumIntervalSeconds)) {
      final waitTime =
          Duration(seconds: AppConfig.signalingMinimumIntervalSeconds) - diff;
      debugPrint(
          'WebRTCSignaler: Throttling request for ${waitTime.inMilliseconds}ms');
      await Future.delayed(waitTime);
    }
    _lastRequestTime = DateTime.now();
  }

  /// Initializes a session mailbox on the backend.
  Future<void> initializeSession(String uuid) async {
    await _throttle();
    final success = await FollowMeBackServer.initializeSession(uuid);
    if (!success) {
      throw Exception('Failed to initialize signaling session on backend');
    }
  }

  /// Posts SDP/Candidate data to the backend for a specific role.
  Future<bool> postData({
    required String uuid,
    required String role,
    required String data,
  }) async {
    await _throttle();
    return await FollowMeBackServer.postReconnectionData(
      uuid: uuid,
      role: role,
      iceData: data,
    );
  }

  /// Polls for data from the target role.
  Future<String?> pollData({
    required String uuid,
    required String targetRole,
  }) async {
    await _throttle();
    return await FollowMeBackServer.pollReconnectionData(
      uuid: uuid,
      targetRole: targetRole,
    );
  }

  /// Fetches fresh TURN/ICE server configurations.
  Future<List<Map<String, dynamic>>> fetchIceServers() async {
    await _throttle();
    return await FollowMeBackServer.fetchIceServers();
  }
}
