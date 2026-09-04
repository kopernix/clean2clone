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
# The only persistent integrations installed by this script are small systemd
# drop-ins for ssh.service and ssh.socket. They generate
# missing host keys before OpenSSH starts or its socket begins listening.
#
# Run this as the LAST action before powering off the golden VM.
#

set -Eeuo pipefail
IFS=$'\n\t'

VERSION="1.2.2"
AUTO_POWEROFF=0
ASSUME_YES=0
CHECK_ONLY=0

SSH_DROPIN_DIR="/etc/systemd/system/ssh.service.d"
SSH_DROPIN_FILE="${SSH_DROPIN_DIR}/10-generate-hostkeys.conf"
SSH_SOCKET_DROPIN_DIR="/etc/systemd/system/ssh.socket.d"
SSH_SOCKET_DROPIN_FILE="${SSH_SOCKET_DROPIN_DIR}/10-generate-hostkeys.conf"

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
WARN_COUNT=0
FAIL_COUNT=0
CURRENT_STEP="Starting"
SUMMARY_PRINTED=0
SUMMARY_TITLE="clean2clone verification summary"

log()  { printf '\n==> %s\n' "$*"; }
warn() { printf '\nWARNING: %s\n' "$*" >&2; }

validate_sshd() {
    local output
    if ! output="$(/usr/sbin/sshd -t 2>&1)"; then
        output="${output//$'\n'/; }"
        die "OpenSSH configuration validation failed${output:+: ${output}}"
    fi
}

record_ok() {
    SUMMARY+=("OK|$1")
    OK_COUNT=$((OK_COUNT + 1))
}

record_fail() {
    SUMMARY+=("FAIL|$1")
    FAIL_COUNT=$((FAIL_COUNT + 1))
}

record_warn() {
    SUMMARY+=("WARN|$1")
    WARN_COUNT=$((WARN_COUNT + 1))
}

print_summary() {
    local force="${1:-0}"
    [[ "$SUMMARY_PRINTED" -eq 1 && "$force" -ne 1 ]] && return 0
    SUMMARY_PRINTED=1

    printf '\n%s\n' '===================================================================='
    printf ' %s\n' "$SUMMARY_TITLE"
    printf '%s\n' '===================================================================='

    local result status detail
    for result in "${SUMMARY[@]}"; do
        IFS='|' read -r status detail <<< "$result"
        case "$status" in
            OK)   printf ' %s[OK]%s   %s\n' "$C_GREEN" "$C_RESET" "$detail" ;;
            WARN) printf ' %s[WARN]%s %s\n' "$C_YELLOW" "$C_RESET" "$detail" ;;
            FAIL) printf ' %s[FAIL]%s %s\n' "$C_RED" "$C_RESET" "$detail" ;;
        esac
    done

    if [[ "$FAIL_COUNT" -eq 0 ]]; then
        printf '\n %sResult: %d passed, %d warnings%s\n' \
            "$C_GREEN" "$OK_COUNT" "$WARN_COUNT" "$C_RESET"
    else
        printf '\n %sResult: %d passed, %d warnings, %d failed%s\n' \
            "$C_RED" "$OK_COUNT" "$WARN_COUNT" "$FAIL_COUNT" "$C_RESET"
    fi
    printf '%s\n\n' '===================================================================='
}

die() {
    printf '\nERROR: %s\n' "$*" >&2
    record_fail "${CURRENT_STEP}: $*"
    print_summary 1
    exit 1
}

on_error() {
    local rc=$?
    local failed_command="$BASH_COMMAND"
    trap - ERR
    record_fail "${CURRENT_STEP} (command failed: ${failed_command})"
    print_summary 1
    exit "$rc"
}

trap on_error ERR

check_result() {
    local description="$1"
    shift

    if "$@"; then
        record_ok "$description"
    else
        record_fail "$description"
    fi
}

check_machine_identity() {
    local machine_id dbus_machine_id

    if [[ -r /etc/machine-id ]] &&
       machine_id="$(tr -d '\n' < /etc/machine-id)" &&
       [[ "$machine_id" =~ ^[0-9a-f]{32}$ ]] &&
       [[ "$machine_id" != "00000000000000000000000000000000" ]]; then
        record_ok "A valid machine-id was established after boot"
    else
        record_fail "A valid machine-id was not established after boot"
    fi

    if [[ -L /var/lib/dbus/machine-id ]] &&
       [[ "$(readlink /var/lib/dbus/machine-id 2>/dev/null)" == "/etc/machine-id" ]] &&
       dbus_machine_id="$(tr -d '\n' < /var/lib/dbus/machine-id 2>/dev/null)" &&
       [[ -n "${machine_id:-}" && "$dbus_machine_id" == "$machine_id" ]]; then
        record_ok "D-Bus machine-id matches the system machine-id"
    else
        record_fail "D-Bus machine-id does not match the system machine-id"
    fi
}

check_ssh_host_keys() {
    local host_key mode owner derived public
    local -a host_key_paths=(
        /etc/ssh/ssh_host_rsa_key
        /etc/ssh/ssh_host_ecdsa_key
        /etc/ssh/ssh_host_ed25519_key
    )
    local keys_ok=1

    for host_key in "${host_key_paths[@]}"; do
        if [[ ! -s "$host_key" || ! -s "${host_key}.pub" ]]; then
            keys_ok=0
            continue
        fi

        owner="$(stat -c '%U:%G' "$host_key" 2>/dev/null || true)"
        mode="$(stat -c '%a' "$host_key" 2>/dev/null || true)"
        if [[ "$owner" != "root:root" || "$mode" != "600" ]]; then
            keys_ok=0
            continue
        fi

        if ! derived="$(ssh-keygen -y -f "$host_key" 2>/dev/null)"; then
            keys_ok=0
            continue
        fi
        public="$(awk 'NR == 1 { print $1 " " $2 }' "${host_key}.pub" 2>/dev/null || true)"
        [[ "$derived" == "$public" ]] || keys_ok=0
    done

    if [[ "$keys_ok" -eq 1 ]]; then
        record_ok "OpenSSH standard host key pairs exist, match, and have safe permissions"
    else
        record_fail "One or more OpenSSH standard host key pairs are missing, invalid, or unsafe"
    fi
}

check_openssh_integrity() {
    local load_state service_pre socket_pre output activation_ok=0

    if ! dpkg-query -W -f='${Status}' openssh-server 2>/dev/null |
        grep -q '^install ok installed$'; then
        record_ok "OpenSSH is not installed; SSH checks are not applicable"
        return
    fi

    if [[ -r "$SSH_DROPIN_FILE" ]] &&
       grep -Fxq 'ExecStartPre=/usr/bin/ssh-keygen -A' "$SSH_DROPIN_FILE" &&
       grep -Fxq 'ExecStartPre=/usr/sbin/sshd -t' "$SSH_DROPIN_FILE"; then
        record_ok "OpenSSH service host-key drop-in is present"
    else
        record_fail "OpenSSH service host-key drop-in is missing or invalid"
    fi

    if service_pre="$(systemctl show ssh.service --property=ExecStartPre --value 2>/dev/null)" &&
       grep -Fq '/usr/bin/ssh-keygen -A' <<< "$service_pre" &&
       grep -Fq '/usr/sbin/sshd -t' <<< "$service_pre"; then
        record_ok "OpenSSH service uses the expected pre-start commands"
    else
        record_fail "OpenSSH service does not use the expected pre-start commands"
    fi

    if [[ -r "$SSH_SOCKET_DROPIN_FILE" ]] &&
       grep -Fxq 'ExecStartPre=/usr/bin/ssh-keygen -A' "$SSH_SOCKET_DROPIN_FILE"; then
        record_ok "OpenSSH socket host-key drop-in is present"
    else
        record_fail "OpenSSH socket host-key drop-in is missing or invalid"
    fi

    load_state="$(systemctl show ssh.socket --property=LoadState --value 2>/dev/null || true)"
    if [[ "$load_state" == "loaded" ]]; then
        if socket_pre="$(systemctl show ssh.socket --property=ExecStartPre --value 2>/dev/null)" &&
           grep -Fq '/usr/bin/ssh-keygen -A' <<< "$socket_pre"; then
            record_ok "OpenSSH socket uses host-key generation during activation"
        else
            record_fail "OpenSSH socket does not use the installed host-key generation command"
        fi
    else
        record_ok "OpenSSH socket activation is not installed; service activation applies"
    fi

    if systemctl is-active --quiet ssh.service || systemctl is-active --quiet ssh.socket; then
        activation_ok=1
    fi
    if [[ "$activation_ok" -eq 1 ]] &&
       ! systemctl is-failed --quiet ssh.service &&
       ! systemctl is-failed --quiet ssh.socket; then
        record_ok "OpenSSH service or socket is active and neither unit is failed"
    else
        record_fail "OpenSSH has no healthy active service or socket"
    fi

    if systemd-analyze verify ssh.service >/dev/null 2>&1 &&
       { [[ "$load_state" != "loaded" ]] ||
         systemd-analyze verify ssh.socket >/dev/null 2>&1; }; then
        record_ok "OpenSSH systemd units pass structural verification"
    else
        record_fail "OpenSSH systemd unit verification failed"
    fi

    check_ssh_host_keys

    # Do not create /run/sshd or start anything in check mode. If the runtime
    # directory already exists, perform the strongest direct configuration
    # test. With an inactive socket-activated service its absence is valid.
    if [[ -d /run/sshd ]]; then
        if output="$(/usr/sbin/sshd -t 2>&1)"; then
            record_ok "OpenSSH direct configuration test passed"
        else
            record_fail "OpenSSH direct configuration test failed: ${output//$'\n'/; }"
        fi
    elif systemctl is-active --quiet ssh.socket; then
        record_ok "OpenSSH runtime directory is correctly deferred to socket activation"
    else
        record_fail "OpenSSH runtime directory is missing without active socket activation"
    fi
}

check_random_state() {
    local owner mode

    if [[ -s /var/lib/systemd/random-seed ]]; then
        owner="$(stat -c '%U:%G' /var/lib/systemd/random-seed 2>/dev/null || true)"
        mode="$(stat -c '%a' /var/lib/systemd/random-seed 2>/dev/null || true)"
        if [[ "$owner" == "root:root" && "$mode" == "600" ]] &&
           ! systemctl is-failed --quiet systemd-random-seed.service; then
            record_ok "Systemd random seed was re-established securely"
        else
            record_fail "Systemd random seed has unsafe metadata or its service failed"
        fi
    else
        record_fail "Systemd random seed was not re-established after boot"
    fi

    if [[ -d /sys/firmware/efi ]] && mountpoint -q /boot/efi &&
       [[ -e /boot/efi/loader/random-seed ]]; then
        if [[ -s /boot/efi/loader/random-seed ]]; then
            record_ok "EFI random seed exists and is non-empty"
        else
            record_fail "EFI random seed exists but is empty"
        fi
    else
        record_ok "EFI random seed is not applicable or not managed on this system"
    fi

    if [[ ! -e /var/lib/systemd/credential.secret ]]; then
        record_ok "Systemd credential secret remains absent until needed"
    else
        owner="$(stat -c '%U:%G' /var/lib/systemd/credential.secret 2>/dev/null || true)"
        mode="$(stat -c '%a' /var/lib/systemd/credential.secret 2>/dev/null || true)"
        if [[ -s /var/lib/systemd/credential.secret &&
              "$owner" == "root:root" && "$mode" == "600" ]]; then
            record_ok "Systemd credential secret was recreated securely"
        else
            record_fail "Systemd credential secret exists with invalid content or metadata"
        fi
    fi
}

check_network_state() {
    local unit load_state failed=0

    if ip -o link show up | awk '$2 != "lo:" { found=1 } END { exit !found }'; then
        record_ok "At least one non-loopback network interface is up"
    else
        record_fail "No non-loopback network interface is up"
    fi

    if ip -o addr show up scope global | grep -q .; then
        record_ok "At least one global-scope IP address is configured"
    else
        record_fail "No global-scope IP address is configured"
    fi

    for unit in NetworkManager.service systemd-networkd.service networking.service; do
        load_state="$(systemctl show "$unit" --property=LoadState --value 2>/dev/null || true)"
        if [[ "$load_state" == "loaded" ]] && systemctl is-failed --quiet "$unit"; then
            failed=1
        fi
    done
    if [[ "$failed" -eq 0 ]]; then
        record_ok "Installed network-management services are not failed"
    else
        record_fail "An installed network-management service is failed"
    fi
}

check_runtime_and_logs() {
    local dir metadata

    if systemctl is-active --quiet systemd-journald.service &&
       journalctl --verify >/dev/null 2>&1; then
        record_ok "Systemd journal service and journal files are healthy"
    else
        record_fail "Systemd journal service or journal verification failed"
    fi

    if [[ -d /var/log && -r /var/log && -w /var/log ]]; then
        record_ok "System log directory is accessible"
    else
        record_fail "System log directory is not accessible"
    fi

    for dir in /tmp /var/tmp; do
        metadata="$(stat -c '%U:%G:%a' "$dir" 2>/dev/null || true)"
        if [[ -d "$dir" && "$metadata" == "root:root:1777" ]]; then
            record_ok "${dir} exists with root:root mode 1777"
        else
            record_fail "${dir} is missing or has incorrect ownership or permissions"
        fi
    done

    if [[ -d /root && -d /home ]]; then
        record_ok "Root and user home directory roots remain present"
    else
        record_fail "Root or user home directory root is missing"
    fi
}

run_integrity_check() {
    local apt_output dpkg_output hostname_value

    SUMMARY_TITLE="clean2clone post-reboot integrity check"
    log "Running non-destructive post-reboot integrity checks"

    check_machine_identity
    check_openssh_integrity
    check_random_state
    check_network_state

    if apt_output="$(apt-get check \
        -o Debug::NoLocking=1 \
        -o Dir::Cache::pkgcache= \
        -o Dir::Cache::srcpkgcache= 2>&1)"; then
        record_ok "APT dependency check passed"
    else
        record_fail "APT dependency check failed: ${apt_output//$'\n'/; }"
    fi

    if dpkg_output="$(dpkg --audit 2>&1)" && [[ -z "$dpkg_output" ]]; then
        record_ok "DPKG reports no partially installed packages"
    else
        record_fail "DPKG audit reported a problem: ${dpkg_output//$'\n'/; }"
    fi

    check_runtime_and_logs

    hostname_value="$(hostnamectl --static 2>/dev/null || true)"
    if [[ -n "$hostname_value" && -s /etc/hostname ]]; then
        record_ok "System hostname remains configured"
    else
        record_fail "System hostname configuration is missing"
    fi

    print_summary
    if [[ "$FAIL_COUNT" -eq 0 ]]; then
        printf 'The post-reboot integrity check passed. No repair action was performed.\n'
        return 0
    fi

    printf 'The post-reboot integrity check failed. No repair action was performed.\n' >&2
    return 1
}

usage() {
    cat <<EOF
clean2clone ${VERSION}

Usage:
  sudo $0 [options]

Options:
  --check        Run a non-destructive post-reboot integrity check.
  --poweroff     Power off automatically after sanitizing.
  -y, --yes      Skip interactive confirmation.
  --version      Show version.
  -h, --help     Show this help.

Recommended:
  sudo $0 --poweroff

Post-reboot check:
  sudo $0 --check
EOF
}

for arg in "$@"; do
    case "$arg" in
        --check)    CHECK_ONLY=1 ;;
        --poweroff) AUTO_POWEROFF=1 ;;
        -y|--yes)   ASSUME_YES=1 ;;
        --version)  echo "$VERSION"; exit 0 ;;
        -h|--help)  usage; exit 0 ;;
        *)          die "Unknown option: $arg" ;;
    esac
done

if [[ "$CHECK_ONLY" -eq 1 &&
      ( "$AUTO_POWEROFF" -eq 1 || "$ASSUME_YES" -eq 1 ) ]]; then
    die "--check cannot be combined with --poweroff or --yes."
fi

[[ $EUID -eq 0 ]] || die "Run this script as root."

# ---------------------------------------------------------------------------
# Basic environment validation
# ---------------------------------------------------------------------------

CURRENT_STEP="Validating operating system"
[[ -r /etc/os-release ]] || die "/etc/os-release not found."
# shellcheck disable=SC1091
. /etc/os-release

case "${ID:-}:${VERSION_ID:-}" in
    ubuntu:24.04|debian:13)
        record_ok "Supported operating system detected (${PRETTY_NAME:-unknown})"
        ;;
    *)
        warn "Validated target systems are Ubuntu 24.04 LTS and Debian 13."
        warn "Detected: ${PRETTY_NAME:-unknown}"
        record_warn "Unvalidated operating system detected (${PRETTY_NAME:-unknown})"
        ;;
esac

CURRENT_STEP="Validating virtualization environment"
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

if [[ "$CHECK_ONLY" -eq 1 ]]; then
    if run_integrity_check; then
        exit 0
    else
        exit 1
    fi
fi

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
    install -d -o root -g root -m 0755 /run/sshd
    [[ "$(stat -c '%U:%G:%a' /run/sshd)" == "root:root:755" ]] ||
        die "/run/sshd has unexpected ownership or permissions."
    record_ok "OpenSSH privilege separation directory ready"

    # A previous clean2clone run may already have removed all host keys. On
    # Ubuntu, socket activation also means ssh.service may not have run merely
    # because the VM rebooted. Generate only missing default keys so this
    # script remains safe to run again; all keys are removed later.
    CURRENT_STEP="Preparing OpenSSH host keys for validation"
    log "Preparing OpenSSH host keys for validation"
    /usr/bin/ssh-keygen -A >/dev/null
    record_ok "OpenSSH host keys available for validation"

    CURRENT_STEP="Validating current OpenSSH configuration"
    log "Validating current OpenSSH configuration"
    validate_sshd
    record_ok "OpenSSH configuration valid"

    # ssh-keygen -A only regenerates the standard host-key paths. Refuse to
    # sanitize an installation that depends on a custom HostKey path.
    CURRENT_STEP="Checking OpenSSH host-key paths"
    SSHD_EFFECTIVE_CONFIG="$(/usr/sbin/sshd -T)" ||
        die "Unable to read the effective OpenSSH configuration."
    HOST_KEY_PATHS="$(awk '$1 == "hostkey" { print $2 }' <<< "$SSHD_EFFECTIVE_CONFIG")" ||
        die "Unable to inspect the configured OpenSSH host-key paths."

    while IFS= read -r host_key; do
        [[ -n "$host_key" ]] || continue
        case "$host_key" in
            /etc/ssh/ssh_host_rsa_key|\
            /etc/ssh/ssh_host_ecdsa_key|\
            /etc/ssh/ssh_host_ed25519_key)
                ;;
            *)
                die "Custom OpenSSH HostKey path detected: ${host_key}"
                ;;
        esac
    done <<< "$HOST_KEY_PATHS"
    record_ok "OpenSSH host-key paths are supported"

    log "Installing OpenSSH host-key generation drop-in"
    CURRENT_STEP="Installing OpenSSH host-key generation drop-in"
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

    # Install this unconditionally with openssh-server. Unit visibility can
    # vary before the next boot; an unused drop-in is harmless on systems
    # without ssh.socket and is ready if the socket unit later becomes visible.
    mkdir -p "$SSH_SOCKET_DROPIN_DIR"
    cat > "$SSH_SOCKET_DROPIN_FILE" <<'EOF'
# Installed by clean2clone.
#
# Ubuntu may start ssh.socket at boot while deferring ssh.service until the
# first connection. Generate missing host keys before the socket listens so
# post-boot state is complete without requiring an incoming connection.
[Socket]
ExecStartPre=/usr/bin/ssh-keygen -A
EOF
    chmod 0644 "$SSH_SOCKET_DROPIN_FILE"

    systemctl daemon-reload

    command -v systemd-analyze >/dev/null 2>&1 ||
        die "systemd-analyze is required to validate ssh.service."

    systemd-analyze verify ssh.service >/dev/null 2>&1 ||
        die "Unable to validate ssh.service after installing the drop-in."

    SSH_EXEC_START_PRE="$(systemctl show ssh.service --property=ExecStartPre --value)" ||
        die "Unable to read the effective ExecStartPre commands for ssh.service."
    grep -Fq '/usr/bin/ssh-keygen -A' <<< "$SSH_EXEC_START_PRE" ||
        die "ssh.service does not contain the host-key generation command."
    grep -Fq '/usr/sbin/sshd -t' <<< "$SSH_EXEC_START_PRE" ||
        die "ssh.service does not contain the OpenSSH validation command."

    grep -Fxq 'ExecStartPre=/usr/bin/ssh-keygen -A' "$SSH_SOCKET_DROPIN_FILE" ||
        die "The ssh.socket host-key generation drop-in is invalid."

    SSH_SOCKET_LOAD_STATE="$(systemctl show ssh.socket --property=LoadState --value 2>/dev/null || true)"
    if [[ "$SSH_SOCKET_LOAD_STATE" == "loaded" ]]; then
        systemd-analyze verify ssh.socket >/dev/null 2>&1 ||
            die "Unable to validate ssh.socket after installing the drop-in."
        SSH_SOCKET_EXEC_START_PRE="$(systemctl show ssh.socket --property=ExecStartPre --value)" ||
            die "Unable to read the effective ExecStartPre commands for ssh.socket."
        grep -Fq '/usr/bin/ssh-keygen -A' <<< "$SSH_SOCKET_EXEC_START_PRE" ||
            die "ssh.socket does not contain the host-key generation command."
        record_ok "OpenSSH service and socket drop-ins installed and active commands validated"
    else
        record_ok "OpenSSH service and socket drop-ins installed; service commands validated"
    fi

    log "Removing inherited OpenSSH host keys"
    CURRENT_STEP="Removing inherited OpenSSH host keys"
    rm -f /etc/ssh/ssh_host_*
    if compgen -G "/etc/ssh/ssh_host_*" >/dev/null; then
        die "Some inherited OpenSSH host keys could not be removed."
    fi
    record_ok "Inherited OpenSSH host keys removed"

    # Exercise the exact commands used by the systemd drop-in, then remove the
    # test keys so the golden image still finishes without inherited keys.
    log "Testing fresh OpenSSH host-key generation"
    CURRENT_STEP="Testing fresh OpenSSH host-key generation"
    /usr/bin/ssh-keygen -A >/dev/null
    validate_sshd
    rm -f /etc/ssh/ssh_host_*
    if compgen -G "/etc/ssh/ssh_host_*" >/dev/null; then
        die "Generated test host keys could not be removed."
    fi
    record_ok "Fresh OpenSSH host-key generation tested; test keys removed"
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
[[ "$(stat -c '%a' /etc/machine-id)" == "444" ]] ||
    die "/etc/machine-id does not have mode 0444."
[[ -L /var/lib/dbus/machine-id ]] &&
    [[ "$(readlink /var/lib/dbus/machine-id)" == "/etc/machine-id" ]] ||
    die "/var/lib/dbus/machine-id does not point to /etc/machine-id."
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

# systemd-boot may maintain an additional seed on the EFI System Partition.
if [[ -d /sys/firmware/efi ]]; then
    if mountpoint -q /boot/efi; then
        rm -f /boot/efi/loader/random-seed
        [[ ! -e /boot/efi/loader/random-seed ]] || die "The EFI random seed still exists."
        record_ok "Systemd and EFI random seeds removed"
    else
        warn "UEFI detected but /boot/efi is not mounted; the EFI random seed was not checked."
        record_ok "Systemd random seed removed"
        record_warn "EFI random seed not checked because /boot/efi is not mounted"
    fi
else
    record_ok "Systemd random seed removed (EFI not in use)"
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
if [[ -d /var/log ]] && find /var/log -xdev \
    -path /var/log/journal -prune -o \
    -type f ! -empty -print -quit | grep -q .; then
    die "A regular log file is not empty after truncation."
fi
record_ok "Regular log files truncated"

log "Cleaning temporary directories"
CURRENT_STEP="Cleaning temporary directories"
for dir in /tmp /var/tmp; do
    if [[ -d "$dir" ]]; then
        find "$dir" -xdev -mindepth 1 -delete
        if find "$dir" -xdev -mindepth 1 -print -quit | grep -q .; then
            die "${dir} is not empty after cleanup."
        fi
    fi
done
record_ok "Temporary directories cleaned"

log "Cleaning shell histories"
CURRENT_STEP="Cleaning shell histories"
rm -f /root/.bash_history /root/.zsh_history

if [[ -d /home ]]; then
    find /home -xdev -maxdepth 2 -type f \
        \( -name '.bash_history' -o -name '.zsh_history' \) \
        -delete
fi
[[ ! -e /root/.bash_history && ! -e /root/.zsh_history ]] ||
    die "A root shell history file still exists."
if [[ -d /home ]] && find /home -xdev -maxdepth 2 -type f \
    \( -name '.bash_history' -o -name '.zsh_history' \) -print -quit | grep -q .; then
    die "A user shell history file still exists."
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
