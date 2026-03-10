import 'dart:convert';
import '../../domain/entities/location_update.dart';
import '../../domain/repositories/tracking_repository.dart';
import '../../domain/entities/session_role.dart';
import '../network/webrtc_manager.dart';

class TrackingRepositoryImpl implements TrackingRepository {
  final WebRTCManager _webRTCManager;

  TrackingRepositoryImpl({WebRTCManager? webRTCManager})
    : _webRTCManager = webRTCManager ?? WebRTCManager();

  @override
  Stream<String> get connectionState => _webRTCManager.connectionStateStream;

  @override
  Stream<LocationUpdate> get locationUpdates =>
      _webRTCManager.locationUpdatesStream;

  @override
  bool get isConnected => _webRTCManager.isConnected;

  @override
  SessionRole? get currentRole => _webRTCManager.currentRole;

  @override
  Future<String> createHostOffer() async {
    return await _webRTCManager.createOffer();
  }

  @override
  Future<void> clientProcessHostOffer(String uuid) async {
    await _webRTCManager.processOfferAndCreateAnswer(uuid);
  }

  @override
  Future<void> waitForPairing() async {
    await _webRTCManager.waitForInitialAnswer();
  }

  @override
  Future<void> requestLocationUpdate() async {
    final payload = jsonEncode({'type': 'REQUEST_LOCATION'});
    await _webRTCManager.sendMessage(payload);
  }

  @override
  Future<void> sendLocationUpdate(LocationUpdate update) async {
    final payload = jsonEncode({
      'type': 'LOCATION_UPDATE',
      'payload': update.toJson(),
    });
    await _webRTCManager.sendMessage(payload);
  }

  @override
  Future<void> sendMessage(String message) async {
    await _webRTCManager.sendMessage(message);
  }

  @override
  Future<void> disconnect() async {
    await _webRTCManager.disconnect();
  }

  @override
  Future<void> dispose() async {
    await _webRTCManager.dispose();
  }
}
