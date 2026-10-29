#!/bin/bash
# Restore a backup made by backup_odoo.sh on the target instance.
#
# Usage:
#   ./backup/restore_odoo.sh BACKUP_DIR [TARGET_DB] [--force] [--neutralize] [--addons]
#
#   --force       drop TARGET_DB (and its filestore) first if it exists
#   --neutralize  disable outgoing mail, crons, webhooks (use for test copies,
#                 NOT for the new production server)
#   --addons      extract addons.tar.gz into BASE_PATH before loading
#
# Expects the target to have the same layout as this repo (BASE_PATH with
# odoo/, .venv/), PostgreSQL reachable by the current user, and Odoo stopped.

set -euo pipefail

BASE_PATH="${BASE_PATH:-/home/odoo/serichai-odoo}"
ADDONS_PATH="addons,../muk_web_theme,../serichai-odoo,../knowledge"

BACKUP_DIR=""
TARGET_DB=""
LOAD_FLAGS=()
RESTORE_ADDONS=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --force) LOAD_FLAGS+=(-f); shift ;;
        --neutralize) LOAD_FLAGS+=(-n); shift ;;
        --addons) RESTORE_ADDONS=true; shift ;;
        -*) echo "Unknown option: $1" >&2; exit 1 ;;
        *)
            if [[ -z "$BACKUP_DIR" ]]; then BACKUP_DIR="$1"
            elif [[ -z "$TARGET_DB" ]]; then TARGET_DB="$1"
            else echo "Unexpected argument: $1" >&2; exit 1; fi
            shift ;;
    esac
done

if [[ -z "$BACKUP_DIR" || ! -d "$BACKUP_DIR" ]]; then
    echo "Usage: $0 BACKUP_DIR [TARGET_DB] [--force] [--neutralize] [--addons]" >&2
    exit 1
fi
BACKUP_DIR="$(cd "$BACKUP_DIR" && pwd)"

ZIP="$(find "$BACKUP_DIR" -maxdepth 1 -name '*.zip' | head -1)"
[[ -n "$ZIP" ]] || { echo "ERROR: no .zip dump in $BACKUP_DIR" >&2; exit 1; }
TARGET_DB="${TARGET_DB:-$(basename "$ZIP" .zip)}"

echo "==> Verifying checksums..."
(cd "$BACKUP_DIR" && sha256sum -c --quiet SHA256SUMS)

if $RESTORE_ADDONS; then
    echo "==> Extracting addons into $BASE_PATH..."
    tar -C "$BASE_PATH" -xzf "$BACKUP_DIR/addons.tar.gz"
fi

source "$BASE_PATH/.venv/bin/activate"

echo "==> Loading '$ZIP' into database '$TARGET_DB'..."
(
    cd "$BASE_PATH/odoo"
    python3 odoo-bin db --addons-path="$ADDONS_PATH" load ${LOAD_FLAGS[@]+"${LOAD_FLAGS[@]}"} "$TARGET_DB" "$ZIP"
)

echo "==> Done. Start Odoo with: ./run_odoo.sh -d $TARGET_DB"
echo "    If addons code changed since the backup, run once with: -u all --stop-after-init"
