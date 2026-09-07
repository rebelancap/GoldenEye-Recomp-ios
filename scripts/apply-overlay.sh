#!/usr/bin/env bash
# Materialise a buildable tree from a pristine vendor tree + our overlay.
#
#   build/overlay/<name>/  =  rsync -ac vendor/<name>/   (minus .git)
#                          +  overlay/<name>/**          (whole new files)
#                          +  patches/<name>/*.patch     (diffs, --fuzz=0)
#
# Every step asserts. A patch that does not apply cleanly fails the build loudly.
# Usage: apply-overlay.sh <name> [<name> ...]   (default: every name in vendor/PINS)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

names=("$@")
if [ ${#names[@]} -eq 0 ]; then
  while read -r n _ _; do
    case "$n" in ''|\#*) continue ;; esac
    names+=("$n")
  done < "$REPO_ROOT/vendor/PINS"
fi

for name in "${names[@]}"; do
  src="$REPO_ROOT/vendor/$name"
  dst="$REPO_ROOT/build/overlay/$name"
  [ -d "$src" ] || { echo "FATAL: no vendor tree at $src (run scripts/bootstrap.sh)" >&2; exit 1; }

  echo "==> overlay $name"
  mkdir -p "$dst"

  # -a archive, -c checksum (mtime is unreliable across patch/rsync cycles),
  # --delete so a removed overlay file really disappears from the build tree.
  # Preserve build outputs and the recompiler's generated/ across syncs.
  rsync -ac --delete \
        --exclude '/.git' \
        --exclude '/build/' \
        --exclude '/generated/' \
        --exclude '/out/' \
        "$src/" "$dst/"

  # 1. Whole new files (new platform backends, scripts, headers).
  if [ -d "$REPO_ROOT/overlay/$name" ]; then
    n=$(find "$REPO_ROOT/overlay/$name" -type f ! -name '.DS_Store' | wc -l | tr -d ' ')
    echo "    + $n added file(s)"
    rsync -ac --exclude '.DS_Store' "$REPO_ROOT/overlay/$name/" "$dst/"
  fi

  # 2. Diffs against upstream files. Sorted, numbered, zero fuzz.
  shopt -s nullglob
  patches=("$REPO_ROOT/patches/$name"/*.patch)
  shopt -u nullglob
  if [ ${#patches[@]} -eq 0 ]; then
    echo "    (no patches)"
  else
    for p in "${patches[@]}"; do
      echo "    ~ $(basename "$p")"
      if ! patch -p1 -d "$dst" --fuzz=0 --no-backup-if-mismatch --forward < "$p"; then
        echo "FATAL: patch failed to apply: $p" >&2
        echo "       Upstream moved under it. Refresh the patch; do NOT hand-edit vendor/." >&2
        exit 1
      fi
    done
  fi
done

echo "overlay trees ready under build/overlay/"
