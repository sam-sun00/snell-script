# Agent Notes

This repository contains Bash scripts for deploying, upgrading, and migrating a
Snell server installation on a Linux host that uses `apt` and `systemd`.

Additional project conversation context is kept in `Agent-Chat-History.md`. Use
that file when reconstructing why the scripts were added or changed.

## Project History Context

- The original deployment workflow was manual: install dependencies, download a
  Snell zip, unzip it, keep only the `snell-server` binary, move it to
  `/usr/local/bin`, then hand-write the config and systemd unit.
- The first deployment script intentionally improved that manual workflow with a
  temp working directory, `install -m 755`, binary existence checks, config mode
  `600`, colored logs, a service health check, and systemd hardening.
- `snell-deploy.sh` later moved from fixed config values to generated
  credentials: a fresh 32-character alphanumeric PSK and either a random port in
  `10000-40000` or the port supplied by `-p/--port`.
- Deployment and upgrade were changed to derive the Snell archive name from the
  repo's `version` endpoint rather than hardcoding a single versioned zip URL.
- `snell-upgrade.sh` was added for existing script-managed installations. It
  intentionally checks for an existing binary, config, and service before
  replacing only the binary, then reloads systemd and restarts the service.
- `snell-migrate.sh` was added after discussing older manual installs. The goal
  is adoption and hardening, not redeployment: preserve the existing binary,
  port, PSK, and custom unit content where possible, while normalizing config
  permissions and desired hardening directives.

## Repository Layout

- `snell-deploy.sh`: first-time deployment script. It installs dependencies,
  downloads the Snell server binary for the version in `version`, creates
  `/etc/snell/snell-server.conf`, writes the systemd service, enables the
  service, and prints the generated connection details.
- `snell-upgrade.sh`: upgrade script for an existing repo-managed install. It
  checks that the binary, config, and service already exist, downloads the latest
  configured Snell binary, replaces `/usr/local/bin/snell-server`, and restarts
  the service without rewriting the config.
- `snell-migrate.sh`: migration script for an existing manual install. It keeps
  the current binary, port, and PSK, restricts config permissions to `600`, adds
  the repo's systemd hardening settings, backs up changed files, and supports
  `--dry-run`.
- `version`: the Snell server version string consumed by the deploy and upgrade
  scripts. Expected format is `v<major>[.<minor>...]`, for example `v5.0.1`.

## Target Environment

These scripts are intended to run as root on Debian/Ubuntu-like Linux systems.
They call tools such as `apt-get`, `curl`, `wget`, `unzip`, `install`,
`systemctl`, and sometimes `systemd-analyze`.

Do not run the deployment, upgrade, or migration scripts directly on a macOS
development machine. Local validation should normally be limited to static checks
such as:

```bash
bash -n snell-deploy.sh
bash -n snell-upgrade.sh
bash -n snell-migrate.sh
```

For behavior testing, use an isolated Linux VM/container with systemd or a
purpose-built test harness. Be careful: the scripts intentionally write to
`/usr/local/bin`, `/etc/snell`, and `/etc/systemd/system`.

## Coding Style

Keep the existing Bash style unless there is a strong reason to change it:

- Start scripts with `#!/usr/bin/env bash` and `set -euo pipefail`.
- Keep configuration constants near the top under a `# --- Config ---` banner.
- Use small helper functions such as `info`, `warn`, `error`, `usage`, and
  validation helpers.
- Quote variable expansions, use `local` inside functions, and prefer explicit
  error messages through `error`.
- Parse CLI arguments with a `while [[ $# -gt 0 ]]; do case "$1" in ... esac`
  loop.
- Use `trap cleanup EXIT` with a `WORKDIR` created by `mktemp -d` for downloaded
  or generated temporary files.
- Preserve the section-banner style already used in the scripts.
- Avoid introducing dependencies that are not already installed by the scripts
  unless the install step and failure behavior are updated too.

## Operational Conventions

- Deployment and upgrade fetch the latest version from:
  `https://github.com/sam-sun00/snell-script/raw/refs/heads/main/version`
- Snell downloads come from:
  `https://dl.nssurge.com/snell`
- The installed binary path is `/usr/local/bin/snell-server`.
- The config path is `/etc/snell/snell-server.conf`.
- The service path is `/etc/systemd/system/snell-server.service`.
- New deployments generate a random port in the inclusive range `10000-40000`.
- New deployments generate a 32-character alphanumeric PSK from `/dev/urandom`.
- The Snell config contains sensitive PSK material; keep permissions at `600`
  and avoid adding logs or debug output that expose secrets unnecessarily.
- The systemd hardening settings currently expected by this repo are:
  `NoNewPrivileges=true`, `ProtectSystem=strict`, `ProtectHome=true`, and
  `ReadWritePaths=/etc/snell`.

## Change Guidance

- Preserve existing installs unless the user explicitly asks to regenerate or
  replace config. `snell-upgrade.sh` should not change port or PSK.
- Migration should be conservative: back up files before changing them, keep
  `--dry-run` accurate, and do not reinstall Snell.
- When changing systemd unit generation or migration logic, make deploy and
  migrate agree on the desired hardening settings.
- When changing version handling, keep the validation strict enough to catch bad
  remote content before constructing a download URL.
- When changing port or PSK generation, avoid modulo bias where practical and
  preserve the current port range unless asked otherwise.
- Treat untracked or modified files as user work. Do not revert them unless the
  user explicitly asks.

## Validation Checklist

Before handing off changes, run the checks that make sense for the edit:

```bash
bash -n snell-deploy.sh
bash -n snell-upgrade.sh
bash -n snell-migrate.sh
```

If a Linux/systemd environment is available, also exercise:

- `sudo bash snell-deploy.sh --help`
- `sudo bash snell-upgrade.sh --help`
- `sudo bash snell-migrate.sh --help`
- `sudo bash snell-migrate.sh --dry-run`

For any change that touches service generation, verify the resulting unit with
`systemd-analyze verify` on a Linux host where systemd is available.
