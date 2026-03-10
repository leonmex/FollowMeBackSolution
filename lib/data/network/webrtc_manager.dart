import 'dart:convert';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import '../../domain/entities/location_update.dart';
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import '../../domain/entities/session_role.dart';
import 'follow_me_back_server.dart';
import '../../core/config/app_config.dart';

class WebRTCManager {
  RTCPeerConnection? _peerConnection;
  RTCDataChannel? _dataChannel;

  final _connectionStateController = StreamController<String>.broadcast();
  final _locationUpdatesController =
      StreamController<LocationUpdate>.broadcast();

  bool _isConnected = false;
  SessionRole? _currentRole;
  String? _sessionUuid;
  bool _isDisconnecting = false;
  bool _isReconnecting = false;
  bool _initialHandshakeInProgress = false;
  bool _isInitializing = false;
  bool _isTickInProgress = false;
  int _reconnectAttemptCount = 0;
  String? _lastHandledReconnectionData;
  final List<Map<String, dynamic>> _localCandidates = [];
  Timer? _pingTimer;
  Timer? _reconnectionTimer;

  WebRTCManager();

  bool get isConnected => _isConnected;
  SessionRole? get currentRole => _currentRole;
  String? get sessionUuid => _sessionUuid;

  Stream<String> get connectionStateStream => _connectionStateController.stream;
  Stream<LocationUpdate> get locationUpdatesStream =>
      _locationUpdatesController.stream;

  /// Initialize WebRTC connection
  Future<void> initWebRTC() async {
    if (_isInitializing) return;
    _isInitializing = true;
    try {
      if (_peerConnection != null) return;
      _localCandidates.clear();
      final iceServers = await FollowMeBackServer.fetchIceServers();

      final configuration = {
        'iceServers': iceServers,
        'iceTransportPolicy': 'all',
        'iceCandidatePoolSize': AppConfig.iceCandidatePoolSize,
        'bundlePolicy': 'max-bundle',
      };

      _peerConnection = await createPeerConnection(configuration);

      _peerConnection!.onConnectionState = handleConnectionState;
      _peerConnection!.onIceConnectionState = handleIceConnectionState;
      _peerConnection!.onIceCandidate = (RTCIceCandidate? candidate) {
        if (candidate != null && candidate.candidate != null) {
          _localCandidates.add({
            'candidate': candidate.candidate,
            'sdpMid': candidate.sdpMid,
            'sdpMLineIndex': candidate.sdpMLineIndex,
          });
        }
      };

      // When the Client answers, the Host receives the data channel here
      _peerConnection!.onDataChannel = (RTCDataChannel channel) {
        _dataChannel = channel;
        _setupDataChannelListeners();
      };
    } finally {
      _isInitializing = false;
    }
    // Fallback: we should handle ICE candidate gathering locally within the SDP
    // For pure QR-code P2P without a signaling server, we must wait for ICE gathering
    // to complete before generating the final QR code, or include candidates in the payload.
  }

  /// HOST: Create initial Offer and post to backend. Returns the Session UUID for the QR code.
  Future<String> createOffer() async {
    _initialHandshakeInProgress = true;
    try {
      _currentRole = SessionRole.host;
      _sessionUuid = const Uuid().v4();

      debugPrint('Host: Generating new Session UUID: $_sessionUuid');
      // Step 1: Initialize session on backend (create mailbox)
      await FollowMeBackServer.initializeSession(_sessionUuid!);

      await initWebRTC();

      // Step 2: Create Data Channel and Offer
      RTCDataChannelInit dataChannelDict = RTCDataChannelInit()..ordered = true;
      _dataChannel = await _peerConnection!.createDataChannel(
        'tracking_channel',
        dataChannelDict,
      );
      _setupDataChannelListeners();

      RTCSessionDescription offer = await _peerConnection!.createOffer();
      await _peerConnection!.setLocalDescription(offer);

      // Step 3: Wait for ICE gathering
      await _waitForIceGathering().timeout(
        Duration(seconds: AppConfig.iceGatheringTimeoutSeconds),
        onTimeout: () => debugPrint('Host: ICE gathering timeout'),
      );

      // Step 4: Post Offer to backend mailbox
      final finalOffer = await _peerConnection!.getLocalDescription();
      final jsonStr = jsonEncode({
        'uuid': _sessionUuid,
        'sdp': finalOffer!.sdp,
        'type': finalOffer.type,
        'candidates': _localCandidates,
      });

      bool postSuccess = await FollowMeBackServer.postReconnectionData(
        uuid: _sessionUuid!,
        role: 'Host',
        iceData: jsonStr,
      );

      if (!postSuccess) {
        throw Exception('Failed to post initial Offer to signaling server');
      }

      _initialHandshakeInProgress = false;
      return _sessionUuid!; // Return ONLY the UUID for the QR code
    } catch (e) {
      _initialHandshakeInProgress = false;
      rethrow;
    } finally {
      _initialHandshakeInProgress = false;
    }
  }

  /// CLIENT: Process Host UUID from QR, fetch Offer from backend, and post Answer.
  Future<void> processOfferAndCreateAnswer(String hostUuid) async {
    _initialHandshakeInProgress = true;
    try {
      await disconnect();
      _currentRole = SessionRole.client;
      _sessionUuid = hostUuid;
      await initWebRTC();

      debugPrint('Client: Fetching initial Offer for UUID: $_sessionUuid');
      // Step 1: Poll backend for Host Offer
      final hostData = await FollowMeBackServer.pollReconnectionData(
        uuid: _sessionUuid!,
        targetRole: 'Host',
      );

      if (hostData == null || hostData.isEmpty) {
        throw Exception('Host Offer not found on signaling server');
      }

      // Step 2: Apply Host Offer
      final offerMap = jsonDecode(hostData);
      final offerData = RTCSessionDescription(
        offerMap['sdp'],
        offerMap['type'],
      );
      await _peerConnection!.setRemoteDescription(offerData);

      final List<dynamic> parsedCandidates = offerMap['candidates'] ?? [];
      for (var c in parsedCandidates) {
        try {
          int? sdpMLineIndex = c['sdpMLineIndex'] is String
              ? int.tryParse(c['sdpMLineIndex'])
              : c['sdpMLineIndex'] as int?;

          await _peerConnection!.addCandidate(
            RTCIceCandidate(
              c['candidate']?.toString(),
              c['sdpMid']?.toString(),
              sdpMLineIndex,
            ),
          );
        } catch (_) {}
      }

      // Step 3: Create Answer
      final answer = await _peerConnection!.createAnswer();
      await _peerConnection!.setLocalDescription(answer);

      await _waitForIceGathering().timeout(
        Duration(seconds: AppConfig.iceGatheringTimeoutSeconds),
        onTimeout: () => debugPrint('Client: ICE gathering timeout'),
      );

      // Step 4: Post Answer to backend mailbox
      final finalAnswer = await _peerConnection!.getLocalDescription();
      final jsonStr = jsonEncode({
        'uuid': _sessionUuid,
        'sdp': finalAnswer!.sdp,
        'type': finalAnswer.type,
        'candidates': _localCandidates,
      });

      await FollowMeBackServer.postReconnectionData(
        uuid: _sessionUuid!,
        role: 'Client',
        iceData: jsonStr,
      );

      _initialHandshakeInProgress = false;
    } catch (e) {
      _initialHandshakeInProgress = false;
      rethrow;
    } finally {
      _initialHandshakeInProgress = false;
    }
  }

  /// HOST: Polling loop to wait for initial Client Answer during pairing.
  Future<void> waitForInitialAnswer({Duration? timeout}) async {
    if (_sessionUuid == null || _currentRole != SessionRole.host) return;

    final startTime = DateTime.now();
    final effectiveTimeout =
        timeout ?? Duration(seconds: AppConfig.iceGatheringTimeoutSeconds * 2);

    debugPrint('Host: Waiting for initial Client Answer...');

    while (DateTime.now().difference(startTime) < effectiveTimeout) {
      if (_isConnected) return;

      try {
        final clientData = await FollowMeBackServer.pollReconnectionData(
          uuid: _sessionUuid!,
          targetRole: 'Client',
        );

        if (clientData != null && clientData.isNotEmpty) {
          debugPrint('Host: Initial Client Answer found! Applying...');
          await acceptAnswer(clientData);
          return;
        }
      } catch (e) {
        debugPrint('Host: Error polling for initial answer: $e');
      }

      await Future.delayed(
        const Duration(seconds: AppConfig.signalingPollIntervalSeconds),
      );
    }

    throw Exception('Timed out waiting for Follower to scan and respond.');
  }

  /// HOST: Accept Client Answer
  Future<void> acceptAnswer(String encodedAnswer) async {
    final answerMap = jsonDecode(encodedAnswer);
    final answerData = RTCSessionDescription(
      answerMap['sdp'],
      answerMap['type'],
    );
    await _peerConnection!.setRemoteDescription(answerData);

    final List<dynamic> parsedCandidates = answerMap['candidates'] ?? [];
    for (var c in parsedCandidates) {
      try {
        int? sdpMLineIndex;
        if (c['sdpMLineIndex'] != null) {
          sdpMLineIndex = c['sdpMLineIndex'] is String
              ? int.tryParse(c['sdpMLineIndex'])
              : c['sdpMLineIndex'] as int;
        }
        await _peerConnection!.addCandidate(
          RTCIceCandidate(
            c['candidate']?.toString(),
            c['sdpMid']?.toString(),
            sdpMLineIndex,
          ),
        );
      } catch (e) {
        debugPrint("Failed to add candidate: ${c['candidate']}. Error: $e");
      }
    }
  }

  /// Internal: Wait for ICE gathering state to complete so SDP has IP info
  Future<void> _waitForIceGathering() async {
    if (_peerConnection!.iceGatheringState ==
        RTCIceGatheringState.RTCIceGatheringStateComplete) {
      return;
    }

    final completer = Completer<void>();
    _peerConnection!.onIceGatheringState = (state) {
      if (state == RTCIceGatheringState.RTCIceGatheringStateComplete) {
        if (!completer.isCompleted) completer.complete();
      }
    };

    // Wait for complete, OR timeout (accounting for 5G API latency)
    try {
      await completer.future.timeout(
        Duration(seconds: AppConfig.iceGatheringTimeoutSeconds),
      );
    } catch (e) {
      debugPrint(
        "ICE gathering timed out, proceeding with gathered candidates.",
      );
    }

    return;
  }

  /// Setup listeners for incoming messages
  void _setupDataChannelListeners() {
    _dataChannel?.onMessage = (RTCDataChannelMessage message) {
      try {
        if (message.isBinary) return;
        final text = message.text;
        final data = jsonDecode(text);
        if (data is! Map) {
          debugPrint("Received non-map message: $text");
          return;
        }

        if (data['type'] == 'LOCATION_UPDATE') {
          final location = LocationUpdate.fromJson(data['payload']);
          if (!_locationUpdatesController.isClosed) {
            _locationUpdatesController.add(location);
          }
        } else if (data['type'] == 'REQUEST_LOCATION') {
          if (!_connectionStateController.isClosed) {
            _connectionStateController.add('REQUEST_LOCATION_RECEIVED');
          }
        } else if (data['type'] == 'PEER_DISCONNECTED') {
          _isConnected = false;
          if (!_isDisconnecting) {
            _connectionStateController.add('PEER_DISCONNECTED');
          }
        } else if (data['type'] == 'ping') {
          debugPrint('Received ping over WebRTC DataChannel');
        }
      } catch (e) {
        debugPrint("Error parsing channel message: $e | Raw: ${message.text}");
      }
    };
  }

  /// Send raw message over Data Channel
  Future<void> sendMessage(String text) async {
    if (_dataChannel != null &&
        _dataChannel!.state == RTCDataChannelState.RTCDataChannelOpen) {
      _dataChannel!.send(RTCDataChannelMessage(text));
    } else {
      debugPrint('Cannot send message: Data channel not open');
    }
  }

  Future<void> sendDisconnectSignal() async {
    final payload = jsonEncode({'type': 'PEER_DISCONNECTED'});
    await sendMessage(payload);
  }

  Future<void> disconnect() async {
    _isDisconnecting = true;
    _reconnectionTimer?.cancel();
    if (_isConnected &&
        _dataChannel?.state == RTCDataChannelState.RTCDataChannelOpen) {
      await sendDisconnectSignal();
      await Future.delayed(
        const Duration(milliseconds: AppConfig.disconnectSignalDelayMs),
      );
    }
    await _dataChannel?.close();
    await _peerConnection?.close();
    _dataChannel = null;
    _peerConnection = null;
    _isConnected = false;
    _isReconnecting = false;
    _currentRole = null;
    if (!_connectionStateController.isClosed) {
      _connectionStateController.add('DISCONNECTED');
    }
    _isDisconnecting = false;
  }

  void _startPingTimer() {
    _pingTimer?.cancel();
    _pingTimer = Timer.periodic(
      const Duration(seconds: AppConfig.keepAlivePingIntervalSeconds),
      (timer) {
        if (_isConnected &&
            _dataChannel?.state == RTCDataChannelState.RTCDataChannelOpen) {
          sendMessage(jsonEncode({'type': 'ping'}));
        }
        // Don't cancel the timer if temporarily disconnected.
        // Wait until internet/5G comes back or user closes session.
      },
    );
  }

  @visibleForTesting
  void handleConnectionState(RTCPeerConnectionState state) {
    switch (state) {
      case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
        _isConnected = true;
        _startPingTimer();
        break;
      case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
      case RTCPeerConnectionState.RTCPeerConnectionStateClosed:
      case RTCPeerConnectionState.RTCPeerConnectionStateDisconnected:
        debugPrint('WebRTC Connection State disrupted: ${state.name}');
        _isConnected = false; // Mark as not connected so reconnection can run

        if (!_isDisconnecting && !_isReconnecting) {
          debugPrint('Triggering attemptReconnection() from ConnectionState');
          attemptReconnection();
        }
        break;
      default:
        break;
    }
    if (!_connectionStateController.isClosed) {
      _connectionStateController.add(state.name);
    }
  }

  @visibleForTesting
  void handleIceConnectionState(RTCIceConnectionState state) {
    switch (state) {
      case RTCIceConnectionState.RTCIceConnectionStateFailed:
      case RTCIceConnectionState.RTCIceConnectionStateClosed:
      case RTCIceConnectionState.RTCIceConnectionStateDisconnected:
        debugPrint('WebRTC ICE Connection State disrupted: ${state.name}');
        _isConnected = false; // Mark as not connected

        if (!_isDisconnecting && !_isReconnecting) {
          debugPrint(
            'Triggering attemptReconnection() from IceConnectionState',
          );
          attemptReconnection();
        }
        break;
      default:
        break;
    }
    if (!_connectionStateController.isClosed) {
      _connectionStateController.add(state.name);
    }
  }

  Future<void> dispose() async {
    _pingTimer?.cancel();
    _reconnectionTimer?.cancel();
    await disconnect();
    _connectionStateController.close();
    _locationUpdatesController.close();
  }

  /// Internal: Closes and recreates the WebRTC stack with fresh ICE/TURN credentials.
  /// Follows the user's critical 1-4 steps for reconnection.
  Future<void> _recreatePeerConnection() async {
    debugPrint('WebRTC: Recreating PeerConnection with fresh credentials...');
    // 1. Fetch fresh TURN credentials occurs inside initWebRTC -> fetchIceServers
    // 2. Close old peer connection
    await _dataChannel?.close();
    await _peerConnection?.close();
    _dataChannel = null;
    _peerConnection = null;
    _isConnected = false;

    // 3. Create new peer connection with fresh credentials
    // 4. Re-attach tracks and listeners
    await initWebRTC();

    if (_currentRole == SessionRole.host) {
      // Re-create data channel on the Host side
      RTCDataChannelInit dataChannelDict = RTCDataChannelInit()..ordered = true;
      _dataChannel = await _peerConnection!.createDataChannel(
        'tracking_channel',
        dataChannelDict,
      );
      _setupDataChannelListeners();
    }
  }

  /// Handles ICE Restart and Session Restoration via Cloud Function
  Future<void> attemptReconnection() async {
    // Only reconnect if we had a successful initial handshake and aren't already trying
    if (_sessionUuid == null ||
        _currentRole == null ||
        _isReconnecting ||
        _initialHandshakeInProgress ||
        _peerConnection == null) {
      debugPrint(
        'Reconnection aborted: precondition not met (Handshake in progress: $_initialHandshakeInProgress)',
      );
      return;
    }
    _isReconnecting = true;
    _reconnectAttemptCount = 0;
    _isTickInProgress = false;

    try {
      if (_currentRole == SessionRole.host) {
        debugPrint('Host: Starting resilient reconnection loop...');
        _reconnectionTimer?.cancel();
        _reconnectionTimer = Timer.periodic(
          const Duration(seconds: AppConfig.signalingPollIntervalSeconds),
          (timer) async {
            if (_isTickInProgress) return;
            _isTickInProgress = true;
            try {
              debugPrint(
                'Host: Reconnection loop tick #$_reconnectAttemptCount. Connected: $_isConnected, Disconnecting: $_isDisconnecting',
              );
              if (_isDisconnecting || _isConnected) {
                debugPrint(
                  'Host: Reconnection loop stopping. Reason: ${_isDisconnecting ? "Manual Disconnect" : "Reconnected"}',
                );
                timer.cancel();
                _isReconnecting = false;
                return;
              }

              _reconnectAttemptCount++;

              debugPrint(
                'Host: Refreshing PeerConnection (Fresh TURN) and posting ICE Restart Offer...',
              );
              // Ensure session is initialized on backend
              await FollowMeBackServer.initializeSession(_sessionUuid!);

              // User's Step 1-4: Fresh TURN and new PC
              await _recreatePeerConnection();

              // User's Step 5: Create offer with iceRestart: true
              _localCandidates.clear();
              RTCSessionDescription offer = await _peerConnection!.createOffer({
                'iceRestart': true,
              });
              await _peerConnection!.setLocalDescription(offer);

              // Wait with a timeout for ICE gathering
              await _waitForIceGathering().timeout(
                Duration(seconds: AppConfig.iceGatheringTimeoutSeconds),
                onTimeout: () {},
              );

              final finalOffer = await _peerConnection!.getLocalDescription();
              final jsonStr = jsonEncode({
                'uuid': _sessionUuid,
                'sdp': finalOffer!.sdp,
                'type': finalOffer.type,
                'candidates': _localCandidates,
              });

              final bodyBytes = jsonStr;

              bool postSuccess = await FollowMeBackServer.postReconnectionData(
                uuid: _sessionUuid!,
                role: 'Host',
                iceData: bodyBytes,
              );
              debugPrint('Host: Post Offer success: $postSuccess');

              // Immediately poll for Client Answer
              debugPrint('Host: Checking for Client Answer...');
              final clientData = await FollowMeBackServer.pollReconnectionData(
                uuid: _sessionUuid!,
                targetRole: 'Client',
              );

              if (clientData != null &&
                  clientData.isNotEmpty &&
                  clientData != _lastHandledReconnectionData) {
                debugPrint('Host: New Client Answer found! Applying...');
                _lastHandledReconnectionData = clientData;
                await acceptAnswer(clientData);
                debugPrint('Host: Answer applied. Waiting for connection...');
              }
            } catch (e) {
              debugPrint('Host: Reconnection loop error: $e');
            } finally {
              _isTickInProgress = false;
            }
          },
        );
      } else if (_currentRole == SessionRole.client) {
        debugPrint('Client: Starting resilient reconnection poll...');
        _reconnectionTimer?.cancel();
        _reconnectionTimer = Timer.periodic(
          const Duration(seconds: AppConfig.signalingPollIntervalSeconds),
          (timer) async {
            if (_isTickInProgress) return;
            _isTickInProgress = true;
            try {
              debugPrint(
                'Client: Reconnection loop tick #$_reconnectAttemptCount. Connected: $_isConnected, Disconnecting: $_isDisconnecting',
              );
              if (_isDisconnecting || _isConnected) {
                debugPrint(
                  'Client: Reconnection loop stopping. Reason: ${_isDisconnecting ? "Manual Disconnect" : "Reconnected"}',
                );
                timer.cancel();
                _isReconnecting = false;
                return;
              }

              _reconnectAttemptCount++;

              // Hard Reset fallback: if we've tried too many times without success, recreate the PC
              if (_reconnectAttemptCount >
                  AppConfig.reconnectionHardResetLimit) {
                debugPrint(
                  'Client: Reconnection stuck for too long. Performing Hard Reset of WebRTC stack...',
                );
                _reconnectAttemptCount = 0;
                _lastHandledReconnectionData = null;
                await disconnect();
                await initWebRTC();
                return; // End this tick, wait for next one with fresh PC
              }

              debugPrint('Client: Polling for Host Offer...');
              final hostData = await FollowMeBackServer.pollReconnectionData(
                uuid: _sessionUuid!,
                targetRole: 'Host',
              );

              if (hostData != null && hostData.isNotEmpty) {
                if (hostData == _lastHandledReconnectionData) {
                  // We only skip if we are still not connected and the offer is the same
                  // But wait, what if the Answer failed to reach the Host?
                  // We check if we should retry anyway.
                  debugPrint(
                    'Client: Host Offer is unchanged. Skipping retry to avoid reset loops.',
                  );
                  return;
                }

                debugPrint(
                  'Client: New Host Offer found! Hard resetting stack and processing Answer...',
                );

                // Ensure session is initialized on backend (mailbox key exists)
                await FollowMeBackServer.initializeSession(_sessionUuid!);

                // User's Step 1-4: Fresh TURN and new PC before applying remote offer
                await _recreatePeerConnection();

                // Apply Host offer
                final offerMap = jsonDecode(hostData);
                final offerData = RTCSessionDescription(
                  offerMap['sdp'],
                  offerMap['type'],
                );
                await _peerConnection!.setRemoteDescription(offerData);

                final List<dynamic> parsedCandidates =
                    offerMap['candidates'] ?? [];
                for (var c in parsedCandidates) {
                  try {
                    int? sdpMLineIndex = c['sdpMLineIndex'] is String
                        ? int.tryParse(c['sdpMLineIndex'])
                        : c['sdpMLineIndex'] as int?;
                    await _peerConnection!.addCandidate(
                      RTCIceCandidate(
                        c['candidate']?.toString(),
                        c['sdpMid']?.toString(),
                        sdpMLineIndex,
                      ),
                    );
                  } catch (_) {}
                }

                _localCandidates.clear();
                final answer = await _peerConnection!.createAnswer();
                await _peerConnection!.setLocalDescription(answer);
                await _waitForIceGathering().timeout(
                  Duration(seconds: AppConfig.iceGatheringTimeoutSeconds),
                  onTimeout: () {},
                );

                final finalAnswer = await _peerConnection!
                    .getLocalDescription();
                final jsonStr = jsonEncode({
                  'uuid': _sessionUuid,
                  'sdp': finalAnswer!.sdp,
                  'type': finalAnswer.type,
                  'candidates': _localCandidates,
                });
                final bodyBytes = jsonStr;

                bool postResult = await FollowMeBackServer.postReconnectionData(
                  uuid: _sessionUuid!,
                  role: 'Client',
                  iceData: bodyBytes,
                );

                if (postResult) {
                  _lastHandledReconnectionData = hostData;
                  debugPrint(
                    'Client: Posting Answer success. Waiting for connection...',
                  );
                } else {
                  debugPrint(
                    'Client: Failed to post Answer to signaling server. Will retry next tick.',
                  );
                }
              } else {
                debugPrint('Client: No Host Offer found on signaling server.');
              }
            } catch (e) {
              debugPrint('Client: Reconnection loop error: $e');
            } finally {
              _isTickInProgress = false;
            }
          },
        );
      }
    } catch (e) {
      debugPrint('Reconnection setup failed: $e');
      _isReconnecting = false;
    }
  }
}
