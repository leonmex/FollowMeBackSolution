/// Defines the role a device plays during a Follow Me Back tracking session.
enum SessionRole {
  host,
  client;

  /// Returns the capitalized string representation for API or UI usage if necessary.
  String get nameString {
    switch (this) {
      case SessionRole.host:
        return 'Host';
      case SessionRole.client:
        return 'Client';
    }
  }
}
