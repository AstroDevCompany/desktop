#!/usr/bin/env bash
# Rebuild a corrupted engine/.git/index without touching commits or desktop/src patches.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENGINE="$ROOT/engine"

if [[ ! -d "$ENGINE/.git" ]]; then
  echo "No engine git repo at $ENGINE" >&2
  exit 1
fi

cd "$ENGINE"
rm -f .git/index.lock

if [[ -f .git/index ]]; then
  cp .git/index ".git/index.corrupt.$(date +%s).bak" || true
  rm -f .git/index
fi

git reset --mixed HEAD
echo "Rebuilt engine git index from HEAD. Run: cd .. && npm run import"
