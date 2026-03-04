import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:follow_me_back/data/network/webrtc_manager.dart';
import 'package:follow_me_back/data/repositories/tracking_repository_impl.dart';
import 'package:follow_me_back/domain/entities/session_role.dart';

class MockWebRTCManager extends Mock implements WebRTCManager {}

void main() {
  late MockWebRTCManager mockWebRTCManager;
  late TrackingRepositoryImpl repository;

  setUp(() {
    mockWebRTCManager = MockWebRTCManager();
    repository = TrackingRepositoryImpl(webRTCManager: mockWebRTCManager);
  });

  group('TrackingRepositoryImpl Persistent Session Tests', () {
    test('isConnected delegates to WebRTCManager', () {
      when(() => mockWebRTCManager.isConnected).thenReturn(true);
      expect(repository.isConnected, isTrue);

      when(() => mockWebRTCManager.isConnected).thenReturn(false);
      expect(repository.isConnected, isFalse);
    });

    test('currentRole delegates to WebRTCManager', () {
      when(() => mockWebRTCManager.currentRole).thenReturn(SessionRole.host);
      expect(repository.currentRole, SessionRole.host);

      when(() => mockWebRTCManager.currentRole).thenReturn(SessionRole.client);
      expect(repository.currentRole, SessionRole.client);
    });

    test('disconnect calls WebRTCManager disconnect', () async {
      when(() => mockWebRTCManager.disconnect()).thenAnswer((_) async {});

      await repository.disconnect();

      verify(() => mockWebRTCManager.disconnect()).called(1);
    });
  });
}
