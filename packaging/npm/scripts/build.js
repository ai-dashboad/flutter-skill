#!/usr/bin/env node

// Regenerates the vendored Dart sources under packaging/npm/dart/.
//
// The npm wrapper falls back to running the server from Dart source whenever a
// native binary is unavailable, so this tree must track lib/ exactly. It is
// wired to the `prepack` lifecycle script, which npm runs before both
// `npm pack` and `npm publish` — do not publish without it.

const fs = require('fs');
const path = require('path');

const rootDir = path.join(__dirname, '..', '..', '..');
const npmDir = path.join(__dirname, '..');
const dartDir = path.join(npmDir, 'dart');

// Whole directories are mirrored rather than an explicit file list: an
// enumerated list silently stops copying newly added files, which is how the
// vendored tree drifted from v0.9.36 source back to v0.9.1.
const treesToCopy = ['lib'];
const filesToCopy = ['bin/server.dart', 'pubspec.yaml'];

// Sanity anchors — files whose absence means the layout moved and this script
// needs updating. Failing here aborts `npm publish` instead of shipping a
// broken or outdated fallback.
const requiredFiles = [
  'lib/flutter_skill.dart',
  'lib/src/cli/server.dart',
  'lib/src/drivers/flutter_driver.dart',
  'bin/server.dart',
  'pubspec.yaml',
];

function fail(message) {
  console.error(`\n[build] ERROR: ${message}`);
  process.exit(1);
}

function mkdirp(dir) {
  fs.mkdirSync(dir, { recursive: true });
}

function copyTree(srcDir, destDir) {
  let count = 0;
  for (const entry of fs.readdirSync(srcDir, { withFileTypes: true })) {
    const src = path.join(srcDir, entry.name);
    const dest = path.join(destDir, entry.name);
    if (entry.isDirectory()) {
      count += copyTree(src, dest);
    } else if (entry.isFile()) {
      mkdirp(path.dirname(dest));
      fs.copyFileSync(src, dest);
      count++;
    }
  }
  return count;
}

console.log('Building npm package...\n');

for (const file of requiredFiles) {
  if (!fs.existsSync(path.join(rootDir, file))) {
    fail(`required source file is missing: ${file}`);
  }
}

// Start from a clean tree so files deleted upstream do not linger here.
fs.rmSync(dartDir, { recursive: true, force: true });
mkdirp(dartDir);

let copied = 0;
for (const tree of treesToCopy) {
  const src = path.join(rootDir, tree);
  if (!fs.existsSync(src)) fail(`source directory is missing: ${tree}`);
  const n = copyTree(src, path.join(dartDir, tree));
  console.log(`Copied ${tree}/ (${n} files)`);
  copied += n;
}

for (const file of filesToCopy) {
  const src = path.join(rootDir, file);
  if (!fs.existsSync(src)) fail(`source file is missing: ${file}`);
  const dest = path.join(dartDir, file);
  mkdirp(path.dirname(dest));
  fs.copyFileSync(src, dest);
  console.log(`Copied ${file}`);
  copied++;
}

// The vendored copy is never published to pub.dev, and its dev dependencies
// would only slow down the `pub get` the wrapper runs on first launch.
const pubspecPath = path.join(dartDir, 'pubspec.yaml');
let pubspec = fs.readFileSync(pubspecPath, 'utf8');
pubspec = pubspec.replace(
  /^#?\s*publish_to:.*$/m,
  "publish_to: 'none' # vendored copy — never published to pub.dev"
);
if (!/^publish_to:/m.test(pubspec)) {
  pubspec = pubspec.replace(
    /^(version:.*)$/m,
    "$1\npublish_to: 'none' # vendored copy — never published to pub.dev"
  );
}
pubspec = pubspec.replace(/\n*^dev_dependencies:\n(?:[ \t].*\n|\n(?=[ \t]))*/m, '\n');
fs.writeFileSync(pubspecPath, pubspec.trimEnd() + '\n');

// bin/server.dart resolves the server through `package:<name>/...`, so a
// package rename upstream would leave the fallback unable to compile.
const packageName = (pubspec.match(/^name:\s*(\S+)/m) || [])[1];
const entrypoint = fs.readFileSync(path.join(dartDir, 'bin', 'server.dart'), 'utf8');
if (!packageName) fail('could not read the package name from pubspec.yaml');
if (!entrypoint.includes(`package:${packageName}/`)) {
  fail(
    `bin/server.dart does not import 'package:${packageName}/...' — ` +
      'the vendored entrypoint and pubspec name disagree, so the Dart ' +
      'fallback would not compile'
  );
}

// Keep the npm version in lockstep with the Dart package version; the release
// workflow refuses to publish when package.json and the git tag disagree.
const packageJsonPath = path.join(npmDir, 'package.json');
const version = (pubspec.match(/^version:\s*(\S+)/m) || [])[1];
if (!version) fail('could not read the version from pubspec.yaml');
const packageJson = JSON.parse(fs.readFileSync(packageJsonPath, 'utf8'));
if (packageJson.version !== version) {
  packageJson.version = version;
  fs.writeFileSync(packageJsonPath, JSON.stringify(packageJson, null, 2) + '\n');
  console.log(`\nUpdated package.json version to ${version}`);
}

console.log(`\nBuild complete — ${copied} files vendored for ${packageName} ${version}.`);
