# clean2clone Project Specification

## 1. Project identity

- Repository: <https://github.com/kopernix/clean2clone>
- Primary program: `clean2clone.sh`
- Current implemented version: `1.1.0`
- Author: Joan Puiggali aka kopernix
- Copyright: Copyright (c) 2026 Joan Puiggali aka kopernix
- License: MIT
- Implementation language: Bash
- Documentation and program output language: English

This document records the complete intended scope and the decisions behind the
current implementation so the project can be continued without access to its
original development conversation.

## 2. Purpose

`clean2clone` sanitizes machine-specific and disposable state in a prepared
golden virtual machine immediately before it is powered off and converted into
a Proxmox VE template.

Validated targets:

- Ubuntu 24.04 LTS
- Debian 13
- A full Proxmox QEMU/KVM virtual machine
- A running systemd system

The utility is intentionally modest. Its purpose is to save time in the
owner's template-preparation workflow, not to automate the whole VM lifecycle.

## 3. Operating workflow

The expected workflow is:

1. Build, configure, update, and manually validate the golden VM.
2. Make any desired template changes before running this script.
3. Run `clean2clone.sh` as root as the last action in the VM.
4. Prefer `sudo ./clean2clone.sh --poweroff` so the VM powers off immediately.
5. Convert the powered-off VM into a Proxmox template.
6. Do not boot the golden VM again before templating. If it is booted again,
   run `clean2clone` again because boot recreates unique state.

It must never be run on a production server. Containers such as LXC, OpenVZ,
Docker, Podman, and systemd-nspawn are rejected.

## 4. Command-line interface

Supported options:

| Option | Meaning |
| --- | --- |
| `--poweroff` | Request system poweroff after successful sanitization. |
| `-y`, `--yes` | Skip the interactive confirmation. |
| `--version` | Print the version and exit without sanitizing. |
| `-h`, `--help` | Print usage and exit without sanitizing. |

Without `--yes`, the user must type the exact token `CLEAN2CLONE`. Unknown
options are fatal. Root privileges are mandatory.

## 5. Required sanitization behavior

### 5.1 Environment validation

- Read `/etc/os-release`.
- Mark Ubuntu 24.04 LTS and Debian 13 as supported.
- Warn, but currently allow continuation, on another OS.
- Reject known container virtualization types.
- Require a running systemd instance through `/run/systemd/system`.

Support documentation must continue to name only platforms that have received
real end-to-end validation.

### 5.2 OpenSSH

This section only applies when the Debian package `openssh-server` is
installed.

Required behavior:

1. Create `/run/sshd` as `root:root` with mode `0755`. This is required because
   the volatile privilege-separation directory may be absent before `sshd -t`.
2. Validate the existing OpenSSH configuration with `/usr/sbin/sshd -t`.
3. Read the effective configuration with `/usr/sbin/sshd -T`.
4. Accept only standard host-key paths that `ssh-keygen -A` can recreate:
   `/etc/ssh/ssh_host_rsa_key`, `/etc/ssh/ssh_host_ecdsa_key`, and
   `/etc/ssh/ssh_host_ed25519_key`. A custom `HostKey` path is a fatal error.
5. Install `/etc/systemd/system/ssh.service.d/10-generate-hostkeys.conf` with
   mode `0644`.
6. The drop-in must clear the existing `ExecStartPre` list, then run, in order:

   ```ini
   ExecStartPre=/usr/bin/ssh-keygen -A
   ExecStartPre=/usr/sbin/sshd -t
   ```

7. Reload systemd, validate the unit with `systemd-analyze verify`, and inspect
   the effective `ExecStartPre` commands.
8. Remove every `/etc/ssh/ssh_host_*` inherited host-key file.
9. Exercise the clone behavior before completion: run `ssh-keygen -A`, validate
   with `sshd -t`, remove the generated test keys again, and verify none remain.

The systemd drop-in is the only persistent integration installed by the
project. `ssh-keygen -A` is intentionally used because it creates missing
default keys without replacing existing keys on later boots.

If OpenSSH is not installed, record a successful not-applicable result and do
not install the drop-in.

### 5.3 systemd and D-Bus machine identity

- Truncate `/etc/machine-id` to an existing empty file.
- Set its mode to `0444`.
- Replace `/var/lib/dbus/machine-id` with a symbolic link whose exact target is
  `/etc/machine-id`.

The empty file is deliberate: systemd establishes a new machine ID on the
clone's next boot without using missing-file first-boot semantics.

### 5.4 Cryptographic per-machine state

- If `systemd-random-seed.service` is active, stop it first. Stopping may save
  the current seed, so deletion must happen after the service is inactive.
- Verify the service is inactive.
- Remove `/var/lib/systemd/random-seed` and verify absence.
- On UEFI systems with `/boot/efi` mounted, remove and verify
  `/boot/efi/loader/random-seed`.
- On UEFI systems where `/boot/efi` is not mounted, report `WARN`; do not claim
  that the EFI seed was checked.
- Remove `/var/lib/systemd/credential.secret` and verify absence.

Removing the credential secret invalidates credentials encrypted against that
machine. This risk must remain in the interactive warning.

### 5.5 Network client state

Remove and verify the absence of persistent DHCP lease files matching:

- `/var/lib/dhcp/dhclient*.leases`
- `/var/lib/dhcp/dhclient*.leases~`
- `/var/lib/NetworkManager/*.lease`
- `/var/lib/NetworkManager/*lease*`

systemd-networkd leases live below `/run` and do not persist across poweroff,
so no systemd-networkd configuration or runtime-specific cleanup is required.
Do not edit Netplan, NetworkManager connections, `/etc/network/interfaces`, or
files below `/etc/systemd/network`.

### 5.6 Cache, journals, logs, temporary files, and histories

- Run `apt-get clean`; do not run `apt autoremove`.
- Verify no `.deb` archives remain in `/var/cache/apt/archives`.
- Ask journald to relinquish persistent storage with
  `journalctl --relinquish-var` before deleting `/var/log/journal` contents.
  This prevents truncating active binary journal files.
- Truncate remaining regular files under `/var/log`, excluding the persistent
  journal tree, and verify that they are empty at check time.
- Delete contents of `/tmp` and `/var/tmp` without crossing filesystem
  boundaries and verify that both are empty.
- Delete root and direct-home-user `.bash_history` and `.zsh_history` files and
  verify absence at check time.
- Finish with `sync`.

Concurrent services or active shells can recreate logs, temporary state, or
history after a check. Therefore the script is intended as the final action,
preferably with immediate poweroff. An `OK` describes the verified state at
the time of the check, not an indefinite guarantee while the VM keeps running.

## 6. State that must remain unchanged

The script intentionally does not change:

- Hostname
- Static or dynamic network configuration
- IP address configuration
- Users or passwords
- SSH `authorized_keys`
- Filesystem UUID or PARTUUID values
- Disk identifiers, partition tables, or partition layout
- Proxmox virtual NIC MAC address
- qemu-guest-agent configuration
- Installed package selection

Proxmox is responsible for the virtual hardware identity of a clone. This
script only sanitizes appropriate in-guest state.

## 7. Explicitly rejected designs

- No cloud-init dependency or cloud-init workflow.
- No project-specific first-boot service.
- No hostname or IP customization in this script.
- No broad cleanup framework, plugin system, configuration file, interactive
  wizard, daemon, installer, or uninstall system.
- No `apt autoremove`.
- No filesystem or partition identifier regeneration.
- No unsolicited AI-generated feature expansion.

These are intentional product decisions, not missing features.

## 8. Verification and output contract

The script uses strict Bash mode (`set -Eeuo pipefail`) and keeps a summary of
completed checks.

- `OK` in green: the operation completed and its postcondition passed, or the
  item was explicitly not applicable.
- `WARN` in yellow: sanitization continued, but a relevant condition could not
  be fully checked or the environment is outside validated support.
- `FAIL` in red: a required operation or postcondition failed; exit non-zero.

Colors are emitted only when standard output is a terminal and `NO_COLOR` is
unset. Plain text labels remain visible when output is redirected.

Before fallible work, `CURRENT_STEP` must identify the operation. Explicit
failures use `die`; unexpected failures are handled by the `ERR` trap. A late
failure must be shown even if a summary was printed previously.

Do not add unconditional `OK` records after commands whose errors were ignored.
If an error is intentionally tolerated, a later postcondition must prove the
desired final state or the result must be `WARN`/`FAIL`.

## 9. Persistent filesystem changes

After a successful run, the only project-owned persistent file that should
remain is:

```text
/etc/systemd/system/ssh.service.d/10-generate-hostkeys.conf
```

It exists only when `openssh-server` is installed. All other mutations are
sanitization of existing system state. `/run/sshd` is temporary because `/run`
is a volatile runtime filesystem.

## 10. Source conventions

- Retain the Bash shebang and strict mode.
- Quote variable expansions unless a deliberate, documented exception exists.
- Prefer clear, direct Bash over abstraction for its own sake.
- Keep the script as one reviewable file unless a concrete requirement makes
  another structure necessary.
- Use `log` for progress, `warn` plus `record_warn` for non-fatal limitations,
  and `die` for fatal failures.
- Every new cleanup action needs a postcondition check.
- Do not hide relevant failures with `2>/dev/null || true` merely to produce a
  clean-looking run.
- Preserve `clean2clone.sh` mode `100755`; documentation uses `100644`.

## 11. Testing strategy and current limits

Safe checks that may run anywhere:

```bash
bash -n clean2clone.sh
./clean2clone.sh --version
./clean2clone.sh --help
shellcheck clean2clone.sh  # when ShellCheck is available
```

Summary functions may be tested in an isolated subshell by sourcing only the
definitions before `usage()`. Both success/warning counts and fatal/ERR paths
should be checked.

A genuine end-to-end test is destructive and must use disposable snapshots of
full VMs. The release acceptance matrix is:

| Platform | Golden-VM run | Poweroff | Clone boot | New machine ID | New SSH keys |
| --- | --- | --- | --- | --- | --- | --- |
| Ubuntu 24.04 LTS | Required | Required | Required | Required | Required |
| Debian 13 | Required | Required | Required | Required | Required |

Also verify that hostname, network configuration, users, `authorized_keys`,
UUID/PARTUUID, partitions, and qemu-guest-agent configuration remain unchanged.

Version 1.1.0 received Bash syntax checks plus isolated normal, explicit-fatal,
ERR-trap, and late-error summary tests. A complete destructive run on both
supported disposable VM types was still pending when this specification was
written. Do not upgrade that claim without evidence.

## 12. Versioning and changelog

The project follows Semantic Versioning:

- Patch: compatible bug fix or documentation correction.
- Minor: backward-compatible functional addition or meaningful verification
  enhancement.
- Major: incompatible command-line or behavioral change.

`VERSION` in `clean2clone.sh` is the program version. `CHANGELOG.md` follows
Keep a Changelog. Normal development entries go under `[Unreleased]`; a release
moves them to a dated version heading. Documentation-only maintenance does not
require an immediate release unless requested by the owner.

## 13. Documentation map

- `README.md`: short public introduction and usage instructions.
- `PROJECT_SPEC.md`: canonical complete specification and decision record.
- `AGENTS.md`: binding instructions and workflow for AI coding agents.
- `CLAUDE.md`: Claude Code entry point; delegates to the canonical files.
- `CHANGELOG.md`: chronological user-visible changes.
- `LICENSE`: MIT license.

Avoid duplicating evolving technical details outside this map. Update the
canonical document first and keep compatibility entry points short.

## 14. Deferred post-clone customization concept

A different utility may eventually help customize a clone after first boot,
especially hostname and IP address. It is not implemented and is not part of
the current repository scope.

Before designing it:

- Verify the then-current behavior of Enhance control panel rather than
  assuming whether Enhance manages hostname changes.
- Treat Ubuntu and Debian networking separately; their installed networking
  stacks and configuration formats can differ.
- Define safe rollback and remote-access protection before changing an IP.
- Obtain explicit owner approval for its scope and decide whether it belongs
  in a separate repository.

Do not use this deferred idea as authorization to modify `clean2clone.sh`.
