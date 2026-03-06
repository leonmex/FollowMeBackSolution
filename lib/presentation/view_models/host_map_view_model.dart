import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import '../../../domain/repositories/tracking_repository.dart';
import '../../../core/config/app_config.dart';

enum UpdateStatus { initial, requesting, success, error }

class HostMapViewModel extends ChangeNotifier {
  final TrackingRepository repository;

  // FIFO Buffer: Max 5 elements
  final List<LatLng> _locations = [];
  int? _clientBatteryLevel;

  String _connectionStatus = 'Waiting for connection...';
  LatLng? _hostLocation;

  UpdateStatus _updateStatus = UpdateStatus.initial;
  Timer? _updateTimer;

  HostMapViewModel(this.repository) {
    _listenToUpdates();
    _fetchHostLocation();
  }

  List<LatLng> get locations => List.unmodifiable(_locations);
  int? get clientBatteryLevel => _clientBatteryLevel;
  String get connectionStatus => _connectionStatus;
  LatLng? get hostLocation => _hostLocation;
  UpdateStatus get updateStatus => _updateStatus;

  Future<void> _fetchHostLocation() async {
    try {
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        _connectionStatus = 'Location services are disabled on Host.';
        notifyListeners();
        return;
      }

      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) {
          _connectionStatus = 'Host Location denied';
          notifyListeners();
          return;
        }
      }

      if (permission == LocationPermission.deniedForever) {
        _connectionStatus = 'Host Location permanently denied';
        notifyListeners();
        return;
      }

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
      _hostLocation = LatLng(position.latitude, position.longitude);
      notifyListeners();
    } catch (e) {
      debugPrint("Error fetching host location: \$e");
    }
  }

  void _listenToUpdates() {
    repository.connectionState.listen((state) {
      if (state.contains('Disconnected') ||
          state.contains('Failed') ||
          state.contains('Closed')) {
        if (state != 'PEER_DISCONNECTED') {
          _connectionStatus = 'Connection lost, waiting to reconnect...';
        } else {
          _connectionStatus = state;
        }
      } else if (state.contains('Connected')) {
        _connectionStatus = 'Securely Connected';
      } else {
        _connectionStatus = state;
      }
      notifyListeners();
    });

    repository.locationUpdates.listen((update) {
      _addLocation(update.coordinates, batteryLevel: update.batteryLevel);
    });
  }

  void _addLocation(LatLng newLocation, {int? batteryLevel}) {
    if (_locations.length >= AppConfig.maxClientLocationsToSave) {
      _locations.removeAt(0); // Remove oldest
    }
    _locations.add(newLocation);
    if (batteryLevel != null) {
      _clientBatteryLevel = batteryLevel;
    }
    if (_updateStatus == UpdateStatus.requesting) {
      _updateStatus = UpdateStatus.success;
      _updateTimer?.cancel();
    }
    notifyListeners();
  }

  Future<void> requestUpdate() async {
    try {
      _updateStatus = UpdateStatus.requesting;
      notifyListeners();

      await repository.requestLocationUpdate();

      _updateTimer?.cancel();
      _updateTimer = Timer(const Duration(seconds: 5), () {
        if (_updateStatus == UpdateStatus.requesting) {
          _updateStatus = UpdateStatus.error;
          notifyListeners();
        }
      });
    } catch (e) {
      _connectionStatus = "Error requesting update";
      _updateStatus = UpdateStatus.error;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _updateTimer?.cancel();
    super.dispose();
  }
}
