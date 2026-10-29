#!/bin/bash
# Full backup of an Odoo instance for migration to another server.
#
# Produces backups/<DB>_<timestamp>/ containing:
#   <DB>.zip          Odoo-standard dump: dump.sql + filestore/ + manifest.json
#                     (restorable with restore_odoo.sh, `odoo-bin db load`, or
#                     the web Database Manager at /web/database/manager)
#   addons.tar.gz     custom + third-party addons source (no .venv / Odoo core)
#   requirements.txt  pip freeze of .venv, to rebuild the Python env
#   SHA256SUMS        checksums to verify the copy on the target
#
# Usage:
#   ./backup/backup_odoo.sh [DB_NAME] [OUTPUT_DIR]

set -euo pipefail

BASE_PATH="${BASE_PATH:-/home/odoo/serichai-odoo}"
DB="${1:-serichai-db}"
OUT_ROOT="${2:-$BASE_PATH/backups}"
ADDONS_PATH="addons,../muk_web_theme,../serichai-odoo,../knowledge"
# Addon directories (relative to BASE_PATH) to ship alongside the DB.
ADDON_DIRS=(serichai-odoo muk_web_theme serichai_inventory)

STAMP="$(date +%Y%m%d_%H%M%S)"
OUT_DIR="$OUT_ROOT/${DB}_${STAMP}"
mkdir -p "$OUT_DIR"

source "$BASE_PATH/.venv/bin/activate"

echo "==> Dumping database '$DB' with filestore..."
(
    cd "$BASE_PATH/odoo"
    python3 odoo-bin db --addons-path="$ADDONS_PATH" dump "$DB" "$OUT_DIR/$DB.zip"
)

echo "==> Archiving addons source..."
existing=()
for d in "${ADDON_DIRS[@]}"; do
    [[ -d "$BASE_PATH/$d" ]] && existing+=("$d")
done
tar -C "$BASE_PATH" --exclude='__pycache__' --exclude='*.pyc' \
    -czf "$OUT_DIR/addons.tar.gz" "${existing[@]}"

echo "==> Freezing Python requirements..."
pip freeze > "$OUT_DIR/requirements.txt"

echo "==> Verifying archive and writing checksums..."
python3 - "$OUT_DIR/$DB.zip" <<'EOF'
import json, sys, zipfile
z = zipfile.ZipFile(sys.argv[1])
bad = z.testzip()
if bad:
    sys.exit(f"Corrupt member in zip: {bad}")
names = z.namelist()
m = json.loads(z.read("manifest.json"))
print(f"    Odoo {m['version']}, PG {m['pg_version']}, {len(m['modules'])} modules, "
      f"{sum(n.startswith('filestore/') for n in names)} filestore files")
EOF
(cd "$OUT_DIR" && sha256sum ./* > SHA256SUMS)

echo "==> Done: $OUT_DIR"
du -sh "$OUT_DIR"/*
