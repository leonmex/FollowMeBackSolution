import 'dart:convert';
import 'dart:io';
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
    _localCandidates.clear();
    final iceServers = await FollowMeBackServer.fetchIceServers();

    final configuration = {
      'iceServers': iceServers,
      'iceTransportPolicy': 'all',
      'iceCandidatePoolSize': 2,
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
    _peerConnection!.onDataChannel = (channel) {
      _dataChannel = channel;
      _setupDataChannelListeners();
    };

    // Fallback: we should handle ICE candidate gathering locally within the SDP
    // For pure QR-code P2P without a signaling server, we must wait for ICE gathering
    // to complete before generating the final QR code, or include candidates in the payload.
  }

  /// HOST: Create Offer
  Future<String> createOffer() async {
    _initialHandshakeInProgress = true;
    try {
      _currentRole = SessionRole.host;
      _sessionUuid = const Uuid().v4();

      debugPrint('Host: Generating new Session UUID: $_sessionUuid');
      // Register the session on the backend for future reconnection hooks
      await FollowMeBackServer.initializeSession(_sessionUuid!);

      await initWebRTC();

      // Create the data channel on the Host side *before* creating the offer
      RTCDataChannelInit dataChannelDict = RTCDataChannelInit()..ordered = true;
      _dataChannel = await _peerConnection!.createDataChannel(
        'tracking_channel',
        dataChannelDict,
      );
      _setupDataChannelListeners();

      RTCSessionDescription offer = await _peerConnection!.createOffer();
      await _peerConnection!.setLocalDescription(offer);

      // Wait for ICE gathering to complete so candidates are embedded in SDP
      await _waitForIceGathering();

      final finalOffer = await _peerConnection!.getLocalDescription();
      final jsonStr = jsonEncode({
        'uuid': _sessionUuid,
        'sdp': finalOffer!.sdp,
        'type': finalOffer.type,
        'candidates': _localCandidates,
      });

      // Compress and Base64 encode to fit in QR Code
      final bytes = utf8.encode(jsonStr);
      final compressed = zlib.encode(bytes);
      _initialHandshakeInProgress = false;
      return base64Encode(compressed);
    } catch (e) {
      _initialHandshakeInProgress = false;
      rethrow;
    }
  }

  Future<String> processOfferAndCreateAnswer(String encodedOffer) async {
    _initialHandshakeInProgress = true;
    try {
      // Ensure we start fresh if a previous attempt was made
      await disconnect();

      _currentRole = SessionRole.client;
      await initWebRTC();

      // Decode and Decompress
      final compressed = base64Decode(encodedOffer);
      final bytes = zlib.decode(compressed);
      final offerJson = utf8.decode(bytes);

      final offerMap = jsonDecode(offerJson);
      _sessionUuid = offerMap['uuid'];
      debugPrint('Client: Received Session UUID from Host: $_sessionUuid');

      // Redundancy: Ensure session is registered on backend
      if (_sessionUuid != null) {
        try {
          await FollowMeBackServer.initializeSession(_sessionUuid!);
        } catch (e) {
          debugPrint('Client: Non-critical error initializing session: $e');
        }
      }

      final offerData = RTCSessionDescription(
        offerMap['sdp'],
        offerMap['type'],
      );
      debugPrint('Client: Setting remote description...');
      await _peerConnection!.setRemoteDescription(offerData);
      debugPrint('Client: Remote description set.');

      final List<dynamic> parsedCandidates = offerMap['candidates'] ?? [];
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

      final answer = await _peerConnection!.createAnswer();
      await _peerConnection!.setLocalDescription(answer);

      // Wait for ICE gathering
      await _waitForIceGathering();

      final finalAnswer = await _peerConnection!.getLocalDescription();
      final jsonStr = jsonEncode({
        'uuid': _sessionUuid,
        'sdp': finalAnswer!.sdp,
        'type': finalAnswer.type,
        'candidates': _localCandidates,
      });

      // Compress and Base64 encode
      final ansBytes = utf8.encode(jsonStr);
      final ansCompressed = zlib.encode(ansBytes);
      _initialHandshakeInProgress = false;
      return base64Encode(ansCompressed);
    } catch (e) {
      _initialHandshakeInProgress = false;
      rethrow;
    }
  }

  /// HOST: Accept Client Answer
  Future<void> acceptAnswer(String encodedAnswer) async {
    // Decode and Decompress
    final compressed = base64Decode(encodedAnswer);
    final bytes = zlib.decode(compressed);
    final answerJson = utf8.decode(bytes);

    final answerMap = jsonDecode(answerJson);
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

    // Wait for complete, OR timeout after 8 seconds (accounting for 5G API latency)
    try {
      await completer.future.timeout(const Duration(seconds: 8));
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
      await Future.delayed(const Duration(milliseconds: 500));
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
        debugPrint('WebRTC Connection State changed to: $state.name');
        // Do not set _isConnected = false.
        // Try to reconnect via the Cloud Function if not already disconnecting
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
        debugPrint('WebRTC ICE Connection State changed to: $state.name');
        // Do not set _isConnected = false.
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

    try {
      if (_currentRole == SessionRole.host) {
        debugPrint('Host: Starting resilient reconnection loop...');
        _reconnectionTimer?.cancel();
        _reconnectionTimer = Timer.periodic(const Duration(seconds: 10), (
          timer,
        ) async {
          if (_isDisconnecting || _isConnected) {
            timer.cancel();
            _isReconnecting = false;
            return;
          }

          try {
            debugPrint('Host: Refreshing ICE candidates and posting Offer...');
            // Ensure session is initialized on backend
            await FollowMeBackServer.initializeSession(_sessionUuid!);

            _localCandidates.clear();
            RTCSessionDescription offer = await _peerConnection!.createOffer({
              'iceRestart': true,
            });
            await _peerConnection!.setLocalDescription(offer);

            // Wait with a timeout for ICE gathering
            await _waitForIceGathering().timeout(
              const Duration(seconds: 5),
              onTimeout: () {},
            );

            final finalOffer = await _peerConnection!.getLocalDescription();
            final jsonStr = jsonEncode({
              'uuid': _sessionUuid,
              'sdp': finalOffer!.sdp,
              'type': finalOffer.type,
              'candidates': _localCandidates,
            });

            final compressed = base64Encode(zlib.encode(utf8.encode(jsonStr)));
            bool postSuccess = await FollowMeBackServer.postReconnectionData(
              uuid: _sessionUuid!,
              role: 'Host',
              iceData: compressed,
            );
            debugPrint('Host: Post Offer success: $postSuccess');

            // Immediately poll for Client Answer
            debugPrint('Host: Checking for Client Answer...');
            final clientData = await FollowMeBackServer.pollReconnectionData(
              uuid: _sessionUuid!,
              targetRole: 'Client',
            );

            if (clientData != null && clientData.isNotEmpty) {
              debugPrint('Host: Client Answer found! Applying...');
              timer.cancel();
              await acceptAnswer(clientData);
              _isReconnecting = false;
              debugPrint('Host: Reconnection complete.');
            }
          } catch (e) {
            debugPrint('Host: Reconnection loop error: $e');
          }
        });
      } else if (_currentRole == SessionRole.client) {
        debugPrint('Client: Starting resilient reconnection poll...');
        _reconnectionTimer?.cancel();
        _reconnectionTimer = Timer.periodic(const Duration(seconds: 5), (
          timer,
        ) async {
          if (_isDisconnecting || _isConnected) {
            timer.cancel();
            _isReconnecting = false;
            return;
          }

          try {
            debugPrint('Client: Polling for Host Offer...');
            final hostData = await FollowMeBackServer.pollReconnectionData(
              uuid: _sessionUuid!,
              targetRole: 'Host',
            );

            if (hostData != null && hostData.isNotEmpty) {
              debugPrint('Client: Host Offer found! Processing Answer...');
              timer.cancel();

              // Ensure session is initialized on backend (mailbox key exists)
              await FollowMeBackServer.initializeSession(_sessionUuid!);

              // Apply Host offer
              final compressed = base64Decode(hostData);
              final offerMap = jsonDecode(utf8.decode(zlib.decode(compressed)));
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
                const Duration(seconds: 5),
                onTimeout: () {},
              );

              final finalAnswer = await _peerConnection!.getLocalDescription();
              final jsonStr = jsonEncode({
                'uuid': _sessionUuid,
                'sdp': finalAnswer!.sdp,
                'type': finalAnswer.type,
                'candidates': _localCandidates,
              });
              final ansCompressed = base64Encode(
                zlib.encode(utf8.encode(jsonStr)),
              );

              bool postResult = await FollowMeBackServer.postReconnectionData(
                uuid: _sessionUuid!,
                role: 'Client',
                iceData: ansCompressed,
              );
              debugPrint('Client: Posting Answer success: $postResult');
              _isReconnecting = false;
              debugPrint('Client: Reconnection complete.');
            }
          } catch (e) {
            debugPrint('Client: Reconnection loop error: $e');
          }
        });
      }
    } catch (e) {
      debugPrint('Reconnection setup failed: $e');
      _isReconnecting = false;
    }
  }
}
