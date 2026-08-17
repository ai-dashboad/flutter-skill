/// Tool definition for the skill engine.
class ToolDefinition {
  final String name;
  final String description;
  final Map<String, dynamic> inputSchema;

  const ToolDefinition({
    required this.name,
    required this.description,
    required this.inputSchema,
  });

  Map<String, dynamic> toJson() => {
        'name': name,
        'description': description,
        'inputSchema': inputSchema,
      };
}

/// Registry of all available tools.
///
/// Extracted from FlutterMcpServer._getToolsList() — pure data, no logic.
class ToolRegistry {
  /// Gemini/Vertex AI maximum tool declarations per request.
  static const geminiToolLimit = 128;

  /// Tools shown before any connection is established.
  ///
  /// Kept intentionally small (~11) so the total stays under the Gemini
  /// 128-function limit even when flutter-skill is combined with other MCP
  /// servers (e.g. Dart MCP). All other tools become visible after connecting.
  static const connectionOnlyTools = <String>{
    'connect_app',
    'connect_cdp',
    'connect_openclaw_browser',
    'connect_webmcp',
    'scan_and_connect',
    'launch_app',
    'list_sessions',
    'list_running_apps',
    'get_connection_status',
    'disconnect',
    'diagnose_project',
    'native_list_simulators',
    'idb_describe',
  };

  /// CDP-only tools that don't apply to bridge/Flutter platforms.
  static const cdpOnlyTools = <String>{
    'connect_cdp',
    'get_title',
    'get_page_source',
    'get_visible_text',
    'count_elements',
    'is_visible',
    'get_attribute',
    'get_css_property',
    'get_bounding_box',
    'get_cookies',
    'set_cookie',
    'clear_cookies',
    'get_local_storage',
    'set_local_storage',
    'clear_local_storage',
    'get_session_storage',
    'get_console_messages',
    'get_network_requests',
    'navigate',
    'go_forward',
    'reload',
    'set_viewport',
    'emulate_device',
    'generate_pdf',
    'wait_for_navigation',
    'wait_for_network_idle',
    'get_tabs',
    'new_tab',
    'close_tab',
    'switch_tab',
    'get_frames',
    'eval_in_frame',
    'get_window_handles',
    'install_dialog_handler',
    'handle_dialog',
    'intercept_requests',
    'clear_interceptions',
    'block_urls',
    'throttle_network',
    'go_offline',
    'go_online',
    'clear_browser_data',
    'accessibility_audit',
    'set_geolocation',
    'set_timezone',
    'set_color_scheme',
    'upload_file',
    'compare_screenshot',
    'highlight_element',
    'mock_response',
    'highlight_elements',
    'fill_rich_text',
    'paste_text',
    'solve_captcha',
    'act',
  };

  /// Flutter VM Service-only tools.
  static const flutterOnlyTools = <String>{
    'get_widget_tree',
    'get_widget_properties',
    'find_by_type',
    'hot_reload',
    'hot_restart',
  };

  /// Mobile-only tools.
  static const mobileOnlyTools = <String>{
    'native_tap',
    'native_input_text',
    'native_swipe',
    'native_screenshot',
    'native_snapshot',
    'native_find_elements',
    'native_get_text',
    'native_tap_element',
    'native_element_at',
    'native_long_press',
    'native_gesture',
    'native_press_key',
    'native_key_combo',
    'native_button',
    'native_video_start',
    'native_video_stop',
    'native_capture_frames',
    'native_list_simulators',
    'auth_biometric',
    'auth_deeplink',
    'qr_login_start',
    'qr_login_wait',
  };

  /// Get the full list of built-in tool definitions as JSON maps.
  ///
  /// This is the canonical list of all 160+ tools. Plugin tools are
  /// appended separately by the engine.
  static List<Map<String, dynamic>> getAllToolDefinitions() {
    return <Map<String, dynamic>>[
      // ======================== Session Management ========================
      {
        "name": "list_sessions",
        "description": """List all active Flutter app sessions.

Returns information about all connected sessions including session ID, project path, device, and URI.
Use this to see available sessions before switching or closing them.""",
        "inputSchema": {
          "type": "object",
          "properties": {},
        },
      },
      {
        "name": "switch_session",
        "description": """Switch the active session to a different Flutter app.

After switching, all subsequent tool calls without an explicit session_id will use this session.
Use list_sessions() to see available session IDs.""",
        "inputSchema": {
          "type": "object",
          "properties": {
            "session_id": {
              "type": "string",
              "description": "Session ID to switch to"
            },
          },
          "required": ["session_id"],
        },
      },
      {
        "name": "close_session",
        "description": """Close and disconnect a specific session.

This will disconnect from the Flutter app and remove the session. The app will continue running.
If closing the active session, the next session becomes active automatically.""",
        "inputSchema": {
          "type": "object",
          "properties": {
            "session_id": {
              "type": "string",
              "description": "Session ID to close"
            },
          },
          "required": ["session_id"],
        },
      },

      // ======================== Connection ========================
      {
        "name": "connect_app",
        "description":
            """Connect to a running Flutter App VM Service using specific URI.

[USE WHEN]
• You have a specific VM Service URI (ws://...)
• Reconnecting to a known app instance

[ALTERNATIVES]
• If you don't have URI: use scan_and_connect() to auto-find
• If app not running: use launch_app() to start it

[AUTO-FIX]
If project_path is provided, automatically checks and fixes missing configuration:
• Adds flutter_skill dependency to pubspec.yaml if missing
• Adds FlutterSkillBinding initialization to main.dart if missing

[MULTI-SESSION]
Returns a session_id that can be used to target this specific app in subsequent tool calls.
Omitting session_id in other tools will use the active session.""",
        "inputSchema": {
          "type": "object",
          "properties": {
            "uri": {
              "type": "string",
              "description": "WebSocket URI (ws://...)"
            },
            "project_path": {
              "type": "string",
              "description":
                  "Optional: Project path for auto-fix configuration check"
            },
            "session_id": {
              "type": "string",
              "description":
                  "Optional session ID (auto-generated if not provided)"
            },
            "name": {
              "type": "string",
              "description": "Optional session name for identification"
            },
          },
          "required": ["uri"],
        },
      },
      {
        "name": "launch_app",
        "description": """⚡ PRIORITY TOOL FOR UI TESTING ⚡

[TRIGGER KEYWORDS]
test app | run app | launch | simulator | emulator | iOS test | Android test | E2E test | verify feature | validate UI | integration test | UI automation | start app | debug app

[PRIMARY PURPOSE]
Launch and test a Flutter app on iOS simulator/Android emulator for UI validation and interaction testing.

[USE WHEN]
• User wants to test/verify a Flutter feature or UI behavior
• User mentions iOS simulator or Android emulator
• User needs to validate user flows or interactions
• User asks to automate UI testing scenarios

[DO NOT USE]
✗ Unit testing (use 'flutter test' command instead)
✗ Widget testing (use WidgetTester instead)
✗ Code analysis or reading source files
✗ Building APK/IPA (use 'flutter build' instead)

[WORKFLOW]
1. Launch app on device/simulator
2. Auto-connect to VM Service
3. Ready for: inspect() → tap() → enter_text() → screenshot()

[FLUTTER 3.x COMPATIBILITY]
⚠️ Flutter 3.x uses DTD protocol by default. This tool requires VM Service protocol.
If launch fails with "getVM method not found" or "no VM Service URI":
• Solution: Add --vm-service-port flag to extra_args
• Example: launch_app(extra_args: ["--vm-service-port=50000"])
• Alternative: Use Dart MCP tools for DTD-based testing

[MULTI-SESSION]
Returns a session_id that can be used to target this specific app in subsequent tool calls.
Omitting session_id in other tools will use the active session.""",
        "inputSchema": {
          "type": "object",
          "properties": {
            "project_path": {
              "type": "string",
              "description": "Path to Flutter project"
            },
            "device_id": {"type": "string", "description": "Target device"},
            "dart_defines": {
              "type": "array",
              "items": {"type": "string"},
              "description": "Dart defines (e.g. ['ENV=staging', 'DEBUG=true'])"
            },
            "extra_args": {
              "type": "array",
              "items": {"type": "string"},
              "description": "Additional flutter run arguments"
            },
            "flavor": {"type": "string", "description": "Build flavor"},
            "target": {
              "type": "string",
              "description": "Target file (e.g. lib/main_staging.dart)"
            },
            "session_id": {
              "type": "string",
              "description":
                  "Optional session ID (auto-generated if not provided)"
            },
            "name": {
              "type": "string",
              "description": "Optional session name for identification"
            },
          },
        },
      },
      {
        "name": "scan_and_connect",
        "description": """⚡ AUTO-CONNECT TOOL ⚡

[TRIGGER KEYWORDS]
connect to app | find running app | auto-connect | connect to running Flutter | find app | detect app | scan for app | discover app

[PRIMARY PURPOSE]
Automatically scan for and connect to a running Flutter app (scans VM Service ports 50000-50100).

[USE WHEN]
• App is already running and you want to connect
• Alternative to launch_app when app is already started
• Quick reconnection to running app

[WORKFLOW]
Scans ports, finds first Flutter app, auto-connects. If no app found, use launch_app instead.

[AUTO-FIX]
If project_path is provided, automatically checks and fixes missing configuration:
• Adds flutter_skill dependency to pubspec.yaml if missing
• Adds FlutterSkillBinding initialization to main.dart if missing

[MULTI-SESSION]
Returns a session_id that can be used to target this specific app in subsequent tool calls.
Omitting session_id in other tools will use the active session.""",
        "inputSchema": {
          "type": "object",
          "properties": {
            "port_start": {
              "type": "integer",
              "description": "Start of port range (default: 50000)"
            },
            "port_end": {
              "type": "integer",
              "description": "End of port range (default: 50100)"
            },
            "project_path": {
              "type": "string",
              "description":
                  "Optional: Project path for auto-fix configuration check"
            },
            "session_id": {
              "type": "string",
              "description":
                  "Optional session ID (auto-generated if not provided)"
            },
            "name": {
              "type": "string",
              "description": "Optional session name for identification"
            },
            "flavor": {
              "type": "string",
              "description":
                  "Optional: Flutter build flavor (e.g. 'dev', 'staging', 'prod'). Selects the correct instance when multiple flavors run simultaneously."
            },
            "device_id": {
              "type": "string",
              "description":
                  "Optional: Device ID to target when multiple devices run the same app."
            },
          },
        },
      },
      {
        "name": "list_running_apps",
        "description":
            "List all running Flutter apps (VM Services) on the system",
        "inputSchema": {
          "type": "object",
          "properties": {
            "port_start": {
              "type": "integer",
              "description": "Start of port range (default: 50000)"
            },
            "port_end": {
              "type": "integer",
              "description": "End of port range (default: 50100)"
            },
          },
        },
      },
      {
        "name": "stop_app",
        "description": "Stop the currently connected/launched Flutter app",
        "inputSchema": {
          "type": "object",
          "properties": {
            "session_id": {
              "type": "string",
              "description": "Optional session ID (defaults to active session)"
            },
          },
        },
      },
      {
        "name": "disconnect",
        "description":
            "Disconnect from the current Flutter app (without stopping it)",
        "inputSchema": {
          "type": "object",
          "properties": {
            "session_id": {
              "type": "string",
              "description": "Optional session ID (defaults to active session)"
            },
          },
        },
      },
      {
        "name": "get_connection_status",
        "description":
            "Get current connection status and app info. If session_id is provided, gets status for that specific session; otherwise uses active session.",
        "inputSchema": {
          "type": "object",
          "properties": {
            "session_id": {
              "type": "string",
              "description": "Optional session ID (defaults to active session)"
            },
          },
        },
      },

      // ======================== CDP Connection ========================
      {
        "name": "connect_cdp",
        "description":
            """Connect to any web page via Chrome DevTools Protocol (CDP).

No SDK injection needed — works with ANY website, React/Vue/Angular apps, or any web content.

[USE WHEN]
• Testing a web app that doesn't have flutter_skill SDK
• Testing any website (React, Vue, Angular, plain HTML)
• Automating browser interactions on arbitrary web pages

[HOW IT WORKS]
1. Launches Chrome with remote debugging (or connects to existing)
2. Navigates to the given URL
3. Connects via CDP WebSocket
4. All subsequent tool calls (inspect, tap, enter_text, screenshot, etc.) work via CDP

[AFTER CONNECTING]
Use the same tools as usual: inspect(), tap(), enter_text(), screenshot(), snapshot(), etc.
They will automatically route through the CDP connection.""",
        "inputSchema": {
          "type": "object",
          "properties": {
            "url": {
              "type": "string",
              "description": "URL to navigate to (e.g. https://example.com)"
            },
            "port": {
              "type": "integer",
              "description": "Chrome remote debugging port (default: 9222)"
            },
            "launch_chrome": {
              "type": "boolean",
              "description":
                  "Launch a new Chrome instance (default: true). Set to false to connect to already-running Chrome."
            },
            "headless": {
              "type": "boolean",
              "description":
                  "Run Chrome in headless mode (default: false). Useful for CI/CD."
            },
            "chrome_path": {
              "type": "string",
              "description": "Custom Chrome/Chromium executable path."
            },
            "proxy": {
              "type": "string",
              "description":
                  "Proxy server URL (e.g. 'http://proxy:8080' or 'socks5://proxy:1080')."
            },
            "ignore_ssl": {
              "type": "boolean",
              "description": "Ignore SSL certificate errors (default: false)."
            },
            "max_tabs": {
              "type": "integer",
              "description":
                  "Maximum number of tabs allowed (default: 20). Prevents runaway tab creation."
            },
          },
          "required": ["url"],
        },
      },

      // ======================== OpenClaw Browser (port 18800) ========================
      {
        "name": "connect_openclaw_browser",
        "description":
            """Connect to OpenClaw's built-in Chrome browser (port 18800). No launch needed — instant connection.

[USE WHEN]
• Running inside OpenClaw and need to automate the browser
• Faster than connect_cdp — no Chrome launch, instant connection

[AFTER CONNECTING]
Use snapshot(), act(), navigate(), screenshot(), eval(), etc.""",
        "inputSchema": {
          "type": "object",
          "properties": {
            "url": {
              "type": "string",
              "description":
                  "Optional URL to navigate to after connecting. Omit to stay on current page."
            },
          },
        },
      },

      // ======================== Chrome WebMCP (Chrome 146+) ========================
      {
        "name": "connect_webmcp",
        "description":
            """Connect via Chrome 146+ native WebMCP protocol. Auto-detects WebMCP, falls back to CDP.

[USE WHEN]
• Chrome 146+ with chrome://flags/#enable-webmcp-testing enabled
• Prefer this over connect_cdp when Chrome WebMCP is available

[SETUP]
1. Chrome 146+ — open chrome://flags/#enable-webmcp-testing → Enabled → Restart""",
        "inputSchema": {
          "type": "object",
          "properties": {
            "url": {"type": "string", "description": "URL to navigate to"},
            "webmcp_port": {
              "type": "integer",
              "description": "Chrome WebMCP port (default: auto-detect)"
            },
            "fallback_cdp_port": {
              "type": "integer",
              "description": "CDP fallback port (default: 18800 for OpenClaw)"
            },
          },
          "required": ["url"],
        },
      },

      // ======================== HTTP Request ========================
      {
        "name": "http_request",
        "description": """Make an HTTP request for API testing.

Supports GET, POST, PUT, PATCH, DELETE with JSON bodies, custom headers, and authentication.
Returns status code, headers, and response body.""",
        "inputSchema": {
          "type": "object",
          "properties": {
            "url": {"type": "string", "description": "Request URL"},
            "method": {
              "type": "string",
              "description":
                  "HTTP method (GET, POST, PUT, PATCH, DELETE). Default: GET"
            },
            "headers": {
              "type": "object",
              "description": "Request headers as key-value pairs"
            },
            "body": {
              "type": "string",
              "description": "Request body (typically JSON string)"
            },
            "timeout": {
              "type": "integer",
              "description": "Timeout in milliseconds (default: 30000)"
            },
          },
          "required": ["url"],
        },
      },

      // ======================== Web Bridge Listener ========================
      {
        "name": "start_bridge_listener",
        "description": """Start a WebSocket listener for browser-based SDKs.

Browser SDKs cannot start a WebSocket server, so this starts one on the MCP
server side that browser clients connect TO. A session is auto-created when
a client connects.

After starting, point the web SDK at ws://127.0.0.1:<port>.""",
        "inputSchema": {
          "type": "object",
          "properties": {
            "port": {
              "type": "integer",
              "description": "Port to listen on (default: 18118)"
            },
          },
        },
      },
      {
        "name": "stop_bridge_listener",
        "description": "Stop the WebSocket bridge listener.",
        "inputSchema": {"type": "object", "properties": {}},
      },

      // ======================== CDP-exclusive tools ========================
      {
        "name": "eval",
        "description":
            "Execute JavaScript in the browser and return the result. Works with CDP and bridge connections.",
        "inputSchema": {
          "type": "object",
          "properties": {
            "expression": {
              "type": "string",
              "description": "JavaScript expression to evaluate"
            }
          },
          "required": ["expression"]
        }
      },
      {
        "name": "press_key",
        "description":
            "Press a keyboard key (Enter, Tab, Escape, ArrowUp, etc.)",
        "inputSchema": {
          "type": "object",
          "properties": {
            "key": {
              "type": "string",
              "description":
                  "Key name (Enter, Tab, Escape, Backspace, ArrowUp, ArrowDown, Space, or any character)"
            },
            "modifiers": {
              "type": "array",
              "items": {"type": "string"},
              "description": "Modifier keys: Alt, Control, Meta, Shift"
            }
          },
          "required": ["key"]
        }
      },
      {
        "name": "hover",
        "description":
            "Hover over an element (triggers CSS :hover styles and mouseover events)",
        "inputSchema": {
          "type": "object",
          "properties": {
            "key": {"type": "string"},
            "text": {"type": "string"},
            "ref": {"type": "string"}
          }
        }
      },
      {
        "name": "select_option",
        "description": "Select an option in a <select> dropdown",
        "inputSchema": {
          "type": "object",
          "properties": {
            "key": {"type": "string", "description": "Element ID or test ID"},
            "value": {"type": "string", "description": "Option value to select"}
          },
          "required": ["key", "value"]
        }
      },
      {
        "name": "set_checkbox",
        "description": "Check or uncheck a checkbox",
        "inputSchema": {
          "type": "object",
          "properties": {
            "key": {"type": "string"},
            "checked": {"type": "boolean"}
          },
          "required": ["key"]
        }
      },
      {
        "name": "fill",
        "description":
            "Fill an input field (clear + set value — faster than enter_text for forms)",
        "inputSchema": {
          "type": "object",
          "properties": {
            "key": {"type": "string"},
            "value": {"type": "string"}
          },
          "required": ["key", "value"]
        }
      },
      {
        "name": "fill_rich_text",
        "description":
            "Fill a rich text editor (contenteditable, Draft.js, ProseMirror, Tiptap, Medium, Quill, etc.). Auto-detects editor type and injects content with proper framework event dispatching.",
        "inputSchema": {
          "type": "object",
          "properties": {
            "selector": {
              "type": "string",
              "description":
                  "CSS selector for the editor element (default: auto-detect via [contenteditable], .ProseMirror, .tiptap, .ql-editor, etc.)"
            },
            "html": {
              "type": "string",
              "description":
                  "HTML content to inject (preferred for rich editors)"
            },
            "text": {
              "type": "string",
              "description": "Plain text to inject (fallback if no html)"
            },
            "append": {
              "type": "boolean",
              "description":
                  "Append instead of replacing content (default: false)"
            }
          }
        }
      },
      {
        "name": "paste_text",
        "description":
            "Paste text instantly via clipboard simulation (Input.insertText). Orders of magnitude faster than type_text for long content. Focus the target element first.",
        "inputSchema": {
          "type": "object",
          "properties": {
            "text": {"type": "string", "description": "Text to paste"}
          },
          "required": ["text"]
        }
      },
      {
        "name": "solve_captcha",
        "description":
            "Auto-detect and solve CAPTCHA on the current page using 2Captcha service. Supports reCAPTCHA v2/v3, hCaptcha, Cloudflare Turnstile, and image CAPTCHAs. Requires a 2Captcha API key.",
        "inputSchema": {
          "type": "object",
          "properties": {
            "api_key": {"type": "string", "description": "2Captcha API key"},
            "site_key": {
              "type": "string",
              "description":
                  "reCAPTCHA/hCaptcha site key (auto-detected if not provided)"
            },
            "page_url": {
              "type": "string",
              "description": "Page URL (auto-detected if not provided)"
            },
            "type": {
              "type": "string",
              "description":
                  "CAPTCHA type: recaptcha_v2, recaptcha_v3, hcaptcha, turnstile, image (auto-detected if not provided)",
              "enum": [
                "recaptcha_v2",
                "recaptcha_v3",
                "hcaptcha",
                "turnstile",
                "image"
              ]
            }
          },
          "required": ["api_key"]
        }
      },
      {
        "name": "get_cookies",
        "description": "Get all browser cookies for the current page",
        "inputSchema": {"type": "object", "properties": {}}
      },
      {
        "name": "set_cookie",
        "description": "Set a browser cookie",
        "inputSchema": {
          "type": "object",
          "properties": {
            "name": {"type": "string"},
            "value": {"type": "string"},
            "domain": {"type": "string"},
            "path": {"type": "string"}
          },
          "required": ["name", "value"]
        }
      },
      {
        "name": "clear_cookies",
        "description": "Clear all browser cookies",
        "inputSchema": {"type": "object", "properties": {}}
      },
      {
        "name": "get_local_storage",
        "description": "Get all localStorage key-value pairs",
        "inputSchema": {"type": "object", "properties": {}}
      },
      {
        "name": "set_local_storage",
        "description": "Set a localStorage value",
        "inputSchema": {
          "type": "object",
          "properties": {
            "key": {"type": "string"},
            "value": {"type": "string"}
          },
          "required": ["key", "value"]
        }
      },
      {
        "name": "clear_local_storage",
        "description": "Clear all localStorage data",
        "inputSchema": {"type": "object", "properties": {}}
      },
      {
        "name": "get_console_messages",
        "description": "Get browser console log messages",
        "inputSchema": {"type": "object", "properties": {}}
      },
      {
        "name": "set_viewport",
        "description": "Set browser viewport size (responsive testing)",
        "inputSchema": {
          "type": "object",
          "properties": {
            "width": {"type": "integer"},
            "height": {"type": "integer"},
            "device_scale_factor": {"type": "number"}
          },
          "required": ["width", "height"]
        }
      },
      {
        "name": "emulate_device",
        "description":
            "Emulate a device viewport + user agent. 143+ presets: iPhone 12-16 (all sizes), SE, Pixel 5-9, Galaxy S21-S24, Z Fold/Flip, OnePlus, Xiaomi, Huawei, iPad Pro/Air/Mini, Galaxy Tab, Surface Pro, MacBook Air/Pro, Dell XPS, desktop resolutions (1080p/1440p/4K) with Chrome/Firefox/Safari/Edge UAs. Supports flexible naming: 'iPhone 14 Pro', 'iphone-14-pro', 'iphone14pro' all work. Pass empty device to list all available presets.",
        "inputSchema": {
          "type": "object",
          "properties": {
            "device": {
              "type": "string",
              "description":
                  "Device name (e.g. 'iphone-16-pro-max', 'pixel-8', 'galaxy-s24-ultra', 'ipad-pro-11', 'macbook-pro-16', 'desktop-1080p'). Empty string lists all devices."
            }
          },
          "required": ["device"]
        }
      },
      {
        "name": "generate_pdf",
        "description": "Generate a PDF of the current page",
        "inputSchema": {"type": "object", "properties": {}}
      },
      {
        "name": "navigate",
        "description": "Navigate to a URL",
        "inputSchema": {
          "type": "object",
          "properties": {
            "url": {"type": "string"}
          },
          "required": ["url"]
        }
      },
      {
        "name": "go_forward",
        "description": "Navigate forward in browser history",
        "inputSchema": {"type": "object", "properties": {}}
      },
      {
        "name": "reload",
        "description": "Reload the current page",
        "inputSchema": {"type": "object", "properties": {}}
      },
      {
        "name": "get_attribute",
        "description": "Get an HTML element's attribute value",
        "inputSchema": {
          "type": "object",
          "properties": {
            "key": {"type": "string"},
            "attribute": {"type": "string"}
          },
          "required": ["key", "attribute"]
        }
      },
      {
        "name": "get_css_property",
        "description": "Get computed CSS property of an element",
        "inputSchema": {
          "type": "object",
          "properties": {
            "key": {"type": "string"},
            "property": {"type": "string"}
          },
          "required": ["key", "property"]
        }
      },
      {
        "name": "get_bounding_box",
        "description": "Get element position and size",
        "inputSchema": {
          "type": "object",
          "properties": {
            "key": {"type": "string"}
          },
          "required": ["key"]
        }
      },
      {
        "name": "focus",
        "description": "Focus an element",
        "inputSchema": {
          "type": "object",
          "properties": {
            "key": {"type": "string"}
          },
          "required": ["key"]
        }
      },
      {
        "name": "blur",
        "description": "Remove focus from an element",
        "inputSchema": {
          "type": "object",
          "properties": {
            "key": {"type": "string"}
          },
          "required": ["key"]
        }
      },
      {
        "name": "count_elements",
        "description": "Count elements matching a CSS selector",
        "inputSchema": {
          "type": "object",
          "properties": {
            "selector": {"type": "string"}
          },
          "required": ["selector"]
        }
      },
      {
        "name": "is_visible",
        "description": "Check if an element is visible on page",
        "inputSchema": {
          "type": "object",
          "properties": {
            "key": {"type": "string"}
          },
          "required": ["key"]
        }
      },
      {
        "name": "get_page_source",
        "description":
            "Get the HTML source of the current page with optional cleaning",
        "inputSchema": {
          "type": "object",
          "properties": {
            "selector": {
              "type": "string",
              "description":
                  "CSS selector to get HTML for a specific element only"
            },
            "remove_scripts": {
              "type": "boolean",
              "description": "Strip <script> tags"
            },
            "remove_styles": {
              "type": "boolean",
              "description": "Strip <style> tags"
            },
            "remove_comments": {
              "type": "boolean",
              "description": "Strip HTML comments"
            },
            "remove_meta": {
              "type": "boolean",
              "description": "Strip <meta> tags"
            },
            "minify": {"type": "boolean", "description": "Collapse whitespace"},
            "clean_html": {
              "type": "boolean",
              "description":
                  "Convenience: removes scripts, styles, comments, and meta tags"
            }
          }
        }
      },
      {
        "name": "get_visible_text",
        "description":
            "Get only visible text content from the page (skips display:none, visibility:hidden elements). CDP only.",
        "inputSchema": {
          "type": "object",
          "properties": {
            "selector": {
              "type": "string",
              "description": "CSS selector to scope text extraction"
            }
          }
        }
      },
      {
        "name": "get_window_handles",
        "description": "Get all browser window/tab handles",
        "inputSchema": {"type": "object", "properties": {}}
      },
      {
        "name": "install_dialog_handler",
        "description":
            "Install auto-handler for JS dialogs (alert/confirm/prompt)",
        "inputSchema": {
          "type": "object",
          "properties": {
            "auto_accept": {
              "type": "boolean",
              "description": "Auto-accept dialogs (default: true)"
            }
          }
        }
      },
      {
        "name": "wait_for_navigation",
        "description": "Wait for page navigation to complete",
        "inputSchema": {
          "type": "object",
          "properties": {
            "timeout_ms": {
              "type": "integer",
              "description": "Timeout in ms (default: 30000)"
            }
          }
        }
      },
      {
        "name": "get_title",
        "description": "Get the page title",
        "inputSchema": {"type": "object", "properties": {}}
      },
      {
        "name": "set_geolocation",
        "description": "Override browser geolocation",
        "inputSchema": {
          "type": "object",
          "properties": {
            "latitude": {"type": "number"},
            "longitude": {"type": "number"}
          },
          "required": ["latitude", "longitude"]
        }
      },
      {
        "name": "set_color_scheme",
        "description": "Set dark/light mode preference",
        "inputSchema": {
          "type": "object",
          "properties": {
            "scheme": {
              "type": "string",
              "enum": ["dark", "light"]
            }
          },
          "required": ["scheme"]
        }
      },
      {
        "name": "block_urls",
        "description":
            "Block network requests matching URL patterns (ads, trackers, etc.)",
        "inputSchema": {
          "type": "object",
          "properties": {
            "patterns": {
              "type": "array",
              "items": {"type": "string"}
            }
          },
          "required": ["patterns"]
        }
      },
      {
        "name": "throttle_network",
        "description": "Simulate slow network (3G, offline, etc.)",
        "inputSchema": {
          "type": "object",
          "properties": {
            "latency_ms": {"type": "integer"},
            "download_kbps": {"type": "integer"},
            "upload_kbps": {"type": "integer"}
          }
        }
      },
      {
        "name": "go_offline",
        "description":
            "Simulate offline mode (no network). Use go_online to restore.",
        "inputSchema": {"type": "object", "properties": {}}
      },
      {
        "name": "go_online",
        "description": "Restore normal network conditions after go_offline.",
        "inputSchema": {"type": "object", "properties": {}}
      },
      {
        "name": "clear_browser_data",
        "description":
            "Clear all browser data (cookies, cache, localStorage, sessionStorage)",
        "inputSchema": {"type": "object", "properties": {}}
      },
      {
        "name": "upload_file",
        "description": "Upload file(s) to a file input element",
        "inputSchema": {
          "type": "object",
          "properties": {
            "selector": {
              "type": "string",
              "description": "CSS selector for input[type=file]"
            },
            "files": {
              "type": "array",
              "items": {"type": "string"},
              "description": "File paths to upload"
            }
          },
          "required": ["selector", "files"]
        }
      },
      {
        "name": "handle_dialog",
        "description":
            "Accept or dismiss browser dialog (alert/confirm/prompt)",
        "inputSchema": {
          "type": "object",
          "properties": {
            "accept": {"type": "boolean"},
            "prompt_text": {"type": "string"}
          },
          "required": ["accept"]
        }
      },
      {
        "name": "get_frames",
        "description": "List all iframes on the page",
        "inputSchema": {"type": "object", "properties": {}}
      },
      {
        "name": "eval_in_frame",
        "description": "Execute JavaScript inside a specific iframe",
        "inputSchema": {
          "type": "object",
          "properties": {
            "frame_id": {"type": "string"},
            "expression": {"type": "string"}
          },
          "required": ["frame_id", "expression"]
        }
      },
      {
        "name": "get_tabs",
        "description": "List all open browser tabs",
        "inputSchema": {"type": "object", "properties": {}}
      },
      {
        "name": "new_tab",
        "description": "Open a new browser tab with a URL",
        "inputSchema": {
          "type": "object",
          "properties": {
            "url": {"type": "string"}
          },
          "required": ["url"]
        }
      },
      {
        "name": "close_tab",
        "description": "Close a browser tab",
        "inputSchema": {
          "type": "object",
          "properties": {
            "target_id": {"type": "string"}
          },
          "required": ["target_id"]
        }
      },
      {
        "name": "switch_tab",
        "description": "Switch to a different browser tab",
        "inputSchema": {
          "type": "object",
          "properties": {
            "target_id": {"type": "string"}
          },
          "required": ["target_id"]
        }
      },
      {
        "name": "intercept_requests",
        "description":
            "Mock/intercept network requests matching a URL pattern (return custom responses)",
        "inputSchema": {
          "type": "object",
          "properties": {
            "url_pattern": {"type": "string"},
            "status_code": {"type": "integer"},
            "body": {"type": "string"},
            "headers": {"type": "object"}
          },
          "required": ["url_pattern"]
        }
      },
      {
        "name": "clear_interceptions",
        "description": "Remove all network request interceptions",
        "inputSchema": {"type": "object", "properties": {}}
      },
      {
        "name": "accessibility_audit",
        "description":
            "Run accessibility audit (WCAG checks: missing alt, labels, heading order, contrast, lang, viewport)",
        "inputSchema": {"type": "object", "properties": {}}
      },
      {
        "name": "compare_screenshot",
        "description":
            "Visual regression test — compare current page to a baseline screenshot",
        "inputSchema": {
          "type": "object",
          "properties": {
            "baseline_path": {
              "type": "string",
              "description": "Path to baseline PNG image"
            }
          },
          "required": ["baseline_path"]
        }
      },
      {
        "name": "wait_for_network_idle",
        "description":
            "Wait until all network requests complete (no pending fetch/XHR)",
        "inputSchema": {
          "type": "object",
          "properties": {
            "timeout_ms": {"type": "integer"},
            "idle_ms": {"type": "integer"}
          }
        }
      },
      {
        "name": "get_session_storage",
        "description": "Get all sessionStorage key-value pairs",
        "inputSchema": {"type": "object", "properties": {}}
      },
      {
        "name": "type_text",
        "description":
            "Type text character by character (realistic typing simulation)",
        "inputSchema": {
          "type": "object",
          "properties": {
            "text": {"type": "string"}
          },
          "required": ["text"]
        }
      },
      {
        "name": "set_timezone",
        "description": "Override browser timezone",
        "inputSchema": {
          "type": "object",
          "properties": {
            "timezone": {
              "type": "string",
              "description": "IANA timezone (e.g. America/New_York)"
            }
          },
          "required": ["timezone"]
        }
      },
      {
        "name": "highlight_element",
        "description":
            "Highlight an element with a colored overlay for visual debugging. Injects a temporary colored border+background on the matched element.",
        "inputSchema": {
          "type": "object",
          "properties": {
            "key": {
              "type": "string",
              "description": "CSS selector, element ID, or data-testid"
            },
            "ref": {
              "type": "string",
              "description": "Element ref from snapshot"
            },
            "color": {
              "type": "string",
              "description": "Highlight color (default: red)",
              "default": "red"
            },
            "duration_ms": {
              "type": "integer",
              "description": "How long to show highlight in ms (default: 3000)",
              "default": 3000
            }
          },
          "required": ["key"]
        }
      },
      {
        "name": "mock_response",
        "description":
            "Mock/intercept network responses for a URL pattern. Returns custom status code and body for matching requests.",
        "inputSchema": {
          "type": "object",
          "properties": {
            "url_pattern": {
              "type": "string",
              "description": "URL pattern to match (glob)"
            },
            "status_code": {
              "type": "integer",
              "description": "HTTP status code to return"
            },
            "body": {
              "type": "string",
              "description": "Response body to return"
            },
            "headers": {"type": "object", "description": "Response headers"}
          },
          "required": ["url_pattern", "status_code", "body"]
        }
      },
      {
        "name": "download_file",
        "description": "Download a file from a URL and save it to disk.",
        "inputSchema": {
          "type": "object",
          "properties": {
            "url": {"type": "string", "description": "URL to download"},
            "save_path": {
              "type": "string",
              "description": "Local file path to save to"
            }
          },
          "required": ["url", "save_path"]
        }
      },
      {
        "name": "cancel_operation",
        "description":
            "Cancel a running long operation (wait_for_element, wait_for_gone, wait_for_network_idle) by operation ID.",
        "inputSchema": {
          "type": "object",
          "properties": {
            "operation_id": {
              "type": "string",
              "description": "ID of the operation to cancel"
            }
          },
          "required": ["operation_id"]
        }
      },
      {
        "name": "highlight_elements",
        "description":
            "Toggle colored outlines on ALL interactive elements (like Playwright's inspector). Useful for visual debugging and test development.",
        "inputSchema": {
          "type": "object",
          "properties": {
            "show": {
              "type": "boolean",
              "description": "true to show highlights, false to remove them",
              "default": true
            }
          }
        }
      },

      // ======================== WebMCP ========================
      {
        "name": "discover_page_tools",
        "description":
            "Discover all structured tools registered by the app. Works on ALL platforms: web (JS-registered tools, data-mcp-tool attributes, well-known manifests, auto-forms), mobile (native registered tools), desktop (registered tools). Use this to find callable tools on the current page/screen.",
        "inputSchema": {"type": "object", "properties": {}}
      },
      {
        "name": "call_page_tool",
        "description":
            "Call a discovered tool by name with parameters. Works on ALL platforms. Routes to the appropriate handler (JS function, form submit, native handler). Use discover_page_tools first to see available tools.",
        "inputSchema": {
          "type": "object",
          "properties": {
            "name": {
              "type": "string",
              "description": "Tool name (from discover_page_tools)"
            },
            "params": {
              "type": "object",
              "description": "Parameters to pass to the tool"
            }
          },
          "required": ["name"]
        }
      },
      {
        "name": "auto_discover_forms",
        "description":
            "Auto-detect ALL <form> elements on the page and convert them into callable tools with field names, labels, types, and validation info. CDP-only.",
        "inputSchema": {"type": "object", "properties": {}}
      },

      // ======================== Basic Inspection ========================
      {
        "name": "inspect",
        "description": """⚡ UI DISCOVERY TOOL ⚡

[TRIGGER KEYWORDS]
what's on screen | list buttons | show elements | see UI | find element | inspect UI | what elements | interactive elements | get widgets | discover components

[PRIMARY PURPOSE]
Discover and list all interactive UI elements currently visible on screen (buttons, text fields, switches, etc.).

[USE WHEN]
• User wants to know what UI elements are available
• Before performing tap/enter_text actions (to find element keys)
• User asks what's on the current screen/page
• Debugging UI issues or verifying element presence

[WORKFLOW]
Essential first step for any UI interaction. Returns element list with keys/texts for use with tap() and enter_text().

[OUTPUT FORMAT]
Each element includes:
• key: Element identifier for targeting
• type: Widget type (Button, TextField, etc.)
• bounds/center: Position coordinates
• coordinatesReliable: Boolean flag indicating if coordinates are trustworthy
• warning: Present if coordinates are unreliable (e.g., TextField at (0,0))

[IMPORTANT]
⚠️ TextFields may report (0,0) coordinates if not fully laid out. Check 'coordinatesReliable' flag.
   When false, use 'key' or 'text' for targeting instead of coordinates.

[MULTI-SESSION]
All action tools support optional session_id parameter. If omitted, uses the active session.
""",
        "inputSchema": {
          "type": "object",
          "properties": {
            "session_id": {
              "type": "string",
              "description": "Optional session ID (defaults to active session)"
            },
            "current_page_only": {
              "type": "boolean",
              "description":
                  "Filter to only show elements on the current visible page (excludes elements with negative coordinates or not visible). Default: true"
            },
          },
        },
      },
      {
        "name": "inspect_interactive",
        "description": """⚡ ENHANCED UI DISCOVERY TOOL ⚡

[TRIGGER KEYWORDS]
interactive elements | structured inspect | enhanced inspect | ui elements with actions | elements with selectors | actionable elements | smart inspect

[PRIMARY PURPOSE]
Discover interactive UI elements with enhanced data structure including:
• Available actions for each element (["tap", "long_press", "enter_text"])
• Reliable selectors for targeting elements
• Current state information (enabled, value, visible)
• Filtered results showing only actionable elements

[USE WHEN]
• You need structured element data for automation
• Building element interaction strategies
• Need reliable selectors instead of coordinates
• Want to see only actionable elements (filter out text/images)

[OUTPUT FORMAT]
Returns structured data:
{
  "elements": [
    {
      "type": "ElevatedButton", 
      "text": "Submit",
      "selector": {"by": "text", "value": "Submit"},
      "actions": ["tap", "long_press"],
      "bounds": {"x": 100, "y": 200, "width": 120, "height": 48},
      "enabled": true,
      "visible": true
    },
    {
      "type": "TextField",
      "label": "Email",
      "selector": {"by": "key", "value": "email_field"},
      "actions": ["tap", "enter_text"],
      "currentValue": "",
      "enabled": true,
      "visible": true
    }
  ],
  "summary": "Found 5 interactive elements: 2 buttons, 2 text fields, 1 switch"
}

[ADVANTAGES OVER inspect()]
• Structured element data with actions array
• Reliable selectors for each element  
• State information (enabled, current value)
• Only returns interactive elements (no static text/images)
• Better for automated workflows

[MULTI-SESSION]
All action tools support optional session_id parameter. If omitted, uses the active session.
""",
        "inputSchema": {
          "type": "object",
          "properties": {
            "session_id": {
              "type": "string",
              "description": "Optional session ID (defaults to active session)"
            },
          },
        },
      },
      {
        "name": "snapshot",
        "description": """📸 TEXT-BASED PAGE SNAPSHOT (Token-Efficient)

Returns a compact text representation of the current screen — like an accessibility tree.
This is MUCH more token-efficient than screenshot (typically 500 tokens vs 10,000+).

Use this INSTEAD of screenshot() when you need to understand what's on screen.
Only use screenshot() when you need actual pixel-level visual verification.

Output format:
```
Screen: LoginPage (375x812)
├── [img] App Logo (187,50 150x150)
├── [text] "Welcome Back" (100,220)
├── [input:Email] "" (20,280 335x48) ← ref
├── [input:Password] "" (20,340 335x48) ← ref
├── [button:Login] "Login" (20,410 335x48) enabled ← ref
├── [link:ForgotPassword] "Forgot Password?" (120,470) ← ref
└── [button:SignUp] "Sign Up" (120,520) enabled ← ref
```

Elements with [ref] can be targeted: tap(ref: "button:Login"), enter_text(ref: "input:Email", text: "...")
""",
        "inputSchema": {
          "type": "object",
          "properties": {
            "session_id": {
              "type": "string",
              "description": "Optional session ID (defaults to active session)"
            },
            "mode": {
              "type": "string",
              "enum": ["text", "smart", "vision", "accessibility", "dom"],
              "description":
                  "Snapshot mode: accessibility (default for CDP — uses Chrome Accessibility Tree, most compact), dom (legacy DOM query), text (default for Flutter), smart (text + hints), vision (screenshot file)"
            },
          },
        },
      },

      // ======================== Act (Composite Action) ========================
      {
        "name": "act",
        "description":
            """🎯 COMPOSITE ACTION — One-step element interaction with auto-wait + auto-scroll.

Combines element finding, waiting, scrolling into view, and action execution in a single call.
Like Playwright's locator.click() but works across Shadow DOM.

Examples:
  act(text: "Sign In", action: "click")
  act(ref: "input:Email", action: "fill", value: "user@test.com")
  act(text: "Submit", action: "click")

Supported actions: click, fill, select, hover, check
Auto-waits up to 5s for element to appear. Auto-scrolls into view if off-screen.
""",
        "inputSchema": {
          "type": "object",
          "properties": {
            "session_id": {
              "type": "string",
              "description": "Optional session ID"
            },
            "ref": {
              "type": "string",
              "description":
                  "Element ref from snapshot (e.g. 'button:Login', 'e1')"
            },
            "text": {
              "type": "string",
              "description": "Visible text of the element to act on"
            },
            "key": {
              "type": "string",
              "description": "CSS selector / element key"
            },
            "action": {
              "type": "string",
              "enum": ["click", "fill", "select", "hover", "check"],
              "description": "Action to perform (default: click)"
            },
            "value": {
              "type": "string",
              "description": "Value for fill/select actions"
            },
            "timeout": {
              "type": "integer",
              "description": "Max wait time in ms (default: 5000)"
            },
          },
          "required": ["action"],
        },
      },

      // ======================== Widget Tree ========================
      {
        "name": "get_widget_tree",
        "description": "Get the full widget tree structure",
        "inputSchema": {
          "type": "object",
          "properties": {
            "max_depth": {
              "type": "integer",
              "description": "Maximum tree depth (default: 10)"
            },
          },
        },
      },
      {
        "name": "get_widget_properties",
        "description": "Get properties of a widget by key",
        "inputSchema": {
          "type": "object",
          "properties": {
            "key": {"type": "string", "description": "Widget key"},
          },
          "required": ["key"],
        },
      },
      {
        "name": "get_text_content",
        "description": "Get all text content on the screen",
        "inputSchema": {"type": "object", "properties": {}},
      },
      {
        "name": "find_by_type",
        "description": """Find widgets by type name

[PRIMARY PURPOSE]
Search for all widgets matching a specific type (e.g., "TextField", "Button", "ListTile").

[USAGE]
find_by_type(type: "TextField")  // Finds all TextFields
find_by_type(type: "Button")     // Finds all button types

[OUTPUT FORMAT]
Returns list of widgets with:
• type: Full widget type name
• key: Element identifier if available
• position: {x, y} coordinates
• size: {width, height} dimensions
• coordinatesReliable: Boolean - true if coordinates are trustworthy

[IMPORTANT]
⚠️ Check 'coordinatesReliable' flag before using coordinates for tap/click actions.
   If false, use 'key' property for reliable targeting.
""",
        "inputSchema": {
          "type": "object",
          "properties": {
            "type": {
              "type": "string",
              "description": "Widget type name to search"
            },
          },
          "required": ["type"],
        },
      },

      // ======================== Basic Actions ========================
      {
        "name": "tap",
        "description": """⚡ UI INTERACTION TOOL ⚡

[TRIGGER KEYWORDS]
tap | click | press | select | activate | touch | hit button | click button | press button | trigger | push

[PRIMARY PURPOSE]
Tap/click a button or any interactive UI element. Simulates real user touch/click interaction.

[SUPPORTED METHODS]
1. By semantic ref ID: tap(ref: "button:Login")  // From inspect_interactive() - RECOMMENDED
2. By Widget key: tap(key: "submit_button")
3. By visible text: tap(text: "Submit")
4. By coordinates: tap(x: 100, y: 200)  // Use center coordinates from inspect()

[USE WHEN]
• User asks to click/press/tap a button or element
• Testing button functionality or navigation
• Automating user interactions in UI flows

[WORKFLOW]
Call inspect() first to see available elements and their keys/texts/coordinates, then use tap() with one of the methods above.

[TIP FOR ICONS/IMAGES]
For elements without text (icons, images), use coordinates from inspect():
  inspect() returns: {"center": {"x": 30, "y": 22}}
  Then call: tap(x: 30, y: 22)
""",
        "inputSchema": {
          "type": "object",
          "properties": {
            "ref": {
              "type": "string",
              "description":
                  "Semantic ref ID from inspect_interactive (RECOMMENDED)"
            },
            "key": {"type": "string", "description": "Widget key"},
            "text": {"type": "string", "description": "Text to find"},
            "x": {"type": "number", "description": "X coordinate (use with y)"},
            "y": {"type": "number", "description": "Y coordinate (use with x)"},
          },
        },
      },
      {
        "name": "enter_text",
        "description": """⚡ TEXT INPUT TOOL ⚡

[TRIGGER KEYWORDS]
enter text | type | input | fill in | write | fill form | enter email | enter password | set value | submit text

[PRIMARY PURPOSE]
Type text into text fields (email, password, search, forms, etc.). Simulates real user keyboard input.

[USE WHEN]
• User wants to fill in forms or input fields
• Testing login screens (email/password)
• Testing search functionality
• Automating data entry in UI flows

[WORKFLOW]
Option 1 (RECOMMENDED): Call inspect_interactive() to find TextField refs, then enter_text(ref: "input:Email", text: "value").
Option 2: Call inspect() to find TextField keys, then enter_text(key: "field_key", text: "value").
Option 3: Tap a TextField first, then enter_text(text: "value") without key/ref - enters into focused field.
""",
        "inputSchema": {
          "type": "object",
          "properties": {
            "ref": {
              "type": "string",
              "description":
                  "Semantic ref ID from inspect_interactive (RECOMMENDED)"
            },
            "key": {
              "type": "string",
              "description":
                  "TextField key (optional - if omitted, enters text into the currently focused TextField)"
            },
            "text": {"type": "string", "description": "Text to enter"},
          },
          "required": ["text"],
        },
      },
      {
        "name": "scroll_to",
        "description": "Scroll to make an element visible",
        "inputSchema": {
          "type": "object",
          "properties": {
            "key": {"type": "string", "description": "Widget key"},
            "text": {"type": "string", "description": "Text to find"}
          }
        }
      },

      // ======================== Advanced Actions ========================
      {
        "name": "long_press",
        "description": "Long press on an element",
        "inputSchema": {
          "type": "object",
          "properties": {
            "key": {"type": "string", "description": "Widget key"},
            "text": {"type": "string", "description": "Text to find"},
            "duration": {
              "type": "integer",
              "description": "Duration in ms (default: 500)"
            }
          }
        }
      },
      {
        "name": "double_tap",
        "description": "Double tap on an element",
        "inputSchema": {
          "type": "object",
          "properties": {
            "key": {"type": "string", "description": "Widget key"},
            "text": {"type": "string", "description": "Text to find"}
          }
        }
      },
      {
        "name": "swipe",
        "description": "Perform a swipe gesture",
        "inputSchema": {
          "type": "object",
          "properties": {
            "direction": {
              "type": "string",
              "enum": ["up", "down", "left", "right"]
            },
            "distance": {
              "type": "number",
              "description": "Swipe distance in pixels (default: 300)"
            },
            "key": {
              "type": "string",
              "description": "Start from element (optional)"
            }
          },
          "required": ["direction"]
        }
      },
      {
        "name": "drag",
        "description": "Drag from one element (from_key/to_key) or between "
            "logical coordinates (start_x/start_y -> end_x/end_y). Set "
            "hold_ms (e.g. 400) for LongPressDraggable / long-press-to-select "
            "lists so the drag is recognised before the pointer moves.",
        "inputSchema": {
          "type": "object",
          "properties": {
            "from_key": {"type": "string", "description": "Source element key"},
            "to_key": {"type": "string", "description": "Target element key"},
            "start_x": {"type": "number", "description": "Start X (logical)"},
            "start_y": {"type": "number", "description": "Start Y (logical)"},
            "end_x": {"type": "number", "description": "End X (logical)"},
            "end_y": {"type": "number", "description": "End Y (logical)"},
            "hold_ms": {
              "type": "integer",
              "description": "Press-and-hold before moving, in ms (default 0)"
            },
            "duration_ms": {
              "type": "integer",
              "description": "Travel time in ms (default 400)"
            }
          }
        }
      },

      // ======================== State & Validation ========================
      {
        "name": "get_text_value",
        "description": "Get current value of a text field",
        "inputSchema": {
          "type": "object",
          "properties": {
            "key": {"type": "string", "description": "TextField key"}
          },
          "required": ["key"]
        }
      },
      {
        "name": "get_checkbox_state",
        "description": "Get state of a checkbox or switch",
        "inputSchema": {
          "type": "object",
          "properties": {
            "key": {"type": "string", "description": "Checkbox/Switch key"}
          },
          "required": ["key"]
        }
      },
      {
        "name": "get_slider_value",
        "description": "Get current value of a slider",
        "inputSchema": {
          "type": "object",
          "properties": {
            "key": {"type": "string", "description": "Slider key"}
          },
          "required": ["key"]
        }
      },
      {
        "name": "wait_for_element",
        "description": "Wait for an element to appear",
        "inputSchema": {
          "type": "object",
          "properties": {
            "key": {"type": "string", "description": "Widget key"},
            "text": {"type": "string", "description": "Text to find"},
            "timeout": {
              "type": "integer",
              "description": "Timeout in ms (default: 5000)"
            }
          }
        }
      },
      {
        "name": "wait_for_gone",
        "description": "Wait for an element to disappear",
        "inputSchema": {
          "type": "object",
          "properties": {
            "key": {"type": "string", "description": "Widget key"},
            "text": {"type": "string", "description": "Text to find"},
            "timeout": {
              "type": "integer",
              "description": "Timeout in ms (default: 5000)"
            }
          }
        }
      },

      // ======================== Screenshot ========================
      {
        "name": "screenshot",
        "description": """⚡ VISUAL CAPTURE TOOL ⚡

[TRIGGER KEYWORDS]
screenshot | take picture | capture screen | show me | how does it look | visual debugging | take photo | snap | show current screen | grab screen | print screen

[PRIMARY PURPOSE]
Capture a screenshot of the current app screen for visual inspection, debugging, or documentation.

[USE WHEN]
• User wants to see what the current screen looks like
• Visual debugging of UI issues
• Documenting app state or test results
• Verifying UI appearance after actions

[RETURNS]
By default, saves screenshot to a temporary file and returns file path. Optionally can return base64-encoded PNG image.

[DEFAULTS OPTIMIZED FOR USABILITY]
• save_to_file: true (saves to file, returns path - recommended for large images)
• quality: 0.5 (prevents token overflow, set to 1.0 for full quality)
• max_width: 800 (scales down large screens, set to null for original size)
• For high-quality screenshots, explicitly set: quality=1.0, max_width=null
""",
        "inputSchema": {
          "type": "object",
          "properties": {
            "save_to_file": {
              "type": "boolean",
              "description":
                  "Save to file and return path (default: true, recommended)",
              "default": true
            },
            "quality": {
              "type": "number",
              "description":
                  "Image quality 0.1-1.0 (default: 0.5, lower = smaller file)"
            },
            "max_width": {
              "type": "integer",
              "description":
                  "Maximum width in pixels (default: 800, null for original size)"
            },
          },
        },
      },
      {
        "name": "screenshot_region",
        "description":
            "Take a screenshot of a specific screen region. Defaults to saving as file to prevent token overflow.",
        "inputSchema": {
          "type": "object",
          "properties": {
            "x": {
              "type": "number",
              "description": "X coordinate of top-left corner"
            },
            "y": {
              "type": "number",
              "description": "Y coordinate of top-left corner"
            },
            "width": {"type": "number", "description": "Width of region"},
            "height": {"type": "number", "description": "Height of region"},
            "save_to_file": {
              "type": "boolean",
              "description":
                  "Save to temp file instead of returning base64 (default: true)"
            }
          },
          "required": ["x", "y", "width", "height"]
        }
      },
      {
        "name": "screenshot_element",
        "description":
            "Take a screenshot of a specific element by CSS selector, key, or text content",
        "inputSchema": {
          "type": "object",
          "properties": {
            "selector": {
              "type": "string",
              "description": "CSS selector (e.g. 'h1', '.my-class', '#my-id')"
            },
            "key": {"type": "string", "description": "Element key"},
            "text": {"type": "string", "description": "Text content to find"}
          }
        }
      },

      // ======================== Navigation ========================
      {
        "name": "get_current_route",
        "description": "Get the current route name",
        "inputSchema": {"type": "object", "properties": {}}
      },
      {
        "name": "go_back",
        "description":
            "Navigate back. Use count > 1 to pop multiple routes at once instead of calling go_back() repeatedly.",
        "inputSchema": {
          "type": "object",
          "properties": {
            "count": {
              "type": "integer",
              "description":
                  "Number of back steps (default: 1). A 300 ms pause between steps allows route transitions to complete.",
              "default": 1,
              "minimum": 1,
            }
          }
        }
      },
      {
        "name": "get_navigation_stack",
        "description": "Get the navigation stack",
        "inputSchema": {"type": "object", "properties": {}}
      },

      // ======================== Debug & Logs ========================
      {
        "name": "get_logs",
        "description": "Get application logs",
        "inputSchema": {"type": "object", "properties": {}}
      },
      {
        "name": "get_errors",
        "description": "Get application errors with pagination support",
        "inputSchema": {
          "type": "object",
          "properties": {
            "limit": {
              "type": "integer",
              "description": "Maximum number of errors to return (default: 50)"
            },
            "offset": {
              "type": "integer",
              "description": "Number of errors to skip (default: 0)"
            }
          }
        }
      },
      {
        "name": "clear_logs",
        "description": "Clear logs and errors",
        "inputSchema": {"type": "object", "properties": {}}
      },
      {
        "name": "get_performance",
        "description": "Get performance metrics",
        "inputSchema": {"type": "object", "properties": {}}
      },

      // ======================== HTTP / Network Monitoring ========================
      {
        "name": "get_network_requests",
        "description": """⚡ NETWORK MONITOR ⚡

[TRIGGER KEYWORDS]
api response | network request | http response | check api | what api called | network traffic | http status | api result

[PRIMARY PURPOSE]
View HTTP/API requests made by the app. Shows URL, method, status code, duration, and response body.
Use after tap/interaction to verify what API calls were triggered.

[USE WHEN]
• After tapping a button to check what API was called
• Verifying login/signup API responses
• Debugging network issues
• Checking API response data after user actions

[WORKFLOW]
1. Call enable_network_monitoring() first (one-time setup)
2. Perform actions (tap, enter_text, etc.)
3. Call get_network_requests() to see API calls made

[OUTPUT]
Each request includes: method, url, status_code, duration_ms, response_body (truncated)
""",
        "inputSchema": {
          "type": "object",
          "properties": {
            "limit": {
              "type": "integer",
              "description":
                  "Maximum number of requests to return (default: 20)"
            },
          },
        },
      },
      {
        "name": "enable_network_monitoring",
        "description":
            "Enable HTTP/network request monitoring. Call once before using get_network_requests.",
        "inputSchema": {
          "type": "object",
          "properties": {
            "enable": {
              "type": "boolean",
              "description":
                  "Enable (true) or disable (false) monitoring. Default: true"
            }
          }
        }
      },
      {
        "name": "clear_network_requests",
        "description": "Clear captured network request history",
        "inputSchema": {"type": "object", "properties": {}}
      },

      // ======================== Utilities ========================
      {
        "name": "hot_reload",
        "description": "Trigger hot reload (fast, keeps app state)",
        "inputSchema": {"type": "object", "properties": {}}
      },
      {
        "name": "hot_restart",
        "description": "Trigger hot restart (slower, resets app state)",
        "inputSchema": {"type": "object", "properties": {}}
      },

      // ======================== Native Platform ========================
      {
        "name": "native_screenshot",
        "description": """Take a screenshot at the OS level (bypasses Flutter).

[USE WHEN]
• A native dialog is shown (photo picker, permission dialog, share sheet)
• Flutter's screenshot returns a blank/stale image
• You need to see system-level UI (status bar, keyboard, etc.)
• The app is presenting a platform view not rendered by Flutter

[HOW IT WORKS]
• iOS Simulator: Uses xcrun simctl screenshot
• Android Emulator: Uses adb shell screencap

[RETURNS]
Screenshot saved to a temporary file (default) or base64-encoded PNG.
This captures the ENTIRE device screen, not just the Flutter app content.""",
        "inputSchema": {
          "type": "object",
          "properties": {
            "save_to_file": {
              "type": "boolean",
              "description": "Save to file and return path (default: true)"
            }
          }
        },
      },
      {
        "name": "native_tap",
        "description":
            """Tap at device coordinates using OS-level input (bypasses Flutter).

[USE WHEN]
• Interacting with native dialogs (photo picker, permission "Allow", share sheet)
• Flutter's tap() doesn't work because the target is a native view
• Tapping system UI elements (status bar, notification)

[HOW IT WORKS]
• iOS Simulator: Uses macOS Accessibility API to find and press UI elements at device coordinates
• Android Emulator: Uses adb shell input tap

[IMPORTANT]
• Coordinates are in device pixels (same as native_screenshot dimensions)
• Take a native_screenshot first to identify tap targets
• iOS: No external tools needed (uses built-in osascript + Accessibility API)
• The Simulator window must be visible and not minimized""",
        "inputSchema": {
          "type": "object",
          "properties": {
            "x": {
              "type": "number",
              "description": "X coordinate in device pixels"
            },
            "y": {
              "type": "number",
              "description": "Y coordinate in device pixels"
            }
          },
          "required": ["x", "y"]
        },
      },
      {
        "name": "native_input_text",
        "description": """Enter text using OS-level input (bypasses Flutter).

[USE WHEN]
• Typing into native text fields (search bars in native pickers, etc.)
• Flutter's enter_text() doesn't work because the field is in a native view
• Entering text in system dialogs

[HOW IT WORKS]
• iOS Simulator: Copies text to pasteboard via simctl, then pastes with Cmd+V
• Android Emulator: Uses adb shell input text

[IMPORTANT]
• The target text field must already be focused (tap it first with native_tap)
• iOS method uses paste, so it replaces clipboard content
• iOS paste confirmation dialog ("Allow Paste") is automatically dismissed""",
        "inputSchema": {
          "type": "object",
          "properties": {
            "text": {"type": "string", "description": "Text to enter"}
          },
          "required": ["text"]
        },
      },
      {
        "name": "native_swipe",
        "description": """Swipe using OS-level input (bypasses Flutter).

[USE WHEN]
• Swiping in native views (photo gallery scroll, native list)
• Dismissing native dialogs with swipe
• Flutter's swipe doesn't work because the scrollable is a native view

[HOW IT WORKS]
• iOS Simulator: Uses macOS Accessibility API scroll actions on elements at device coordinates
• Android Emulator: Uses adb shell input swipe

[IMPORTANT]
• Coordinates are in device pixels
• Take a native_screenshot first to plan your swipe path
• iOS: Scrolls by page using accessibility actions (AXScrollUpByPage/AXScrollDownByPage)""",
        "inputSchema": {
          "type": "object",
          "properties": {
            "start_x": {
              "type": "number",
              "description": "Start X in device pixels"
            },
            "start_y": {
              "type": "number",
              "description": "Start Y in device pixels"
            },
            "end_x": {
              "type": "number",
              "description": "End X in device pixels"
            },
            "end_y": {
              "type": "number",
              "description": "End Y in device pixels"
            },
            "duration": {
              "type": "integer",
              "description": "Swipe duration in ms (default: 300)"
            }
          },
          "required": ["start_x", "start_y", "end_x", "end_y"]
        },
      },
      {
        "name": "native_long_press",
        "description":
            "Long press at device coordinates using OS-level input (bypasses Flutter). iOS: AX tree element press. Android: adb swipe to same point.",
        "inputSchema": {
          "type": "object",
          "properties": {
            "x": {
              "type": "number",
              "description": "X coordinate in device pixels"
            },
            "y": {
              "type": "number",
              "description": "Y coordinate in device pixels"
            },
            "duration": {
              "type": "integer",
              "description": "Duration in ms (default: 1000)"
            },
          },
          "required": ["x", "y"],
        },
      },
      {
        "name": "native_gesture",
        "description":
            "Perform a preset gesture: scroll_up/down/left/right, edge_swipe_left/right, pull_to_refresh.",
        "inputSchema": {
          "type": "object",
          "properties": {
            "gesture": {
              "type": "string",
              "description": "Gesture name",
              "enum": [
                "scroll_up",
                "scroll_down",
                "scroll_left",
                "scroll_right",
                "edge_swipe_left",
                "edge_swipe_right",
                "pull_to_refresh"
              ]
            },
          },
          "required": ["gesture"],
        },
      },
      {
        "name": "native_press_key",
        "description":
            "Press a single key: enter, backspace, tab, escape, delete, space, up, down, left, right, home_key, end_key, volume_up, volume_down.",
        "inputSchema": {
          "type": "object",
          "properties": {
            "key": {"type": "string", "description": "Key name"},
          },
          "required": ["key"],
        },
      },
      {
        "name": "native_key_combo",
        "description":
            "Press a key combination (e.g. cmd+a, ctrl+c). Android: limited to ctrl+a/c/v/x/z.",
        "inputSchema": {
          "type": "object",
          "properties": {
            "keys": {
              "type": "string",
              "description": "Key combo (e.g. 'cmd+a', 'shift+tab')"
            },
          },
          "required": ["keys"],
        },
      },
      {
        "name": "native_button",
        "description":
            "Press a hardware button: home, lock, power, siri, volume_up, volume_down, app_switch.",
        "inputSchema": {
          "type": "object",
          "properties": {
            "button": {"type": "string", "description": "Button name"},
          },
          "required": ["button"],
        },
      },
      {
        "name": "native_video_start",
        "description":
            "Start recording the iOS Simulator screen to an MP4 video file using H.264 codec. Use native_video_stop to finish.",
        "inputSchema": {
          "type": "object",
          "properties": {
            "device_id": {
              "type": "string",
              "description": "Device identifier ('ios' for auto-detect)",
            },
            "path": {
              "type": "string",
              "description":
                  "Output file path (default: auto-generated in temp dir)",
            },
          },
        },
      },
      {
        "name": "native_video_stop",
        "description":
            "Stop recording the iOS Simulator screen and return the MP4 file path and size.",
        "inputSchema": {
          "type": "object",
          "properties": {
            "device_id": {
              "type": "string",
              "description": "Device identifier ('ios' for auto-detect)",
            },
          },
        },
      },
      {
        "name": "native_capture_frames",
        "description":
            "Capture a burst of screenshot frames from the iOS Simulator at a target FPS. Returns JPEG frame paths for GIF creation or visual comparison.",
        "inputSchema": {
          "type": "object",
          "properties": {
            "device_id": {
              "type": "string",
              "description": "Device identifier ('ios' for auto-detect)",
            },
            "fps": {
              "type": "integer",
              "description": "Target frames per second (default: 5, max: 15)",
            },
            "duration_ms": {
              "type": "integer",
              "description": "Capture duration in milliseconds (default: 3000)",
            },
            "quality": {
              "type": "integer",
              "description": "JPEG quality 1-100 (default: 80)",
            },
          },
        },
      },
      {
        "name": "native_list_simulators",
        "description":
            "List available iOS simulators and Android emulators with their state.",
        "inputSchema": {
          "type": "object",
          "properties": {
            "platform": {
              "type": "string",
              "description":
                  "Filter: 'ios', 'android', or 'all' (default: 'all')",
              "enum": ["ios", "android", "all"]
            },
          },
        },
      },

      // ======================== idb (iOS Development Bridge) ========================
      {
        "name": "idb_describe",
        "description": "Describe the booted iOS Simulator via idb (iOS Development Bridge). "
            "Returns device model, OS version, logical screen resolution, scale factor, "
            "and idb availability. Use this to verify idb is working before using "
            "native_tap / native_swipe / native_input_text (which prefer idb when available).",
        "inputSchema": {
          "type": "object",
          "properties": {},
        },
      },

      // ======================== Diagnose ========================
      {
        "name": "diagnose_project",
        "description": """⚡ DIAGNOSTIC & AUTO-FIX TOOL ⚡

[TRIGGER KEYWORDS]
diagnose | check configuration | verify setup | fix config | configuration problem | setup issue | missing dependency | not configured

[PRIMARY PURPOSE]
Diagnose Flutter project configuration and automatically fix common issues.

[USE WHEN]
• Connection problems ("not connected", "VM Service not found")
• Setup verification before testing
• Troubleshooting configuration issues
• First-time project setup

[CHECKS PERFORMED]
• pubspec.yaml - flutter_skill dependency
• lib/main.dart - FlutterSkillBinding initialization
• Running processes - Flutter app status
• Port availability - VM Service ports

[AUTO-FIX OPTIONS]
• auto_fix: true (default) - Automatically fix detected issues
• auto_fix: false - Only report issues without fixing

[RETURNS]
Detailed diagnostic report with:
• Configuration status (✅/❌)
• Detected issues
• Auto-fix results
• Recommendations""",
        "inputSchema": {
          "type": "object",
          "properties": {
            "project_path": {
              "type": "string",
              "description":
                  "Path to Flutter project (default: current directory)"
            },
            "auto_fix": {
              "type": "boolean",
              "description": "Automatically fix detected issues (default: true)"
            }
          }
        },
      },
      {
        "name": "pub_search",
        "description": "Search Flutter packages on pub.dev",
        "inputSchema": {
          "type": "object",
          "properties": {
            "query": {"type": "string", "description": "Search query"}
          },
          "required": ["query"]
        }
      },

      // ======================== Test Indicators ========================
      {
        "name": "enable_test_indicators",
        "description":
            "Enable visual indicators for test actions (tap, swipe, long press, text input)",
        "inputSchema": {
          "type": "object",
          "properties": {
            "enabled": {
              "type": "boolean",
              "description": "Enable or disable indicators",
              "default": true
            },
            "style": {
              "type": "string",
              "description":
                  "Indicator style: minimal (fast, small), standard (default), detailed (slow, large with debug info)",
              "enum": ["minimal", "standard", "detailed"],
              "default": "standard"
            }
          }
        }
      },
      {
        "name": "get_indicator_status",
        "description": "Get current test indicator status",
        "inputSchema": {"type": "object", "properties": {}}
      },

      // ======================== Batch Operations ========================
      {
        "name": "execute_batch",
        "description":
            "Execute multiple actions in sequence. Reduces round-trip latency for complex test flows.",
        "inputSchema": {
          "type": "object",
          "properties": {
            "actions": {
              "type": "array",
              "description": "List of actions to execute",
              "items": {
                "type": "object",
                "properties": {
                  "action": {
                    "type": "string",
                    "description":
                        "Action name (tap, enter_text, swipe, wait, screenshot, assert_visible, assert_text)"
                  },
                  "key": {"type": "string"},
                  "text": {"type": "string"},
                  "value": {"type": "string"},
                  "direction": {"type": "string"},
                  "duration": {"type": "integer"},
                  "expected": {"type": "string"}
                },
                "required": ["action"]
              }
            },
            "stop_on_failure": {
              "type": "boolean",
              "description": "Stop execution on first failure (default: true)"
            }
          },
          "required": ["actions"]
        }
      },

      // ======================== Coordinate-based Actions ========================
      {
        "name": "tap_at",
        "description": "Tap at specific screen coordinates",
        "inputSchema": {
          "type": "object",
          "properties": {
            "x": {"type": "number", "description": "X coordinate"},
            "y": {"type": "number", "description": "Y coordinate"}
          },
          "required": ["x", "y"]
        }
      },
      {
        "name": "long_press_at",
        "description": "Long press at specific screen coordinates",
        "inputSchema": {
          "type": "object",
          "properties": {
            "x": {"type": "number", "description": "X coordinate"},
            "y": {"type": "number", "description": "Y coordinate"},
            "duration": {
              "type": "integer",
              "description": "Duration in ms (default: 500)"
            }
          },
          "required": ["x", "y"]
        }
      },
      {
        "name": "swipe_coordinates",
        "description": "Swipe from one coordinate to another",
        "inputSchema": {
          "type": "object",
          "properties": {
            "start_x": {"type": "number", "description": "Start X coordinate"},
            "start_y": {"type": "number", "description": "Start Y coordinate"},
            "end_x": {"type": "number", "description": "End X coordinate"},
            "end_y": {"type": "number", "description": "End Y coordinate"},
            "duration": {
              "type": "integer",
              "description": "Duration in ms (default: 300)"
            }
          },
          "required": ["start_x", "start_y", "end_x", "end_y"]
        }
      },
      {
        "name": "edge_swipe",
        "description":
            "Swipe from screen edge (for drawer menus, back gestures)",
        "inputSchema": {
          "type": "object",
          "properties": {
            "edge": {
              "type": "string",
              "enum": ["left", "right", "top", "bottom"],
              "description": "Screen edge to start from"
            },
            "direction": {
              "type": "string",
              "enum": ["up", "down", "left", "right"],
              "description": "Swipe direction"
            },
            "distance": {
              "type": "number",
              "description": "Swipe distance in pixels (default: 200)"
            }
          },
          "required": ["edge", "direction"]
        }
      },
      {
        "name": "gesture",
        "description":
            "Perform a gesture with preset or custom coordinates. Presets: drawer_open, drawer_close, pull_refresh, page_back, swipe_left, swipe_right",
        "inputSchema": {
          "type": "object",
          "properties": {
            "preset": {
              "type": "string",
              "enum": [
                "drawer_open",
                "drawer_close",
                "pull_refresh",
                "page_back",
                "swipe_left",
                "swipe_right"
              ],
              "description": "Use a predefined gesture"
            },
            "from_x": {
              "type": "number",
              "description": "Custom start X (0.0-1.0 as ratio, or pixels)"
            },
            "from_y": {
              "type": "number",
              "description": "Custom start Y (0.0-1.0 as ratio, or pixels)"
            },
            "to_x": {
              "type": "number",
              "description": "Custom end X (0.0-1.0 as ratio, or pixels)"
            },
            "to_y": {
              "type": "number",
              "description": "Custom end Y (0.0-1.0 as ratio, or pixels)"
            },
            "duration": {
              "type": "integer",
              "description": "Gesture duration in ms (default: 300)"
            }
          }
        }
      },
      {
        "name": "wait_for_idle",
        "description":
            "Wait for the app to become idle (no animations, no pending frames)",
        "inputSchema": {
          "type": "object",
          "properties": {
            "timeout": {
              "type": "integer",
              "description": "Maximum wait time in ms (default: 5000)"
            },
            "min_idle_time": {
              "type": "integer",
              "description":
                  "Minimum idle duration to confirm stability (default: 500)"
            }
          }
        }
      },

      // ======================== Smart Scroll ========================
      {
        "name": "scroll_until_visible",
        "description":
            "Scroll in a direction until target element becomes visible",
        "inputSchema": {
          "type": "object",
          "properties": {
            "key": {"type": "string", "description": "Target element key"},
            "text": {"type": "string", "description": "Target element text"},
            "direction": {
              "type": "string",
              "enum": ["up", "down", "left", "right"],
              "description": "Scroll direction (default: down)"
            },
            "max_scrolls": {
              "type": "integer",
              "description": "Maximum scroll attempts (default: 10)"
            },
            "scrollable_key": {
              "type": "string",
              "description": "Key of the scrollable container (optional)"
            }
          }
        }
      },

      // ======================== Assertions ========================
      {
        "name": "assert_visible",
        "description": "Assert that an element is visible on screen",
        "inputSchema": {
          "type": "object",
          "properties": {
            "key": {"type": "string", "description": "Element key"},
            "text": {"type": "string", "description": "Element text"},
            "timeout": {
              "type": "integer",
              "description": "Wait timeout in ms (default: 5000)"
            }
          }
        }
      },
      {
        "name": "assert_not_visible",
        "description": "Assert that an element is NOT visible on screen",
        "inputSchema": {
          "type": "object",
          "properties": {
            "key": {"type": "string", "description": "Element key"},
            "text": {"type": "string", "description": "Element text"},
            "timeout": {
              "type": "integer",
              "description": "Wait timeout in ms (default: 5000)"
            }
          }
        }
      },
      {
        "name": "assert_text",
        "description": "Assert that an element contains specific text",
        "inputSchema": {
          "type": "object",
          "properties": {
            "key": {"type": "string", "description": "Element key"},
            "expected": {
              "type": "string",
              "description": "Expected text content"
            },
            "contains": {
              "type": "boolean",
              "description": "Use contains instead of equals (default: false)"
            }
          },
          "required": ["key", "expected"]
        }
      },
      {
        "name": "assert_element_count",
        "description": "Assert the count of elements matching criteria",
        "inputSchema": {
          "type": "object",
          "properties": {
            "type": {"type": "string", "description": "Widget type to count"},
            "text": {"type": "string", "description": "Text to match"},
            "expected_count": {
              "type": "integer",
              "description": "Expected count"
            },
            "min_count": {
              "type": "integer",
              "description": "Minimum count (alternative to exact)"
            },
            "max_count": {
              "type": "integer",
              "description": "Maximum count (alternative to exact)"
            }
          }
        }
      },
      {
        "name": "assert_batch",
        "description":
            "Run multiple assertions in a single call. Returns all results (does not fail-fast).",
        "inputSchema": {
          "type": "object",
          "properties": {
            "assertions": {
              "type": "array",
              "description": "List of assertions to run",
              "items": {
                "type": "object",
                "properties": {
                  "type": {
                    "type": "string",
                    "enum": ["visible", "not_visible", "text", "element_count"],
                    "description": "Assertion type"
                  },
                  "key": {"type": "string", "description": "Element key"},
                  "text": {
                    "type": "string",
                    "description":
                        "Text to find (for visible/not_visible) or expected text (for text assertion)"
                  },
                  "expected": {
                    "type": "string",
                    "description": "Expected value for text assertion"
                  },
                  "count": {
                    "type": "integer",
                    "description": "Expected count for element_count assertion"
                  }
                },
                "required": ["type"]
              }
            }
          },
          "required": ["assertions"]
        }
      },

      // ======================== Page State ========================
      {
        "name": "get_page_state",
        "description":
            "Get complete page state snapshot (route, scroll position, focused element, keyboard, loading indicators)",
        "inputSchema": {"type": "object", "properties": {}}
      },
      {
        "name": "get_interactable_elements",
        "description":
            "Get all interactable elements on current screen with suggested actions",
        "inputSchema": {
          "type": "object",
          "properties": {
            "include_positions": {
              "type": "boolean",
              "description": "Include x/y positions (default: true)"
            }
          }
        }
      },

      // ======================== Performance & Memory ========================
      {
        "name": "get_frame_stats",
        "description":
            "Get frame rendering statistics (FPS, jank, build/raster times)",
        "inputSchema": {"type": "object", "properties": {}}
      },
      {
        "name": "get_memory_stats",
        "description": "Get memory usage statistics (heap, external)",
        "inputSchema": {"type": "object", "properties": {}}
      },

      // ======================== Smart Diagnosis ========================
      {
        "name": "diagnose",
        "description":
            "Analyze logs and UI state to detect issues and provide fix suggestions. Returns structured diagnosis with issues, suggestions, and next steps.",
        "inputSchema": {
          "type": "object",
          "properties": {
            "scope": {
              "type": "string",
              "enum": ["all", "logs", "ui", "performance"],
              "description": "Diagnosis scope (default: all)"
            },
            "log_lines": {
              "type": "integer",
              "description":
                  "Number of recent log lines to analyze (default: 100)"
            },
            "include_screenshot": {
              "type": "boolean",
              "description": "Include screenshot in diagnosis (default: false)"
            }
          }
        }
      },

      // ======================== Auth Tools ========================
      {
        "name": "auth_inject_session",
        "description":
            "Inject auth token into app storage (cookie, localStorage, or shared_preferences).",
        "inputSchema": {
          "type": "object",
          "properties": {
            "token": {"type": "string", "description": "Auth token to inject"},
            "key": {
              "type": "string",
              "description": "Storage key (default: auth_token)"
            },
            "storage_type": {
              "type": "string",
              "enum": ["cookie", "local_storage", "shared_preferences"],
              "description": "Storage type"
            }
          },
          "required": ["token"]
        }
      },
      {
        "name": "auth_biometric",
        "description":
            "Simulate biometric authentication on iOS simulator or Android emulator.",
        "inputSchema": {
          "type": "object",
          "properties": {
            "action": {
              "type": "string",
              "enum": ["enroll", "match", "fail"],
              "description": "Biometric action"
            }
          },
          "required": ["action"]
        }
      },
      {
        "name": "auth_otp",
        "description":
            "Generate TOTP code from secret, or read OTP from simulator clipboard.",
        "inputSchema": {
          "type": "object",
          "properties": {
            "secret": {
              "type": "string",
              "description":
                  "TOTP secret (base32). If omitted, reads clipboard."
            },
            "digits": {
              "type": "integer",
              "description": "OTP digits (default: 6)"
            },
            "period": {
              "type": "integer",
              "description": "TOTP period in seconds (default: 30)"
            }
          }
        }
      },
      {
        "name": "auth_deeplink",
        "description": "Open a deep link URL on the simulator/emulator.",
        "inputSchema": {
          "type": "object",
          "properties": {
            "url": {"type": "string", "description": "Deep link URL to open"},
            "device": {"type": "string", "description": "Device identifier"}
          },
          "required": ["url"]
        }
      },

      // ======================== QR Code Login ========================
      {
        "name": "qr_login_start",
        "description":
            "Detect and screenshot a QR code on the current page for remote scanning. Returns base64 image + initial page state for login detection. Workflow: 1) Call this to get QR image, 2) Send image to user (e.g. via Telegram/chat), 3) User scans with phone, 4) Call qr_login_wait to detect success. Works with WeChat, CSDN, Zhihu, DingTalk, Alipay, and any QR-based login.",
        "inputSchema": {
          "type": "object",
          "properties": {
            "selector": {
              "type": "string",
              "description":
                  "CSS selector for QR code element (auto-detects if omitted)"
            },
            "full_page": {
              "type": "boolean",
              "description":
                  "Take full page screenshot instead of cropping QR (default: false)"
            }
          }
        }
      },
      {
        "name": "qr_login_wait",
        "description":
            "Poll until QR code login succeeds. Detects: URL change, cookie change, QR element disappearing, or success text appearing. Default timeout: 120s.",
        "inputSchema": {
          "type": "object",
          "properties": {
            "initial_url": {
              "type": "string",
              "description":
                  "URL before scanning (from qr_login_start response)"
            },
            "initial_cookie_length": {
              "type": "integer",
              "description":
                  "Cookie length before scanning (from qr_login_start response)"
            },
            "timeout_ms": {
              "type": "integer",
              "description": "Timeout in milliseconds (default: 120000)"
            },
            "poll_ms": {
              "type": "integer",
              "description": "Poll interval in milliseconds (default: 1000)"
            },
            "success_url_pattern": {
              "type": "string",
              "description":
                  "Regex pattern for successful redirect URL (optional)"
            },
            "success_text": {
              "type": "string",
              "description":
                  "Text that appears on page after successful login (optional)"
            },
            "qr_selector": {
              "type": "string",
              "description":
                  "CSS selector for QR element — login detected when it disappears (optional)"
            }
          }
        }
      },

      // ======================== Recording & Code Generation ========================
      {
        "name": "record_start",
        "description": "Start recording tool calls for test code generation.",
        "inputSchema": {"type": "object", "properties": {}}
      },
      {
        "name": "record_stop",
        "description": "Stop recording and return recorded steps.",
        "inputSchema": {"type": "object", "properties": {}}
      },
      {
        "name": "record_export",
        "description": "Export recorded steps as test code in various formats.",
        "inputSchema": {
          "type": "object",
          "properties": {
            "format": {
              "type": "string",
              "enum": [
                "jest",
                "pytest",
                "dart_test",
                "playwright",
                "cypress",
                "selenium",
                "xcuitest",
                "espresso",
                "json"
              ],
              "description":
                  "Export format: jest (JS), pytest (Python), dart_test (Dart), playwright (JS), cypress (JS), selenium (Python), xcuitest (Swift), espresso (Kotlin), json (raw)"
            }
          },
          "required": ["format"]
        }
      },

      // ======================== Video Recording ========================
      {
        "name": "video_start",
        "description": "Start screen recording on simulator/emulator.",
        "inputSchema": {
          "type": "object",
          "properties": {
            "device": {"type": "string", "description": "Device identifier"},
            "path": {"type": "string", "description": "Output file path"}
          }
        }
      },
      {
        "name": "video_stop",
        "description": "Stop screen recording and return the video file path.",
        "inputSchema": {"type": "object", "properties": {}}
      },

      // ======================== AI Visual Verification ========================
      {
        "name": "visual_verify",
        "description":
            """Take a screenshot AND text snapshot for AI visual verification.

Returns both a screenshot file and structured text snapshot so the calling AI can verify
the UI matches the expected description. Optionally checks for specific elements.

[USE WHEN]
• Verifying UI looks correct after a series of actions
• Checking that expected elements are present on screen
• Visual QA of a screen against a description

[RETURNS]
Combined result with screenshot path, text snapshot, element matching results, and a hint
for the AI to compare against the provided description.""",
        "inputSchema": {
          "type": "object",
          "properties": {
            "description": {
              "type": "string",
              "description":
                  "What the UI should look like (e.g., 'login form with email and password fields')"
            },
            "check_elements": {
              "type": "array",
              "items": {"type": "string"},
              "description":
                  "Specific elements that should be visible (matched against snapshot refs and text)"
            },
            "quality": {
              "type": "number",
              "description": "Screenshot quality 0-1 (default 0.5)"
            }
          }
        },
      },
      {
        "name": "visual_diff",
        "description": """Compare current screen against a baseline screenshot.

Takes a new screenshot and returns both the current and baseline paths so the calling AI
can visually compare them. Also returns text snapshots for structural comparison.

[USE WHEN]
• Visual regression testing
• Comparing before/after states
• Verifying no unintended UI changes""",
        "inputSchema": {
          "type": "object",
          "properties": {
            "baseline_path": {
              "type": "string",
              "description": "Path to baseline screenshot file"
            },
            "description": {
              "type": "string",
              "description": "What to focus on when comparing (optional)"
            },
            "quality": {
              "type": "number",
              "description": "Screenshot quality 0-1 (default 0.5)"
            }
          },
          "required": ["baseline_path"]
        },
      },

      // ======================== Parallel Multi-Device ========================
      {
        "name": "parallel_snapshot",
        "description": "Take snapshots from multiple sessions in parallel.",
        "inputSchema": {
          "type": "object",
          "properties": {
            "session_ids": {
              "type": "array",
              "items": {"type": "string"},
              "description": "Session IDs (default: all)"
            }
          }
        }
      },
      {
        "name": "parallel_tap",
        "description": "Execute tap on multiple sessions in parallel.",
        "inputSchema": {
          "type": "object",
          "properties": {
            "ref": {"type": "string", "description": "Element ref to tap"},
            "key": {"type": "string", "description": "Element key to tap"},
            "text": {"type": "string", "description": "Element text to tap"},
            "session_ids": {
              "type": "array",
              "items": {"type": "string"},
              "description": "Session IDs (default: all)"
            }
          }
        }
      },

      // ======================== Cross-Platform Test ========================
      {
        "name": "multi_platform_test",
        "description":
            "Run the same test steps across all connected platforms simultaneously. Great for cross-platform verification.",
        "inputSchema": {
          "type": "object",
          "properties": {
            "actions": {
              "type": "array",
              "items": {
                "type": "object",
                "properties": {
                  "tool": {"type": "string"},
                  "args": {"type": "object"}
                }
              },
              "description":
                  "Sequence of tool calls to execute on each platform"
            },
            "session_ids": {
              "type": "array",
              "items": {"type": "string"},
              "description":
                  "Specific sessions to test (default: all connected)"
            },
            "stop_on_failure": {
              "type": "boolean",
              "description":
                  "Stop all platforms on first failure (default: false)"
            }
          },
          "required": ["actions"]
        }
      },
      {
        "name": "compare_platforms",
        "description":
            "Take snapshots from all connected platforms and compare element presence. Identifies cross-platform inconsistencies.",
        "inputSchema": {
          "type": "object",
          "properties": {
            "session_ids": {
              "type": "array",
              "items": {"type": "string"},
              "description":
                  "Specific sessions to compare (default: all connected)"
            }
          }
        }
      },

      // ======================== Plugins & Reports ========================
      {
        "name": "list_plugins",
        "description":
            "List all loaded custom plugin tools with their descriptions.",
        "inputSchema": {"type": "object", "properties": {}}
      },
      {
        "name": "generate_report",
        "description":
            "Generate a test report from recorded test steps and assertions. Supports HTML, JSON, and Markdown formats.",
        "inputSchema": {
          "type": "object",
          "properties": {
            "format": {
              "type": "string",
              "enum": ["html", "json", "markdown"],
              "description": "Report format (default: html)"
            },
            "title": {"type": "string", "description": "Report title"},
            "output_path": {
              "type": "string",
              "description": "Where to save the report file"
            },
            "include_screenshots": {
              "type": "boolean",
              "description": "Embed screenshots in report (default: true)"
            }
          }
        }
      },
      // ======================== Diff Testing ========================
      {
        "name": "diff_baseline_create",
        "description":
            "Create a baseline snapshot of current app state (all pages) for future comparison. Crawls pages via CDP and saves screenshots + element snapshots.",
        "inputSchema": {
          "type": "object",
          "properties": {
            "path": {
              "type": "string",
              "description":
                  "Directory to save baseline (default: ./.flutter-skill-baseline)"
            },
            "depth": {
              "type": "integer",
              "description": "Max crawl depth (default: 2)"
            }
          }
        }
      },
      {
        "name": "diff_compare",
        "description":
            "Compare current app state against a saved baseline — detect UI changes, missing elements, new pages. Returns per-page diff results.",
        "inputSchema": {
          "type": "object",
          "properties": {
            "baseline_path": {
              "type": "string",
              "description":
                  "Path to baseline directory (default: ./.flutter-skill-baseline)"
            },
            "threshold": {
              "type": "number",
              "description":
                  "Pixel diff threshold 0-1 (default: 0.05). Changes below this are ignored."
            }
          }
        }
      },
      {
        "name": "diff_pages",
        "description":
            "Compare two specific pages or URLs side by side — element counts, visual diff, text content.",
        "inputSchema": {
          "type": "object",
          "properties": {
            "url_a": {"type": "string", "description": "First URL"},
            "url_b": {"type": "string", "description": "Second URL"}
          },
          "required": ["url_a", "url_b"]
        }
      },

      // ======================== Bug Report ========================
      {
        "name": "create_bug_report",
        "description":
            "Generate a structured bug report from current state — screenshot, repro steps (auto-collected from recording), environment info, console errors, severity classification.",
        "inputSchema": {
          "type": "object",
          "properties": {
            "title": {"type": "string", "description": "Bug title"},
            "steps": {
              "type": "array",
              "items": {"type": "string"},
              "description":
                  "Reproduction steps (auto-collected from recording if omitted)"
            },
            "severity": {
              "type": "string",
              "enum": ["critical", "high", "medium", "low"],
              "description": "Bug severity (default: medium)"
            },
            "format": {
              "type": "string",
              "enum": ["markdown", "github_issue", "jira"],
              "description": "Output format (default: markdown)"
            },
            "save_path": {
              "type": "string",
              "description": "Optional file path to save the report"
            }
          }
        }
      },
      {
        "name": "create_github_issue",
        "description":
            "Create a GitHub issue with auto-generated bug report (requires gh CLI authenticated). Includes screenshot, environment info, and repro steps.",
        "inputSchema": {
          "type": "object",
          "properties": {
            "repo": {
              "type": "string",
              "description": "GitHub repository (owner/repo)"
            },
            "title": {"type": "string", "description": "Issue title"},
            "severity": {
              "type": "string",
              "enum": ["critical", "high", "medium", "low"],
              "description": "Bug severity"
            },
            "steps": {
              "type": "array",
              "items": {"type": "string"},
              "description": "Reproduction steps"
            },
            "labels": {
              "type": "array",
              "items": {"type": "string"},
              "description": "Issue labels (default: [\"bug\"])"
            }
          },
          "required": ["repo", "title"]
        }
      },

      // ======================== Test Fixtures ========================
      {
        "name": "fixture_load",
        "description":
            "Load test fixture — seed app with test data via API call, localStorage injection, cookies, or JSON file.",
        "inputSchema": {
          "type": "object",
          "properties": {
            "type": {
              "type": "string",
              "enum": ["api", "localStorage", "cookies", "file"],
              "description": "Injection method (default: localStorage)"
            },
            "url": {
              "type": "string",
              "description":
                  "API endpoint for seeding (POST) — used with type=api"
            },
            "data": {
              "type": "object",
              "description": "Data to inject as key-value pairs"
            },
            "file_path": {
              "type": "string",
              "description": "JSON file with fixture data"
            }
          }
        }
      },
      {
        "name": "fixture_reset",
        "description":
            "Reset app to clean state — clear localStorage, sessionStorage, cookies, cache, and optionally call a reset API endpoint.",
        "inputSchema": {
          "type": "object",
          "properties": {
            "reset_api_url": {
              "type": "string",
              "description":
                  "Optional API endpoint to call for server-side reset (POST)"
            },
            "clear_storage": {
              "type": "boolean",
              "description":
                  "Clear localStorage and sessionStorage (default: true)"
            },
            "clear_cookies": {
              "type": "boolean",
              "description": "Clear all cookies (default: true)"
            },
            "clear_cache": {
              "type": "boolean",
              "description": "Clear browser cache (default: true)"
            }
          }
        }
      },
      {
        "name": "fixture_switch_user",
        "description":
            "Switch user role/account for multi-role testing. Navigates to login page, fills credentials, and submits. Or injects auth token directly.",
        "inputSchema": {
          "type": "object",
          "properties": {
            "role": {
              "type": "string",
              "description": "Role name: admin, user, guest, or custom"
            },
            "credentials": {
              "type": "object",
              "description":
                  "Login credentials: {username, password} or {token}"
            },
            "login_url": {"type": "string", "description": "URL of login page"},
            "username_field": {
              "type": "string",
              "description":
                  "Name/type of username field to match (default: email)"
            },
            "password_field": {
              "type": "string",
              "description": "Name of password field (default: password)"
            },
            "submit_button": {
              "type": "string",
              "description": "Text of submit button (default: Sign In)"
            }
          }
        }
      },
      {
        "name": "fixture_switch_env",
        "description":
            "Switch test environment (dev/staging/prod) — sets env in localStorage, injects env vars, and navigates to new base URL.",
        "inputSchema": {
          "type": "object",
          "properties": {
            "env": {
              "type": "string",
              "enum": ["dev", "staging", "prod", "custom"],
              "description": "Target environment"
            },
            "base_url": {
              "type": "string",
              "description":
                  "Base URL for the environment (navigates there if provided)"
            },
            "env_vars": {
              "type": "object",
              "description":
                  "Environment-specific variables to inject into localStorage"
            }
          },
          "required": ["env"]
        }
      },
      // ======================== AI Explore ========================
      {
        "name": "page_summary",
        "description":
            "Get compact semantic page summary via Chrome Accessibility Tree — nav items, forms, buttons, headings, landmarks, features. ~200 tokens vs ~4000 for screenshots. Use for AI-driven autonomous testing.",
        "inputSchema": {
          "type": "object",
          "properties": {
            "include_ax_tree": {
              "type": "boolean",
              "default": false,
              "description": "Include raw accessibility tree nodes"
            },
            "max_elements": {
              "type": "integer",
              "default": 50,
              "description": "Max AX tree nodes to return"
            }
          }
        }
      },
      {
        "name": "explore_actions",
        "description":
            "Execute a batch of UI actions (tap, fill, scroll, back, navigate, press, select). Send multiple actions at once to reduce LLM round-trips. Returns results + console errors.",
        "inputSchema": {
          "type": "object",
          "properties": {
            "actions": {
              "type": "array",
              "description": "Actions to execute in order",
              "items": {
                "type": "object",
                "properties": {
                  "type": {
                    "type": "string",
                    "enum": [
                      "tap",
                      "fill",
                      "scroll",
                      "back",
                      "navigate",
                      "press",
                      "select"
                    ]
                  },
                  "target": {
                    "type": "string",
                    "description":
                        "Element ref (e.g. 'button:Login', 'input:Username', 'link:Home')"
                  },
                  "value": {
                    "type": "string",
                    "description": "Value for fill/select actions"
                  }
                },
                "required": ["type", "target"]
              }
            }
          },
          "required": ["actions"]
        }
      },
      {
        "name": "boundary_test",
        "description":
            "Run boundary/security tests on an input field — XSS (6 payloads), SQL injection (2), long strings (256/5000 chars), emoji, null bytes, special chars. Detects XSS reflection in DOM.",
        "inputSchema": {
          "type": "object",
          "properties": {
            "target": {
              "type": "string",
              "description": "Input field ref (e.g. 'input:Username')"
            },
            "payloads": {
              "type": "array",
              "items": {"type": "string"},
              "description":
                  "Custom payloads (uses built-in 13-payload set if omitted)"
            }
          },
          "required": ["target"]
        }
      },
      {
        "name": "explore_report",
        "description":
            "Generate styled HTML explore report from collected step data.",
        "inputSchema": {
          "type": "object",
          "properties": {
            "steps": {
              "type": "array",
              "description":
                  "Array of step objects: {url, actions, bugs, a11y_issues}",
              "items": {"type": "object"}
            },
            "title": {"type": "string", "default": "Explore Report"},
            "output": {"type": "string", "default": "./explore-report.html"}
          },
          "required": ["steps"]
        }
      },
    ];
  }

  /// Get the filtered tools list based on current connection state.
  static List<Map<String, dynamic>> getFilteredTools({
    required bool hasCdp,
    required bool hasBridge,
    required bool hasFlutter,
    required bool hasConnection,
    List<Map<String, dynamic>> pluginTools = const [],
  }) {
    final allTools = getAllToolDefinitions();

    // Append plugin-defined tools
    for (final plugin in pluginTools) {
      allTools.add({
        "name": plugin['name'],
        "description": plugin['description'] ?? 'Custom plugin tool',
        "inputSchema": {"type": "object", "properties": {}},
      });
    }

    // Before any connection: only show connection/discovery tools.
    // This keeps the total under the Gemini 128-function-declaration limit
    // when flutter-skill is used alongside other MCP servers (e.g. Dart MCP).
    // All tools become visible after connect_app / connect_cdp / etc.
    if (!hasConnection) {
      return allTools
          .where((t) => connectionOnlyTools.contains(t['name'] as String))
          .toList();
    }

    return allTools.where((tool) {
      final name = tool['name'] as String;
      if (hasCdp) {
        if (flutterOnlyTools.contains(name)) return false;
        if (mobileOnlyTools.contains(name)) return false;
      } else if (hasBridge) {
        if (cdpOnlyTools.contains(name)) return false;
        if (flutterOnlyTools.contains(name)) return false;
      } else if (hasFlutter) {
        if (cdpOnlyTools.contains(name)) return false;
      }
      return true;
    }).toList();
  }
}
