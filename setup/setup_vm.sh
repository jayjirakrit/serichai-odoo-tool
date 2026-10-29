#!/bin/bash
# Setup a fresh Ubuntu 24.04 VM for running Serichai Odoo 19.0.
# Installs system packages, PostgreSQL 16, Python 3.12 venv, pulls Odoo
# community + Serichai + OCA repos, and (optionally) nginx/certbot.
#
# Usage (run as the user that will run Odoo, NOT root; needs sudo):
#   ./setup/setup_vm.sh                 # full setup
#   SETUP_NGINX=1 DOMAIN=erp.example.com ./setup/setup_vm.sh
#
# Re-runnable: existing repos are fetched/updated instead of re-cloned.

set -euo pipefail

# ----- Configuration (adjust as needed) -----
BASE_PATH="${BASE_PATH:-$HOME/serichai-odoo}"
DB="${DB:-serichai-db}"
ODOO_BRANCH="${ODOO_BRANCH:-19.0}"
SETUP_NGINX="${SETUP_NGINX:-0}"      # 1 = install nginx + certbot and write a site config
DOMAIN="${DOMAIN:-}"                 # required for the nginx site config
INSTALL_SERVICE="${INSTALL_SERVICE:-0}"  # 1 = create systemd unit "odoo"
ODOO_WORKERS="${ODOO_WORKERS:-0}"    # 0 = threaded mode (websocket served on 8069), >0 = multiprocess (websocket on 8072)

# Behind nginx, Odoo must not be reachable directly from the network.
if [ "$SETUP_NGINX" = "1" ]; then HTTP_INTERFACE="127.0.0.1"; else HTTP_INTERFACE="0.0.0.0"; fi
if [ "$ODOO_WORKERS" -gt 0 ]; then WEBSOCKET_PORT=8072; else WEBSOCKET_PORT=8069; fi

ODOO_REPO="https://github.com/odoo/odoo.git"

# Custom repos: "<dir under BASE_PATH>|<git url>|<branch>"
# NOTE: serichai-odoo is cloned INTO $BASE_PATH/serichai-odoo (same layout as today).
CUSTOM_REPOS=(
    "serichai-odoo|https://github.com/jayjirakrit/serichai-odoo.git|main"
    "knowledge|https://github.com/jayjirakrit/knowledge.git|main"
)

# OCA repos (fill in the provided repos): "<dir under BASE_PATH>|<git url>|<branch>"
# Example: "oca-web|https://github.com/OCA/web.git|19.0"
OCA_REPOS=(
    # "oca-web|https://github.com/OCA/web.git|19.0"
    # "oca-server-tools|https://github.com/OCA/server-tools.git|19.0"
)

# Extra addons dirs that are not git repos here (copy them manually, e.g. muk_web_theme).
# Paths relative to BASE_PATH. Skipped from addons-path if the directory is missing.
EXTRA_ADDON_DIRS=(
    "muk_web_theme"
)

# ----- Sanity checks -----
if [ "$(id -u)" -eq 0 ]; then
    echo "ERROR: run as a regular user with sudo, not as root." >&2
    exit 1
fi
. /etc/os-release
if [ "${VERSION_ID%%.*}" != "24" ]; then
    echo "WARNING: written for Ubuntu 24.xx, detected $PRETTY_NAME" >&2
fi

log() { echo -e "\n=== $* ==="; }

# ----- System packages -----
log "Installing system packages"
sudo apt update
sudo apt install -y git wget curl nodejs npm build-essential \
    python3.12 python3.12-venv python3-pip
sudo apt install -y python3-dev libpq-dev libldap2-dev libsasl2-dev libssl-dev \
    libxml2-dev libxslt1-dev zlib1g-dev libjpeg-dev
# rtlcss is needed by Odoo for RTL languages
sudo npm install -g rtlcss

# ----- PDF generation (wkhtmltopdf, cairo libs, Thai font) -----
log "Installing PDF rendering dependencies"
sudo apt install -y wget fontconfig libfontconfig1 libxrender1 xfonts-75dpi xfonts-base
# libjpeg62-turbo is the Debian name; Ubuntu 24.04 ships libjpeg-turbo8 instead
sudo apt install -y libjpeg62-turbo || sudo apt install -y libjpeg-turbo8
if ! command -v wkhtmltopdf >/dev/null || ! wkhtmltopdf --version | grep -q "0.12.6.1"; then
    WKHTML_DEB="wkhtmltox_0.12.6.1-3.jammy_amd64.deb"
    wget -O "/tmp/$WKHTML_DEB" \
        "https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6.1-3/$WKHTML_DEB"
    sudo dpkg -i "/tmp/$WKHTML_DEB" || true
    sudo apt install -f -y
    rm -f "/tmp/$WKHTML_DEB"
fi
sudo apt install -y libcairo2-dev pkg-config python3-dev
sudo apt install -y fonts-thai-tlwg

# ----- PostgreSQL 16 -----
log "Installing PostgreSQL"
sudo apt install -y postgresql postgresql-client
sudo systemctl enable --now postgresql
if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='$USER'" | grep -q 1; then
    sudo -u postgres createuser -d -R -S "$USER"
fi
if ! psql -lqt postgres | cut -d'|' -f1 | grep -qw "$USER"; then
    createdb "$USER"
fi

# ----- Git repos -----
# clone_or_update <dir> <url> <branch> [depth]
clone_or_update() {
    local dir="$1" url="$2" branch="$3" depth="${4:-}"
    local target="$BASE_PATH/$dir"
    if [ -d "$target/.git" ]; then
        log "Updating $dir"
        git -C "$target" fetch origin "$branch"
        git -C "$target" checkout "$branch"
        git -C "$target" pull --ff-only origin "$branch"
    else
        log "Cloning $dir ($branch)"
        git clone ${depth:+--depth "$depth"} --branch "$branch" "$url" "$target"
    fi
}

mkdir -p "$BASE_PATH"

# Odoo community core: shallow clone to save time/disk
clone_or_update "odoo" "$ODOO_REPO" "$ODOO_BRANCH" 1

for entry in "${CUSTOM_REPOS[@]}" "${OCA_REPOS[@]}"; do
    [ -z "$entry" ] && continue
    IFS='|' read -r dir url branch <<<"$entry"
    clone_or_update "$dir" "$url" "$branch"
done

# ----- Python virtualenv -----
log "Creating virtualenv and installing Python requirements"
if [ ! -d "$BASE_PATH/.venv" ]; then
    python3.12 -m venv "$BASE_PATH/.venv"
fi
# shellcheck disable=SC1091
source "$BASE_PATH/.venv/bin/activate"
pip install --upgrade pip wheel setuptools
pip install -r "$BASE_PATH/odoo/requirements.txt"
# Python libs for PDF rendering (needs libcairo2-dev installed above)
pip install pycairo rlPyCairo

# Requirements shipped by custom/OCA repos
for entry in "${CUSTOM_REPOS[@]}" "${OCA_REPOS[@]}"; do
    [ -z "$entry" ] && continue
    IFS='|' read -r dir _ _ <<<"$entry"
    req="$BASE_PATH/$dir/requirements.txt"
    [ -f "$req" ] && pip install -r "$req"
done

# ----- Addons path + run script -----
ADDONS_PATH="addons"
for entry in "${EXTRA_ADDON_DIRS[@]}"; do
    [ -d "$BASE_PATH/$entry" ] && ADDONS_PATH+=",$BASE_PATH/$entry" \
        || echo "WARNING: $BASE_PATH/$entry not found, skipped in addons-path." >&2
done
for entry in "${CUSTOM_REPOS[@]}" "${OCA_REPOS[@]}"; do
    [ -z "$entry" ] && continue
    IFS='|' read -r dir _ _ <<<"$entry"
    ADDONS_PATH+=",$BASE_PATH/$dir"
done

log "Writing $BASE_PATH/run_odoo.sh"
if [ -f "$BASE_PATH/run_odoo.sh" ]; then
    cp "$BASE_PATH/run_odoo.sh" "$BASE_PATH/run_odoo.sh.bak"
fi
cat > "$BASE_PATH/run_odoo.sh" <<EOF
#!/bin/bash
# Odoo startup script for serichai project (generated by setup_vm.sh)
set -e
BASE_PATH="$BASE_PATH"
DB="$DB"
ADDONS_PATH="$ADDONS_PATH"

cd "\$BASE_PATH"
source .venv/bin/activate
cd odoo
python3 odoo-bin \\
    --addons-path="\$ADDONS_PATH" \\
    -d "\$DB" \\
    --http-interface=$HTTP_INTERFACE \\
    --workers=$ODOO_WORKERS \\
    --proxy-mode \\
    --without-demo=all \\
    "\$@"
EOF
chmod +x "$BASE_PATH/run_odoo.sh"

# ----- Optional: systemd service -----
if [ "$INSTALL_SERVICE" = "1" ]; then
    log "Installing systemd service 'odoo'"
    sudo tee /etc/systemd/system/odoo.service >/dev/null <<EOF
[Unit]
Description=Odoo (Serichai)
After=network.target postgresql.service

[Service]
Type=simple
User=$USER
WorkingDirectory=$BASE_PATH/odoo
ExecStart=$BASE_PATH/run_odoo.sh
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
    sudo systemctl daemon-reload
    sudo systemctl enable odoo
fi

# ----- Optional: nginx + certbot -----
if [ "$SETUP_NGINX" = "1" ]; then
    [ -n "$DOMAIN" ] || { echo "ERROR: set DOMAIN=... when SETUP_NGINX=1" >&2; exit 1; }
    log "Installing nginx + certbot"
    sudo apt install -y nginx certbot python3-certbot-nginx
    sudo tee /etc/nginx/sites-available/odoo >/dev/null <<EOF
upstream odoo     { server 127.0.0.1:8069; }
upstream odoochat { server 127.0.0.1:$WEBSOCKET_PORT; }

map \$http_upgrade \$connection_upgrade {
    default upgrade;
    ''      close;
}

server {
    listen 80;
    server_name $DOMAIN;

    client_max_body_size 200m;
    proxy_read_timeout 720s;
    proxy_connect_timeout 720s;
    proxy_send_timeout 720s;

    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;

    location /websocket {
        proxy_pass http://odoochat;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
    }

    location / {
        proxy_pass http://odoo;
        proxy_redirect off;
    }

    gzip on;
    gzip_types text/css text/plain text/xml application/xml application/json application/javascript;
}
EOF
    sudo ln -sf /etc/nginx/sites-available/odoo /etc/nginx/sites-enabled/odoo
    sudo rm -f /etc/nginx/sites-enabled/default
    sudo nginx -t && sudo systemctl reload nginx
    echo "HTTPS: run  sudo certbot --nginx -d $DOMAIN  once DNS points to this VM."
fi

log "Done"
cat <<EOF
Base path : $BASE_PATH
Addons    : $ADDONS_PATH
Start     : $BASE_PATH/run_odoo.sh -i base      (first run on a new DB)
            $BASE_PATH/run_odoo.sh              (afterwards)
To restore an existing DB see: $BASE_PATH/scripts/restore_odoo.sh
EOF
