class AppConfig {
  /// FollowMeBack REST API URL for fetching TURN credentials
  static const String followMeBackRestUrl = '<URL_TO_YOUR_SERVER>';

  /// FollowMeBack API Key
  static const String followMeBackApiKey = '<YOUR_API_KEY>';

  /// WebRTC DataChannel Keep-alive ping interval
  static const int keepAlivePingIntervalSeconds = 20;

  /// Number of previous locations to save from the client
  static const int maxClientLocationsToSave = 20;

  /// Cloud function for exchanging SDPs during ICE Restarts
  static const String restablishCommunicationUrl = '<YOUR_CLOUD_FUNCTION_URL>';

  /// Timeout for HTTP signaling requests
  static const int signalingTimeoutSeconds = 10;

  /// Timeout for WebRTC ICE gathering
  static const int iceGatheringTimeoutSeconds = 15;

  /// Interval for polling signaling server
  static const int signalingPollIntervalSeconds = 5;

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
