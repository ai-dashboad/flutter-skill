/// Web implementation: exposes Dart-side element lookup to JavaScript.
/// Registers window.__FLUTTER_SKILL_DART_CALL__(method, paramsJson)
/// so the JS bridge (flutter-skill.js) can call into Dart for key-based lookups.

import 'dart:js_interop';

@JS('window.__FLUTTER_SKILL_DART_CALL__')
external set _dartCallSetter(JSFunction? fn);

String Function(String, String)? _handler;

@JS('window.__FLUTTER_SKILL_DART_BRIDGE_READY__')
external set _dartBridgeReady(JSBoolean value);

String _jsDartCall(JSString method, JSString paramsJson) {
  if (_handler == null) return '{"error":"No handler registered"}';
  return _handler!(method.toDart, paramsJson.toDart);
}

void registerWebBridge(
    String Function(String method, String paramsJson) handler) {
  _handler = handler;
  _dartCallSetter = _jsDartCall.toJS;
  _dartBridgeReady = true.toJS;
}
