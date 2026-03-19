import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:follow_me_back/data/network/webrtc/api_v1_webrtc_server.dart';

void main() {
  group('API v1 E2E Integration (Live Server)', () {
    String? sharedSessionUuid;
    String? clientPeerUuid;
    final Map<String, dynamic> mockOfferPayload = {
      'uuid': 'test-offer-uuid',
      'sdp': 'v=0\r\no=- 0 0 IN IP4 127.0.0.1...',
      'type': 'offer',
      'candidates': []
    };
    final Map<String, dynamic> mockAnswerPayload = {
      'uuid': 'test-answer-uuid',
      'sdp': 'v=0\r\no=- 0 0 IN IP4 127.0.0.1...',
      'type': 'answer',
      'candidates': []
    };

    test('Step 1: Host creates a new session & fetches ICE servers', () async {
      final data = await ApiV1WebRTCServer.fetchIceServers();
      expect(data, isNotNull);
      expect(data.containsKey('session_uuid'), isTrue);
      expect(data.containsKey('ice_servers'), isTrue);

      sharedSessionUuid = data['session_uuid'];
      expect(sharedSessionUuid, isNotNull);
      expect(sharedSessionUuid!.isNotEmpty, isTrue);
    });

    test('Step 2: Host initializes the session handshake (role: offerer)', () async {
      expect(sharedSessionUuid, isNotNull);
      final success = await ApiV1WebRTCServer.initializeSession(
        sessionUuid: sharedSessionUuid!,
        peerUuid: 'host-peer-uuid',
        role: 'offerer',
      );
      expect(success, isTrue);
    });

    test('Step 3: Host posts SDP offer data', () async {
      final success = await ApiV1WebRTCServer.postReconnectionData(
        sessionUuid: sharedSessionUuid!,
        peerUuid: 'host-peer-uuid',
        role: 'offerer',
        iceData: mockOfferPayload,
      );
      expect(success, isTrue);
    });

    test('Step 4: Client joins the existing session & fetches ICE servers', () async {
      final data = await ApiV1WebRTCServer.fetchIceServers(sessionId: sharedSessionUuid);
      expect(data, isNotNull);
      expect(data['session_uuid'], equals(sharedSessionUuid));
      expect(data.containsKey('ice_servers'), isTrue);

      final List<dynamic> servers = data['ice_servers'];
      for (final s in servers) {
        if (s['username'] != null) {
          final username = s['username'].toString();
          if (username.contains(':')) {
            clientPeerUuid = username.split(':')[0];
            break;
          }
        }
      }
      expect(clientPeerUuid, isNotNull);
      expect(clientPeerUuid!.isNotEmpty, isTrue);
    });

    test('Step 5: Client posts SDP answer & Host polls it', () async {
      // Client posts answer
      final success = await ApiV1WebRTCServer.postReconnectionData(
        sessionUuid: sharedSessionUuid!,
        peerUuid: 'client-peer-uuid',
        role: 'answerer',
        iceData: mockAnswerPayload,
      );
      expect(success, isTrue);

      // Host polls answer
      final polledData = await ApiV1WebRTCServer.pollReconnectionData(
        sessionUuid: sharedSessionUuid!,
        role: 'answerer',
      );
      expect(polledData, isNotNull);
      
      final Map<String, dynamic> decoded = jsonDecode(polledData!);
      expect(decoded['uuid'], equals('test-answer-uuid'));
      expect(decoded['type'], equals('answer'));
    });

    test('Step 6: Client Refreshes ICE Credentials', () async {
      expect(clientPeerUuid, isNotNull);
      final data = await ApiV1WebRTCServer.refreshIceServers(peerUuid: clientPeerUuid!);
      expect(data, isNotNull);
      expect(data.containsKey('ice_servers'), isTrue);
    });

    test('Step 7: Host simulates Wifi to 5G switch (reconnect)', () async {
      final mockUpdatePayload = Map<String, dynamic>.from(mockOfferPayload);
      mockUpdatePayload['candidates'] = ['candidate:host-5g-123'];
      
      final success = await ApiV1WebRTCServer.postReconnectionData(
        sessionUuid: sharedSessionUuid!,
        peerUuid: 'host-peer-uuid',
        role: 'offerer',
        iceData: mockUpdatePayload,
      );
      expect(success, isTrue);

      // Client polls the updated Offer payload natively
      final polledData = await ApiV1WebRTCServer.pollReconnectionData(
        sessionUuid: sharedSessionUuid!,
        role: 'offerer',
      );
      expect(polledData, isNotNull);
      final Map<String, dynamic> decoded = jsonDecode(polledData!);
      expect(decoded['candidates'], isNotEmpty);
      expect(decoded['candidates'].first, equals('candidate:host-5g-123'));
    });

    test('Step 8: Client offline timeout / recover (reconnect)', () async {
      final mockUpdatePayload = Map<String, dynamic>.from(mockAnswerPayload);
      mockUpdatePayload['candidates'] = ['candidate:client-recover-456'];
      
      final success = await ApiV1WebRTCServer.postReconnectionData(
        sessionUuid: sharedSessionUuid!,
        peerUuid: clientPeerUuid!,
        role: 'answerer',
        iceData: mockUpdatePayload,
      );
      expect(success, isTrue);

      // Host polls the updated Answer payload natively
      final polledData = await ApiV1WebRTCServer.pollReconnectionData(
        sessionUuid: sharedSessionUuid!,
        role: 'answerer',
      );
      expect(polledData, isNotNull);
      final Map<String, dynamic> decoded = jsonDecode(polledData!);
      expect(decoded['candidates'], isNotEmpty);
      expect(decoded['candidates'].first, equals('candidate:client-recover-456'));
    });
  });
}
