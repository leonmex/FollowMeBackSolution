import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:mocktail/mocktail.dart';
import 'package:follow_me_back/domain/repositories/tracking_repository.dart';
import 'package:follow_me_back/presentation/screens/role_selection_screen.dart';
import 'package:follow_me_back/domain/entities/session_role.dart';
import 'package:follow_me_back/domain/entities/connection_method.dart';

class MockTrackingRepository extends Mock implements TrackingRepository {}

void main() {
  late MockTrackingRepository mockTrackingRepository;

  setUp(() {
    mockTrackingRepository = MockTrackingRepository();
    // Provide a dummy stream for tests where stream state doesn't change
    when(
      () => mockTrackingRepository.connectionState,
    ).thenAnswer((_) => const Stream.empty());
  });

  Widget createWidgetUnderTest({
    ConnectionMethod method = ConnectionMethod.qr,
  }) {
    return MaterialApp(
      home: Provider<TrackingRepository>.value(
        value: mockTrackingRepository,
        child: RoleSelectionScreen(selectedMethod: method),
      ),
    );
  }

  group('RoleSelectionScreen Tests', () {
    testWidgets('Shows Role Cards when NOT connected (QR Method)', (
      WidgetTester tester,
    ) async {
      when(() => mockTrackingRepository.isConnected).thenReturn(false);
      when(() => mockTrackingRepository.currentRole).thenReturn(null);

      await tester.pumpWidget(
        createWidgetUnderTest(method: ConnectionMethod.qr),
      );

      // Should show the title "Select Your Role"
      expect(find.text('Select Your Role'), findsOneWidget);
      // Should show generic Host and Client cards
      expect(find.text('Following (Host)'), findsOneWidget);
      expect(find.text('Follower (Client)'), findsOneWidget);

      // Verify QR specific subtitles
      expect(
        find.text('Track another device, view locations on a Map.'),
        findsOneWidget,
      );
      expect(
        find.text('Share your location directly with a Host.'),
        findsOneWidget,
      );

      // Should NOT show Active Session UI
      expect(find.text('Return to Session'), findsNothing);
    });

    testWidgets('Shows Role Cards when NOT connected (NFC Method)', (
      WidgetTester tester,
    ) async {
      when(() => mockTrackingRepository.isConnected).thenReturn(false);
      when(() => mockTrackingRepository.currentRole).thenReturn(null);

      await tester.pumpWidget(
        createWidgetUnderTest(method: ConnectionMethod.nfc),
      );

      // Should show generic Host and Client cards
      expect(find.text('Following (Host)'), findsOneWidget);
      expect(find.text('Follower (Client)'), findsOneWidget);

      // Verify NFC specific subtitles
      expect(
        find.text('Create a sharing link and wait for a tap.'),
        findsOneWidget,
      );
      expect(find.text('Tap your device to the Host.'), findsOneWidget);
    });

    testWidgets('Shows Active Session UI when connected as Host', (
      WidgetTester tester,
    ) async {
      when(() => mockTrackingRepository.isConnected).thenReturn(true);
      when(
        () => mockTrackingRepository.currentRole,
      ).thenReturn(SessionRole.host);

      final controller = StreamController<String>();
      when(
        () => mockTrackingRepository.connectionState,
      ).thenAnswer((_) => controller.stream);

      await tester.pumpWidget(createWidgetUnderTest());
      await tester.pump();

      expect(find.textContaining('Active Session'), findsOneWidget);
      expect(find.text('Return to Session'), findsOneWidget);
      expect(find.text('Close Connection'), findsOneWidget);

      // Should hide standard role cards
      expect(find.text('Following (Host)'), findsNothing);
    });

    testWidgets(
      'Tapping Close Connection disconnects and returns to Role Selection',
      (WidgetTester tester) async {
        when(() => mockTrackingRepository.isConnected).thenReturn(true);
        when(
          () => mockTrackingRepository.currentRole,
        ).thenReturn(SessionRole.client);
        when(
          () => mockTrackingRepository.disconnect(),
        ).thenAnswer((_) async {});

        final controller = StreamController<String>.broadcast();
        when(
          () => mockTrackingRepository.connectionState,
        ).thenAnswer((_) => controller.stream);

        await tester.pumpWidget(createWidgetUnderTest());

        expect(find.text('Close Connection'), findsOneWidget);

        await tester.tap(find.text('Close Connection'));
        await tester.pump();

        verify(() => mockTrackingRepository.disconnect()).called(1);
      },
    );
  });
}
