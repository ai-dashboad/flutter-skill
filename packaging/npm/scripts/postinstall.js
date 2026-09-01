#!/usr/bin/env node

const https = require('https');
const fs = require('fs');
const path = require('path');
const os = require('os');

const packageJson = require('../package.json');
const VERSION = packageJson.version;

const cacheDir = path.join(os.homedir(), '.flutter-skill');
const binDir = path.join(cacheDir, 'bin');

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

function downloadBinary(url, destPath) {
  return new Promise((resolve, reject) => {
    fs.mkdirSync(path.dirname(destPath), { recursive: true });

    const file = fs.createWriteStream(destPath);

    const request = (url) => {
      https.get(url, (response) => {
        if (response.statusCode === 302 || response.statusCode === 301) {
          request(response.headers.location);
          return;
        }

        if (response.statusCode !== 200) {
          // createWriteStream has already created an empty file. Leaving it
          // behind makes every later install believe the binary is present.
          file.close(() => fs.unlink(destPath, () => {}));
          reject(new Error(`HTTP ${response.statusCode}`));
          return;
        }

        const totalBytes = parseInt(response.headers['content-length'], 10);
        let downloadedBytes = 0;

        response.on('data', (chunk) => {
          downloadedBytes += chunk.length;
          if (totalBytes) {
            const percent = Math.round((downloadedBytes / totalBytes) * 100);
            process.stdout.write(`\r[flutter-skill] Downloading native binary... ${percent}%`);
          }
        });

        response.pipe(file);
        file.on('finish', () => {
          file.close();
          try {
            fs.chmodSync(destPath, 0o755);
          } catch (chmodErr) {
            // chmod failed — reject so the caller can log a warning instead
            // of leaving a non-executable file behind silently.
            reject(new Error(`Downloaded binary but could not set execute permission: ${chmodErr.message}`));
            return;
          }
          console.log('\n[flutter-skill] Native binary installed successfully!');
          resolve(destPath);
        });
      }).on('error', (err) => {
        file.close(() => fs.unlink(destPath, () => {}));
        reject(err);
      });
    };

    request(url);
  });
}

async function main() {
  const binaryName = getBinaryName();
  if (!binaryName) {
    console.log('[flutter-skill] No native binary available for this platform, using Dart runtime');
    return;
  }

  const localPath = path.join(binDir, `${binaryName}-v${VERSION}`);

  // A zero-byte file is the residue of an interrupted or 404'd download, not an
  // installed binary. Treat it as absent so the download is retried.
  if (fs.existsSync(localPath) && fs.statSync(localPath).size > 0) {
    // Re-apply execute permission in case a previous install left the binary
    // without +x (e.g. chmod failed silently inside a restricted npm sandbox).
    try { fs.chmodSync(localPath, 0o755); } catch (_) {}
    console.log('[flutter-skill] Native binary already installed');
    return;
  }

  const downloadUrl = `https://github.com/ai-dashboad/flutter-skill/releases/download/v${VERSION}/${binaryName}`;

  console.log(`[flutter-skill] Installing native binary for faster startup...`);

  try {
    await downloadBinary(downloadUrl, localPath);
  } catch (error) {
    console.log(`[flutter-skill] Could not download native binary (${error.message}), will use Dart runtime`);
    console.log('[flutter-skill] This is normal for new releases, Dart fallback works fine');
  }
}

// Install tool priority rules for Claude Code
function installToolPriorityRules() {
  const homeDir = os.homedir();
  const promptsDir = path.join(homeDir, '.claude', 'prompts');
  const targetFile = path.join(promptsDir, 'flutter-tool-priority.md');

  if (fs.existsSync(targetFile)) {
    return Promise.resolve(); // Already installed
  }

  // Download from GitHub
  const url = 'https://raw.githubusercontent.com/ai-dashboad/flutter-skill/main/docs/prompts/tool-priority.md';

  return new Promise((resolve) => {
    fs.mkdirSync(promptsDir, { recursive: true });
    const file = fs.createWriteStream(targetFile);

    const request = (reqUrl) => {
      https.get(reqUrl, (response) => {
        if (response.statusCode === 302 || response.statusCode === 301) {
          request(response.headers.location);
          return;
        }
        if (response.statusCode !== 200) {
          resolve(); // Silent fail
          return;
        }
        response.pipe(file);
        file.on('finish', () => {
          file.close();
          console.log('[flutter-skill] Tool priority rules installed for Claude Code');
          resolve();
        });
      }).on('error', () => resolve());
    };

    request(url);
  });
}

main()
  .then(() => installToolPriorityRules())
  .catch(() => {
    // Silent fail - Dart fallback will work
    installToolPriorityRules().catch(() => {});
  });
