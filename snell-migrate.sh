#!/usr/bin/env bash
# =============================================================================
# Snell Server Migration Script
# =============================================================================

set -euo pipefail

# --- Config ------------------------------------------------------------------
SNELL_BIN="/usr/local/bin/snell-server"
SNELL_CONF="/etc/snell/snell-server.conf"
SNELL_SERVICE="/etc/systemd/system/snell-server.service"
DRY_RUN=0
WORKDIR=""
BACKUP_SUFFIX="$(date +%Y%m%d%H%M%S)"

# --- Helpers -----------------------------------------------------------------
info()  { echo -e "\e[32m[INFO]\e[0m  $*"; }
warn()  { echo -e "\e[33m[WARN]\e[0m  $*"; }
error() { echo -e "\e[31m[ERROR]\e[0m $*" >&2; exit 1; }

usage() {
    cat <<EOF
Usage: sudo bash $0 [options]

Migrates an existing manual Snell installation to match this repo's service
hardening and config-file permission practices. This does not reinstall Snell,
replace the config, change the port, or regenerate the PSK.

Options:
  --dry-run     Show what would change without writing files or restarting
  -h, --help    Show this help message

Examples:
  sudo bash $0
  sudo bash $0 --dry-run
EOF
}

cleanup() {
    [[ -n "$WORKDIR" && -d "$WORKDIR" ]] && rm -rf "$WORKDIR"
}

run() {
    if (( DRY_RUN )); then
        info "[dry-run] $*"
    else
        "$@"
    fi
}

backup_file() {
    local source="$1"
    local backup="${source}.bak-${BACKUP_SUFFIX}"

    if (( DRY_RUN )); then
        info "[dry-run] cp -p $source $backup"
        info "Backup would be saved to $backup"
    else
        cp -p "$source" "$backup"
        info "Backup saved to $backup"
    fi
}

check_existing_installation() {
    [[ -f "$SNELL_BIN" ]] \
        || error "snell-server binary not found at $SNELL_BIN."

    [[ -f "$SNELL_CONF" ]] \
        || error "Snell config not found at $SNELL_CONF."

    [[ -f "$SNELL_SERVICE" ]] \
        || error "systemd service not found at $SNELL_SERVICE."

    grep -Eq '^[[:space:]]*ExecStart=.*snell-server' "$SNELL_SERVICE" \
        || error "$SNELL_SERVICE does not look like a Snell systemd service."
}

ensure_config_permissions() {
    local mode

    mode="$(stat -c "%a" "$SNELL_CONF")" \
        || error "Failed to read permissions for $SNELL_CONF."

    if [[ "$mode" == "600" ]]; then
        info "Config permissions already set to 600."
        return
    fi

    info "Restricting config permissions from $mode to 600..."
    backup_file "$SNELL_CONF"
    run chmod 600 "$SNELL_CONF"
}

write_hardened_service() {
    awk '
        BEGIN {
            desired["NoNewPrivileges"] = "NoNewPrivileges=true"
            desired["ProtectSystem"] = "ProtectSystem=strict"
            desired["ProtectHome"] = "ProtectHome=true"
            desired["ReadWritePaths"] = "ReadWritePaths=/etc/snell"

            order[++order_count] = "NoNewPrivileges"
            order[++order_count] = "ProtectSystem"
            order[++order_count] = "ProtectHome"
            order[++order_count] = "ReadWritePaths"
        }

        function key_of(line, raw, pieces, key) {
            raw = line
            sub(/^[[:space:]]*/, "", raw)
            split(raw, pieces, "=")
            key = pieces[1]
            sub(/[[:space:]]*$/, "", key)
            return key
        }

        function emit_missing(i, key) {
            for (i = 1; i <= order_count; i++) {
                key = order[i]
                if (!seen[key]) {
                    print desired[key]
                }
            }
        }

        /^[[:space:]]*\[Service\][[:space:]]*$/ {
            service_seen = 1
            in_service = 1
            print
            next
        }

        in_service && /^[[:space:]]*\[[^]]+\][[:space:]]*$/ {
            emit_missing()
            in_service = 0
            print
            next
        }

        in_service {
            key = key_of($0)
            if (key in desired) {
                if (!seen[key]) {
                    print desired[key]
                    seen[key] = 1
                }
                next
            }

            print
            next
        }

        { print }

        END {
            if (!service_seen) {
                exit 42
            }

            if (in_service) {
                emit_missing()
            }
        }
    ' "$SNELL_SERVICE"
}

ensure_service_hardening() {
    local migrated_service="$WORKDIR/snell-server.service"

    if ! write_hardened_service > "$migrated_service"; then
        error "Failed to update $SNELL_SERVICE. Missing or invalid [Service] section."
    fi

    if cmp -s "$SNELL_SERVICE" "$migrated_service"; then
        info "systemd service already contains the desired hardening."
        return
    fi

    info "Applying systemd service hardening..."
    backup_file "$SNELL_SERVICE"
    run install -m 644 "$migrated_service" "$SNELL_SERVICE"
}

reload_and_restart() {
    if (( DRY_RUN )); then
        info "[dry-run] systemctl daemon-reload"
        info "[dry-run] systemctl restart snell-server"
        return
    fi

    if command -v systemd-analyze >/dev/null 2>&1; then
        systemd-analyze verify "$SNELL_SERVICE" \
            || error "systemd unit verification failed for $SNELL_SERVICE."
    else
        warn "systemd-analyze not found; skipping unit verification."
    fi

    info "Reloading systemd and restarting snell-server..."
    systemctl daemon-reload
    systemctl restart snell-server
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)
            DRY_RUN=1
            shift
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

trap cleanup EXIT

# --- Root check --------------------------------------------------------------
[[ "$EUID" -eq 0 ]] || error "This script must be run as root (try: sudo $0)"

WORKDIR="$(mktemp -d)"

# --- Step 1: Verify existing installation ------------------------------------
info "Checking existing Snell installation..."
check_existing_installation

# --- Step 2: Migrate config and service --------------------------------------
ensure_config_permissions
ensure_service_hardening

# --- Step 3: Reload and restart ----------------------------------------------
reload_and_restart

# --- Done --------------------------------------------------------------------
if (( DRY_RUN )); then
    info "Dry run complete. No files were changed and snell-server was not restarted."
    exit 0
fi

info "Verifying service status..."
sleep 1
if systemctl is-active --quiet snell-server; then
    info "Snell migration completed successfully."
    systemctl status snell-server --no-pager -l
else
    warn "Migration finished but snell-server may not be active yet. Check with:"
    warn "  journalctl -xeu snell-server"
fi
