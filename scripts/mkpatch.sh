#!/usr/bin/env bash
# Capture edits made in build/overlay/<tree>/ back out as a reviewable -p1 patch.
#
#   scripts/mkpatch.sh <tree> <NNNN-slug> <relpath> [<relpath> ...]
#   e.g. scripts/mkpatch.sh rexglue 0001-apple-platform CMakeLists.txt
#
# Then `scripts/apply-overlay.sh <tree>` re-materialises from pristine vendor +
# patches and must reproduce your tree exactly. Files that exist ONLY in the
# overlay belong in overlay/<tree>/, not here -- this tool refuses them.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tree="${1:?usage: mkpatch.sh <tree> <NNNN-slug> <relpath>...}"; shift
slug="${1:?usage: mkpatch.sh <tree> <NNNN-slug> <relpath>...}"; shift
[ $# -gt 0 ] || { echo "FATAL: no paths given" >&2; exit 1; }

dst="$REPO_ROOT/build/overlay/$tree"
out="$REPO_ROOT/patches/$tree/$slug.patch"
mkdir -p "$(dirname "$out")"

# The baseline is NOT pristine vendor -- it is vendor plus every patch that
# sorts before this one, plus the additive overlay tree. Diffing against
# pristine would fold earlier patches' hunks into this one, and applying the
# series would then double-apply them. Build that baseline in a scratch tree.
base="$REPO_ROOT/build/.mkpatch-base/$tree"
rm -rf "$base"
mkdir -p "$base"
rsync -a --exclude '/.git' --exclude '/build/' --exclude '/generated/' \
      --exclude '/out/' "$REPO_ROOT/vendor/$tree/" "$base/"
if [ -d "$REPO_ROOT/overlay/$tree" ]; then
  rsync -a --exclude '.DS_Store' "$REPO_ROOT/overlay/$tree/" "$base/"
fi
shopt -s nullglob
for p in "$REPO_ROOT/patches/$tree"/*.patch; do
  # Strictly-earlier patches only; re-writing an existing patch must not
  # baseline against itself.
  [ "$(basename "$p" .patch)" \< "$slug" ] || continue
  patch -p1 -d "$base" --fuzz=0 --no-backup-if-mismatch --forward --silent < "$p" \
    || { echo "FATAL: baseline patch $p does not apply" >&2; exit 1; }
done
shopt -u nullglob
src="$base"

: > "$out.tmp"
changed=0
for rel in "$@"; do
  [ -f "$src/$rel" ] || { echo "FATAL: $rel does not exist upstream -- new files go in overlay/$tree/" >&2; rm -f "$out.tmp"; exit 1; }
  [ -f "$dst/$rel" ] || { echo "FATAL: $rel missing from build/overlay/$tree" >&2; rm -f "$out.tmp"; exit 1; }
  if ! diff -q "$src/$rel" "$dst/$rel" >/dev/null; then
    diff -u --label "a/$rel" --label "b/$rel" "$src/$rel" "$dst/$rel" >> "$out.tmp" || true
    changed=$((changed + 1))
    echo "    ~ $rel"
  else
    echo "    = $rel (identical, skipped)"
  fi
done

if [ "$changed" -eq 0 ]; then
  echo "FATAL: nothing changed -- no patch written" >&2
  rm -f "$out.tmp"
  exit 1
fi

mv "$out.tmp" "$out"
echo "wrote $out ($changed file(s))"
