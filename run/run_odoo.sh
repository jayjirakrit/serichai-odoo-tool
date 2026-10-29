#!/bin/bash
# Odoo startup script for serichai project

set -e  # stop on any error

# ----- Configuration (adjust as needed) -----
BASE_PATH="/home/odoo/serichai-odoo"
DB="serichai-db"        # PostgreSQL
ADDITIONAL_ADDONS="$BASE_PATH/muk_web_theme,$BASE_PATH/serichai-odoo,$BASE_PATH/knowledge"

# ----- Activate virtual environment -----
cd "$BASE_PATH"
if [ ! -f ".venv/bin/activate" ]; then
    echo "ERROR: Virtual environment not found at $BASE_PATH/.venv"
    exit 1
fi
source .venv/bin/activate

# ----- Change to Odoo source directory -----
cd odoo

# ----- Build add‑ons path (relative + custom) -----
ADDONS_PATH="addons,$ADDITIONAL_ADDONS"

# ----- Start Odoo -----
python3 odoo-bin \
    --addons-path="$ADDONS_PATH" \
    -d "$DB" \
    --http-interface=0.0.0.0 \
    --proxy-mode \
    --without-demo=all \
    "$@"
