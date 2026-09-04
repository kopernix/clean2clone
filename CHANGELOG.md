# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.2.3] - 2026-09-04

### Fixed

- Normalize `ssh-keygen -y` output before comparing it with the corresponding
  public host-key file. Some OpenSSH versions append a comment such as
  `root@hostname`; that comment is not cryptographic key material and caused
  valid RSA, ECDSA, and Ed25519 pairs to be reported as invalid.

## [1.2.2] - 2026-09-04

### Fixed

- Verify the standard OpenSSH host-key pairs directly in `--check` instead of
  using `sshd -T`. On Ubuntu with socket activation, `/run/sshd` may
  legitimately remain absent until `ssh.service` starts, and `sshd -T` reports
  that absence even when the generated keys and socket are healthy.
- Preserve the strictly non-destructive check contract: the checker does not
  create `/run/sshd` merely to make OpenSSH validation pass.

## [1.2.1] - 2026-09-04

### Fixed

- Always install the OpenSSH `ssh.socket` host-key drop-in when
  `openssh-server` is installed. This avoids depending on whether systemd
  exposes the socket unit during sanitization and fixes missing host keys after
  reboot on affected Ubuntu 24.04 systems.
- Report a missing socket drop-in separately from an installed drop-in whose
  command is not active, while keeping `--check` strictly non-destructive.

## [1.2.0] - 2026-09-04

### Added

- Add `--check`, a non-destructive post-reboot integrity check that reports all
  relevant postconditions as `OK` or `FAIL` and exits non-zero on failure.
- Add an OpenSSH `ssh.socket` drop-in when socket activation is available, so
  missing host keys are generated during boot-time socket activation rather
  than waiting for the first incoming connection.

### Changed

- Expand the README, agent instructions, and canonical project specification
  with the post-reboot verification contract and its honest limitations.

## [1.1.1] - 2026-09-04

### Added

- Add portable AI-agent maintenance instructions in `AGENTS.md`, a Claude Code
  entry point in `CLAUDE.md`, and the complete project specification and
  decision record in `PROJECT_SPEC.md`.

### Fixed

- Generate any missing default OpenSSH host keys before the initial `sshd -t`
  check. This makes the script repeatable after an earlier sanitization run,
  including on Ubuntu systems where socket activation has not started
  `ssh.service` after reboot.
- Include the actual `sshd -t` diagnostic in the fatal verification entry.

### Changed

- Document that Ubuntu socket activation may defer host-key generation until
  the first incoming SSH connection.

## [1.1.0] - 2026-09-04

### Added

- Add a final verification summary with green `OK`, yellow `WARN`, and red
  `FAIL` states.
- Add explicit post-cleanup checks for machine identity, random seeds,
  credentials, DHCP leases, APT archives, journals, logs, temporary files,
  and shell histories.
- Test fresh OpenSSH host-key generation and `sshd` validation, then remove
  the generated test keys before completion.
- Add this changelog.

### Changed

- Make cleanup failures visible instead of reporting success after ignored
  errors.
- Ensure failures occurring after a previously printed summary are still
  reported.
- Validate the effective `ssh.service` pre-start commands and OpenSSH host-key
  paths more reliably.
- Report unsupported operating systems and an unmounted EFI partition as
  warnings rather than successful checks.

## [1.0.1] - 2026-09-04

### Fixed

- Create `/run/sshd` with the required ownership and permissions before
  validating OpenSSH, avoiding the `Missing privilege separation directory`
  error.

## [1.0.0] - 2026-09-04

### Added

- Initial release for sanitizing Ubuntu 24.04 LTS and Debian 13 Proxmox VE
  golden virtual machines without cloud-init or a custom first-boot service.
