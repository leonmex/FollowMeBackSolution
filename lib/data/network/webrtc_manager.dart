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
  final List<Map<String, dynamic>> _localCandidates = [];
  Timer? _pingTimer;

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
    _currentRole = SessionRole.host;
    _sessionUuid = const Uuid().v4();

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
    return base64Encode(compressed);
  }

  /// CLIENT: Process Host Offer & Create Answer
  Future<String> processOfferAndCreateAnswer(String encodedOffer) async {
    _currentRole = SessionRole.client;
    await initWebRTC();

    // Decode and Decompress
    final compressed = base64Decode(encodedOffer);
    final bytes = zlib.decode(compressed);
    final offerJson = utf8.decode(bytes);

    final offerMap = jsonDecode(offerJson);
    _sessionUuid = offerMap['uuid'];
    final offerData = RTCSessionDescription(offerMap['sdp'], offerMap['type']);
    await _peerConnection!.setRemoteDescription(offerData);

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
    return base64Encode(ansCompressed);
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
        if (message.isBinary) return; // We only send text JSON
        final data = jsonDecode(message.text);

        if (data['type'] == 'LOCATION_UPDATE') {
          final location = LocationUpdate.fromJson(data['payload']);
          _locationUpdatesController.add(location);
        } else if (data['type'] == 'REQUEST_LOCATION') {
          // We signal internally that a request was made
          // In a real app we might expose a Stream for "requests" separately
          // but for simplicity we will handle it via callbacks or streams in repo
          _connectionStateController.add('REQUEST_LOCATION_RECEIVED');
        } else if (data['type'] == 'PEER_DISCONNECTED') {
          _isConnected = false;
          if (!_isDisconnecting) {
            _connectionStateController.add('PEER_DISCONNECTED');
          }
        } else if (data['type'] == 'ping') {
          // Respond with a pong to visually debug if needed, or just ignore since receiving also keeps it alive
          debugPrint('Received ping over WebRTC DataChannel');
        }
      } catch (e) {
        debugPrint('Error parsing channel message: \$e');
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
        } else {
          timer.cancel();
        }
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
        _isConnected = false;
        break;
      case RTCPeerConnectionState.RTCPeerConnectionStateDisconnected:
        // Temporary drop, WebRTC STUN/TURN handles reconnection
        break;
      default:
        break;
    }
    _connectionStateController.add(state.name);
  }

  @visibleForTesting
  void handleIceConnectionState(RTCIceConnectionState state) {
    switch (state) {
      case RTCIceConnectionState.RTCIceConnectionStateFailed:
      case RTCIceConnectionState.RTCIceConnectionStateClosed:
        _isConnected = false;
        break;
      case RTCIceConnectionState.RTCIceConnectionStateDisconnected:
        // Temporary drop, WebRTC STUN/TURN handles reconnection
        break;
      default:
        break;
    }
    _connectionStateController.add(state.name);
  }

  Future<void> dispose() async {
    _pingTimer?.cancel();
    await disconnect();
    _connectionStateController.close();
    _locationUpdatesController.close();
  }
}
