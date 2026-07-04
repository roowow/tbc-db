#!/bin/bash
#
# Incremental, non-destructive update for the TBC-DB *world* database only.
#
# Unlike InstallFullDB.sh's "Install fresh TBC-DB" (option 2 / "-World"), this script
# does NOT drop/reimport the database. It only applies the Updates/*.sql files that
# come after the last applied content version recorded in the `db_version` table,
# i.e. the same files apply_content_db() would apply, minus the destructive
# "reinstall from scratch" step.
#
# It reuses InstallFullDB.config for connection settings, so run it from the same
# directory as InstallFullDB.sh (the tbc-db repo root).
#
# Usage:
#   ./IncrementalWorldUpdate.sh          # apply pending updates
#   ./IncrementalWorldUpdate.sh --dry-run  # only list what would be applied

set -euo pipefail

CONFIG_FILE="InstallFullDB.config"
UPDATES_DIR="Updates"
DRY_RUN=false

if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=true
fi

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo ">>> ERROR: $CONFIG_FILE not found. Run this script from your tbc-db directory." >&2
  exit 1
fi

# shellcheck disable=SC1090
source "$CONFIG_FILE"

MYSQL_HOST="${MYSQL_HOST:-localhost}"
MYSQL_PORT="${MYSQL_PORT:-3306}"
MYSQL_PATH="${MYSQL_PATH:-mysql}"

if [[ -z "${WORLD_DB_NAME:-}" || -z "${MYSQL_USERNAME:-}" ]]; then
  echo ">>> ERROR: WORLD_DB_NAME or MYSQL_USERNAME missing from $CONFIG_FILE" >&2
  exit 1
fi

export MYSQL_PWD="$MYSQL_PASSWORD"
MYSQL=("$MYSQL_PATH" -u"$MYSQL_USERNAME" -h"$MYSQL_HOST" -P"$MYSQL_PORT")

echo "Target world database...: $WORLD_DB_NAME @ $MYSQL_HOST:$MYSQL_PORT"

# 1. Find current content marker column (e.g. content_0647_quest_spiritual_aid)
CURRENT_CONTENT_COL=$("${MYSQL[@]}" -s -N -e \
  "SELECT COLUMN_NAME FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA='$WORLD_DB_NAME' AND TABLE_NAME='db_version' AND COLUMN_NAME LIKE 'content_%' LIMIT 1;")

if [[ -z "$CURRENT_CONTENT_COL" ]]; then
  echo ">>> ERROR: could not find a 'content_*' column in ${WORLD_DB_NAME}.db_version." >&2
  echo ">>> This script only works on a database that was already installed at least once." >&2
  exit 1
fi

CURRENT_CONTENT_ID="${CURRENT_CONTENT_COL#content_}"

echo "Current content version.: $CURRENT_CONTENT_ID"
echo

# 2. Build the full, sorted list of update files (same order InstallFullDB.sh would apply them in)
ALL_FILES=()
for f in "$UPDATES_DIR"/[0-9]*.sql; do
  [[ -e "$f" ]] || continue
  ALL_FILES+=("$f")
done
mapfile -t ALL_FILES < <(printf '%s\n' "${ALL_FILES[@]}" | sort)

# 3. Locate the exact file matching the current marker, and take everything after it.
#    Fall back to a numeric-prefix cutoff only if no exact match is found (older/ambiguous markers).
PENDING=()
FOUND_INDEX=-1
for i in "${!ALL_FILES[@]}"; do
  base="$(basename "${ALL_FILES[$i]}")"
  if [[ "${base%.sql}" == "$CURRENT_CONTENT_ID" ]]; then
    FOUND_INDEX=$i
    break
  fi
done

if [[ "$FOUND_INDEX" -ge 0 ]]; then
  PENDING=("${ALL_FILES[@]:$((FOUND_INDEX+1))}")
else
  echo ">>> WARNING: could not find an exact file match for marker '$CURRENT_CONTENT_ID'." >&2
  echo ">>> Falling back to numeric-prefix comparison (less precise for older '0001_xxxx' style files)." >&2
  CURRENT_NUM=$((10#${CURRENT_CONTENT_ID:0:4}))
  for f in "${ALL_FILES[@]}"; do
    base="$(basename "$f")"
    num=$((10#${base:0:4}))
    if [[ "$num" -gt "$CURRENT_NUM" ]]; then
      PENDING+=("$f")
    fi
  done
fi

if [[ ${#PENDING[@]} -eq 0 ]]; then
  echo "Nothing to do, world database content is already up to date."
  exit 0
fi

echo "Pending updates (${#PENDING[@]}):"
for f in "${PENDING[@]}"; do
  echo "  - $(basename "$f")"
done
echo

if [[ "$DRY_RUN" = true ]]; then
  echo "Dry-run only, nothing was applied."
  exit 0
fi

read -r -p "Apply these ${#PENDING[@]} update(s) to '$WORLD_DB_NAME'? [y/N] " CONFIRM || CONFIRM="n"
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
  echo "Aborted."
  exit 1
fi

# 3. Apply each pending file, in order
LAST_APPLIED=""
for f in "${PENDING[@]}"; do
  base="$(basename "$f")"
  echo -n "  - Applying $base ... "
  if "${MYSQL[@]}" -D "$WORLD_DB_NAME" < "$f" 2>/tmp/incr_update_err.log; then
    echo "SUCCESS"
    LAST_APPLIED="${base%.sql}"
  else
    echo "FAILED!"
    echo ">>> $(cat /tmp/incr_update_err.log)" >&2
    echo ">>> Stopped after applying $(basename "${PENDING[0]}") .. previous file. Fix the error above and re-run." >&2
    exit 1
  fi
done

# 4. Update the content marker column to the last applied file (mirrors apply_content_db())
if [[ -n "$LAST_APPLIED" ]]; then
  echo
  echo "Updating db_version content marker to: $LAST_APPLIED"
  "${MYSQL[@]}" -D "$WORLD_DB_NAME" -e \
    "ALTER TABLE db_version DROP COLUMN \`${CURRENT_CONTENT_COL}\`, ADD COLUMN \`content_${LAST_APPLIED}\` bit DEFAULT NULL;"
fi

echo
echo "Done. Applied ${#PENDING[@]} update(s)."
