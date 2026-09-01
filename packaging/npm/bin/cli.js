#!/usr/bin/env node

const { spawn, execSync } = require('child_process');
const path = require('path');
const fs = require('fs');
const https = require('https');
const os = require('os');

// Package info
const packageJson = require('../package.json');
const VERSION = packageJson.version;

// Update check config
const CHECK_INTERVAL_HOURS = 24;
const UPDATE_CHECK_FILE = path.join(os.homedir(), '.flutter-skill', 'update-check.json');

// Paths
const cacheDir = path.join(os.homedir(), '.flutter-skill');
const binDir = path.join(cacheDir, 'bin');

// Get platform-specific binary name
function getBinaryName() {
  const platform = os.platform();
  const arch = os.arch();

  if (platform === 'darwin') {
    return arch === 'arm64' ? 'flutter-skill-macos-arm64' : 'flutter-skill-macos-x64';
  } else if (platform === 'linux') {
    return 'flutter-skill-linux-x64';
  } else if (platform === 'win32') {
    return 'flutter-skill-windows-x64.exe';
  }
  return null;
}

// Get the local binary path
function getLocalBinaryPath() {
  const binaryName = getBinaryName();
  if (!binaryName) return null;
  return path.join(binDir, `${binaryName}-v${VERSION}`);
}

// Download binary from GitHub releases
function downloadBinary(url, destPath) {
  return new Promise((resolve, reject) => {
    // Ensure directory exists
    fs.mkdirSync(path.dirname(destPath), { recursive: true });

    const file = fs.createWriteStream(destPath);

    const request = (url) => {
      https.get(url, (response) => {
        // Handle redirects
        if (response.statusCode === 302 || response.statusCode === 301) {
          request(response.headers.location);
          return;
        }

        if (response.statusCode !== 200) {
          reject(new Error(`Failed to download: ${response.statusCode}`));
          return;
        }

        response.pipe(file);
        file.on('finish', () => {
          file.close();
          // Make executable
          fs.chmodSync(destPath, 0o755);
          resolve(destPath);
        });
      }).on('error', (err) => {
        fs.unlink(destPath, () => {});
        reject(err);
      });
    };

    request(url);
  });
}

// Try to use native binary, fallback to Dart
async function main() {
  const binaryName = getBinaryName();
  const localBinaryPath = getLocalBinaryPath();

  // Try to use existing native binary
  if (localBinaryPath && fs.existsSync(localBinaryPath) && fs.statSync(localBinaryPath).size > 0) {
    // Always ensure the execute bit is set before spawning.
    // postinstall chmodSync can silently fail on some npm configurations
    // (e.g. restricted sandbox, npm run as root on certain macOS setups),
    // leaving the binary present but not executable (EACCES).
    try { fs.chmodSync(localBinaryPath, 0o755); } catch (_) {}
    runNativeBinary(localBinaryPath);
    return;
  }

  // Try to download native binary
  if (binaryName && localBinaryPath) {
    const downloadUrl = `https://github.com/ai-dashboad/flutter-skill/releases/download/v${VERSION}/${binaryName}`;

    try {
      // Download in background, don't block startup for first time
      // For now, just fall through to Dart
      // Future: implement async download with progress
      console.error(`[flutter-skill] Native binary not found, using Dart runtime`);
      console.error(`[flutter-skill] To install native binary for faster startup:`);
      console.error(`[flutter-skill]   curl -L ${downloadUrl} -o ${localBinaryPath} && chmod +x ${localBinaryPath}`);
    } catch (e) {
      // Ignore download errors, fall back to Dart
    }
  }

  // Fallback to Dart
  runWithDart();
}

// Run using native binary
function runNativeBinary(binaryPath) {
  const args = process.argv.slice(2);
  // Default to 'server' command if no args
  if (args.length === 0) {
    args.push('server');
  }

  // spawn() reports launch failures (ENOEXEC, EACCES, ENOENT, wrong-arch, ...)
  // inconsistently across platforms/Node versions: some surface synchronously
  // as a thrown exception from spawn() itself, others only asynchronously via
  // the 'error' event. Without handling both, the failure is uncaught and
  // crashes the process instead of ever reaching the Dart fallback.
  let server;
  try {
    server = spawn(binaryPath, args, {
      stdio: 'inherit'
    });
  } catch (err) {
    console.error(`[flutter-skill] Native binary failed to launch (${err.code || err.message}), falling back to Dart runtime`);
    runWithDart();
    return;
  }

  server.on('error', (err) => {
    console.error(`[flutter-skill] Native binary failed to launch (${err.code || err.message}), falling back to Dart runtime`);
    runWithDart();
  });

  server.on('close', (code) => {
    process.exit(code || 0);
  });

  process.on('SIGINT', () => server.kill('SIGINT'));
  process.on('SIGTERM', () => server.kill('SIGTERM'));
}

const isWindows = process.platform === 'win32';

// The Flutter and Dart entrypoints on Windows are `.bat` scripts, which
// CreateProcess cannot execute directly — spawn() fails with UNKNOWN or ENOENT
// unless it goes through a shell. A shell does no argument quoting for us, so
// anything containing whitespace has to be quoted by hand.
function quoteArg(value) {
  return isWindows && /[\s&|<>^()]/.test(value) ? `"${value}"` : value;
}

// Run using Dart
function runWithDart() {
  const dartDir = path.join(__dirname, '..', 'dart');
  const serverScript = path.join(dartDir, 'bin', 'server.dart');

  if (!fs.existsSync(serverScript)) {
    console.error('Error: Server script not found at:', serverScript);
    console.error('The npm package looks incomplete — try reinstalling flutter-skill.');
    process.exit(1);
  }

  // The vendored package depends on package:flutter, so `dart pub get` can
  // never resolve it ("Because flutter_skill requires the Flutter SDK, version
  // solving failed"). Checking only for Dart let that failure through and the
  // run then died with a confusing "Couldn't resolve the package
  // 'flutter_skill'" instead of naming the real prerequisite.
  if (!checkFlutter()) {
    console.error('Error: Flutter SDK not found.');
    console.error('flutter-skill runs on the Flutter SDK — the Dart SDK alone cannot');
    console.error('resolve its dependencies. Install Flutter and make sure it is on PATH:');
    console.error('  https://docs.flutter.dev/get-started/install');
    process.exit(1);
  }

  try {
    execSync('dart --version', { stdio: 'ignore' });
  } catch (e) {
    console.error('Error: `dart` was not found on PATH, but `flutter` was.');
    console.error('Add the Flutter SDK\'s bin directory to PATH so `dart` resolves too.');
    process.exit(1);
  }

  // A failure here used to be swallowed, leaving the run to fail later with an
  // unrelated-looking import error. Report it and stop.
  try {
    execSync('flutter pub get', {
      cwd: dartDir,
      stdio: ['ignore', 'pipe', 'pipe']
    });
  } catch (e) {
    console.error('[flutter-skill] `flutter pub get` failed in', dartDir);
    const details = ((e.stderr || '') + (e.stdout || '')).toString().trim();
    if (details) console.error(details);
    console.error('[flutter-skill] Cannot start without resolved dependencies.');
    process.exit(1);
  }

  // Start with Dart
  const args = process.argv.slice(2);
  if (args.length === 0) {
    args.push('server');
  }

  const dartArgs = ['run', serverScript, ...args].map(quoteArg);

  // Same launch-failure handling as the native path: spawn() reports failures
  // synchronously on some platforms and only via the 'error' event on others.
  // There is no further fallback beyond Dart, so both paths exit with a
  // diagnostic rather than crashing on an uncaught exception.
  let server;
  try {
    server = spawn('dart', dartArgs, {
      cwd: dartDir,
      stdio: 'inherit',
      shell: isWindows
    });
  } catch (err) {
    console.error(`[flutter-skill] Failed to start the Dart runtime (${err.code || err.message})`);
    process.exit(1);
  }

  server.on('error', (err) => {
    console.error(`[flutter-skill] Failed to start the Dart runtime (${err.code || err.message})`);
    process.exit(1);
  });

  server.on('close', (code) => {
    process.exit(code || 0);
  });

  process.on('SIGINT', () => server.kill('SIGINT'));
  process.on('SIGTERM', () => server.kill('SIGTERM'));
}

function checkFlutter() {
  try {
    execSync('flutter --version', { stdio: 'ignore' });
    return true;
  } catch (e) {
    return false;
  }
}

// Check for updates (non-blocking, runs in background)
function checkForUpdates() {
  // Only check periodically
  try {
    const checkDir = path.dirname(UPDATE_CHECK_FILE);
    if (!fs.existsSync(checkDir)) {
      fs.mkdirSync(checkDir, { recursive: true });
    }

    let lastCheck = 0;
    let skippedVersion = null;

    if (fs.existsSync(UPDATE_CHECK_FILE)) {
      try {
        const data = JSON.parse(fs.readFileSync(UPDATE_CHECK_FILE, 'utf-8'));
        lastCheck = data.lastCheck || 0;
        skippedVersion = data.skippedVersion;
      } catch {}
    }

    const now = Date.now();
    const hoursSinceLastCheck = (now - lastCheck) / (1000 * 60 * 60);

    if (hoursSinceLastCheck < CHECK_INTERVAL_HOURS) {
      return;
    }

    // Update last check time
    fs.writeFileSync(UPDATE_CHECK_FILE, JSON.stringify({
      lastCheck: now,
      skippedVersion
    }));

    // Check npm registry for latest version (async, non-blocking)
    https.get('https://registry.npmjs.org/flutter-skill', (res) => {
      let data = '';
      res.on('data', (chunk) => data += chunk);
      res.on('end', () => {
        try {
          const json = JSON.parse(data);
          const latestVersion = json['dist-tags'].latest;

          if (latestVersion && compareVersions(latestVersion, VERSION) > 0) {
            if (skippedVersion !== latestVersion) {
              console.error(`\n[flutter-skill] Update available: ${VERSION} → ${latestVersion}`);
              console.error(`[flutter-skill] Run: npm update -g flutter-skill\n`);
            }
          }
        } catch {}
      });
    }).on('error', () => {});
  } catch {}
}

function compareVersions(v1, v2) {
  const parts1 = v1.split('.').map(Number);
  const parts2 = v2.split('.').map(Number);

  for (let i = 0; i < Math.max(parts1.length, parts2.length); i++) {
    const p1 = parts1[i] || 0;
    const p2 = parts2[i] || 0;
    if (p1 > p2) return 1;
    if (p1 < p2) return -1;
  }
  return 0;
}

// Show tips when running interactively without arguments
function showTips() {
  const isInteractive = process.stdin.isTTY && process.stdout.isTTY;
  const args = process.argv.slice(2);

  if (!isInteractive || args.length > 0) {
    return false; // Not interactive or has args, don't show tips
  }

  console.log(`Flutter Skill v${VERSION} - AI Agent Bridge for Flutter Apps`);
  console.log('');
  console.log('Commands:');
  console.log('  server          Start MCP server (default when launched by IDE)');
  console.log('  launch          Launch and connect to a Flutter app');
  console.log('  inspect         Inspect interactive elements in running app');
  console.log('  act             Perform actions (tap, scroll, enter_text)');
  console.log('  doctor          Check installation and environment health');
  console.log('  setup           Install tool priority rules for Claude Code');
  console.log('  --version       Show version');
  console.log('');
  console.log('Quick Start:');
  console.log('  flutter-skill doctor              Check your environment is ready');
  console.log('  flutter-skill launch ./my_app      Launch and connect to your app');
  console.log('');
  console.log('What can AI agents do with Flutter Skill?');
  console.log('  - Launch your Flutter app and auto-connect');
  console.log('  - Inspect UI: find buttons, text fields, lists');
  console.log('  - Tap, swipe, scroll, and enter text');
  console.log('  - Take screenshots to verify visual changes');
  console.log('  - Read app logs and debug issues');
  console.log('  - Hot reload after code changes');
  console.log('');
  console.log('Example: Ask your AI agent:');
  console.log('  "Launch my Flutter app and tap the login button"');
  console.log('  "Take a screenshot and check if the list is showing"');
  console.log('  "Enter \'hello@test.com\' in the email field and submit"');
  console.log('');
  console.log('Docs: https://pub.dev/packages/flutter_skill');
  console.log('');
  return true;
}

// Handle --version / -v directly (fast, no binary needed)
const cliArgs = process.argv.slice(2);
if (cliArgs.includes('--version') || cliArgs.includes('-v')) {
  console.log(VERSION);
  process.exit(0);
}

// Show tips if interactive, otherwise run server
if (showTips()) {
  process.exit(0);
}

// Run update check in background (non-blocking)
checkForUpdates();

main().catch(console.error);
