import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:provider/provider.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import '../../../domain/repositories/tracking_repository.dart';
import '../../view_models/host_map_view_model.dart';
import '../../../main.dart';

class HostMapScreen extends StatefulWidget {
  const HostMapScreen({super.key});

  @override
  State<HostMapScreen> createState() => _HostMapScreenState();
}

class _HostMapScreenState extends State<HostMapScreen> {
  final MapController _mapController = MapController();
  late HostMapViewModel _viewModel;
  bool _isShowingDisconnectDialog = false;

  @override
  void initState() {
    super.initState();
    _initBackground();
    _viewModel = context.read<HostMapViewModel>();
    _viewModel.addListener(_onViewModelChange);
  }

  void _onViewModelChange() {
    if (_viewModel.connectionStatus == 'PEER_DISCONNECTED') {
      if (mounted && !_isShowingDisconnectDialog) {
        _isShowingDisconnectDialog = true;
        showDialog(
          context: context,
          barrierDismissible: false,
          builder: (ctx) => AlertDialog(
            title: const Text('Client Disconnected'),
            content: const Text(
              'The Follower has closed their app or lost connection.',
            ),
            actions: [
              TextButton(
                onPressed: () {
                  Navigator.of(ctx).pop();
                  if (mounted) {
                    Navigator.of(context).pop();
                    context.read<TrackingRepository>().disconnect();
                  }
                },
                child: const Text('OK'),
              ),
            ],
          ),
        );
      }
    }
  }

  Future<void> _initBackground() async {
    if (Platform.isAndroid) {
      FlutterForegroundTask.init(
        androidNotificationOptions: AndroidNotificationOptions(
          channelId: 'follow_me_back_channel',
          channelName: 'Location Tracking',
          channelDescription:
              'This notification appears when tracking is active',
          channelImportance: NotificationChannelImportance.LOW,
          priority: NotificationPriority.LOW,
        ),
        iosNotificationOptions: const IOSNotificationOptions(
          showNotification: true,
          playSound: false,
        ),
        foregroundTaskOptions: ForegroundTaskOptions(
          eventAction: ForegroundTaskEventAction.repeat(5000),
          autoRunOnBoot: false,
          allowWakeLock: true,
          allowWifiLock: true,
        ),
      );

      bool reqResult =
          await FlutterForegroundTask.requestIgnoreBatteryOptimization();
      if (!reqResult) {
        debugPrint("Battery optimization ignore denied.");
      }

      ServiceRequestResult startResult =
          await FlutterForegroundTask.startService(
            notificationTitle: 'Follow Me Back is active',
            notificationText: 'Tracking session is running in the background',
            callback: startCallback,
          );
      if (startResult is ServiceRequestSuccess) {
        debugPrint("Foreground service started on Host");
      }
    }
  }

  @override
  void dispose() {
    if (Platform.isAndroid) {
      FlutterForegroundTask.stopService();
    }
    _viewModel.removeListener(_onViewModelChange);
    _mapController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<HostMapViewModel>(
      builder: (context, viewModel, child) {
        final lastLoc = viewModel.locations.isNotEmpty
            ? viewModel.locations.last
            : viewModel.hostLocation;

        return Scaffold(
          appBar: AppBar(
            title: const Text('Following Map (Host)'),
            bottom: PreferredSize(
              preferredSize: const Size.fromHeight(20.0),
              child: Text(
                viewModel.connectionStatus,
                style: const TextStyle(fontSize: 12, color: Colors.white70),
              ),
            ),
          ),
          body: lastLoc == null
              ? const Center(child: CircularProgressIndicator())
              : FlutterMap(
                  mapController: _mapController,
                  options: MapOptions(
                    initialCenter: lastLoc,
                    initialZoom: 15.0,
                  ),
                  children: [
                    TileLayer(
                      urlTemplate:
                          'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                      userAgentPackageName: 'com.example.follow_me_back',
                    ),
                    if (viewModel.locations.isNotEmpty &&
                        viewModel.hostLocation != null)
                      PolylineLayer(
                        polylines: [
                          Polyline(
                            points: [
                              viewModel.hostLocation!,
                              ...viewModel.locations,
                            ],
                            strokeWidth: 4.0,
                            color: Colors.blue,
                          ),
                        ],
                      ),
                    MarkerLayer(
                      markers: [
                        if (viewModel.hostLocation != null)
                          Marker(
                            point: viewModel.hostLocation!,
                            width: 50,
                            height: 50,
                            child: const Icon(
                              Icons.person_pin,
                              color: Colors.green,
                              size: 45,
                            ),
                          ),
                        ...viewModel.locations.map((loc) {
                          final isLast = loc == viewModel.locations.last;
                          return Marker(
                            point: loc,
                            width: isLast ? 60 : 40,
                            height: isLast ? 60 : 40,
                            child: Icon(
                              Icons.location_on,
                              color: isLast
                                  ? Colors.red
                                  : Colors.blue.withValues(alpha: 0.5),
                              size: isLast ? 50 : 30,
                            ),
                          );
                        }),
                      ],
                    ),
                  ],
                ),
          floatingActionButton: Column(
            mainAxisAlignment: MainAxisAlignment.end,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              FloatingActionButton(
                heroTag: 'centerMapHost',
                onPressed: () {
                  final centerLoc = viewModel.locations.isNotEmpty
                      ? viewModel.locations.last
                      : viewModel.hostLocation;
                  if (centerLoc != null) {
                    _mapController.move(centerLoc, _mapController.camera.zoom);
                  }
                },
                child: const Stack(
                  alignment: Alignment.center,
                  children: [
                    Padding(
                      padding: EdgeInsets.only(top: 8.0),
                      child: Icon(Icons.public, size: 28),
                    ),
                    Positioned(
                      top: 8,
                      child: Icon(Icons.location_on, size: 20),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              FloatingActionButton.extended(
                heroTag: 'requestUpdateHost',
                onPressed: () => viewModel.requestUpdate(),
                foregroundColor: viewModel.updateStatus == UpdateStatus.success
                    ? Colors.green
                    : viewModel.updateStatus == UpdateStatus.error
                    ? Colors.red
                    : null,
                icon: const Icon(Icons.refresh),
                label: const Text('Request Update'),
              ),
            ],
          ),
        );
      },
    );
  }
}
