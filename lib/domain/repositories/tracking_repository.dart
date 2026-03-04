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

  /// Called by the Host when it scans the Client's generated Answer QR Code.
  Future<void> hostAcceptClientAnswer(String answerJson);

  /// Called by the Client when it scans the Host's Offer QR Code.
  /// Returns the Answer JSON string to be encoded in a QR consequence.
  Future<String> clientProcessHostOffer(String offerJson);

  /// Sends a string payload to the connected peer over the direct Data Channel.
  Future<void> sendMessage(String message);

  /// Helper to specifically request a location update from the client.
  Future<void> requestLocationUpdate();

  /// Send the actual LocationUpdate to the host.
  Future<void> sendLocationUpdate(LocationUpdate update);

  /// Helper to send a disconnect signal before closing the connection
  Future<void> sendDisconnectSignal();

  /// Close current connection without disposing streams
  Future<void> disconnect();

  /// Close connection and cleanup.
  Future<void> dispose();
}
