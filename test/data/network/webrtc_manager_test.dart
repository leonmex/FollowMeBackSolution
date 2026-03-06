import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:follow_me_back/data/network/webrtc_manager.dart';
import 'package:follow_me_back/domain/entities/session_role.dart';
import 'package:mocktail/mocktail.dart';

void main() {
  setUpAll(() {
    registerFallbackValue(SessionRole.host);
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

    test('RTCPeerConnectionStateFailed sets isConnected to false', () {
      webRTCManager.handleConnectionState(
        RTCPeerConnectionState.RTCPeerConnectionStateConnected,
      );
      webRTCManager.handleConnectionState(
        RTCPeerConnectionState.RTCPeerConnectionStateFailed,
      );
      expect(webRTCManager.isConnected, isFalse);
    });

    test('RTCPeerConnectionStateClosed sets isConnected to false', () {
      webRTCManager.handleConnectionState(
        RTCPeerConnectionState.RTCPeerConnectionStateConnected,
      );
      webRTCManager.handleConnectionState(
        RTCPeerConnectionState.RTCPeerConnectionStateClosed,
      );
      expect(webRTCManager.isConnected, isFalse);
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

    test('RTCIceConnectionStateFailed DOES drop session', () {
      webRTCManager.handleConnectionState(
        RTCPeerConnectionState.RTCPeerConnectionStateConnected,
      );
      expect(webRTCManager.isConnected, isTrue);

      webRTCManager.handleIceConnectionState(
        RTCIceConnectionState.RTCIceConnectionStateFailed,
      );

      expect(webRTCManager.isConnected, isFalse);
    });

    test('RTCIceConnectionStateClosed DOES drop session', () {
      webRTCManager.handleConnectionState(
        RTCPeerConnectionState.RTCPeerConnectionStateConnected,
      );
      expect(webRTCManager.isConnected, isTrue);

      webRTCManager.handleIceConnectionState(
        RTCIceConnectionState.RTCIceConnectionStateClosed,
      );

      expect(webRTCManager.isConnected, isFalse);
    });
  });
}
