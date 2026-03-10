import '../entities/location_update.dart';
import '../entities/session_role.dart';

/// The core interface for our P2P Tracking features.
abstract class TrackingRepository {
  /// The stream of location updates received from the connected peer.
  Stream<LocationUpdate> get locationUpdates;

  /// The physical connection state (e.g., disconnected, connecting, connected).
  Stream<String> get connectionState;

  bool get isConnected;
  SessionRole? get currentRole;

  /// Called by the Host to start a new tracking session.
  /// Returns the Offer JSON string to be encoded in a QR Code.
  Future<String> createHostOffer();

  /// Called by the Client when it scans the Host's Offer QR Code (UUID).
  Future<void> clientProcessHostOffer(String uuid);

  /// Called by the Host to wait for the Client to scan its QR and respond.
  Future<void> waitForPairing();

  /// Sends a string payload to the connected peer over the direct Data Channel.
  Future<void> sendMessage(String message);

  /// Helper to specifically request a location update from the client.
  Future<void> requestLocationUpdate();

  /// Send the actual LocationUpdate to the host.
  Future<void> sendLocationUpdate(LocationUpdate update);

  /// Close current connection without disposing streams
  Future<void> disconnect();

  /// Close connection and cleanup.
  Future<void> dispose();
}
