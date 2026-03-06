import 'package:latlong2/latlong.dart';

class LocationUpdate {
  final LatLng coordinates;
  final DateTime timestamp;
  final int? batteryLevel;

  LocationUpdate({
    required this.coordinates,
    required this.timestamp,
    this.batteryLevel,
  });

  Map<String, dynamic> toJson() {
    return {
      'lat': coordinates.latitude,
      'lng': coordinates.longitude,
      'timestamp': timestamp.toIso8601String(),
      if (batteryLevel != null) 'batteryLevel': batteryLevel,
    };
  }

  factory LocationUpdate.fromJson(Map<String, dynamic> json) {
    return LocationUpdate(
      coordinates: LatLng(json['lat'] as double, json['lng'] as double),
      timestamp: DateTime.parse(json['timestamp'] as String),
      batteryLevel: json['batteryLevel'] as int?,
    );
  }
}
