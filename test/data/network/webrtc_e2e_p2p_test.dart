import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:follow_me_back/data/network/webrtc/api_v1_webrtc_signaler.dart';
import 'package:follow_me_back/data/network/webrtc/client_session.dart';
import 'package:follow_me_back/data/network/webrtc/host_session.dart';
import 'package:flutter/widgets.dart';

void main() {
  group('Real WebRTC P2P DataChannel E2E', () {
    test('Host and Client establish a DataChannel stream through API v1 Coturn', () async {
      WidgetsFlutterBinding.ensureInitialized();

      final hostSignaler = const ApiV1WebRTCSignaler();
      final clientSignaler = const ApiV1WebRTCSignaler();
      
      final hostSession = WebRTCHostSession(hostSignaler);
      final clientSession = WebRTCClientSession(clientSignaler);

      final completer = Completer<bool>();

      // Listeners for successful connection mapping
      clientSession.connectionStateStream.listen((state) {
        if (state == 'RTCPeerConnectionStateConnected') {
          if (!completer.isCompleted) completer.complete(true);
        }
      });

      hostSession.connectionStateStream.listen((state) {
        print('HOST PC State: $state');
        if (state == 'PEER_DISCONNECTED') {
          if (!completer.isCompleted) completer.completeError('Disconnected');
        }
      });

      print('--- E2E STARTING HOST ---');
      // Host generates Session UUID and posts Offer
      final hostUuid = await hostSession.createHostOffer(null);
      
      print('--- E2E STARTING CLIENT AGAINST UUID: $hostUuid ---');

      // Client natively joins UUID, pulls offer, generates answer, posts answer
      // Meanwhile, Host's `waitForInitialAnswer` will pull the newly posted answer and connect.
      await Future.wait([
        clientSession.processHostOffer(hostUuid),
        hostSession.waitForInitialAnswer(timeout: const Duration(seconds: 40)),
      ]);

      print('--- E2E AWAITING P2P ESTABLISHMENT ---');

      // Wait for the final ICE candidate connection establishment
      final result = await completer.future.timeout(const Duration(seconds: 40));
      expect(result, isTrue);

      await hostSession.dispose();
      await clientSession.dispose();
    }, timeout: const Timeout(Duration(seconds: 90)));
  });
}
