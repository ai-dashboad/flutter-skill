# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Flutter Skill is a bridge that connects AI Agents to running Flutter applications via the Dart VM Service Protocol. It enables agents to inspect UI structure, perform actions (tap, scroll, enter text), and verify visual changes.

## Common Commands

```bash
# Activate the CLI globally (from this repo)
dart pub global activate --source path .

# Run the CLI directly without global activation
dart run bin/flutter_skill.dart <command>

# Launch a Flutter app with auto-setup (adds dependency + patches main.dart)
flutter_skill launch /path/to/flutter_project

# Inspect interactive widgets in running app
flutter_skill inspect

# Perform actions
flutter_skill act tap "button_key"
flutter_skill act enter_text "field_key" "text value"

# Run integration tests (uses mock Flutter app)
dart run test/integration_test.dart
```

## Architecture

The codebase has two main parts:

**1. Target App Library** (`lib/flutter_skill.dart`)
- `FlutterSkillBinding` - Registers VM Service extensions in the Flutter app
- Extensions: `ext.flutter.flutter_skill.interactive`, `.tap`, `.enterText`, `.scroll`
- Target apps call `FlutterSkillBinding.ensureInitialized()` in main.dart

**2. CLI/Server Tools** (`lib/src/`)
- `lib/src/drivers/` - Framework-specific app drivers
  - `app_driver.dart` - Abstract `AppDriver` interface (connect, tap, screenshot, etc.)
  - `flutter_driver.dart` - `FlutterSkillClient implements AppDriver` — VM Service client
  - `native_driver.dart` - Native OS-level interaction (macOS Accessibility API, adb)
  - `drivers.dart` - Barrel export
- `lib/src/discovery/` - VM Service auto-discovery
  - `unified_discovery.dart` - Smart multi-strategy discovery orchestrator
  - `process_based_discovery.dart` - Discovers apps from running Flutter processes
  - `dtd_service_discovery.dart` - DTD-based discovery
  - `quick_port_check.dart` - Parallel port scanning
  - `discovery.dart` - Barrel export
- `lib/src/cli/` - CLI command implementations (launch, inspect, act, server, setup)
- `lib/src/diagnostics/` - Error reporting
- MCP Server mode (`cli/server.dart`) - JSON-RPC interface for IDEs like Cursor

**Entry Points:**
- `bin/flutter_skill.dart` - Main CLI entry point, routes to subcommands
- `bin/server.dart` - Standalone MCP server entry point

**Connection Flow:**
1. `launch` runs `flutter run`, captures VM Service URI from stdout
2. URI saved to `.flutter_skill_uri` for subsequent commands
3. `FlutterSkillClient` connects via WebSocket, finds main isolate
4. Commands invoke registered extensions on the running app

**Backward Compatibility:**
- `lib/src/flutter_skill_client.dart` is a re-export shim pointing to `drivers/flutter_driver.dart`

## Key Files

- `lib/flutter_skill.dart` - The binding that target apps import
- `lib/src/drivers/app_driver.dart` - Abstract driver interface for multi-framework support
- `lib/src/drivers/flutter_driver.dart` - VM Service client wrapper (`FlutterSkillClient`)
- `lib/src/discovery/unified_discovery.dart` - Smart VM Service discovery
- `lib/src/cli/setup.dart` - Auto-patches pubspec.yaml and main.dart
- `test/bin/flutter` - Mock flutter CLI for integration tests

## Release Process

### Quick Release

**CRITICAL: ALWAYS use the release script. NEVER bump versions or commit/tag/push manually.**

When the user asks to release a new version, run:

```bash
./scripts/release.sh X.Y.Z "Brief description"
```

Example:
```bash
./scripts/release.sh 0.9.9 "C++ desktop automation SDK"
```

The script handles everything: version bumps across all files, CHANGELOG entry, git commit, tag, and push — which triggers GitHub Actions to auto-publish to pub.dev, npm, VSCode, JetBrains, Homebrew, Scoop, MCP Registry, and GitHub Release.

**Never do any of these steps manually** (no `sed` version bumps, no `git tag`, no `git push --tags`, no `gh release create`) unless the script explicitly fails and you explain why to the user first.

### Manual Release Steps

1. **Prepare CHANGELOG**
   - If there's a `RELEASE_NOTES_vX.Y.Z.md`, extract key points
   - Add concise entry to `CHANGELOG.md` (at the top)
   - Follow existing format: version, description, features, docs

2. **Update Version Numbers**
   - `pubspec.yaml` - version: X.Y.Z
   - `lib/src/cli/server.dart` - const String _currentVersion = 'X.Y.Z'
   - `packaging/npm/package.json` - "version": "X.Y.Z"
   - `vscode-extension/package.json` - "version": "X.Y.Z"
   - `intellij-plugin/build.gradle.kts` - version = "X.Y.Z"
   - `intellij-plugin/src/main/resources/META-INF/plugin.xml` - <version>X.Y.Z</version>
   - `README.md` - flutter_skill: ^X.Y.Z

3. **Commit and Tag**

   First confirm the release will be cut from `origin/main` — the tag is what
   triggers the release workflow, so a tag that is not on `main` publishes from a
   commit nobody can see. This is how v0.9.24 and v0.9.36 shipped the wrong tree.

   ```bash
   git fetch origin main
   git rev-parse main origin/main   # must print the same SHA twice

   git add -A
   git commit -m "chore: Release vX.Y.Z\n\n<description>"
   git tag vX.Y.Z

   # --atomic, never `--tags`: without it a rejected branch update still lets
   # the tag through, and CI then publishes from an orphaned commit.
   git push --atomic origin main refs/tags/vX.Y.Z
   ```

4. **Verify**
   - Check GitHub Actions: https://github.com/ai-dashboad/flutter-skill/actions
   - Verify auto-publish to: pub.dev, npm, VSCode, JetBrains, Homebrew

### Version Numbering

Follow [Semantic Versioning](https://semver.org/):
- `MAJOR.MINOR.PATCH` (e.g., 0.3.1)
- **PATCH** (0.3.0 → 0.3.1): Bug fixes, optimizations, small improvements
- **MINOR** (0.3.0 → 0.4.0): New features, backward-compatible changes
- **MAJOR** (0.x.x → 1.0.0): Breaking changes, major refactor

### Complete Documentation

See `RELEASE_PROCESS.md` for:
- Detailed manual steps
- Troubleshooting
- Special release scenarios
- Post-release checklist

## Tool Selection Rules

### Flutter Testing - ALWAYS Use flutter-skill

**CRITICAL**: For ANY Flutter app testing, ALWAYS use flutter-skill MCP tools, NEVER use Dart MCP.

#### Decision Matrix

| User Request | Tool to Use | DO NOT USE |
|--------------|-------------|------------|
| Test Flutter app | `flutter-skill` | ❌ Dart MCP |
| Launch app | `launch_app` with `--vm-service-port=50000` | ❌ `mcp__dart__launch_app` |
| Get logs | `get_logs` | ❌ `mcp__dart__get_app_logs` |
| Hot reload | `hot_reload` | ❌ `mcp__dart__hot_reload` |
| Inspect UI | `inspect` | ❌ `mcp__dart__get_widget_tree` |
| Tap/swipe/screenshot | `tap`, `swipe`, `screenshot` | ❌ Dart MCP (lacks these) |

#### Why flutter-skill is Superior

- ✅ **Complete UI automation**: tap, swipe, screenshot, input
- ✅ **VM Service protocol**: Full access to app internals
- ✅ **All testing needs**: Lifecycle + UI + debugging in ONE tool
- ✅ **100% capability**: vs Dart MCP's ~40%

**Dart MCP limitations**:
- ❌ No tap/click
- ❌ No swipe/scroll
- ❌ No screenshot
- ❌ No text input
- ❌ Read-only inspection
- ❌ Only ~40% of testing needs

#### Launch Configuration

**Flutter 3.x Auto-Configuration:**

The `launch_app` tool **automatically adds** `--vm-service-port=50000` for Flutter 3.x compatibility.
You don't need to specify it manually!

```bash
# ✅ Simplest usage (auto-configured)
launch_app(
  project_path: ".",
  device_id: "iPhone 16 Pro"
)
# Automatically becomes: flutter run -d "iPhone 16 Pro" --vm-service-port=50000

# ✅ With custom VM Service port (if needed)
launch_app(
  project_path: ".",
  device_id: "iPhone 16 Pro",
  extra_args: ["--vm-service-port=8888"]  # Custom port
)

# ❌ Wrong - Don't use Dart MCP for Flutter testing
mcp__dart__launch_app(...)  # ❌ Don't use this
```

#### Exception Handling

**Note:** Since v0.3.2+, `--vm-service-port=50000` is **auto-added** by default.

If you still see "Found DTD URI but no VM Service URI" error (rare):
1. ✅ Check if the app is using a custom Flutter version
2. ✅ Verify the Flutter output logs for any VM Service errors
3. ✅ Try specifying a custom port: `extra_args: ["--vm-service-port=8888"]`
4. ❌ DO NOT switch to Dart MCP for Flutter testing

The error should be extremely rare now that auto-configuration is enabled.

---

## Project Rules

- Do not include "Co-Authored-By: Claude" in commit messages
- Always update CHANGELOG.md when releasing
- Keep release notes concise but informative
- Test on all platforms before major releases
- **CRITICAL**: For Flutter testing, ALWAYS use flutter-skill, NEVER Dart MCP

## Language Requirements

**IMPORTANT: All documentation and code comments MUST be in English.**

### What must be in English:
- All code comments (inline comments, doc comments, TODO comments)
- All documentation files (README.md, CHANGELOG.md, etc.)
- All error messages and log output in code
- All variable names, function names, class names
- All commit messages
- All PR descriptions and issue comments

### Files that need translation (currently contain Chinese):
- `lib/src/discovery/dtd_service_discovery.dart` - Chinese comments
- `lib/src/cli/server.dart` - Chinese in tool descriptions
- `test/flutter_skill_complete_test.dart` - Chinese test output

### When writing new code:
- Write all comments in English
- Use English for all user-facing strings
- Keep consistent terminology with existing English documentation
