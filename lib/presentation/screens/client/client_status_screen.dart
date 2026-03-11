import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:battery_plus/battery_plus.dart';
import '../../../domain/entities/location_update.dart';
import '../../../domain/repositories/tracking_repository.dart';
import '../../../core/config/app_config.dart';
import '../../../main.dart';

class ClientStatusScreen extends StatefulWidget {
  const ClientStatusScreen({super.key});

  @override
  State<ClientStatusScreen> createState() => _ClientStatusScreenState();
}

class _ClientStatusScreenState extends State<ClientStatusScreen>
    with WidgetsBindingObserver {
  String _statusMessage = 'Listening for requests...';
  bool _isDisconnectDialogShowing = false;
  StreamSubscription<String>? _connectionSubscription;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkPermissions();
    _initBackground();
    _listenToHostPings();
  }

  Future<void> _initBackground() async {
    if (Platform.isAndroid) {
      FlutterForegroundTask.init(
        androidNotificationOptions: AndroidNotificationOptions(
          channelId: AppConfig.notificationChannelId,
          channelName: AppConfig.notificationChannelName,
          channelDescription: AppConfig.notificationChannelDescription,
          channelImportance: NotificationChannelImportance.LOW,
          priority: NotificationPriority.LOW,
        ),
        iosNotificationOptions: const IOSNotificationOptions(
          showNotification: true,
          playSound: false,
        ),
        foregroundTaskOptions: ForegroundTaskOptions(
          eventAction: ForegroundTaskEventAction.repeat(
            AppConfig.foregroundTaskIntervalMs,
          ),
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
            notificationTitle: AppConfig.notificationTitle,
            notificationText: AppConfig.notificationText,
            callback: startCallback,
          );
      if (startResult is ServiceRequestSuccess) {
        debugPrint("Foreground service started");
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _connectionSubscription?.cancel();
    if (Platform.isAndroid) {
      FlutterForegroundTask.stopService();
    }
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

  Future<void> _checkPermissions() async {
    try {
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        setState(() {
          _statusMessage = 'Location services are disabled.';
        });
        return;
      }

      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) {
          setState(() {
            _statusMessage = 'Location permissions are denied';
          });
          return;
        }
      }
      if (permission == LocationPermission.deniedForever) {
        setState(() {
          _statusMessage = 'Location permissions are permanently denied';
        });
        return;
      }
    } catch (e) {
      setState(() {
        _statusMessage = 'Error checking permissions: \$e';
      });
    }
  }

  void _listenToHostPings() {
    final repo = context.read<TrackingRepository>();

    // We listen to the connectionState stream for the custom "REQUEST_LOCATION_RECEIVED" state
    // we fire in the WebRTCManager.
    _connectionSubscription?.cancel();
    _connectionSubscription = repo.connectionState.listen((state) async {
      if (state == 'DISCONNECTED') {
        if (mounted) {
          setState(() {
            _statusMessage = 'Disconnected from host.';
          });
        }
      } else if (state.contains('Disconnected') ||
          state.contains('Failed') ||
          state.contains('Closed')) {
        if (state != 'PEER_DISCONNECTED' && mounted) {
          setState(() {
            _statusMessage = 'Connection lost, waiting to reconnect...';
          });
        }
      } else if (state == 'NO_INTERNET') {
        if (mounted) {
          setState(() {
            _statusMessage = 'Waiting for Internet Connection...';
          });
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Internet connection lost. Waiting for network...'),
              backgroundColor: Colors.orange,
              duration: Duration(seconds: 4),
            ),
          );
        }
      } else if (state == 'INTERNET_RESTORED') {
        if (mounted) {
          setState(() {
            _statusMessage = 'Internet restored, reconnecting...';
          });
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Internet restored! Reconnecting...'),
              backgroundColor: Colors.blue,
              duration: Duration(seconds: 3),
            ),
          );
        }
      } else if (state.contains('Connected') && mounted) {
        setState(() {
          _statusMessage = 'Listening for requests...';
        });
      } else if (state == 'REQUEST_LOCATION_RECEIVED') {
        if (mounted) {
          setState(() {
            _statusMessage = 'Fetch location...';
          });
        }

        try {
          // forceAndroidLocationManager allows background location fetches on Android
          // otherwise the FusedLocationProvider gets suspended when screen is off.
          LocationSettings locationSettings;
          if (Platform.isAndroid) {
            locationSettings = AndroidSettings(
              accuracy: LocationAccuracy.high,
              forceLocationManager: true,
            );
          } else if (Platform.isIOS || Platform.isMacOS) {
            locationSettings = AppleSettings(
              accuracy: LocationAccuracy.high,
              activityType: ActivityType.fitness,
            );
          } else {
            locationSettings = const LocationSettings(
              accuracy: LocationAccuracy.high,
            );
          }

          Position position = await Geolocator.getCurrentPosition(
            locationSettings: locationSettings,
          );

          final battery = Battery();
          final batteryLevel = await battery.batteryLevel;

          final update = LocationUpdate(
            coordinates: LatLng(position.latitude, position.longitude),
            timestamp: DateTime.now(),
            batteryLevel: batteryLevel,
          );

          await repo.sendLocationUpdate(update);

          if (mounted) {
            setState(() {
              _statusMessage = 'Location Sent!';
            });
          }

          // Revert back
          Future.delayed(
            Duration(seconds: AppConfig.uiMessageResetDelaySeconds),
            () {
              if (mounted) {
                setState(() {
                  _statusMessage = 'Listening for requests...';
                });
              }
            },
          );
        } catch (e) {
          if (mounted) {
            setState(() {
              _statusMessage = 'Error getting GPS';
            });
          }
        }
      } else if (state == 'PEER_DISCONNECTED') {
        if (mounted && !_isDisconnectDialogShowing) {
          _isDisconnectDialogShowing = true;
          showDialog(
            context: context,
            barrierDismissible: false,
            builder: (ctx) => AlertDialog(
              title: const Text('Host Disconnected'),
              content: const Text('The Host has closed the session.'),
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
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Following Status (Client)')),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.security, size: 80, color: Colors.green),
            const SizedBox(height: 24),
            const Text(
              'Securely Connected',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            Text(
              _statusMessage,
              style: const TextStyle(fontSize: 16, color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }
}
