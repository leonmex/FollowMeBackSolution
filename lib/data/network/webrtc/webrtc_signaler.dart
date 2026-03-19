import 'package:flutter/foundation.dart';
import '../../../core/config/app_config.dart';

class TurnResponse {
  final String sessionId;
  final String peerUuid;
  final List<Map<String, dynamic>> iceServers;
  TurnResponse({required this.sessionId, required this.peerUuid, required this.iceServers});
}

/// Abstract base class for WebRTC signaling operations.
/// Implementing classes should handle the actual backend REST calls.
abstract class WebRTCSignaler {
  const WebRTCSignaler();

  static DateTime? _lastRequestTime;

  /// Enforces a minimum delay between requests to prevent DDoS-like behavior.
  @protected
  Future<void> throttle() async {
    if (_lastRequestTime == null) {
      _lastRequestTime = DateTime.now();
      return;
    }

    final diff = DateTime.now().difference(_lastRequestTime!);
    if (diff < const Duration(seconds: AppConfig.signalingMinimumIntervalSeconds)) {
      final waitTime =
          const Duration(seconds: AppConfig.signalingMinimumIntervalSeconds) - diff;
      debugPrint('WebRTCSignaler: Throttling request for ${waitTime.inMilliseconds}ms');
      await Future.delayed(waitTime);
    }
    _lastRequestTime = DateTime.now();
  }

  /// Initializes a session mailbox on the backend.
  Future<void> initializeSession({
    required String uuid,
    required String peerId,
    required String role,
  });

  /// Posts SDP/Candidate data to the backend.
  Future<bool> postData({
    required String uuid,
    required String role,
    required String data,
    required String peerId,
  });

  /// Polls for data from the target role.
  Future<String?> pollData({
    required String uuid,
    required String targetRole,
    required String peerId,
  });

  /// Fetches fresh TURN/ICE server configurations and joins/creates a session.
  Future<TurnResponse> fetchIceServers({String? sessionId});

  /// Refreshes expired credentials using the cached peer_uuid
  Future<TurnResponse> refreshIceServers({required String peerUuid});
}
