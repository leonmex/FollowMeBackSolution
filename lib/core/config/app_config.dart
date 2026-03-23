class AppConfig {
  /// FollowMeBack REST API URL for fetching TURN credentials
<<<<<<< HEAD
  static const String followMeBackRestUrl = '<followMeBackRestUrl>';

  /// FollowMeBack API Key
  static const String followMeBackApiKey = '<followMeBackApiKey>';

  /// IMPORTANT: Set to true to use the new API v1 WebRTC Signaling and TURN service
  static const bool useApiV1Webrtc = true;

  /// Base URL for the new WebRTC API v1 endpoints
  static const String apiV1BaseUrl = '<NEW_TURN_FOLLOW_ME_BACK_SERVER>';

  /// API Key for the new WebRTC API v1
  static const String apiV1ApiKey = '<API_KEY_FOLLOW_ME_BACK_SERVER>';

  /// Public hostname/IP of the Coturn TURN server.
  /// The Go backend config.json still has the placeholder "yourdomain.com";
  /// this value substitutes it on the Flutter side until the backend is updated.
  /// Set to null once the backend config is corrected.
  static const String? turnPublicHostname = '<TURN_SERVER_IP>';
=======
  static const String followMeBackRestUrl =
      'https://followmeback.metered.live/api/v1/turn/credentials';

  /// FollowMeBack API Key
  static const String followMeBackApiKey =
      '24a75e97d644fcef2badc928762c1cc2fbc1';
>>>>>>> df8dc83 (feat: Credentials for Prod - Don't use or merge)

  /// WebRTC DataChannel Keep-alive ping interval
  static const int keepAlivePingIntervalSeconds = 20;

  /// Number of previous locations to save from the client
  static const int maxClientLocationsToSave = 200;

  /// Cloud function for exchanging SDPs during ICE Restarts
<<<<<<< HEAD
  static const String restablishCommunicationUrl = '<CLOUD_FUNCTION_URL>';
=======
  static const String restablishCommunicationUrl =
      'https://europe-west1-mexican-fans.cloudfunctions.net/RestablishComunicationFMB';
>>>>>>> df8dc83 (feat: Credentials for Prod - Don't use or merge)

  /// Timeout for HTTP signaling requests
  static const int signalingTimeoutSeconds = 10;

  /// Timeout for WebRTC ICE gathering.
  /// 10s is needed for 5G/mobile networks where TURN relay candidates
  /// (critical for CGNAT traversal) can take longer to arrive.
  static const int iceGatheringTimeoutSeconds = 10;

  /// Interval for polling signaling server
  static const int signalingPollIntervalSeconds = 5;

  /// Minimum interval between any two signaling requests to prevent DDoS
  static const int signalingMinimumIntervalSeconds = 1;

  /// Number of failed reconnection attempts before a hard reset
  static const int reconnectionHardResetLimit = 6;

  /// WebRTC ICE candidate pool size
  static const int iceCandidatePoolSize = 2;

  /// Delay to allow disconnect signal to propagate before closing PeerConnection
  static const int disconnectSignalDelayMs = 500;

  /// Delay to reset UI status messages (e.g. "Location Sent!")
  static const int uiMessageResetDelaySeconds = 2;

  /// Foreground task repetition interval
  static const int foregroundTaskIntervalMs = 5000;

  /// Android Notification Details
  static const String notificationChannelId = 'follow_me_back_channel';
  static const String notificationChannelName = 'Location Tracking';
  static const String notificationChannelDescription =
      'This notification appears when tracking is active';
  static const String notificationTitle = 'Follow Me Back is active';
  static const String notificationText =
      'Location sharing is running in the background';
}
