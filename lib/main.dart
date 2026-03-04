import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'domain/repositories/tracking_repository.dart';
import 'data/repositories/tracking_repository_impl.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'presentation/screens/intro_screen.dart';
import 'presentation/view_models/host_map_view_model.dart';

// The callback function must be a top-level function.
@pragma('vm:entry-point')
void startCallback() {
  FlutterForegroundTask.setTaskHandler(LocationTaskHandler());
}

class LocationTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    debugPrint('Foreground Service Task Started');
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    // We don't necessarily need a repeat event; the isolate just needs to be alive
    // so our WebRTC DataChannel listeners in the main isolate keep firing.
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isDestroyed) async {
    debugPrint('Foreground Service Task Destroyed');
  }
}

void main() {
  // Initialize port for communication between TaskHandler and UI.
  FlutterForegroundTask.initCommunicationPort();
  runApp(
    MultiProvider(
      providers: [
        // Provide the Singleton Repository instance across the entire app
        Provider<TrackingRepository>(
          create: (_) => TrackingRepositoryImpl(),
          dispose: (_, repo) => repo.dispose(),
        ),
        // Provide the Host Map View Model
        ChangeNotifierProxyProvider<TrackingRepository, HostMapViewModel>(
          create: (context) => HostMapViewModel(
            Provider.of<TrackingRepository>(context, listen: false),
          ),
          update: (context, repository, previousViewModel) =>
              previousViewModel!,
        ),
      ],
      child: const FollowMeBackApp(),
    ),
  );
}

class FollowMeBackApp extends StatelessWidget {
  const FollowMeBackApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Follow Me Back',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: const IntroScreen(),
    );
  }
}
