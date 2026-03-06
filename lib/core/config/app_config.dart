class AppConfig {
  /// FollowMeBack REST API URL for fetching TURN credentials
  static const String followMeBackRestUrl = '<URL_TO_YOUR_SERVER>';

  /// FollowMeBack API Key
  static const String followMeBackApiKey = 'API_TOKEN';

  /// WebRTC DataChannel Keep-alive ping interval
  static const int keepAlivePingIntervalSeconds = 20;

  /// Number of previous locations to save from the client
  static const int maxClientLocationsToSave = 5;
}
