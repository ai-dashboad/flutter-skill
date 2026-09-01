/// Abstract interface for framework-agnostic app drivers.
///
/// Each supported framework (Flutter, React Native, web, etc.) implements
/// this interface so that the MCP server and CLI tools can interact with
/// any running app through a single API.
abstract class AppDriver {
  /// Human-readable framework name (e.g. "Flutter", "React Native").
  String get frameworkName;

  /// Whether the driver currently has an active connection to the app.
  bool get isConnected;

  /// Establish a connection to the running app.
  Future<void> connect();

  /// Tear down the connection.
  Future<void> disconnect();

  /// Tap an element identified by key, text, or semantic ref.
  Future<Map<String, dynamic>> tap({String? key, String? text, String? ref});

  /// Enter text into a field identified by key or semantic ref.
  Future<Map<String, dynamic>> enterText(String? key, String text,
      {String? ref});

  /// Swipe in a direction, optionally anchored to an element.
  Future<bool> swipe(
      {required String direction, double distance = 300, String? key});

  /// Return a list of interactive elements visible on screen.
  Future<List<dynamic>> getInteractiveElements({bool includePositions = true});

  /// Return interactive elements with enhanced structure including actions and selectors.
  Future<Map<String, dynamic>> getInteractiveElementsStructured();

  /// Capture a screenshot and return the base-64 encoded image data.
  Future<String?> takeScreenshot({double quality = 1.0, int? maxWidth});

  /// Retrieve recent log lines from the app.
  Future<List<String>> getLogs();

  /// Clear collected log lines.
  Future<void> clearLogs();

  /// Trigger a hot-reload of the running app.
  Future<void> hotReload();
}
