import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import '../../../domain/entities/session_role.dart';
import '../../../core/config/app_config.dart';
import 'webrtc_base_handler.dart';

class WebRTCClientSession extends WebRTCBaseHandler {
  Timer? _reconnectionTimer;
  bool _isReconnecting = false;
  bool _isTickInProgress = false;
  int _reconnectAttemptCount = 0;
  int _consecutiveNetworkFailures = 0;

  // FIX 1 Revised: We DO need _lastHandledOffer! 
  // If we generate a new Answer for an old Offer, the Host cannot accept
  // it because it is already in a `stable` state or it causes an m-lines mismatch.
  String? _lastHandledOffer;

  WebRTCClientSession(super.signaler);

  // ── Connection state callbacks ───────────────────────────────────────────────

  @override
  void onConnectionStateChanged(RTCPeerConnectionState state) {
    switch (state) {
      case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
      case RTCPeerConnectionState.RTCPeerConnectionStateDisconnected:
        // Start polling for a new host offer
        _startReconnectionPoll();
        break;

      case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
        // FIX 2: Stop reconnection as soon as the connection is confirmed.
        // Previously this was only checked inside the timer tick, causing
        // the poll to keep running even after ICE succeeded.
        debugPrint(
          'Client: Connection established. Stopping reconnection poll.',
        );
        _stopReconnection();
        break;

      case RTCPeerConnectionState.RTCPeerConnectionStateClosed:
        // Closed is a terminal state triggered by us.
        // If we are actively tearing down to rebuild, do NOT stop the poll!
        if (isDisconnecting) _stopReconnection();
        break;

      default:
        break;
    }
  }

  @override
  void onIceConnectionStateChanged(RTCIceConnectionState state) {
    switch (state) {
      case RTCIceConnectionState.RTCIceConnectionStateFailed:
      case RTCIceConnectionState.RTCIceConnectionStateDisconnected:
        _startReconnectionPoll();
        break;

      case RTCIceConnectionState.RTCIceConnectionStateConnected:
      case RTCIceConnectionState.RTCIceConnectionStateCompleted:
        // FIX 2 (same): ICE confirming a working path should also stop the poll.
        debugPrint('Client: ICE connected. Stopping reconnection poll.');
        _stopReconnection();
        break;

      case RTCIceConnectionState.RTCIceConnectionStateClosed:
        if (isDisconnecting) _stopReconnection();
        break;

      default:
        break;
    }
  }

  // ── Initial connection ───────────────────────────────────────────────────────

  /// CLIENT: Process Host UUID from QR, fetch Offer from backend, post Answer.
  Future<void> processHostOffer(String hostUuid) async {
    await _checkConnectivity('Client');
    setSessionInfo(hostUuid, SessionRole.client);
    
    // Register the session on the server (Moved from Host)
    await signaler.initializeSession(hostUuid);
    debugPrint('Client: Initialized session mailbox for UUID: $hostUuid');

    // Post "READY" to tell Host to push its Offer
    await signaler.postData(
      uuid: hostUuid,
      role: 'Client',
      data: jsonEncode({'type': 'READY'}),
    );
    debugPrint('Client: Pinged Host with READY state.');

    await initWebRTC();

    final hostData = await _pollForHostOffer(
      timeout: Duration(seconds: AppConfig.iceGatheringTimeoutSeconds * 2),
    );

    if (hostData == null) {
      throw Exception(
        'Client: Host Offer not found on signaling server after timeout.',
      );
    }

    await _applyOfferAndPostAnswer(hostData);
  }

  // ── Signaling helpers ────────────────────────────────────────────────────────

  /// Poll Firebase until a host offer appears or [timeout] is reached.
  Future<String?> _pollForHostOffer({required Duration timeout}) async {
    final startTime = DateTime.now();
    debugPrint('Client: Polling for Host Offer (uuid: $sessionUuid)...');

    while (DateTime.now().difference(startTime) < timeout) {
      final data = await signaler.pollData(
        uuid: sessionUuid!,
        targetRole: 'Host',
      );
      if (data != null && data.isNotEmpty) {
        final map = jsonDecode(data);
        if (map['type'] == 'offer') {
          return data;
        }
      }
      await Future.delayed(
        const Duration(seconds: AppConfig.signalingPollIntervalSeconds),
      );
    }
    return null;
  }

  Future<void> _applyOfferAndPostAnswer(String hostData) async {
    _lastHandledOffer = hostData;
    
    final offerMap = jsonDecode(hostData);
    final description = RTCSessionDescription(
      offerMap['sdp'],
      offerMap['type'],
    );
    await peerConnection!.setRemoteDescription(description);

    // Add host ICE candidates bundled in the offer payload
    final List<dynamic> candidates = offerMap['candidates'] ?? [];
    for (final c in candidates) {
      try {
        await peerConnection!.addCandidate(
          RTCIceCandidate(
            c['candidate']?.toString(),
            c['sdpMid']?.toString(),
            c['sdpMLineIndex'] is String
                ? int.tryParse(c['sdpMLineIndex'])
                : c['sdpMLineIndex'],
          ),
        );
      } catch (e) {
        debugPrint('Client: Failed to add ICE candidate: $e');
      }
    }

    final answer = await peerConnection!.createAnswer();
    await peerConnection!.setLocalDescription(answer);

    await waitForIceGathering();

    final finalAnswer = await peerConnection!.getLocalDescription();
    final payload = jsonEncode({
      'uuid': sessionUuid,
      'sdp': finalAnswer!.sdp,
      'type': finalAnswer.type,
      'candidates': localIceCandidates,
    });

    debugPrint('=== CLIENT RECONNECTION TRACE: POST ANSWER ===');
    debugPrint('Client POST UUID: $sessionUuid');
    debugPrint('Client POST Role: Client');
    debugPrint('Client POST SDP Type: ${finalAnswer.type}');
    debugPrint('Client POST SDP Content Length: ${finalAnswer.sdp?.length ?? 0}');
    debugPrint('Client POST Candidates Count: ${localIceCandidates.length}');
    debugPrint('Client POST Full Payload Preview: ${payload.length > 100 ? '${payload.substring(0, 100)}...' : payload}');
    debugPrint('==============================================');

    await signaler.postData(uuid: sessionUuid!, role: 'Client', data: payload);
    debugPrint('Client: Answer successfully posted to FollowMeBackServer. Waiting for connection...');
  }

  Future<void> _checkConnectivity(String role) async {
    try {
      final servers = await signaler.fetchIceServers();
      if (servers.isEmpty) throw Exception('No ICE servers returned');
    } catch (e) {
      debugPrint('$role: Internet connectivity check failed: $e');
      throw Exception('Internet is requiered for FollowMeBack $role');
    }
  }

  // ── Reconnection ─────────────────────────────────────────────────────────────

  void _startReconnectionPoll() {
    // Don't stack multiple polls
    if (_isReconnecting || sessionUuid == null) return;

    _isReconnecting = true;
    _reconnectAttemptCount = 0;
    _reconnectionTimer?.cancel();

    debugPrint('Client: Starting reconnection poll...');

    _reconnectionTimer = Timer.periodic(
      const Duration(seconds: AppConfig.signalingPollIntervalSeconds),
      _onReconnectionTick,
    );
  }

  Future<void> _onReconnectionTick(Timer timer) async {
    // Skip tick if a previous one is still running
    if (_isTickInProgress) return;

    // FIX 2: Stop immediately if connection recovered between ticks
    if (isConnected) {
      debugPrint('Client: Connection recovered. Stopping poll.');
      _stopReconnection();
      return;
    }

    _isTickInProgress = true;

    try {
      _reconnectAttemptCount++;
      debugPrint('Client: Reconnection poll tick #$_reconnectAttemptCount');

      // FIX 3: Trigger Hard Reset IMMEDIATELY on the first tick.
      // This ensures we fetch fresh ICE/TURN credentials as soon as the
      // connection drops instead of trying to salvage the dead session.
      final bool needsHardReset = _reconnectAttemptCount == 1 ||
          _reconnectAttemptCount % AppConfig.reconnectionHardResetLimit == 0;

      if (needsHardReset) {
        debugPrint('Client: Hard resetting WebRTC stack...');
        await forceRecreatePC();
        // Plan: Add centralized delay after hard reset
        await Future.delayed(
            Duration(seconds: AppConfig.signalingMinimumIntervalSeconds));
        // Fall through — don't return. Let the offer fetch below run immediately.
      }

      final hostData = await signaler.pollData(
        uuid: sessionUuid!,
        targetRole: 'Host',
      );

      if (hostData != null && hostData.isNotEmpty) {
        if (hostData == _lastHandledOffer) {
          debugPrint('Client: Ignoring stale Host Offer already answered.');
          return;
        }

        debugPrint('=== CLIENT RECONNECTION TRACE: POLL SUCCESS ===');
        debugPrint('Client RECOVERED Host Data. Size: ${hostData.length}');
        debugPrint('Client RECOVERED Host Data Preview: ${hostData.length > 100 ? '${hostData.substring(0, 100)}...' : hostData}');
        debugPrint('===============================================');

        // FIX 1 Revised: We MUST wait for a NEW Offer from the Host.
        // If we generate a new Answer for an old Offer, the Host cannot accept
        // it because it is already in a `stable` state, or it will cause an
        // m-lines mismatch if the Host just hard-reset.
        await forceRecreatePC();
        // Plan: Add delay before applying offer to allow server state to settle
        await Future.delayed(
            Duration(seconds: AppConfig.signalingMinimumIntervalSeconds));
        await _applyOfferAndPostAnswer(hostData);
      } else {
        debugPrint('Client: No new Host Offer yet. Will retry...');
      }

      // If we reach here, the network request succeeded
      if (_consecutiveNetworkFailures > 0) {
        _consecutiveNetworkFailures = 0;
        emitConnectionState('INTERNET_RESTORED');
      }
    } catch (e) {
      final errorStr = e.toString();
      if (errorStr.contains('SocketException') || errorStr.contains('TimeoutException')) {
        _consecutiveNetworkFailures++;
        if (_consecutiveNetworkFailures >= 2) {
          emitConnectionState('NO_INTERNET');
        }
      }
      debugPrint('Client: Reconnection tick error: $e');
    } finally {
      _isTickInProgress = false;
    }
  }

  void _stopReconnection() {
    if (!_isReconnecting) return;
    _reconnectionTimer?.cancel();
    _reconnectionTimer = null;
    _isReconnecting = false;
    _reconnectAttemptCount = 0;
    debugPrint('Client: Reconnection poll stopped.');
  }

  // ── Lifecycle ────────────────────────────────────────────────────────────────

  @override
  Future<void> dispose() async {
    _stopReconnection();
    await super.dispose();
  }
}
