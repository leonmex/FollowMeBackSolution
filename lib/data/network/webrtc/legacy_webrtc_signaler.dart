import '../follow_me_back_server.dart';
import 'webrtc_signaler.dart';

/// Legacy implementation using the original FollowMeBackServer.
/// Safely ignores new parameters like peerId that API v1 expects.
class LegacyWebRTCSignaler extends WebRTCSignaler {
  const LegacyWebRTCSignaler();

  @override
  Future<void> initializeSession({
    required String uuid,
    required String peerId,
    required String role,
  }) async {
    await throttle();
    final success = await FollowMeBackServer.initializeSession(uuid);
    if (!success) {
      throw Exception('Failed to initialize signaling session on legacy backend');
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
    return await FollowMeBackServer.postReconnectionData(
      uuid: uuid,
      role: role,
      iceData: data,
    );
  }

  @override
  Future<String?> pollData({
    required String uuid,
    required String targetRole,
    required String peerId,
  }) async {
    await throttle();
    return await FollowMeBackServer.pollReconnectionData(
      uuid: uuid,
      targetRole: targetRole,
    );
  }

  @override
  Future<TurnResponse> fetchIceServers({String? sessionId}) async {
    await throttle();
    final servers = await FollowMeBackServer.fetchIceServers();
    return TurnResponse(
      sessionId: sessionId ?? 'legacy-UUID-fallback',
      peerUuid: 'legacy-peer',
      iceServers: servers,
    );
  }

  @override
  Future<TurnResponse> refreshIceServers({required String peerUuid}) async {
    // Legacy server doesn't support peer-level refreshing, so just generate new ones.
    return fetchIceServers();
  }
}
