#!/usr/bin/env bash
#
# clean2clone.sh
# Prepare Ubuntu 24.04 LTS / Debian 13 for cloning as a Proxmox VE VM template.
#
# Author: Joan Puiggali aka kopernix
# Copyright (c) 2026 Joan Puiggali aka kopernix
# Repository: https://github.com/kopernix/clean2clone
# License: MIT
#
# No cloud-init. No custom first-boot service.
#
# The only persistent integration installed by this script is a small systemd
# drop-in for ssh.service which runs "ssh-keygen -A" before "sshd -t".
# This ensures that clones whose inherited SSH host keys were removed can
# start OpenSSH normally and receive fresh host keys automatically.
#
# Run this as the LAST action before powering off the golden VM.
#

set -Eeuo pipefail
IFS=$'\n\t'

VERSION="1.0.1"
AUTO_POWEROFF=0
ASSUME_YES=0

SSH_DROPIN_DIR="/etc/systemd/system/ssh.service.d"
SSH_DROPIN_FILE="${SSH_DROPIN_DIR}/10-generate-hostkeys.conf"

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    C_GREEN=$'\033[32m'
    C_RED=$'\033[31m'
    C_YELLOW=$'\033[33m'
    C_RESET=$'\033[0m'
else
    C_GREEN=""
    C_RED=""
    C_YELLOW=""
    C_RESET=""
fi

SUMMARY=()
OK_COUNT=0
FAIL_COUNT=0
CURRENT_STEP="Starting"
SUMMARY_PRINTED=0

log()  { printf '\n==> %s\n' "$*"; }
warn() { printf '\nWARNING: %s\n' "$*" >&2; }

record_ok() {
    SUMMARY+=("OK|$1")
    OK_COUNT=$((OK_COUNT + 1))
}

record_fail() {
    SUMMARY+=("FAIL|$1")
    FAIL_COUNT=$((FAIL_COUNT + 1))
}

print_summary() {
    [[ "$SUMMARY_PRINTED" -eq 1 ]] && return 0
    SUMMARY_PRINTED=1

    printf '\n%s\n' '===================================================================='
    printf ' clean2clone verification summary\n'
    printf '%s\n' '===================================================================='

    local result status detail
    for result in "${SUMMARY[@]}"; do
        IFS='|' read -r status detail <<< "$result"
        if [[ "$status" == "OK" ]]; then
            printf ' %s[OK]%s   %s\n' "$C_GREEN" "$C_RESET" "$detail"
        else
            printf ' %s[FAIL]%s %s\n' "$C_RED" "$C_RESET" "$detail"
        fi
    done

    if [[ "$FAIL_COUNT" -eq 0 ]]; then
        printf '\n %sResult: %d checks passed%s\n' "$C_GREEN" "$OK_COUNT" "$C_RESET"
    else
        printf '\n %sResult: %d passed, %d failed%s\n' "$C_RED" "$OK_COUNT" "$FAIL_COUNT" "$C_RESET"
    fi
    printf '%s\n\n' '===================================================================='
}

die() {
    printf '\nERROR: %s\n' "$*" >&2
    record_fail "${CURRENT_STEP}: $*"
    print_summary
    exit 1
}

on_error() {
    local rc=$?
    if [[ "$SUMMARY_PRINTED" -eq 0 ]]; then
        record_fail "${CURRENT_STEP} (command failed: ${BASH_COMMAND})"
        print_summary
    fi
    exit "$rc"
}

trap on_error ERR

usage() {
    cat <<EOF
clean2clone ${VERSION}

Usage:
  sudo $0 [options]

Options:
  --poweroff     Power off automatically after sanitizing.
  -y, --yes      Skip interactive confirmation.
  --version      Show version.
  -h, --help     Show this help.

Recommended:
  sudo $0 --poweroff
EOF
}

for arg in "$@"; do
    case "$arg" in
        --poweroff) AUTO_POWEROFF=1 ;;
        -y|--yes)   ASSUME_YES=1 ;;
        --version)  echo "$VERSION"; exit 0 ;;
        -h|--help)  usage; exit 0 ;;
        *)          die "Unknown option: $arg" ;;
    esac
done

[[ $EUID -eq 0 ]] || die "Run this script as root."

# ---------------------------------------------------------------------------
# Basic environment validation
# ---------------------------------------------------------------------------

[[ -r /etc/os-release ]] || die "/etc/os-release not found."
# shellcheck disable=SC1091
. /etc/os-release
CURRENT_STEP="Validating operating system"

case "${ID:-}:${VERSION_ID:-}" in
    ubuntu:24.04|debian:13)
        ;;
    *)
        warn "Validated target systems are Ubuntu 24.04 LTS and Debian 13."
        warn "Detected: ${PRETTY_NAME:-unknown}"
        ;;
esac
record_ok "Operating system check completed (${PRETTY_NAME:-unknown})"

if command -v systemd-detect-virt >/dev/null 2>&1; then
    VIRT="$(systemd-detect-virt 2>/dev/null || true)"
    case "$VIRT" in
        lxc|openvz|docker|podman|systemd-nspawn)
            die "Container detected (${VIRT}). This script is for a full Proxmox QEMU/KVM VM."
            ;;
    esac
fi

[[ -d /run/systemd/system ]] || die "systemd is not running."
record_ok "Full systemd VM environment detected"

# ---------------------------------------------------------------------------
# Confirmation
# ---------------------------------------------------------------------------

if [[ "$ASSUME_YES" -ne 1 ]]; then
    cat <<'EOF'

This will sanitize THIS VM for use as a Proxmox template.

It will remove:
  - the current machine-id
  - SSH server host keys
  - systemd random seed
  - systemd credential secret
  - DHCP lease state where applicable
  - logs, temporary files, APT cache and shell history

It will NOT modify:
  - hostname
  - users or passwords
  - authorized_keys
  - network configuration
  - filesystem UUID/PARTUUID
  - disk partitioning
  - qemu-guest-agent configuration

Deleting the systemd credential secret invalidates credentials previously
encrypted against this machine. Do not continue if this VM uses them.

DO NOT run this on a production server.

EOF
    read -r -p "Type CLEAN2CLONE to continue: " answer
    [[ "$answer" == "CLEAN2CLONE" ]] || die "Cancelled."
fi
record_ok "Sanitization confirmation accepted"

# ---------------------------------------------------------------------------
# OpenSSH
# ---------------------------------------------------------------------------

if dpkg-query -W -f='${Status}' openssh-server 2>/dev/null | grep -q '^install ok installed$'; then
    CURRENT_STEP="Preparing OpenSSH privilege separation directory"
    install -d -m 0755 /run/sshd
    [[ -d /run/sshd ]] || die "Unable to create /run/sshd."
    record_ok "OpenSSH privilege separation directory ready"

    CURRENT_STEP="Validating current OpenSSH configuration"
    log "Validating current OpenSSH configuration"
    /usr/sbin/sshd -t
    record_ok "OpenSSH configuration valid"

    # ssh-keygen -A only regenerates the standard host-key paths. Refuse to
    # sanitize an installation that depends on a custom HostKey path.
    while IFS= read -r host_key; do
        case "$host_key" in
            /etc/ssh/ssh_host_rsa_key|\
            /etc/ssh/ssh_host_ecdsa_key|\
            /etc/ssh/ssh_host_ed25519_key)
                ;;
            *)
                die "Custom OpenSSH HostKey path detected: ${host_key}"
                ;;
        esac
    done < <(/usr/sbin/sshd -T | awk '$1 == "hostkey" { print $2 }')
    record_ok "OpenSSH host-key paths are supported"

    log "Installing OpenSSH host-key generation drop-in"
    mkdir -p "$SSH_DROPIN_DIR"
    cat > "$SSH_DROPIN_FILE" <<'EOF'
# Installed by clean2clone.
#
# Ubuntu/Debian's ssh.service normally validates sshd before starting it.
# A cloned golden image intentionally has no inherited SSH host keys, so
# generate any missing default host keys first.
#
# ssh-keygen -A is idempotent: existing host keys are never replaced.
[Service]
ExecStartPre=
ExecStartPre=/usr/bin/ssh-keygen -A
ExecStartPre=/usr/sbin/sshd -t
EOF

    chmod 0644 "$SSH_DROPIN_FILE"
    systemctl daemon-reload

    command -v systemd-analyze >/dev/null 2>&1 ||
        die "systemd-analyze is required to validate ssh.service."

    systemd-analyze verify ssh.service >/dev/null 2>&1 ||
        die "Unable to validate ssh.service after installing the drop-in."
    record_ok "OpenSSH systemd drop-in installed and validated"

    log "Removing inherited OpenSSH host keys"
    rm -f /etc/ssh/ssh_host_*
    if compgen -G "/etc/ssh/ssh_host_*" >/dev/null; then
        die "Some inherited OpenSSH host keys could not be removed."
    fi
    record_ok "Inherited OpenSSH host keys removed"
else
    log "openssh-server is not installed; no SSH host keys to sanitize"
    record_ok "OpenSSH not installed; no host keys required"
fi

# ---------------------------------------------------------------------------
# machine-id
# ---------------------------------------------------------------------------

log "Resetting systemd/D-Bus machine identity"
CURRENT_STEP="Resetting systemd/D-Bus machine identity"

# An existing empty file causes systemd to establish a new machine-id at boot
# without making ConditionFirstBoot=yes true.
: > /etc/machine-id
chmod 0444 /etc/machine-id

rm -f /var/lib/dbus/machine-id
mkdir -p /var/lib/dbus
ln -s /etc/machine-id /var/lib/dbus/machine-id
[[ ! -s /etc/machine-id ]] || die "/etc/machine-id is not empty after reset."
[[ -L /var/lib/dbus/machine-id ]] || die "/var/lib/dbus/machine-id is not a symlink."
record_ok "Machine-id reset and D-Bus link verified"

# ---------------------------------------------------------------------------
# Cryptographic per-machine state
# ---------------------------------------------------------------------------

log "Removing systemd random seed"
CURRENT_STEP="Removing systemd random seed"

# Stopping this oneshot service saves its current seed. Remove that saved file
# only after the service is fully inactive so shutdown cannot recreate it.
if systemctl is-active --quiet systemd-random-seed.service; then
    systemctl stop systemd-random-seed.service ||
        die "Unable to stop systemd-random-seed.service."
fi

if systemctl is-active --quiet systemd-random-seed.service; then
    die "systemd-random-seed.service is still active."
fi

rm -f /var/lib/systemd/random-seed
[[ ! -e /var/lib/systemd/random-seed ]] || die "The systemd random seed still exists."
record_ok "Systemd random seed removed"

# systemd-boot may maintain an additional seed on the EFI System Partition.
if [[ -d /sys/firmware/efi ]]; then
    if mountpoint -q /boot/efi; then
        rm -f /boot/efi/loader/random-seed
    else
        warn "UEFI detected but /boot/efi is not mounted; the EFI random seed was not checked."
    fi
fi

log "Removing systemd machine credential secret"
CURRENT_STEP="Removing systemd machine credential secret"
rm -f /var/lib/systemd/credential.secret
[[ ! -e /var/lib/systemd/credential.secret ]] || die "The credential secret still exists."
record_ok "Systemd credential secret removed"

# ---------------------------------------------------------------------------
# Network client state
# ---------------------------------------------------------------------------

log "Removing persistent DHCP lease state"
CURRENT_STEP="Removing persistent DHCP lease state"

# ISC dhclient / Debian-style state.
rm -f /var/lib/dhcp/dhclient*.leases 2>/dev/null || true
rm -f /var/lib/dhcp/dhclient*.leases~ 2>/dev/null || true

# NetworkManager lease files, if NetworkManager is installed/used.
rm -f /var/lib/NetworkManager/*.lease 2>/dev/null || true
rm -f /var/lib/NetworkManager/*lease* 2>/dev/null || true

# systemd-networkd lease state is below /run and does not persist across
# poweroff. Network configuration itself is intentionally left untouched.
if compgen -G "/var/lib/dhcp/dhclient*.leases" >/dev/null ||
   compgen -G "/var/lib/dhcp/dhclient*.leases~" >/dev/null ||
   compgen -G "/var/lib/NetworkManager/*.lease" >/dev/null ||
   compgen -G "/var/lib/NetworkManager/*lease*" >/dev/null; then
    die "Some persistent DHCP lease files could not be removed."
fi
record_ok "Persistent DHCP lease state removed"

# ---------------------------------------------------------------------------
# Package/cache/temp/log cleanup
# ---------------------------------------------------------------------------

log "Cleaning APT cache"
CURRENT_STEP="Cleaning APT cache"
apt-get clean
if compgen -G "/var/cache/apt/archives/*.deb" >/dev/null; then
    die "APT package archives remain in the cache."
fi
record_ok "APT cache cleaned"

log "Cleaning systemd journal"
CURRENT_STEP="Cleaning systemd journal"

# Close persistent journal files and continue logging temporarily below /run.
# This avoids truncating binary journal files while journald has them open.
journalctl --relinquish-var >/dev/null

if [[ -d /var/log/journal ]]; then
    find /var/log/journal -xdev -mindepth 1 -delete
fi
if [[ -d /var/log/journal ]] && find /var/log/journal -xdev -type f -print -quit | grep -q .; then
    die "Persistent journal files remain."
fi
record_ok "Systemd journal cleaned"

log "Truncating remaining regular log files"
CURRENT_STEP="Truncating remaining regular log files"
if [[ -d /var/log ]]; then
    find /var/log -xdev \
        -path /var/log/journal -prune -o \
        -type f -exec truncate -s 0 -- {} +
fi
record_ok "Regular log files truncated"

log "Cleaning temporary directories"
CURRENT_STEP="Cleaning temporary directories"
for dir in /tmp /var/tmp; do
    if [[ -d "$dir" ]]; then
        find "$dir" -xdev -mindepth 1 -delete 2>/dev/null || true
    fi
done
record_ok "Temporary directories cleaned"

log "Cleaning shell histories"
CURRENT_STEP="Cleaning shell histories"
rm -f /root/.bash_history /root/.zsh_history 2>/dev/null || true

if [[ -d /home ]]; then
    find /home -xdev -maxdepth 2 -type f \
        \( -name '.bash_history' -o -name '.zsh_history' \) \
        -delete 2>/dev/null || true
fi
record_ok "Shell histories removed"

# ---------------------------------------------------------------------------
# Finish
# ---------------------------------------------------------------------------

log "Flushing filesystem buffers"
CURRENT_STEP="Flushing filesystem buffers"
sync
record_ok "Filesystem buffers flushed"

print_summary

cat <<'EOF'

====================================================================
 clean2clone completed
====================================================================

The VM is ready to be powered off and converted to a Proxmox template.

Intentionally NOT changed:
  * hostname
  * filesystem UUID / PARTUUID
  * disk identifiers / partition table
  * MAC address (Proxmox creates the clone's virtual NIC identity)
  * authorized_keys
  * users/passwords
  * network configuration

On each clone:
  * systemd will establish a new machine-id.
  * OpenSSH will generate fresh host keys automatically before sshd starts.

IMPORTANT:
  Do not reboot this golden VM and then turn it back into a template without
  running clean2clone again, because booting it regenerates unique state.
====================================================================

EOF

if [[ "$AUTO_POWEROFF" -eq 1 ]]; then
    log "Powering off"
    systemctl poweroff
else
    warn "Power the VM off now. Do NOT reboot it before converting it to a template."
fi
