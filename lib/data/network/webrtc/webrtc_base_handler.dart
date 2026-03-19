import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import '../../../domain/entities/location_update.dart';
import '../../../domain/entities/session_role.dart';
import '../../../core/config/app_config.dart';
import 'webrtc_signaler.dart';

/// Base class managing the fundamental WebRTC PeerConnection and DataChannel lifecycle.
abstract class WebRTCBaseHandler {
  final WebRTCSignaler signaler;
  RTCPeerConnection? _peerConnection;
  RTCDataChannel? _dataChannel;

  WebRTCBaseHandler(this.signaler);

  final _connectionStateController = StreamController<String>.broadcast();
  final _locationUpdatesController =
      StreamController<LocationUpdate>.broadcast();

  bool _isConnected = false;
  SessionRole? _currentRole;
  String? _sessionUuid;
  String? _peerUuid;
  bool _isDisconnecting = false;
  bool get isDisconnecting => _isDisconnecting;
  bool _isInitializing = false;

  final List<Map<String, dynamic>> _localIceCandidates = [];

  // ── Getters ──────────────────────────────────────────────────────────────────

  RTCPeerConnection? get peerConnection => _peerConnection;
  RTCDataChannel? get dataChannel => _dataChannel;
  bool get isConnected => _isConnected;
  SessionRole? get currentRole => _currentRole;
  String? get sessionUuid => _sessionUuid;
  String? get peerUuid => _peerUuid; // Added peerUuid getter

  // Return a copy so callers can't mutate the internal list mid-gathering.
  List<Map<String, dynamic>> get localIceCandidates =>
      List.unmodifiable(_localIceCandidates);

  Stream<String> get connectionStateStream => _connectionStateController.stream;
  Stream<LocationUpdate> get locationUpdatesStream =>
      _locationUpdatesController.stream;

  void setSessionInfo(String uuid, SessionRole role) {
    _sessionUuid = uuid;
    _currentRole = role;
  }

  // ── Initialisation ───────────────────────────────────────────────────────────

  /// Initializes the WebRTC stack with fresh ICE/TURN credentials.
  /// Safe to call after forceRecreatePC() nulls the old PC.
  Future<void> initWebRTC() async {
    if (_isInitializing) return;
    if (_peerConnection != null) {
      debugPrint('WebRTC: initWebRTC called but PC already exists. Skipping.');
      return;
    }

    _isInitializing = true;
    try {
      _localIceCandidates.clear();

      // Always fetch fresh credentials — Metered.ca credentials are
      // time-limited (~1hr). Stale credentials silently produce zero
      // TURN candidates, leaving ICE stuck at CONNECTING forever.
      debugPrint('WebRTC: Fetching fresh ICE/TURN credentials...');
      TurnResponse response;
      if (_peerUuid == null) {
        response = await signaler.fetchIceServers(sessionId: _sessionUuid);
        if (response.peerUuid.isNotEmpty) {
          _peerUuid = response.peerUuid;
        }
      } else {
        debugPrint('WebRTC: Reconnecting with existing peer UUID...');
        response = await signaler.refreshIceServers(peerUuid: _peerUuid!);
      }

      if (_sessionUuid == null && response.sessionId.isNotEmpty) {
        _sessionUuid = response.sessionId;
      }
      
      debugPrint('WebRTC: Configuring PC with ICE Servers: ${jsonEncode(response.iceServers)}');

      final configuration = {
        'iceServers': response.iceServers,
        'iceTransportPolicy': 'all',
        'iceCandidatePoolSize': AppConfig.iceCandidatePoolSize,
        'bundlePolicy': 'max-bundle',
      };

      _peerConnection = await createPeerConnection(configuration);
      debugPrint('WebRTC: PeerConnection created.');

      _peerConnection!.onConnectionState = _handleConnectionState;
      _peerConnection!.onIceConnectionState = _handleIceConnectionState;

      _peerConnection!.onIceCandidate = (RTCIceCandidate? candidate) {
        if (candidate != null && candidate.candidate != null) {
          debugPrint('WebRTC: Gathered local ICE candidate: ${candidate.candidate}');
          _localIceCandidates.add({
            'candidate': candidate.candidate,
            'sdpMid': candidate.sdpMid,
            'sdpMLineIndex': candidate.sdpMLineIndex,
          });
        }
      };

      _peerConnection!.onIceGatheringState = (RTCIceGatheringState state) {
        debugPrint('WebRTC: ICE Gathering State Changed: ${state.name}');
      };

      _peerConnection!.onDataChannel = (RTCDataChannel channel) {
        _dataChannel = channel;
        _setupDataChannelListeners();
      };
    } finally {
      _isInitializing = false;
    }
  }

  // ── Connection state ─────────────────────────────────────────────────────────

  /// For test instrumentation via WebRTCManager.
  void handleConnectionState(RTCPeerConnectionState state) =>
      _handleConnectionState(state);

  void _handleConnectionState(RTCPeerConnectionState state) {
    final wasConnected = _isConnected;
    if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
      _isConnected = true;
    } else if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
        state == RTCPeerConnectionState.RTCPeerConnectionStateClosed ||
        state == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
      _isConnected = false;
    }
    debugPrint(
      'WebRTC: PC state → ${state.name} | isConnected: $wasConnected → $_isConnected',
    );
    emitConnectionState(state.name);
    onConnectionStateChanged(state);
  }

  /// For test instrumentation via WebRTCManager.
  void handleIceConnectionState(RTCIceConnectionState state) =>
      _handleIceConnectionState(state);

  void _handleIceConnectionState(RTCIceConnectionState state) {
    final wasConnected = _isConnected;
    if (state == RTCIceConnectionState.RTCIceConnectionStateConnected ||
        state == RTCIceConnectionState.RTCIceConnectionStateCompleted) {
      _isConnected = true;
    } else if (state == RTCIceConnectionState.RTCIceConnectionStateFailed ||
        state == RTCIceConnectionState.RTCIceConnectionStateClosed ||
        state == RTCIceConnectionState.RTCIceConnectionStateDisconnected) {
      _isConnected = false;
    }
    debugPrint(
      'WebRTC: ICE state → ${state.name} | isConnected: $wasConnected → $_isConnected',
    );
    emitConnectionState(state.name);
    onIceConnectionStateChanged(state);
  }

  /// Subclasses override to react to state changes (start/stop reconnection).
  void onConnectionStateChanged(RTCPeerConnectionState state);
  void onIceConnectionStateChanged(RTCIceConnectionState state);

  void emitConnectionState(String state) {
    if (!_connectionStateController.isClosed) {
      _connectionStateController.add(state);
    }
  }

  // ── ICE gathering ────────────────────────────────────────────────────────────

  Future<void> waitForIceGathering() async {
    if (_peerConnection == null) return;

    if (_peerConnection!.iceGatheringState ==
        RTCIceGatheringState.RTCIceGatheringStateComplete) {
      return;
    }

    final completer = Completer<void>();
    // Preserve any existing listener so we don't silently discard it.
    final originalListener = _peerConnection!.onIceGatheringState;

    _peerConnection!.onIceGatheringState = (state) {
      originalListener?.call(state);
      if (state == RTCIceGatheringState.RTCIceGatheringStateComplete) {
        if (!completer.isCompleted) completer.complete();
      }
    };

    await completer.future.timeout(
      Duration(seconds: AppConfig.iceGatheringTimeoutSeconds),
      onTimeout: () => debugPrint(
        'WebRTC: ICE Gathering timed out after '
        '${AppConfig.iceGatheringTimeoutSeconds}s. '
        'Proceeding with ${_localIceCandidates.length} candidates.',
      ),
    );

    _peerConnection?.onIceGatheringState = originalListener;
  }

  // ── Data channel ─────────────────────────────────────────────────────────────

  void _setupDataChannelListeners() {
    _dataChannel?.onMessage = (RTCDataChannelMessage message) {
      try {
        if (message.isBinary) return;
        final data = jsonDecode(message.text);
        if (data is! Map) return;

        if (data['type'] == 'LOCATION_UPDATE') {
          final location = LocationUpdate.fromJson(data['payload']);
          if (!_locationUpdatesController.isClosed) {
            _locationUpdatesController.add(location);
          }
        } else if (data['type'] == 'REQUEST_LOCATION') {
          emitConnectionState('REQUEST_LOCATION_RECEIVED');
        } else if (data['type'] == 'PEER_DISCONNECTED') {
          _isConnected = false;
          if (!_isDisconnecting) emitConnectionState('PEER_DISCONNECTED');
        }
      } catch (e) {
        debugPrint('WebRTC: Error parsing message: $e');
      }
    };
  }

  Future<void> sendMessage(String text) async {
    if (_dataChannel != null &&
        _dataChannel!.state == RTCDataChannelState.RTCDataChannelOpen) {
      _dataChannel!.send(RTCDataChannelMessage(text));
    }
  }

  // ── Lifecycle ────────────────────────────────────────────────────────────────

  Future<void> disconnect() async {
    _isDisconnecting = true;
    if (_isConnected &&
        _dataChannel?.state == RTCDataChannelState.RTCDataChannelOpen) {
      await sendMessage(jsonEncode({'type': 'PEER_DISCONNECTED'}));
      await Future.delayed(
        const Duration(milliseconds: AppConfig.disconnectSignalDelayMs),
      );
    }
    _dataChannel?.close();
    _peerConnection?.close().catchError((_) {});
    _peerConnection?.dispose();
    _dataChannel = null;
    _peerConnection = null;
    _isConnected = false;
    emitConnectionState('DISCONNECTED');
    _isDisconnecting = false;
  }

  /// Tear down and recreate the PeerConnection with fresh credentials.
  Future<void> forceRecreatePC() async {
    debugPrint('WebRTC: Recreating PeerConnection with fresh credentials...');
    _dataChannel?.close();
    _peerConnection?.close().catchError((_) {});
    _peerConnection?.dispose();
    _dataChannel = null;
    _peerConnection = null;
    await initWebRTC();
  }

  /// Base dispose — subclasses must call super.dispose() AFTER their own cleanup.
  /// Firebase session deletion is handled by WebRTCHostSession only, since
  /// the host owns the session document. The client must never delete it.
  Future<void> dispose() async {
    await disconnect();
    if (!_connectionStateController.isClosed) {
      _connectionStateController.close();
    }
    if (!_locationUpdatesController.isClosed) {
      _locationUpdatesController.close();
    }
  }

  void setDataChannel(RTCDataChannel channel) {
    _dataChannel = channel;
    _setupDataChannelListeners();
  }
}
