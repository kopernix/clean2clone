# clean2clone Project Specification

## 1. Project identity

- Repository: <https://github.com/kopernix/clean2clone>
- Primary program: `clean2clone.sh`
- Current implemented version: `1.2.3`
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
6. Boot a clone and run `sudo ./clean2clone.sh --check` to validate its
   post-reboot state without changing it.
7. Do not boot the golden VM again before templating. If it is booted again,
   run `clean2clone` again because boot recreates unique state.

It must never be run on a production server. Containers such as LXC, OpenVZ,
Docker, Podman, and systemd-nspawn are rejected.

## 4. Command-line interface

Supported options:

| Option | Meaning |
| --- | --- |
| `--check` | Run a read-only post-reboot integrity check and exit. |
| `--poweroff` | Request system poweroff after successful sanitization. |
| `-y`, `--yes` | Skip the interactive confirmation. |
| `--version` | Print the version and exit without sanitizing. |
| `-h`, `--help` | Print usage and exit without sanitizing. |

Without `--yes`, the user must type the exact token `CLEAN2CLONE`. Unknown
options are fatal. Root privileges are mandatory.

`--check` cannot be combined with `--poweroff` or `--yes`.

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
2. Run `/usr/bin/ssh-keygen -A` before validation. It creates only missing
   default keys, which makes repeated clean2clone runs safe even when an
   earlier run already removed every host key.
3. Validate the existing OpenSSH configuration with `/usr/sbin/sshd -t` and
   include its diagnostic output in a fatal summary entry if it fails.
4. Read the effective configuration with `/usr/sbin/sshd -T`.
5. Accept only standard host-key paths that `ssh-keygen -A` can recreate:
   `/etc/ssh/ssh_host_rsa_key`, `/etc/ssh/ssh_host_ecdsa_key`, and
   `/etc/ssh/ssh_host_ed25519_key`. A custom `HostKey` path is a fatal error.
6. Install `/etc/systemd/system/ssh.service.d/10-generate-hostkeys.conf` with
   mode `0644`.
7. The drop-in must clear the existing `ExecStartPre` list, then run, in order:

   ```ini
   ExecStartPre=/usr/bin/ssh-keygen -A
   ExecStartPre=/usr/sbin/sshd -t
   ```

8. Reload systemd, validate the unit with `systemd-analyze verify`, and inspect
   the effective `ExecStartPre` commands.
9. Install
   `/etc/systemd/system/ssh.socket.d/10-generate-hostkeys.conf` with mode
   `0644`. Its `[Socket]` section must run
   `ExecStartPre=/usr/bin/ssh-keygen -A`. Installation must not depend on the
   socket unit being visible before the next boot. Validate the file itself in
   all cases, and validate the unit structure and effective command when the
   unit is loaded. This guarantees boot-time key generation before an enabled
   Ubuntu socket begins listening, without a custom first-boot service.
10. Remove every `/etc/ssh/ssh_host_*` inherited host-key file.
11. Exercise the clone behavior before completion: run `ssh-keygen -A`, validate
   with `sshd -t`, remove the generated test keys again, and verify none remain.

The systemd drop-ins are the only persistent integrations installed by the
project. `ssh-keygen -A` is intentionally used because it creates missing
default keys without replacing existing keys. Ubuntu 24.04 normally uses
systemd socket activation for OpenSSH; the socket drop-in ensures key
generation happens as that socket activates during boot.

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

### 8.1 Post-reboot `--check` mode

`--check` is a strictly observational integrity check. It must not create or
delete files, generate host keys, start/restart/stop services, clean caches,
alter network state, or power off. It accumulates all check results rather than
stopping at the first failed postcondition. On supported systems its results
are binary `OK` or `FAIL`; any failure produces a non-zero exit status.

It verifies:

- A non-zero 32-character hexadecimal machine ID and matching D-Bus link.
- OpenSSH service and socket drop-ins, plus their effective commands when the
  corresponding units are loaded.
- A healthy active `ssh.service` or `ssh.socket` with neither unit failed.
- Structural validity of the OpenSSH systemd units.
- The standard RSA, ECDSA, and Ed25519 OpenSSH private/public host-key pairs:
  existence, non-empty content, matching public material, root ownership, and
  private mode `0600`. This check must not call `sshd -T` when `/run/sshd` is
  absent because Ubuntu's server binary requires that runtime directory even
  for effective-configuration output.
- Direct `sshd -t` validation when `/run/sshd` already exists. With a healthy
  inactive socket-activated service, absence of that runtime directory is
  valid because systemd creates it when the service starts; check mode must not
  create it merely to make the test pass.
- A non-empty secure systemd random seed and a non-failed seed service.
- EFI seed validity when one is present and credential-secret validity whether
  it remains absent or was securely recreated.
- An active non-loopback interface, a global-scope address, and no failed
  installed network-management service.
- `apt-get check` with locking and package-cache writes disabled, plus an empty
  `dpkg --audit` result.
- Active journald with journals passing `journalctl --verify`.
- `/var/log` accessibility; `/tmp` and `/var/tmp` as `root:root` mode `1777`.
- Presence of `/root`, `/home`, and a configured hostname.

The check demonstrates validity and operational readiness on the current VM.
It cannot prove that a machine ID or SSH key differs from the golden VM using
only the current post-reboot state. Demonstrating uniqueness requires comparing
fingerprints/IDs between clones or against an external pre-clean baseline; the
script must not persist the removed identity merely to enable that comparison.

## 9. Persistent filesystem changes

After a successful run, the project-owned persistent files that may remain are:

```text
/etc/systemd/system/ssh.service.d/10-generate-hostkeys.conf
/etc/systemd/system/ssh.socket.d/10-generate-hostkeys.conf
```

They exist only when `openssh-server` is installed. The socket drop-in is
installed even when `ssh.socket` is not currently visible; it remains harmless
unless that unit is present. All other mutations are sanitization of existing
system state. `/run/sshd` is temporary because `/run` is a volatile runtime
filesystem.

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

Version 1.1.1 corrected repeat execution after host-key removal. It received
Bash syntax, CLI, and isolated summary/error-path checks; its complete
destructive VM acceptance matrix remains pending.

Version 1.2.0 adds the non-destructive `--check` path and boot-time
`ssh.socket` integration. It received Bash syntax, CLI, option-conflict, and
isolated summary/error-path checks. Full clean, reboot, and post-check testing
on disposable Ubuntu 24.04 LTS and Debian 13 VMs remains required.

Version 1.2.1 removes the cleanup-time dependency on `ssh.socket` unit
visibility and makes the post-reboot socket diagnostics more specific. It
received Bash syntax, CLI, option-conflict, and isolated summary/error-path
checks. A user-reported Ubuntu 24.04.4 reboot exposed the 1.2.0 defect; a full
clean, reboot, and successful post-check with 1.2.1 remains required.

Version 1.2.2 makes host-key verification independent of `/run/sshd` by
checking the standard key pairs directly. It received Bash syntax, CLI, and
option-conflict checks. A user-reported Ubuntu 24.04.4 post-reboot check exposed
the false failure caused by using `sshd -T` before `ssh.service` had created its
runtime directory; a successful real-VM post-check with 1.2.2 remains required.

Version 1.2.3 normalizes both the public key derived from each private key and
the corresponding `.pub` file to their algorithm and encoded key fields before
comparison. This avoids treating the optional `ssh-keygen -y` comment as key
material. It received Bash syntax, CLI, option-conflict, and isolated RSA,
ECDSA, and Ed25519 pair-comparison checks. A successful full real-VM
post-reboot check with 1.2.3 remains required.

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
