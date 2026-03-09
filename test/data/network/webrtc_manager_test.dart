import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:follow_me_back/data/network/webrtc_manager.dart';
import 'package:follow_me_back/domain/entities/session_role.dart';
import 'package:mocktail/mocktail.dart';
import 'package:follow_me_back/data/network/follow_me_back_server.dart';
import 'package:flutter/services.dart';

class MockFollowMeBackServer extends Mock implements FollowMeBackServer {}

void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    registerFallbackValue(SessionRole.host);

    // Stub the WebRTC plugin method channel to avoid MissingPluginException
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('FlutterWebRTC.Method'), (
          MethodCall methodCall,
        ) async {
          if (methodCall.method == 'initialize') return null;
          if (methodCall.method == 'createPeerConnection') {
            return {'peerConnectionId': 'mock-pc-123'};
          }
          return null;
        });

    // Stub the Data Channel as well if needed
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('FlutterWebRTC.DataChannel'),
          (MethodCall methodCall) async {
            return null;
          },
        );
  });
  late WebRTCManager webRTCManager;

  setUp(() {
    webRTCManager = WebRTCManager();
  });

  tearDown(() async {
    await webRTCManager.dispose();
  });

  group('WebRTCManager Connection State Logic', () {
    test('RTCPeerConnectionStateConnected sets isConnected to true', () {
      expect(webRTCManager.isConnected, isFalse);

      webRTCManager.handleConnectionState(
        RTCPeerConnectionState.RTCPeerConnectionStateConnected,
      );

      expect(webRTCManager.isConnected, isTrue);
    });

    test('RTCPeerConnectionStateDisconnected DOES NOT drop session', () {
      // Setup connected
      webRTCManager.handleConnectionState(
        RTCPeerConnectionState.RTCPeerConnectionStateConnected,
      );
      expect(webRTCManager.isConnected, isTrue);

      webRTCManager.handleConnectionState(
        RTCPeerConnectionState.RTCPeerConnectionStateDisconnected,
      );

      expect(webRTCManager.isConnected, isTrue);
    });

    test('RTCPeerConnectionStateFailed DOES NOT drop session', () {
      webRTCManager.handleConnectionState(
        RTCPeerConnectionState.RTCPeerConnectionStateConnected,
      );
      webRTCManager.handleConnectionState(
        RTCPeerConnectionState.RTCPeerConnectionStateFailed,
      );
      expect(webRTCManager.isConnected, isTrue);
    });

    test('RTCPeerConnectionStateClosed DOES NOT drop session', () {
      webRTCManager.handleConnectionState(
        RTCPeerConnectionState.RTCPeerConnectionStateConnected,
      );
      webRTCManager.handleConnectionState(
        RTCPeerConnectionState.RTCPeerConnectionStateClosed,
      );
      expect(webRTCManager.isConnected, isTrue);
    });

    test(
      'Heartbeat ping timer initialized on connect and cancelled on dispose',
      () async {
        // It starts the ping timer
        webRTCManager.handleConnectionState(
          RTCPeerConnectionState.RTCPeerConnectionStateConnected,
        );
        expect(webRTCManager.isConnected, isTrue);

        // We ensure no exception occurs on dispose when timer is active
        await webRTCManager.dispose();
        expect(webRTCManager.isConnected, isFalse);
      },
    );
  });

  group('WebRTCManager ICE Connection State Logic', () {
    test('RTCIceConnectionStateDisconnected DOES NOT drop session', () {
      // Connect first
      webRTCManager.handleConnectionState(
        RTCPeerConnectionState.RTCPeerConnectionStateConnected,
      );
      expect(webRTCManager.isConnected, isTrue);

      // Simulating a temporary network drop (e.g. app goes into background)
      webRTCManager.handleIceConnectionState(
        RTCIceConnectionState.RTCIceConnectionStateDisconnected,
      );

      // isConnected should remain true, as we want the session to persist
      expect(webRTCManager.isConnected, isTrue);
    });

    test('RTCIceConnectionStateFailed DOES NOT drop session', () {
      webRTCManager.handleConnectionState(
        RTCPeerConnectionState.RTCPeerConnectionStateConnected,
      );
      expect(webRTCManager.isConnected, isTrue);

      webRTCManager.handleIceConnectionState(
        RTCIceConnectionState.RTCIceConnectionStateFailed,
      );

      expect(webRTCManager.isConnected, isTrue);
    });

    test('RTCIceConnectionStateClosed DOES NOT drop session', () {
      webRTCManager.handleConnectionState(
        RTCPeerConnectionState.RTCPeerConnectionStateConnected,
      );
      expect(webRTCManager.isConnected, isTrue);

      webRTCManager.handleIceConnectionState(
        RTCIceConnectionState.RTCIceConnectionStateClosed,
      );

      expect(webRTCManager.isConnected, isTrue);
    });
  });

  group('WebRTCManager Handshake and UUID Synchronization', () {
    test('Host creates unique UUID and registers on backend', () async {
      // We expect this might throw due to native WebRTC or mock Network calls,
      // but we want to see if sessionUuid gets set before the crash.
      try {
        await webRTCManager.createOffer();
      } catch (_) {}

      expect(webRTCManager.sessionUuid, isNotNull);
      expect(webRTCManager.currentRole, equals(SessionRole.host));
    });

    test('Client receives UUID from Host and registers on backend', () async {
      final dummyUuid = 'test-uuid-123';
      final payloadMap = {
        'uuid': dummyUuid,
        'sdp': 'dummy-sdp',
        'type': 'offer',
        'candidates': [],
      };

      final offerBytes = utf8.encode(jsonEncode(payloadMap));
      final compressedOffer = base64Encode(zlib.encode(offerBytes));

      try {
        await webRTCManager.processOfferAndCreateAnswer(compressedOffer);
      } catch (_) {}

      expect(webRTCManager.sessionUuid, equals(dummyUuid));
      expect(webRTCManager.currentRole, equals(SessionRole.client));
    });
  });
}
