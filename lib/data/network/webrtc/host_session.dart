import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import '../../../domain/entities/session_role.dart';
import '../../../core/config/app_config.dart';
import 'webrtc_base_handler.dart';

class WebRTCHostSession extends WebRTCBaseHandler {
  Timer? _reconnectionTimer;
  bool _isReconnecting = false;
  bool _isTickInProgress = false;
  int _reconnectAttemptCount = 0;
  int _consecutiveNetworkFailures = 0;

  // FIX 1 Revised: We DO need _lastAcceptedAnswer! 
  // If the host hard-resets, it creates a NEW PC and a NEW Offer. It CANNOT 
  // re-apply an OLD Answer from the server, because the m-lines and DTLS will mismatch.
  // It must ignore the old Answer and wait for the Client to post a new one.
  String? _lastAcceptedAnswer;

  WebRTCHostSession(super.signaler);

  // ── Connection state callbacks ───────────────────────────────────────────────

  @override
  void onConnectionStateChanged(RTCPeerConnectionState state) {
    switch (state) {
      case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
      case RTCPeerConnectionState.RTCPeerConnectionStateDisconnected:
        _startReconnectionLoop();
        break;

      case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
        // FIX 2: Stop the reconnection loop immediately when connected.
        // Previously the loop only stopped if isConnected was true at the
        // START of a tick — meaning it always ran at least one extra tick
        // after connection, which called setRemoteDescription on an
        // already-stable PC throwing "Called in wrong state: stable".
        debugPrint('Host: Connection established. Stopping reconnection loop.');
        _stopReconnection();
        break;

      case RTCPeerConnectionState.RTCPeerConnectionStateClosed:
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
        _startReconnectionLoop();
        break;

      case RTCIceConnectionState.RTCIceConnectionStateConnected:
      case RTCIceConnectionState.RTCIceConnectionStateCompleted:
        // FIX 2 (same): ICE finding a working path also stops the loop.
        debugPrint('Host: ICE connected. Stopping reconnection loop.');
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

  /// HOST: Create initial Offer and post to Firebase.
  Future<String> createHostOffer(String uuid) async {
    await _checkConnectivity('Host');
    setSessionInfo(uuid, SessionRole.host);
    await initWebRTC();

    final dcInit = RTCDataChannelInit()..ordered = true;
    final channel = await peerConnection!.createDataChannel(
      'tracking_channel',
      dcInit,
    );
    setDataChannel(channel);

    final offer = await peerConnection!.createOffer();
    await peerConnection!.setLocalDescription(offer);
    await waitForIceGathering();
    
    debugPrint('Host: Offer generated and stored locally for UUID: $uuid');
    return uuid;
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

  Future<void> waitForInitialAnswer({Duration? timeout}) async {
    final startTime = DateTime.now();
    final effectiveTimeout =
        timeout ?? Duration(seconds: AppConfig.iceGatheringTimeoutSeconds * 4);

    bool hasPushedOffer = false;

    while (DateTime.now().difference(startTime) < effectiveTimeout) {
      if (isConnected) return;

      final data = await signaler.pollData(
        uuid: sessionUuid!,
        targetRole: 'Client',
      );
      if (data != null && data.isNotEmpty) {
        final map = jsonDecode(data);
        if (map['type'] == 'READY' && !hasPushedOffer) {
          debugPrint('Host: Client ping received. Pushing Offer to server.');
          await _postCurrentOffer();
          hasPushedOffer = true;
        } else if (map['type'] == 'answer') {
          await _acceptAnswer(data);
          return;
        }
      }
      await Future.delayed(
        const Duration(seconds: AppConfig.signalingPollIntervalSeconds),
      );
    }
    throw Exception('Host: Timed out waiting for client response');
  }

  // ── Signaling helpers ────────────────────────────────────────────────────────

  Future<void> _postCurrentOffer() async {
    final finalOffer = await peerConnection!.getLocalDescription();
    final payload = jsonEncode({
      'uuid': sessionUuid,
      'sdp': finalOffer!.sdp,
      'type': finalOffer.type,
      'candidates': localIceCandidates,
    });
    
    debugPrint('=== HOST RECONNECTION TRACE: POST OFFER ===');
    debugPrint('Host POST UUID: $sessionUuid');
    debugPrint('Host POST Role: Host');
    debugPrint('Host POST SDP Type: ${finalOffer.type}');
    debugPrint('Host POST SDP Content Length: ${finalOffer.sdp?.length ?? 0}');
    debugPrint('Host POST Candidates Count: ${localIceCandidates.length}');
    debugPrint('Host POST Full Payload Preview: ${payload.length > 100 ? '${payload.substring(0, 100)}...' : payload}');
    debugPrint('=============================================');

    final success = await signaler.postData(
      uuid: sessionUuid!,
      role: 'Host',
      data: payload,
    );
    if (!success) {
      debugPrint('!!! HOST RECONNECTION TRACE ERROR: Failed to post offer to FollowMeBackServer');
      throw Exception('Host: Failed to post offer to Firebase');
    }
    debugPrint('Host: Offer successfully posted to FollowMeBackServer (uuid: $sessionUuid).');
  }

  Future<void> _acceptAnswer(String data) async {
    _lastAcceptedAnswer = data;
    
    debugPrint('=== HOST RECONNECTION TRACE: ACCEPT ANSWER ===');
    debugPrint('Host RECEIVED Data Length: ${data.length}');
    debugPrint('Host RECEIVED Data Preview: ${data.length > 100 ? '${data.substring(0, 100)}...' : data}');
    
    // FIX 4: Guard against setRemoteDescription in wrong signaling state.
    // This was the direct cause of "Called in wrong state: stable".
    // After ICE succeeds the PC moves to stable — calling setRemoteDescription
    // again crashes. Now we check before every call.
    final signalingState = peerConnection?.signalingState;
    if (signalingState == null ||
        signalingState == RTCSignalingState.RTCSignalingStateStable ||
        signalingState == RTCSignalingState.RTCSignalingStateClosed) {
      debugPrint(
        'Host: Skipping setRemoteDescription — '
        'PC already in state: $signalingState',
      );
      return;
    }

    final map = jsonDecode(data);
    final description = RTCSessionDescription(map['sdp'], map['type']);
    await peerConnection!.setRemoteDescription(description);

    final List<dynamic> candidates = map['candidates'] ?? [];
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
        debugPrint('Host: Failed to add ICE candidate: $e');
      }
    }
    debugPrint('Host: Remote answer applied successfully.');
  }

  // ── Reconnection loop ────────────────────────────────────────────────────────

  void _startReconnectionLoop() {
    if (_isReconnecting || sessionUuid == null) return;
    _isReconnecting = true;
    _reconnectAttemptCount = 0;
    _reconnectionTimer?.cancel();
    debugPrint('Host: Starting reconnection loop...');

    _reconnectionTimer = Timer.periodic(
      const Duration(seconds: AppConfig.signalingPollIntervalSeconds),
      _onReconnectionTick,
    );
  }

  Future<void> _onReconnectionTick(Timer timer) async {
    if (_isTickInProgress) return;

    // FIX 2: Stop immediately if connection recovered between ticks
    if (isConnected) {
      debugPrint('Host: Connection recovered. Stopping loop.');
      _stopReconnection();
      return;
    }

    _isTickInProgress = true;
    try {
      _reconnectAttemptCount++;
      debugPrint('Host: Reconnection poll... Attempt: $_reconnectAttemptCount');

      // FIX 5: Make Hard Reset trigger IMMEDIATELY on the first tick (attempt 1)
      // per user request, so that ICE, TURN, and SDP are always recreated as 
      // soon as the connection drops, rather than trying to salvage the dead PC.
      // It will also repeat every N attempts if it remains disconnected.
      final bool needsHardReset =
          _reconnectAttemptCount == 1 ||
          _reconnectAttemptCount % AppConfig.reconnectionHardResetLimit == 0;

      if (needsHardReset) {
        debugPrint(
          'Host: Hard resetting at attempt $_reconnectAttemptCount...',
        );
        await forceRecreatePC();

        // Re-create data channel — host always owns it
        final dcInit = RTCDataChannelInit()..ordered = true;
        final channel = await peerConnection!.createDataChannel(
          'tracking_channel',
          dcInit,
        );
        setDataChannel(channel);

        // Post fresh offer with iceRestart so client knows to re-answer
        final offer = await peerConnection!.createOffer({'iceRestart': true});
        await peerConnection!.setLocalDescription(offer);
        await waitForIceGathering();
        await _postCurrentOffer();
        // Plan: Add centralized delay after posting offer during hard reset
        await Future.delayed(
            Duration(seconds: AppConfig.signalingMinimumIntervalSeconds));
      }

      // FIX 3: Direct lookup — signaler uses doc(sessionUuid).get() internally
      final clientData = await signaler.pollData(
        uuid: sessionUuid!,
        targetRole: 'Client',
      );

      if (clientData != null && clientData.isNotEmpty) {
        if (clientData == _lastAcceptedAnswer) {
          debugPrint('Host: Ignoring stale Answer already applied.');
          return;
        }

        debugPrint('=== HOST RECONNECTION TRACE: POLL SUCCESS ===');
        debugPrint('Host RECOVERED Client Data. Size: ${clientData.length}');
        debugPrint('=============================================');
        // Plan: Avoid immediate setRemoteDescription if we just posted an offer
        await Future.delayed(
            Duration(seconds: AppConfig.signalingMinimumIntervalSeconds));
        // _acceptAnswer guards against wrong state internally (FIX 4)
        await _acceptAnswer(clientData);
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
      debugPrint('Host: Reconnection error: $e');
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
    debugPrint('Host: Reconnection loop stopped.');
  }

  // ── Lifecycle ────────────────────────────────────────────────────────────────

  @override
  Future<void> dispose() async {
    debugPrint('Host: Cleaning garbage for stored Offer & Session UUID: $sessionUuid');
    _stopReconnection();
    await super.dispose();
  }
}
