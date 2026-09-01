/// Stub implementation for non-web platforms.
/// This is a no-op; the real implementation is in flutter_skill_web_interop.dart.

void registerWebBridge(
    String Function(String method, String paramsJson) handler) {
  // No-op on non-web platforms
}
