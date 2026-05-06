#!/usr/bin/env bash
# =============================================================================
# Snell Server Upgrade Script
# =============================================================================

set -euo pipefail

# --- Config ------------------------------------------------------------------
VERSION_URL="https://github.com/sam-sun00/snell-script/raw/refs/heads/main/version"
SNELL_DOWNLOAD_BASE_URL="https://dl.nssurge.com/snell"
SNELL_BIN="/usr/local/bin/snell-server"
SNELL_CONF="/etc/snell/snell-server.conf"
SNELL_SERVICE="/etc/systemd/system/snell-server.service"
WORKDIR=""

# --- Helpers -----------------------------------------------------------------
info()  { echo -e "\e[32m[INFO]\e[0m  $*"; }
warn()  { echo -e "\e[33m[WARN]\e[0m  $*"; }
error() { echo -e "\e[31m[ERROR]\e[0m $*" >&2; exit 1; }

usage() {
    cat <<EOF
Usage: sudo bash $0

Downloads the latest Snell server binary and upgrades the existing installation.
EOF
}

fetch_latest_version() {
    local version

    version="$(curl -fsSL "$VERSION_URL" | tr -d '[:space:]')" \
        || error "Failed to fetch latest Snell version from $VERSION_URL."

    [[ "$version" =~ ^v[0-9]+(\.[0-9]+)*$ ]] \
        || error "Invalid Snell version returned from $VERSION_URL: $version"

    printf "%s\n" "$version"
}

cleanup() {
    [[ -n "$WORKDIR" && -d "$WORKDIR" ]] && rm -rf "$WORKDIR"
}

check_existing_installation() {
    [[ -f "$SNELL_BIN" ]] \
        || error "snell-server binary not found at $SNELL_BIN. Run the deployment script first."

    [[ -f "$SNELL_CONF" ]] \
        || error "Snell config not found at $SNELL_CONF. Run the deployment script first."

    [[ -f "$SNELL_SERVICE" ]] \
        || error "systemd service not found at $SNELL_SERVICE. Run the deployment script first."
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            usage
            exit 0
            ;;
        *)
            error "Unknown argument: $1"
            ;;
    esac
done

trap cleanup EXIT

# --- Root check --------------------------------------------------------------
[[ "$EUID" -eq 0 ]] || error "This script must be run as root (try: sudo $0)"

# --- Step 1: Verify existing installation ------------------------------------
info "Checking existing Snell installation..."
check_existing_installation

# --- Step 2: Install dependencies --------------------------------------------
info "Installing required packages..."
apt-get update -qq
apt-get install -y -qq unzip wget curl

# --- Step 3: Download --------------------------------------------------------
SNELL_VERSION="$(fetch_latest_version)"
SNELL_ZIP="snell-server-${SNELL_VERSION}-linux-amd64.zip"
SNELL_URL="${SNELL_DOWNLOAD_BASE_URL}/${SNELL_ZIP}"
WORKDIR="$(mktemp -d)"

info "Downloading snell-server from $SNELL_URL..."
wget -q --show-progress \
    -O "$WORKDIR/$SNELL_ZIP" \
    "$SNELL_URL" \
    || error "Download failed. Check the URL or network connectivity."

# --- Step 4: Extract ---------------------------------------------------------
info "Extracting archive..."
unzip -q "$WORKDIR/$SNELL_ZIP" -d "$WORKDIR"

# --- Step 5: Install binary --------------------------------------------------
info "Installing snell-server to $SNELL_BIN..."
[[ -f "$WORKDIR/snell-server" ]] \
    || error "snell-server binary not found in archive. Check the zip contents."

install -m 755 "$WORKDIR/snell-server" "$SNELL_BIN"

cleanup
WORKDIR=""
info "Cleaned up temporary files."

# --- Step 6: Restart service -------------------------------------------------
info "Reloading systemd and restarting snell-server..."
systemctl daemon-reload
systemctl restart snell-server

# --- Done --------------------------------------------------------------------
info "Verifying service status..."
sleep 1   # give systemd a moment to restart the service
if systemctl is-active --quiet snell-server; then
    info "✓ snell-server upgraded successfully."
    systemctl status snell-server --no-pager -l
else
    warn "Upgrade finished but snell-server may not be active yet. Check with:"
    warn "  journalctl -xeu snell-server"
fi

info "Snell version: $SNELL_VERSION"
