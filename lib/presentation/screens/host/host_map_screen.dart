import 'dart:io';
import 'package:flutter/cupertino.dart';
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

class _HostMapScreenState extends State<HostMapScreen>
    with WidgetsBindingObserver {
  final MapController _mapController = MapController();
  late HostMapViewModel _viewModel;
  bool _isShowingDisconnectDialog = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
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
              'The Client has disconnected from the session.',
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
    WidgetsBinding.instance.removeObserver(this);
    if (Platform.isAndroid) {
      FlutterForegroundTask.stopService();
    }
    _viewModel.removeListener(_onViewModelChange);
    _mapController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.detached) {
      // The app is being destroyed by the user or OS.
      // On Android, swiping the app away can trigger `detached`, but we want
      // the Foreground Service to keep the WebRTC Isolate alive.
      // We only forcefully disconnect on iOS where background execution is stricter.
      if (Platform.isIOS && mounted) {
        context.read<TrackingRepository>().disconnect();
      }
    }
  }

  Widget _buildConnectionIcon(PeerConnectionIcon state) {
    const double iconSize = 26;
    const double containerSize = 36;

    switch (state) {
      case PeerConnectionIcon.connected:
        return Container(
          key: const ValueKey('connected'),
          width: containerSize,
          height: containerSize,
          decoration: BoxDecoration(
            color: Colors.green.withValues(alpha: 0.2),
            shape: BoxShape.circle,
            border: Border.all(color: Colors.green, width: 1.5),
          ),
          child: const Icon(
            CupertinoIcons.arrow_right_arrow_left_circle_fill,
            color: Colors.green,
            size: iconSize,
          ),
        );
      case PeerConnectionIcon.sessionAlive:
        return Container(
          key: const ValueKey('sessionAlive'),
          width: containerSize,
          height: containerSize,
          decoration: BoxDecoration(
            color: Colors.orange.withValues(alpha: 0.2),
            shape: BoxShape.circle,
            border: Border.all(color: Colors.orange, width: 1.5),
          ),
          child: const Icon(
            CupertinoIcons.arrow_right_arrow_left_circle,
            color: Colors.orange,
            size: iconSize,
          ),
        );
      case PeerConnectionIcon.clientDisconnected:
        return Container(
          key: const ValueKey('clientDisconnected'),
          width: containerSize,
          height: containerSize,
          decoration: BoxDecoration(
            color: Colors.red.withValues(alpha: 0.2),
            shape: BoxShape.circle,
            border: Border.all(color: Colors.red, width: 1.5),
          ),
          child: const Icon(
            CupertinoIcons.arrow_right_circle,
            color: Colors.red,
            size: iconSize,
          ),
        );
      case PeerConnectionIcon.reconnecting:
        return _SpinningIcon(
          key: const ValueKey('reconnecting'),
          size: containerSize,
          iconSize: iconSize,
        );
    }
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
              preferredSize: const Size.fromHeight(52.0),
              child: Padding(
                padding: const EdgeInsets.only(bottom: 8.0),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 400),
                      transitionBuilder: (child, animation) => ScaleTransition(
                        scale: animation,
                        child: FadeTransition(opacity: animation, child: child),
                      ),
                      child: _buildConnectionIcon(
                        viewModel.connectionIconState,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      viewModel.connectionStatus == 'PEER_DISCONNECTED'
                          ? 'Client disconnected'
                          : viewModel.connectionStatus,
                      style: const TextStyle(
                        fontSize: 12,
                        color: Colors.white70,
                      ),
                    ),
                    if (viewModel.clientBatteryLevel != null) ...[
                      const SizedBox(width: 8),
                      Icon(
                        viewModel.clientBatteryLevel! > 20
                            ? Icons.battery_full
                            : Icons.battery_alert,
                        size: 14,
                        color: viewModel.clientBatteryLevel! > 50
                            ? Colors.green
                            : viewModel.clientBatteryLevel! > 20
                            ? Colors.orange
                            : Colors.red,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        '${viewModel.clientBatteryLevel}%',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: viewModel.clientBatteryLevel! > 50
                              ? Colors.green
                              : viewModel.clientBatteryLevel! > 20
                              ? Colors.orange
                              : Colors.red,
                        ),
                      ),
                    ],
                  ],
                ),
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
                    if (viewModel.locations.length > 1)
                      PolylineLayer(
                        polylines: [
                          Polyline(
                            points: viewModel.locations,
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

class _SpinningIcon extends StatefulWidget {
  final double size;
  final double iconSize;

  const _SpinningIcon({super.key, required this.size, required this.iconSize});

  @override
  State<_SpinningIcon> createState() => _SpinningIconState();
}

class _SpinningIconState extends State<_SpinningIcon>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RotationTransition(
      turns: _controller,
      child: Container(
        width: widget.size,
        height: widget.size,
        decoration: const BoxDecoration(
          color: Colors.red,
          shape: BoxShape.circle,
        ),
        child: Icon(
          CupertinoIcons.arrow_2_circlepath_circle,
          color: Colors.white,
          size: widget.iconSize,
        ),
      ),
    );
  }
}
