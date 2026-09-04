# Agent Instructions

These instructions apply to every AI agent or automated coding tool working
in this repository, including Codex, Claude Code, OpenCode, and similar tools.

## Required reading

Before proposing or making a change, read these files in order:

1. `AGENTS.md`
2. `PROJECT_SPEC.md`
3. `README.md`
4. `CHANGELOG.md`
5. `clean2clone.sh`

`PROJECT_SPEC.md` is the canonical functional and technical specification.
The current source code is authoritative for the implemented version. If the
documentation and source disagree, stop and report the discrepancy instead of
silently choosing one.

## Project intent

`clean2clone` is deliberately a small, focused Bash utility. It saves time
when preparing an Ubuntu 24.04 LTS or Debian 13 Proxmox VE golden VM for
conversion into a template. It is not intended to become a provisioning
framework, configuration-management system, image builder, or general-purpose
server maintenance tool.

AI-assisted maintenance explicitly requested by the repository owner is
welcome. Unsolicited feature expansion, speculative refactoring, generated
feature lists, and AI-created expansion pull requests are outside the scope.

## Non-negotiable constraints

- Do not add cloud-init integration.
- Do not add a custom first-boot service.
- Do not change the hostname, IP address, or network configuration.
- Do not alter filesystem UUIDs, PARTUUIDs, partitions, disks, or virtual MAC
  addresses.
- Do not change users, passwords, `authorized_keys`, or qemu-guest-agent
  configuration.
- Do not run `apt autoremove` or remove installed packages.
- Do not broaden support claims beyond Ubuntu 24.04 LTS and Debian 13 without
  real testing on the newly claimed platform.
- Keep the OpenSSH systemd drop-in as the only persistent integration unless
  the owner explicitly changes this design decision.
- Preserve the executable mode of `clean2clone.sh` (`100755`).
- Preserve the MIT license and the credit `Joan Puiggali aka kopernix`.
- Keep user-facing script output and repository documentation in English.

## Safety rules

The main script is destructive by design. Never execute its sanitization path
on a development machine, CI runner, container host, or any system containing
valuable state. A complete execution is only appropriate inside a disposable
snapshot of a supported full QEMU/KVM virtual machine.

Static checks and isolated tests of non-destructive functions are acceptable.
Do not weaken confirmation, environment checks, error handling, or final
verification merely to make a test pass.

Every destructive action must have a corresponding explicit verification or a
clearly reported `WARN` when verification is impossible. Never report `OK`
after suppressing an error unless a subsequent check proves the final state.

## Change workflow

1. Confirm the requested change is within `PROJECT_SPEC.md` or explicitly
   authorized by the owner.
2. Inspect the complete script before editing; preserve unrelated behavior.
3. Keep Bash strict mode: `set -Eeuo pipefail` and the restricted `IFS`.
4. Use absolute paths for system commands where the script already relies on
   a specific binary location or where security depends on it.
5. Set `CURRENT_STEP` before fallible work and use `die` for a specific,
   actionable failure message.
6. Add or update a postcondition check for every changed sanitization step.
7. Run the non-destructive checks listed below.
8. Update `CHANGELOG.md` under `[Unreleased]` for every user-visible change.
9. Apply Semantic Versioning only when preparing a release. Keep the version
   in `clean2clone.sh` and the changelog release heading consistent.
10. Re-read the final diff for accidental scope expansion and verify that the
    executable bit remains set.

## Minimum validation

Run at least:

```bash
bash -n clean2clone.sh
./clean2clone.sh --version
./clean2clone.sh --help
```

If ShellCheck is available, also run:

```bash
shellcheck clean2clone.sh
```

For changes to summary/error handling, exercise the relevant functions in an
isolated subshell without entering the sanitization path. For behavioral or
release validation, test both Ubuntu 24.04 LTS and Debian 13 using disposable
full VMs and verify the clone after boot. Record what was actually tested; do
not claim end-to-end validation when only syntax or mocked tests were run.

## Releases

- Follow Semantic Versioning.
- Follow Keep a Changelog in `CHANGELOG.md`.
- Move relevant entries from `[Unreleased]` into a dated version section.
- Verify that `clean2clone.sh --version` prints the release version.
- Do not create tags or GitHub releases unless the owner requests a release.

## Deferred idea: separate post-clone customization

The owner has discussed a possible separate script for changing hostname and
IP address after a clone's first boot. It is intentionally not part of
`clean2clone` today and must not be added opportunistically. Ubuntu and Debian
network handling differ, and any future design must first verify current
Enhance control-panel behavior. Treat it as a separate project or separately
approved component.
