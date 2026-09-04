# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
