#!/bin/bash
# One-command release script
#
# Usage:
#   ./scripts/release.sh 0.2.16 "Brief description of this release"

set -e

VERSION=$1
DESCRIPTION=${2:-"Release $VERSION"}

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Get project root (script location's parent)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_ROOT"

usage() {
    echo "Usage: ./scripts/release.sh <version> [description]"
    echo ""
    echo "Examples:"
    echo "  ./scripts/release.sh 0.2.16 \"Bug fixes and performance improvements\""
    echo "  ./scripts/release.sh 0.3.0 \"Major feature release\""
    echo ""
    echo "What it does:"
    echo "  1. Updates version in pubspec.yaml, package.json, etc."
    echo "  2. Adds entry to CHANGELOG.md"
    echo "  3. Commits, tags, and pushes"
    echo "  4. Triggers GitHub Actions release workflow"
    exit 1
}

confirm() {
    read -p "$1 [y/N] " response
    case "$response" in
        [yY][eE][sS]|[yY]) return 0 ;;
        *) return 1 ;;
    esac
}

# Validate arguments
if [ -z "$VERSION" ]; then
    usage
fi

# Validate version format
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo -e "${RED}❌ Invalid version format: $VERSION${NC}"
    echo "   Expected format: x.y.z (e.g., 0.2.16)"
    exit 1
fi

echo -e "${BLUE}🚀 Releasing v$VERSION${NC}"
echo ""

# Step 0: Make sure the release will actually be cut from origin/main.
#
# The tag is what triggers the release workflow, so a tag that does not sit on
# main means the published artifacts were built from a commit nobody can see.
# This has already happened twice (v0.9.24, v0.9.36): the release was cut on a
# stale local main, `git push origin main --tags` had the branch rejected but
# still delivered the tag, CI published from the orphaned commit, and the
# follow-up `pull --rebase` left the tag pointing at the pre-rebase copy.
echo "📋 Verifying branch is in sync with origin..."

CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
if [ "$CURRENT_BRANCH" != "main" ]; then
    echo -e "${RED}❌ Releases must be cut from main, but you are on '$CURRENT_BRANCH'.${NC}"
    echo "   git switch main"
    exit 1
fi

git fetch origin main --tags --quiet

if git rev-parse --verify --quiet "refs/tags/v$VERSION" >/dev/null; then
    echo -e "${RED}❌ Tag v$VERSION already exists.${NC}"
    echo "   Pick a new version, or delete the tag if it was never published."
    exit 1
fi

LOCAL=$(git rev-parse main)
REMOTE=$(git rev-parse origin/main)
if [ "$LOCAL" != "$REMOTE" ]; then
    BEHIND=$(git rev-list --count main..origin/main)
    AHEAD=$(git rev-list --count origin/main..main)
    echo -e "${RED}❌ Local main is out of sync with origin/main${NC}"
    echo "   behind: $BEHIND commit(s)   ahead: $AHEAD commit(s)"
    echo ""
    if [ "$BEHIND" -gt 0 ]; then
        echo "   Releasing now would tag a commit that is not on origin/main, and the"
        echo "   published build would silently omit those $BEHIND commit(s)."
        echo ""
        echo "   git pull --rebase origin main"
    else
        echo "   Push your local commits first so the tag lands on origin/main:"
        echo ""
        echo "   git push origin main"
    fi
    exit 1
fi

echo -e "  ${GREEN}✓ main matches origin/main ($(git rev-parse --short main))${NC}"

# Step 1: Check for uncommitted changes
echo ""
echo "📋 Checking git status..."
if [ -n "$(git status --porcelain)" ]; then
    echo -e "${YELLOW}⚠️  You have uncommitted changes:${NC}"
    git status --short
    echo ""
    if ! confirm "Continue anyway?"; then
        echo "Aborted."
        exit 0
    fi
fi

# Step 2: Sync version to all files
echo ""
echo -e "${BLUE}📦 Syncing version to all files...${NC}"

# pubspec.yaml
sed -i '' "s/^version: .*/version: $VERSION/" pubspec.yaml
echo "  ✓ pubspec.yaml"

# packaging/npm/package.json
sed -i '' "s/\"version\": \"[^\"]*\"/\"version\": \"$VERSION\"/" packaging/npm/package.json
echo "  ✓ packaging/npm/package.json"

# vscode-extension/package.json
sed -i '' "s/\"version\": \"[^\"]*\"/\"version\": \"$VERSION\"/" vscode-extension/package.json
echo "  ✓ vscode-extension/package.json"

# intellij-plugin/build.gradle.kts
sed -i '' "s/version = \"[^\"]*\"/version = \"$VERSION\"/" intellij-plugin/build.gradle.kts
echo "  ✓ intellij-plugin/build.gradle.kts"

# intellij-plugin/plugin.xml
sed -i '' "s/<version>[^<]*<\/version>/<version>$VERSION<\/version>/" intellij-plugin/src/main/resources/META-INF/plugin.xml
echo "  ✓ intellij-plugin/plugin.xml"

# README.md
sed -i '' "s/flutter_skill: \^[0-9.]*/flutter_skill: ^$VERSION/g" README.md
echo "  ✓ README.md"

# sdks/electron/package.json
if [ -f sdks/electron/package.json ]; then
    sed -i '' "s/\"version\": \"[^\"]*\"/\"version\": \"$VERSION\"/" sdks/electron/package.json
    echo "  ✓ sdks/electron/package.json"
fi

# sdks/react-native/package.json
if [ -f sdks/react-native/package.json ]; then
    sed -i '' "s/\"version\": \"[^\"]*\"/\"version\": \"$VERSION\"/" sdks/react-native/package.json
    echo "  ✓ sdks/react-native/package.json"
fi

# sdks/tauri/Cargo.toml
if [ -f sdks/tauri/Cargo.toml ]; then
    sed -i '' "s/^version = \"[^\"]*\"/version = \"$VERSION\"/" sdks/tauri/Cargo.toml
    echo "  ✓ sdks/tauri/Cargo.toml"
fi

# sdks/android/build.gradle.kts
if [ -f sdks/android/build.gradle.kts ]; then
    sed -i '' "s/version = \"[^\"]*\"/version = \"$VERSION\"/" sdks/android/build.gradle.kts
    echo "  ✓ sdks/android/build.gradle.kts"
fi

# sdks/kmp/build.gradle.kts
if [ -f sdks/kmp/build.gradle.kts ]; then
    sed -i '' "s/version = \"[^\"]*\"/version = \"$VERSION\"/" sdks/kmp/build.gradle.kts
    echo "  ✓ sdks/kmp/build.gradle.kts"
fi

# sdks/ios/Package.swift - update in comment/constant if present
# sdks/dotnet-maui - version in .csproj
if [ -f sdks/dotnet-maui/FlutterSkill.csproj ]; then
    sed -i '' "s/<Version>[^<]*<\/Version>/<Version>$VERSION<\/Version>/" sdks/dotnet-maui/FlutterSkill.csproj
    # Add Version tag if not present
    if ! grep -q '<Version>' sdks/dotnet-maui/FlutterSkill.csproj; then
        sed -i '' "s|</PropertyGroup>|  <Version>$VERSION</Version>\n  </PropertyGroup>|" sdks/dotnet-maui/FlutterSkill.csproj
    fi
    echo "  ✓ sdks/dotnet-maui/FlutterSkill.csproj"
fi

# lib/src/cli/server.dart
sed -i '' "s/const String currentVersion = '[^']*'/const String currentVersion = '$VERSION'/" lib/src/cli/server.dart
echo "  ✓ lib/src/cli/server.dart"

# server.json (MCP Registry)
if [ -f server.json ]; then
    sed -i '' "s/\"version\": \"[^\"]*\"/\"version\": \"$VERSION\"/g" server.json
    echo "  ✓ server.json"
fi

# skills/e2e-testing/SKILL.md (skills.sh + OpenClaw)
if [ -f skills/e2e-testing/SKILL.md ]; then
    sed -i '' "s/^version: .*/version: $VERSION/" skills/e2e-testing/SKILL.md
    echo "  ✓ skills/e2e-testing/SKILL.md"
fi

# packaging/homebrew/flutter-skill.rb
sed -i '' "s/version \"[^\"]*\"/version \"$VERSION\"/" packaging/homebrew/flutter-skill.rb
sed -i '' "s|/v[0-9]*\.[0-9]*\.[0-9]*/|/v$VERSION/|g" packaging/homebrew/flutter-skill.rb
sed -i '' "s/flutter_skill: \^[0-9.]*/flutter_skill: ^$VERSION/" packaging/homebrew/flutter-skill.rb
echo "  ✓ packaging/homebrew/flutter-skill.rb"

# Step 3: Update CHANGELOG
echo ""
echo -e "${BLUE}📝 Updating CHANGELOG.md...${NC}"

if grep -q "^## $VERSION" CHANGELOG.md; then
    echo -e "  ${GREEN}✓ CHANGELOG.md already has $VERSION entry${NC}"
else
    CHANGELOG_ENTRY="## $VERSION

**$DESCRIPTION**

### Changes
- TODO: Add your changes here

---

"
    # Prepend to CHANGELOG.md
    echo "$CHANGELOG_ENTRY$(cat CHANGELOG.md)" > CHANGELOG.md
    echo "  ✓ Added $VERSION entry"
    echo -e "  ${YELLOW}⚠️  Edit CHANGELOG.md to add release details before confirming${NC}"
fi

# Step 4: Show changes and confirm
echo ""
echo "📋 Changes to be committed:"
git add -u  # Only stage modified tracked files (not untracked)
git add .gitignore  # Include .gitignore changes
git diff --cached --stat
echo ""

if ! confirm "Commit, tag, and push v$VERSION?"; then
    echo "Aborted. Changes are staged but not committed."
    exit 0
fi

# Step 5: Commit
echo ""
echo "💾 Committing..."
git commit -m "chore: Release v$VERSION

$DESCRIPTION"

# Step 6: Tag
echo "🏷️  Creating tag v$VERSION..."
git tag "v$VERSION"

# Step 7: Push
#
# --atomic makes the branch and the tag land together or not at all. Without it
# git updates each ref independently, so a rejected branch update still lets the
# tag through — which is what published v0.9.24 and v0.9.36 from commits that
# were never on main. Only this release's tag is pushed; `--tags` would also
# re-push unrelated local tags.
echo "📤 Pushing to origin..."
if ! git push --atomic origin main "refs/tags/v$VERSION"; then
    echo ""
    echo -e "${RED}❌ Push failed — nothing was published.${NC}"
    echo "   The tag was NOT pushed, so the release workflow did not start."
    echo ""
    echo "   Removing the local tag so you can retry cleanly:"
    git tag -d "v$VERSION"
    echo ""
    echo "   Then: git pull --rebase origin main && ./scripts/release.sh $VERSION \"$DESCRIPTION\""
    exit 1
fi

echo ""
echo -e "${GREEN}✅ Released v$VERSION successfully!${NC}"
echo ""
echo "🔗 GitHub Actions: https://github.com/ai-dashboad/flutter-skill/actions"
echo ""
echo "Publishing to:"
echo "  • pub.dev"
echo "  • npm"
echo "  • VSCode Marketplace"
echo "  • Open VSX Registry"
echo "  • JetBrains Marketplace"
echo "  • Homebrew"
echo "  • Scoop"
echo "  • GitHub Release (native binaries)"
echo "  • MCP Registry"
echo "  • skills.sh (auto-indexed from skills/)"
