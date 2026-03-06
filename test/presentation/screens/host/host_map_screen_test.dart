import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:mocktail/mocktail.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:follow_me_back/presentation/screens/host/host_map_screen.dart';
import 'package:follow_me_back/presentation/view_models/host_map_view_model.dart';
import 'package:follow_me_back/domain/repositories/tracking_repository.dart';
import 'package:latlong2/latlong.dart' as latlong;

class MockTrackingRepository extends Mock implements TrackingRepository {}

class MockHostMapViewModel extends Mock implements HostMapViewModel {}

void main() {
  late MockHostMapViewModel mockViewModel;

  setUp(() {
    mockViewModel = MockHostMapViewModel();
    when(() => mockViewModel.locations).thenReturn([]);
    when(() => mockViewModel.hostLocation).thenReturn(null);
    when(() => mockViewModel.connectionStatus).thenReturn('Connecting...');
    when(() => mockViewModel.updateStatus).thenReturn(UpdateStatus.initial);
  });

  Widget createWidgetUnderTest() {
    return MaterialApp(
      home: ChangeNotifierProvider<HostMapViewModel>.value(
        value: mockViewModel,
        child: const HostMapScreen(),
      ),
    );
  }

  testWidgets('HostMapScreen initializes flutter_foreground_task on Android', (
    tester,
  ) async {
    final log = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('flutter_foreground_task/methods'),
      (MethodCall methodCall) async {
        log.add(methodCall);
        return true;
      },
    );

    await tester.pumpWidget(createWidgetUnderTest());

    expect(find.byType(FlutterMap), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    when(
      () => mockViewModel.hostLocation,
    ).thenReturn(const latlong.LatLng(0, 0));
    mockViewModel.notifyListeners(); // simulate update
    await tester.pumpWidget(createWidgetUnderTest());
    await tester.pump(const Duration(milliseconds: 50));

    // Cleanup mock handler
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('flutter_foreground_task/methods'),
      null,
    );
  });

  testWidgets(
    'HostMapScreen draws polyline only for client locations, not host bounds (Data Provider)',
    (tester) async {
      final clientLocations = [
        const latlong.LatLng(1.0, 1.0),
        const latlong.LatLng(2.0, 2.0),
        const latlong.LatLng(3.0, 3.0),
        const latlong.LatLng(4.0, 4.0),
        const latlong.LatLng(5.0, 5.0),
      ];
      final hostLoc = const latlong.LatLng(0.0, 0.0);

      when(() => mockViewModel.locations).thenReturn(clientLocations);
      when(() => mockViewModel.hostLocation).thenReturn(hostLoc);
      when(() => mockViewModel.connectionStatus).thenReturn('Connected');

      await tester.pumpWidget(createWidgetUnderTest());

      final polylineLayerFinder = find.byType(PolylineLayer);
      expect(polylineLayerFinder, findsOneWidget);

      final polylineLayer = tester.widget<PolylineLayer>(polylineLayerFinder);

      expect(polylineLayer.polylines.length, 1);

      final points = polylineLayer.polylines.first.points;

      expect(points.length, clientLocations.length);
      for (final loc in clientLocations) {
        expect(points.contains(loc), isTrue);
      }

      expect(
        points.contains(hostLoc),
        isFalse,
        reason: 'Polyline should not tether to Host location',
      );
    },
  );
}
