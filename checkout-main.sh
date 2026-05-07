#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOS_DIR="$SCRIPT_DIR/repos"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}==>${NC} $*"; }
warn()  { echo -e "${YELLOW}==>${NC} $*"; }
error() { echo -e "${RED}ERROR:${NC} $*" >&2; }

if [[ ! -d "$REPOS_DIR" ]]; then
    error "repos directory not found: $REPOS_DIR"
    exit 1
fi

shopt -s nullglob
repos=("$REPOS_DIR"/*/)
if [[ ${#repos[@]} -eq 0 ]]; then
    warn "No repositories found in $REPOS_DIR"
    exit 0
fi

switched=0
skipped=0
failed=0

for dir in "${repos[@]}"; do
    repo=$(basename "$dir")

    if [[ ! -d "$dir/.git" ]]; then
        warn "$repo: not a git repository, skipping"
        continue
    fi

    branch=$(git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "?")

    if [[ "$branch" == "main" ]]; then
        echo "  $repo: already on main"
        skipped=$((skipped + 1))
        continue
    fi

    dirty=$(git -C "$dir" status --porcelain | wc -l | tr -d ' ')
    if [[ "$dirty" -gt 0 ]]; then
        warn "$repo: uncommitted changes on '$branch' — skipping (commit or stash first)"
        failed=$((failed + 1))
        continue
    fi

    info "$repo: switching '$branch' -> main"
    if git -C "$dir" checkout main; then
        switched=$((switched + 1))
    else
        error "$repo: checkout failed"
        failed=$((failed + 1))
    fi
done

echo ""
info "Done. switched=$switched already-on-main=$skipped skipped/failed=$failed"
