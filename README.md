# clean2clone

`clean2clone` is a small Bash script that prepares an Ubuntu 24.04 LTS or
Debian 13 virtual machine to be used as a Proxmox VE template.

It removes machine-specific state such as the machine ID, OpenSSH host keys,
random seeds, DHCP leases, logs and temporary files. Small systemd drop-ins
generate fresh OpenSSH host keys when a clone starts.

On Ubuntu, OpenSSH may use systemd socket activation. When `ssh.socket` is
available, clean2clone installs a matching drop-in so the keys are generated
as the socket activates during boot, before it begins listening. Service-based
OpenSSH installations generate them before `ssh.service` starts.

There is no cloud-init integration and no custom first-boot service.

## Scope

This is intentionally a modest utility created to save time when preparing
our own VM templates. It is not a complete image-building, provisioning or
configuration-management system, and it is not intended to become one.

Feature-expansion requests and generated feature-expansion pull requests are
outside the scope of this repository. Reports of clear defects are welcome.

## Requirements

- Ubuntu 24.04 LTS or Debian 13
- A full Proxmox QEMU/KVM virtual machine, not an LXC container
- systemd
- Root privileges

Review the script before running it. It removes machine-specific data and must
never be used on a production server.

## Download and run

Clone the repository:

```bash
git clone https://github.com/kopernix/clean2clone.git
cd clean2clone
chmod 0755 clean2clone.sh
sudo ./clean2clone.sh --poweroff
```

Alternatively, download only the script:

```bash
curl -fLO https://raw.githubusercontent.com/kopernix/clean2clone/main/clean2clone.sh
chmod 0755 clean2clone.sh
sudo ./clean2clone.sh --poweroff
```

The script asks you to type `CLEAN2CLONE` before making changes. Use `--yes`
to skip this confirmation:

```bash
sudo ./clean2clone.sh --yes --poweroff
```

At the end it prints a verification summary. Green `[OK]` entries are checks
that passed, yellow `[WARN]` entries need attention, and a red `[FAIL]` entry
stops the script and identifies the failed step. The OpenSSH check actually
generates temporary host keys, validates `sshd`, and removes those test keys.

Run it as the last action inside the golden VM. Do not boot that VM again
before converting it to a Proxmox template. If it is booted again, run the
script again before creating or updating the template.

## Post-reboot integrity check

After booting a clone, run:

```bash
sudo ./clean2clone.sh --check
```

This mode is read-only: it does not generate keys, start or restart services,
repair files, clean data, or power off the VM. It checks the state created
after boot and reports every result as `OK` or `FAIL`, then exits non-zero if
any check failed.

The check covers the regenerated machine ID, D-Bus identity, OpenSSH host-key
pairs and activation units, random-seed state, credential-secret state,
network interfaces and addresses, APT/DPKG health, journald, log and temporary
directories, home-directory roots, and hostname availability.

It can prove that the current machine ID and SSH keys are structurally valid,
but a single VM cannot prove that they differ from the golden image without a
saved external baseline. Compare values across two clones if uniqueness itself
must be demonstrated.

## Options

```text
--check        Run a non-destructive post-reboot integrity check
--poweroff     Power off automatically after sanitizing
-y, --yes      Skip interactive confirmation
--version      Show the script version
-h, --help     Show help
```

## License

MIT

## Changelog

See [CHANGELOG.md](CHANGELOG.md). Versions follow Semantic Versioning.

## Continuing with an AI coding agent

Start with [AGENTS.md](AGENTS.md). It contains portable instructions for
Codex, Claude Code, OpenCode, and other coding agents. The complete functional
and technical specification is in [PROJECT_SPEC.md](PROJECT_SPEC.md).

## Author

Joan Puiggali aka kopernix

Project repository: <https://github.com/kopernix/clean2clone>
