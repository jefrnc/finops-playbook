#!/bin/bash
# Run every query block in finops-queries.sql and write CSV results.
#
# Usage:
#   ./run-all.sh [output-dir]

set -e
OUT="${1:-./output}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SCRIPT_DIR/finops-queries.sql"

mkdir -p "$OUT"

# extract each Qxx block and run it
grep -oE '^-- Q[0-9]+:' "$SRC" | tr -d ':' | while read -r tag; do
  qnum="${tag#-- }"
  # extract from "-- Qxx" to next "-- Q" (exclusive)
  block=$(awk -v start="^-- $qnum" '
    $0 ~ start        { p=1; next }
    p && /^-- Q[0-9]+/ { exit }
    p                  { print }
  ' "$SRC")
  label=$(echo "$block" | head -1 | sed 's/^-- [A-Z0-9]*: //;s/[^a-zA-Z0-9]/-/g;s/--*/-/g;s/-$//' | tr 'A-Z' 'a-z')
  file="$OUT/${qnum}-${label:0:40}.csv"
  echo "→ $qnum → $(basename "$file")"
  steampipe query --output csv "$block" > "$file" 2>&1 || echo "  (failed)"
done

echo
echo "Done — $(ls "$OUT"/*.csv 2>/dev/null | wc -l) files in $OUT"
