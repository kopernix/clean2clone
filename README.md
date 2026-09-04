# clean2clone

`clean2clone` is a small Bash script that prepares an Ubuntu 24.04 LTS or
Debian 13 virtual machine to be used as a Proxmox VE template.

It removes machine-specific state such as the machine ID, OpenSSH host keys,
random seeds, DHCP leases, logs and temporary files. A small `ssh.service`
drop-in generates fresh OpenSSH host keys when a clone starts.

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
that passed; a `[FAIL]` entry stops the script and identifies the failed step.

Run it as the last action inside the golden VM. Do not boot that VM again
before converting it to a Proxmox template. If it is booted again, run the
script again before creating or updating the template.

## Options

```text
--poweroff     Power off automatically after sanitizing
-y, --yes      Skip interactive confirmation
--version      Show the script version
-h, --help     Show help
```

## License

MIT

## Author

Joan Puiggali aka kopernix

Project repository: <https://github.com/kopernix/clean2clone>
