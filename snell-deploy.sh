#!/usr/bin/env bash
# =============================================================================
# Snell Server Deployment Script
# =============================================================================

set -euo pipefail

# --- Config ------------------------------------------------------------------
VERSION_URL="https://github.com/sam-sun00/snell-script/raw/refs/heads/main/version"
SNELL_DOWNLOAD_BASE_URL="https://dl.nssurge.com/snell"
SNELL_BIN="/usr/local/bin/snell-server"
SNELL_CONF_DIR="/etc/snell"
SNELL_CONF="$SNELL_CONF_DIR/snell-server.conf"
SNELL_SERVICE="/etc/systemd/system/snell-server.service"
SYSCTL_CONF="/etc/sysctl.d/99-snell-network.conf"
MIN_PORT=10000
MAX_PORT=40000
PORT_ARG=""
WORKDIR=""

# --- Helpers -----------------------------------------------------------------
info()  { echo -e "\e[32m[INFO]\e[0m  $*"; }
warn()  { echo -e "\e[33m[WARN]\e[0m  $*"; }
error() { echo -e "\e[31m[ERROR]\e[0m $*" >&2; exit 1; }

usage() {
    cat <<EOF
Usage: sudo bash $0 [options]

Options:
  -p, --port PORT   Use the specified Snell listen port (${MIN_PORT}-${MAX_PORT})
  -h, --help        Show this help message

Examples:
  sudo bash $0
  sudo bash $0 -p 10000
EOF
}

normalize_port() {
    local port="$1"

    [[ "$port" =~ ^[0-9]+$ ]] || error "Port must be a number."

    local port_num=$((10#$port))
    (( port_num >= MIN_PORT && port_num <= MAX_PORT )) \
        || error "Port must be between $MIN_PORT and $MAX_PORT."

    printf "%d\n" "$port_num"
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -p|--port)
                [[ $# -ge 2 ]] || error "Option $1 requires a port number."
                PORT_ARG="$(normalize_port "$2")"
                shift 2
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                error "Unknown argument: $1"
                ;;
        esac
    done
}

generate_psk() {
    local chars="ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
    local psk="" byte index

    while ((${#psk} < 32)); do
        for byte in $(od -An -N128 -tu1 /dev/urandom); do
            (( byte < 248 )) || continue
            index=$((byte % ${#chars}))
            psk+="${chars:$index:1}"
            ((${#psk} == 32)) && break
        done
    done

    printf "%s\n" "$psk"
}

generate_port() {
    local range=$((MAX_PORT - MIN_PORT + 1))
    local limit=$((65536 - (65536 % range)))
    local random

    while true; do
        random="$(od -An -N2 -tu2 /dev/urandom)"
        random="${random//[[:space:]]/}"
        [[ -n "$random" ]] || continue

        if (( random < limit )); then
            printf "%d\n" "$((MIN_PORT + (random % range)))"
            return
        fi
    done
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

ensure_tcp_bbr_available() {
    local available

    available="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null)" \
        || error "Failed to read available TCP congestion controls."

    if [[ " $available " == *" bbr "* ]]; then
        return
    fi

    command -v modprobe >/dev/null 2>&1 \
        || error "BBR is not available and modprobe was not found."

    info "Loading tcp_bbr kernel module..."
    modprobe tcp_bbr \
        || error "Failed to load tcp_bbr kernel module."

    available="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null)" \
        || error "Failed to read available TCP congestion controls."

    [[ " $available " == *" bbr "* ]] \
        || error "BBR is not available on this kernel."
}

ensure_sysctl_value() {
    local key="$1"
    local desired="$2"
    local current

    current="$(sysctl -n "$key" 2>/dev/null)" \
        || error "Failed to read sysctl value for $key."

    if [[ "$current" == "$desired" ]]; then
        info "$key already set to $desired."
        return
    fi

    info "Setting $key from $current to $desired..."
    sysctl -w "$key=$desired" >/dev/null \
        || error "Failed to set $key to $desired."
}

ensure_sysctl_config() {
    if [[ -f "$SYSCTL_CONF" ]] \
        && grep -Eq '^[[:space:]]*net\.core\.default_qdisc[[:space:]]*=[[:space:]]*fq([[:space:]]*(#.*)?)?$' "$SYSCTL_CONF" \
        && grep -Eq '^[[:space:]]*net\.ipv4\.tcp_congestion_control[[:space:]]*=[[:space:]]*bbr([[:space:]]*(#.*)?)?$' "$SYSCTL_CONF" \
        && grep -Eq '^[[:space:]]*net\.ipv4\.tcp_fastopen[[:space:]]*=[[:space:]]*3([[:space:]]*(#.*)?)?$' "$SYSCTL_CONF"; then
        info "Persistent kernel networking settings already set in $SYSCTL_CONF."
        return
    fi

    info "Writing persistent kernel networking settings to $SYSCTL_CONF..."
    cat > "$SYSCTL_CONF" <<EOF
# Managed by snell-deploy.sh
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
EOF
    chmod 644 "$SYSCTL_CONF"
}

ensure_kernel_networking() {
    info "Configuring kernel networking with BBR, fq, and TCP Fast Open..."
    ensure_tcp_bbr_available
    ensure_sysctl_value "net.core.default_qdisc" "fq"
    ensure_sysctl_value "net.ipv4.tcp_congestion_control" "bbr"
    ensure_sysctl_value "net.ipv4.tcp_fastopen" "3"
    ensure_sysctl_config
}

parse_args "$@"
trap cleanup EXIT

# --- Root check --------------------------------------------------------------
[[ "$EUID" -eq 0 ]] || error "This script must be run as root (try: sudo $0)"

# --- Step 1: Install dependencies --------------------------------------------
info "Installing required packages..."
apt-get update -qq
apt-get install -y -qq unzip wget curl procps kmod

# --- Step 2: Configure kernel networking --------------------------------------
ensure_kernel_networking

# --- Step 3: Download --------------------------------------------------------
SNELL_VERSION="$(fetch_latest_version)"
SNELL_ZIP="snell-server-${SNELL_VERSION}-linux-amd64.zip"
SNELL_URL="${SNELL_DOWNLOAD_BASE_URL}/${SNELL_ZIP}"
WORKDIR="$(mktemp -d)"

info "Downloading snell-server from $SNELL_URL..."
wget --no-check-certificate -q --show-progress \
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

# --- Step 6: Write config ----------------------------------------------------
SNELL_PORT="${PORT_ARG:-$(generate_port)}"
SNELL_PSK="$(generate_psk)"

info "Creating config at $SNELL_CONF..."
mkdir -p "$SNELL_CONF_DIR"
cat > "$SNELL_CONF" <<EOF
[snell-server]
listen = 0.0.0.0:$SNELL_PORT
psk = $SNELL_PSK
ipv6 = true
EOF
chmod 600 "$SNELL_CONF"   # psk is sensitive — restrict read access

# --- Step 7: Write systemd unit ----------------------------------------------
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

# --- Step 8: Enable and start ------------------------------------------------
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

info "Snell version: $SNELL_VERSION"
info "Snell port: $SNELL_PORT"
info "Snell psk: $SNELL_PSK"
