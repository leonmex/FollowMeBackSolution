import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:mocktail/mocktail.dart';
import 'package:follow_me_back/domain/entities/location_update.dart';
import 'package:follow_me_back/presentation/screens/client/client_status_screen.dart';
import 'package:follow_me_back/domain/repositories/tracking_repository.dart';

import 'dart:async';

class MockTrackingRepository extends Mock implements TrackingRepository {}

class FakeLocationUpdate extends Fake implements LocationUpdate {}

void main() {
  late MockTrackingRepository mockTrackingRepository;
  late StreamController<String> connectionStateController;

  setUpAll(() {
    registerFallbackValue(FakeLocationUpdate());
  });

  setUp(() {
    mockTrackingRepository = MockTrackingRepository();
    connectionStateController = StreamController<String>.broadcast();
    when(
      () => mockTrackingRepository.connectionState,
    ).thenAnswer((_) => connectionStateController.stream);
  });

  Widget createWidgetUnderTest() {
    return MaterialApp(
      home: Provider<TrackingRepository>.value(
        value: mockTrackingRepository,
        child: const ClientStatusScreen(),
      ),
    );
  }

  testWidgets(
    'ClientStatusScreen initializes flutter_foreground_task on Android',
    (tester) async {
      final log = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('flutter_foreground_task/methods'),
        (MethodCall methodCall) async {
          log.add(methodCall);
          return true;
        },
      );

      await tester.pumpWidget(createWidgetUnderTest());
      await tester.pumpAndSettle();

      expect(find.text('Securely Connected'), findsOneWidget);

      // Cleanup mock handler
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('flutter_foreground_task/methods'),
        null,
      );
    },
  );

  testWidgets('ClientStatusScreen responds to background ping requests', (
    tester,
  ) async {
    // Mock Geolocator method channel
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('flutter.baseflow.com/geolocator'),
      (MethodCall methodCall) async {
        if (methodCall.method == 'getCurrentPosition') {
          return {
            'latitude': 37.4219983,
            'longitude': -122.084,
            'timestamp': DateTime.now().millisecondsSinceEpoch,
            'altitude': 0.0,
            'accuracy': 10.0,
            'heading': 0.0,
            'speed': 0.0,
            'speedAccuracy': 0.0,
          };
        }
        return null;
      },
    );

    when(
      () => mockTrackingRepository.sendLocationUpdate(any()),
    ).thenAnswer((_) async {});

    await tester.pumpWidget(createWidgetUnderTest());
    await tester.pumpAndSettle();

    // Trigger a ping request as if receiving from WebRTC
    connectionStateController.add('REQUEST_LOCATION_RECEIVED');
    await tester.pumpAndSettle();

    // Verify the UI changes to indicate fetching
    expect(find.text('Location Sent!'), findsOneWidget);

    // Verify that the repository was called to send the location update
    verify(() => mockTrackingRepository.sendLocationUpdate(any())).called(1);

    // Fast-forward 2 seconds to flush the Future.delayed Timer in the widget
    await tester.pump(const Duration(seconds: 2));

    // Cleanup
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('flutter.baseflow.com/geolocator'),
      null,
    );
    await connectionStateController.close();
  });
}
