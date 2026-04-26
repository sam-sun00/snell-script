#!/usr/bin/env bash
# =============================================================================
# Snell Server Deployment Script
# =============================================================================

set -euo pipefail

# --- Config ------------------------------------------------------------------
SNELL_URL="https://dl.nssurge.com/snell/snell-server-v5.0.1-linux-amd64.zip"
SNELL_ZIP="snell-server-v5.0.1-linux-amd64.zip"
SNELL_BIN="/usr/local/bin/snell-server"
SNELL_CONF_DIR="/etc/snell"
SNELL_CONF="$SNELL_CONF_DIR/snell-server.conf"
SNELL_SERVICE="/etc/systemd/system/snell-server.service"
WORKDIR="$(mktemp -d)"

# --- Helpers -----------------------------------------------------------------
info()  { echo -e "\e[32m[INFO]\e[0m  $*"; }
warn()  { echo -e "\e[33m[WARN]\e[0m  $*"; }
error() { echo -e "\e[31m[ERROR]\e[0m $*" >&2; exit 1; }

# --- Root check --------------------------------------------------------------
[[ "$EUID" -eq 0 ]] || error "This script must be run as root (try: sudo $0)"

# --- Step 1: Install dependencies --------------------------------------------
info "Installing required packages..."
apt-get update -qq
apt-get install -y -qq unzip wget curl

# --- Step 2: Download --------------------------------------------------------
info "Downloading snell-server from $SNELL_URL..."
wget --no-check-certificate -q --show-progress \
    -O "$WORKDIR/$SNELL_ZIP" \
    "$SNELL_URL" \
    || error "Download failed. Check the URL or network connectivity."

# --- Step 3: Extract ---------------------------------------------------------
info "Extracting archive..."
unzip -q "$WORKDIR/$SNELL_ZIP" -d "$WORKDIR"

# --- Step 4: Install binary --------------------------------------------------
info "Installing snell-server to $SNELL_BIN..."
[[ -f "$WORKDIR/snell-server" ]] \
    || error "snell-server binary not found in archive. Check the zip contents."

install -m 755 "$WORKDIR/snell-server" "$SNELL_BIN"

# Cleanup temp dir (zip already removed implicitly since it lives in $WORKDIR)
rm -rf "$WORKDIR"
info "Cleaned up temporary files."

# --- Step 5: Write config ----------------------------------------------------
info "Creating config at $SNELL_CONF..."
mkdir -p "$SNELL_CONF_DIR"
cat > "$SNELL_CONF" <<'EOF'
[snell-server]
listen = 0.0.0.0:12345
psk = pskkey
ipv6 = true
EOF
chmod 600 "$SNELL_CONF"   # psk is sensitive — restrict read access

# --- Step 6: Write systemd unit ----------------------------------------------
info "Creating systemd service at $SNELL_SERVICE..."
cat > "$SNELL_SERVICE" <<'EOF'
[Unit]
Description=Snell Server
After=network.target

[Service]
ExecStart=/usr/local/bin/snell-server -c /etc/snell/snell-server.conf
Restart=on-failure
RestartSec=10s
# Security hardening
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/etc/snell

[Install]
WantedBy=multi-user.target
EOF

# --- Step 7: Enable and start ------------------------------------------------
info "Reloading systemd and enabling snell-server..."
systemctl daemon-reload
systemctl enable --now snell-server

# --- Done --------------------------------------------------------------------
info "Verifying service status..."
sleep 1   # give systemd a moment to start the service
if systemctl is-active --quiet snell-server; then
    info "✓ snell-server is running successfully."
    systemctl status snell-server --no-pager -l
else
    warn "Service enabled but may not be active yet. Check with:"
    warn "  journalctl -xeu snell-server"
fi
