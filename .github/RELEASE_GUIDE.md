# 🚀 Quick Release Guide

## TL;DR

```bash
# One-command release
./scripts/release.sh 0.3.2 "Bug fixes and improvements"

# Or tell Claude Code:
"Release version 0.3.2 with bug fixes"
```

---

## When to Release

### Patch Release (0.3.0 → 0.3.1)
- Bug fixes
- Performance improvements
- Documentation updates
- Minor optimizations

### Minor Release (0.3.0 → 0.4.0)
- New features
- New MCP tools
- Backward-compatible changes
- Significant improvements

### Major Release (0.x.x → 1.0.0)
- Breaking changes
- API redesign
- Major refactor

---

## Quick Manual Release

```bash
# 1. Update CHANGELOG.md (add new version at top)

# 2. Update all version numbers
# - pubspec.yaml
# - lib/src/cli/server.dart
# - npm/package.json
# - vscode-extension/package.json
# - intellij-plugin/build.gradle.kts
# - intellij-plugin/plugin.xml
# - README.md

# 3. Confirm the release is cut from origin/main.
# The tag triggers the release workflow, so a tag that is not on main publishes
# from a commit nobody can see — this is how v0.9.24 and v0.9.36 shipped.
git fetch origin main
git rev-parse main origin/main   # must print the same SHA twice

# 4. Commit and tag
git add -A
git commit -m "chore: Release vX.Y.Z"
git tag vX.Y.Z

# --atomic, never `--tags`: without it a rejected branch update still lets the
# tag through, and CI then publishes from an orphaned commit.
git push --atomic origin main refs/tags/vX.Y.Z

# 5. Wait for GitHub Actions
# Auto-publishes to: pub.dev, npm, VSCode, JetBrains, Homebrew
```

---

## Files to Update

| File | Change |
|------|--------|
| `CHANGELOG.md` | Add new version entry at top |
| `pubspec.yaml` | `version: X.Y.Z` |
| `lib/src/cli/server.dart` | `const String _currentVersion = 'X.Y.Z'` |
| `npm/package.json` | `"version": "X.Y.Z"` |
| `vscode-extension/package.json` | `"version": "X.Y.Z"` |
| `intellij-plugin/build.gradle.kts` | `version = "X.Y.Z"` |
| `intellij-plugin/.../plugin.xml` | `<version>X.Y.Z</version>` |
| `README.md` | `flutter_skill: ^X.Y.Z` |

---

## Verification Checklist

- [ ] All version numbers updated consistently
- [ ] CHANGELOG.md has new entry
- [ ] Commit message follows format: `chore: Release vX.Y.Z`
- [ ] Git tag created: `vX.Y.Z`
- [ ] Pushed to GitHub with tags
- [ ] GitHub Actions running successfully
- [ ] New version appears on pub.dev (within 10 min)
- [ ] New version appears on npm (within 10 min)

---

## Common Issues

### Wrong version number?
```bash
# If not yet pushed:
git reset --soft HEAD~1
git tag -d vX.Y.Z
# Fix and redo

# If already pushed:
# Create a new patch version instead
```

### GitHub Actions failed?
```bash
# Check logs
open https://github.com/ai-dashboad/flutter-skill/actions

# Re-run failed jobs
# Or delete tag and re-push
git tag -d vX.Y.Z
git push origin :refs/tags/vX.Y.Z
# Fix issue, then:
git tag vX.Y.Z
git push origin vX.Y.Z
```

---

## Detailed Documentation

See `RELEASE_PROCESS.md` for complete guide with:
- Troubleshooting
- Special scenarios
- Best practices
- Automation tips
