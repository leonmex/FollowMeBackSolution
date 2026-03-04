import 'package:latlong2/latlong.dart';

class LocationUpdate {
  final LatLng coordinates;
  final DateTime timestamp;

  LocationUpdate({required this.coordinates, required this.timestamp});

  Map<String, dynamic> toJson() {
    return {
      'lat': coordinates.latitude,
      'lng': coordinates.longitude,
      'timestamp': timestamp.toIso8601String(),
    };
  }

  factory LocationUpdate.fromJson(Map<String, dynamic> json) {
    return LocationUpdate(
      coordinates: LatLng(json['lat'] as double, json['lng'] as double),
      timestamp: DateTime.parse(json['timestamp'] as String),
    );
  }
}
