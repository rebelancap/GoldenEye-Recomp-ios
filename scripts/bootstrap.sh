#!/usr/bin/env bash
# Clone/refresh the pristine vendor trees to the commits named in vendor/PINS.
# Idempotent. Loud on failure. Never touches patches/ or build/.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PINS="$REPO_ROOT/vendor/PINS"
[ -f "$PINS" ] || { echo "FATAL: missing $PINS" >&2; exit 1; }

while read -r name url commit; do
  case "$name" in ''|\#*) continue ;; esac
  dst="$REPO_ROOT/vendor/$name"

  if [ ! -d "$dst/.git" ]; then
    echo "==> cloning $name"
    git clone --quiet "$url" "$dst"
  fi

  # Refuse to clobber local modifications in a tree that is supposed to be pristine.
  if [ -n "$(git -C "$dst" status --porcelain)" ]; then
    echo "FATAL: vendor/$name is dirty. vendor/ trees must stay pristine;" >&2
    echo "       put local changes in patches/$name/ instead." >&2
    git -C "$dst" status --short >&2
    exit 1
  fi

  if [ "$(git -C "$dst" rev-parse HEAD)" != "$commit" ]; then
    echo "==> $name -> $commit"
    git -C "$dst" fetch --quiet origin
    git -C "$dst" checkout --quiet --detach "$commit"
  fi

  printf '    %-18s %s\n' "$name" "$(git -C "$dst" rev-parse --short HEAD)"
done < "$PINS"

echo "vendor trees are at their pinned commits."
