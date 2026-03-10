import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:uuid/uuid.dart';
import '../../domain/entities/location_update.dart';
import '../../domain/entities/session_role.dart';
import 'webrtc/host_session.dart';
import 'webrtc/client_session.dart';
import 'webrtc/webrtc_base_handler.dart';
import 'webrtc/webrtc_signaler.dart';

/// Facade for WebRTC operations. Delegates to Host or Client specific sessions.
class WebRTCManager {
  final WebRTCSignaler _signaler = const WebRTCSignaler();
  WebRTCHostSession? _hostSession;
  WebRTCClientSession? _clientSession;
  SessionRole? _currentRole;

  final _connectionStateController = StreamController<String>.broadcast();
  final _locationUpdatesController =
      StreamController<LocationUpdate>.broadcast();

  WebRTCManager();

  // Getters
  bool get isConnected => _activeHandler?.isConnected ?? false;
  SessionRole? get currentRole => _currentRole;
  String? get sessionUuid => _activeHandler?.sessionUuid;

  WebRTCBaseHandler? get _activeHandler {
    if (_currentRole == SessionRole.host) return _hostSession;
    if (_currentRole == SessionRole.client) return _clientSession;
    return null;
  }

  Stream<String> get connectionStateStream => _connectionStateController.stream;
  Stream<LocationUpdate> get locationUpdatesStream =>
      _locationUpdatesController.stream;

  Future<void> initWebRTC() async {
    // If role is already set, init that session.
    // Usually called via createOffer or processOfferAndCreateAnswer.
    await _activeHandler?.initWebRTC();
  }

  /// HOST: Create initial Offer.
  Future<String> createOffer() async {
    _currentRole = SessionRole.host;
    _hostSession ??= WebRTCHostSession(_signaler);
    _setupListeners(_hostSession!);

    final uuid = const Uuid().v4();
    return await _hostSession!.createHostOffer(uuid);
  }

  /// CLIENT: Process Host UUID and establish connection.
  Future<void> processOfferAndCreateAnswer(String hostUuid) async {
    _currentRole = SessionRole.client;
    _clientSession ??= WebRTCClientSession(_signaler);
    _setupListeners(_clientSession!);

    await _clientSession!.processHostOffer(hostUuid);
  }

  /// HOST: Wait for Follower to respond.
  Future<void> waitForInitialAnswer({Duration? timeout}) async {
    await _hostSession?.waitForInitialAnswer(timeout: timeout);
  }

  Future<void> sendMessage(String text) async {
    await _activeHandler?.sendMessage(text);
  }

  Future<void> disconnect() async {
    await _activeHandler?.disconnect();
    _currentRole = null;
  }

  void _setupListeners(WebRTCBaseHandler handler) {
    handler.connectionStateStream.listen((state) {
      if (!_connectionStateController.isClosed) {
        _connectionStateController.add(state);
      }
    });

    handler.locationUpdatesStream.listen((update) {
      if (!_locationUpdatesController.isClosed) {
        _locationUpdatesController.add(update);
      }
    });
  }

  Future<void> dispose() async {
    await _hostSession?.dispose();
    await _clientSession?.dispose();
    _connectionStateController.close();
    _locationUpdatesController.close();
  }

  // Testing helper
  @visibleForTesting
  void handleConnectionState(RTCPeerConnectionState state) {
    _activeHandler?.handleConnectionState(state);
  }

  @visibleForTesting
  void handleIceConnectionState(RTCIceConnectionState state) {
    _activeHandler?.handleIceConnectionState(state);
  }

  @visibleForTesting
  void forceSetHostRole() {
    _currentRole = SessionRole.host;
    _hostSession ??= WebRTCHostSession(_signaler);
  }
}
