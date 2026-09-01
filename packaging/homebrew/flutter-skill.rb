class FlutterSkill < Formula
  desc "MCP Server for Flutter app automation - AI Agent control for Flutter apps"
  homepage "https://github.com/ai-dashboad/flutter-skill"
  version "0.9.37"
  license "MIT"

  # Platform-specific native binaries
  # Intel macOS (x64) has no native binary: GitHub retired the macos-13 hosted
  # runner used to build it, and current x64 runner images require a paid
  # large-runner tier. Intel Mac users should install via npm/pub.dev instead,
  # which fall back to the Dart runtime automatically.
  on_macos do
    on_arm do
      url "https://github.com/ai-dashboad/flutter-skill/releases/download/v0.9.37/flutter-skill-macos-arm64"
      sha256 "PLACEHOLDER_ARM64_SHA256"
    end
  end

  on_linux do
    url "https://github.com/ai-dashboad/flutter-skill/releases/download/v0.9.37/flutter-skill-linux-x64"
    sha256 "PLACEHOLDER_LINUX_SHA256"
  end

  def install
    # Install the native binary directly
    bin.install Dir["flutter-skill-*"].first => "flutter-skill"
  end

  def caveats
    <<~EOS
      flutter-skill is now installed as a native binary for instant startup!

      MCP Configuration (add to ~/.claude/settings.json):
        {
          "mcpServers": {
            "flutter-skill": {
              "command": "flutter-skill",
              "args": ["server"]
            }
          }
        }

      CLI Usage:
        flutter-skill launch /path/to/flutter/project
        flutter-skill inspect
        flutter-skill act tap "button_key"

      Note: Your Flutter app needs to include the flutter_skill package.
      Add to pubspec.yaml:
        dependencies:
          flutter_skill: ^0.9.37
    EOS
  end

  test do
    assert_match "flutter-skill", shell_output("#{bin}/flutter-skill server --help 2>&1", 1)
  end
end
