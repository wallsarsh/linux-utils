# Generic Linux LXC development bootstrap

`lxc-dev-bootstrap.sh` is a Bash bootstrap for **Debian, Ubuntu, Fedora, RHEL, CentOS Stream, Rocky Linux, AlmaLinux, openSUSE Leap/Tumbleweed and Arch Linux** LXC guests. Recognized derivatives are best-effort; only install on a freshly provisioned, trusted container or VM after taking a snapshot.

It generalizes [`archlinux/arch-lxc-bootstrap.sh`](https://github.com/wallsarsh/linux-utils/blob/main/archlinux/arch-lxc-bootstrap.sh) without replacing it. Unlike the Arch predecessor, the default setup **does not install `yay` or assign the username as the password**.

## What it installs and configures

- OS package refresh/update, and optional Arch reflector mirror tuning; Arch `ParallelDownloads=15` (backups made).
- Common build/development utilities: Git, compiler/make, Python 3/pip, Go, curl/wget, Zip/Unzip, editors and OpenSSH.
- A non-root developer account with Zsh as login shell and family-specific `sudo`/`wheel` membership when available.
- Developer-local Oh My Zsh, Zsh autosuggestions, and NVM (pinned to `v0.40.8` by default); re-runs preserve unrelated `.zshrc` content.
- NVM-managed Node.js runtime prerequisite: detect `libatomic.so.1` via `ldconfig -p` and install the distribution-appropriate GCC atomic library package only when absent.
- Docker Engine and **Compose V2**; account added to the `docker` group; services enabled/started when systemd runs.
- Optional public-key SSH access, secure password input from stdin, or interactive `passwd` (when prompted for username).
- Root-operated package management; user-owned shell customization. Optional Arch `yay` is explicitly opt-in and `makepkg` runs as the developer.
- Logging in `/var/log/lxc-dev-bootstrap.log`; package/install errors fail the run, but service activation failures are warned about (typical with unconfigured nested LXC).

## Usage

Run as root **inside the LXC guest** (not on the Proxmox host):

```bash
chmod +x lxc-dev-bootstrap.sh
sudo ./lxc-dev-bootstrap.sh
```

The above prompts for a developer username and password when invoked interactively with a TTY. With a positional username or `--user NAME`, the invocation is **unattended**. A newly created account will have a **locked password** unless you supply a password or SSH key. Existing accounts keep their current password when no password is supplied.

**SSH-key-based unattended bootstrap:**

```bash
sudo ./lxc-dev-bootstrap.sh --user dev --ssh-key-file /root/dev.pub
```

**Password passed securely over stdin:**

```bash
# Execute in a root shell, or use a secure secret-manager command producing one line.
read -rsp 'New password: ' DEV_PASSWORD; echo
printf '%s\n' "$DEV_PASSWORD" | sudo ./lxc-dev-bootstrap.sh --user dev --password-stdin
unset DEV_PASSWORD
```

**Conservative test run without Docker services or an OS upgrade** (Arch requires an upgrade and rejects `--no-upgrade`):

```bash
sudo ./lxc-dev-bootstrap.sh --user dev --no-docker --no-services --no-upgrade
```

**Arch with the optional AUR helper:**

```bash
sudo ./lxc-dev-bootstrap.sh --user dev --arch-yay --no-arch-mirrors
```

**Password-required sudo:**

```bash
sudo ./lxc-dev-bootstrap.sh --user dev --sudo-mode password --ssh-key-file /root/dev.pub
```

`--sudo-mode password` makes `sudo` require the account's own password, so set it via `passwd dev` before using sudo unless it already exists. The default `nopasswd` retains the original script's convenience and has equivalent-to-root implications.

## Distribution handling

| Family | Update action | Docker setup (`--docker-source auto`) | OpenSSH unit |
|---|---|---|---|
| Debian / Ubuntu | `apt-get update` and `upgrade` | Docker's official APT repository and Compose plugin | `ssh.service` (or `sshd.service`) |
| Fedora / RHEL / CentOS Stream / Rocky / AlmaLinux | DNF/YUM upgrade | Docker's official RPM repository; Rocky/Alma map to CentOS repo | `sshd.service` (or `ssh.service`) |
| openSUSE Leap | `zypper refresh`, `update` | SUSE `docker` + `docker-compose` packages | `sshd.service` (or `ssh.service`) |
| openSUSE Tumbleweed | `zypper refresh`, `dup` | SUSE `docker` + `docker-compose` packages | `sshd.service` (or `ssh.service`) |
| Arch Linux | Pacman keyring, full system upgrade; optional reflector | Official `docker` + `docker-compose` packages (no AUR required) | `sshd.service` (or `ssh.service`) |

`--docker-source distro` explicitly uses the distro-maintained packages. On certain Debian/RHEL derivatives, no Compose V2 package may be available: the script will stop with an actionable error instead of installing obsolete Compose V1. `--docker-source official` is restricted to recognized supported distribution mappings, to avoid silently using an incorrect repo on derivatives.

Docker Engine official packages can conflict with existing `docker.io`, Podman compatibility packages, or container runtimes; **this script does not uninstall existing software**. Investigate conflicts on an already customized guest before proceeding. RHEL requires a working registered subscription/repository configuration for base packages.

## NVM and Node.js: `libatomic.so.1` runtime dependency

**Why:** NVM downloads official prebuilt Node.js executables; depending on the Node.js release and target system, they may link dynamically against `libatomic.so.1`. Minimal LXC images (especially AlmaLinux/RHEL-like images) may not include this library. A download via `nvm install` may succeed while launching `node` fails with:

```text
node: error while loading shared libraries: libatomic.so.1: cannot open shared object file: No such file or directory
```

**Bootstrap change:** After common development tools are installed and **before** the developer's NVM setup, `install_node_runtime_deps` checks `ldconfig -p` for `libatomic.so.1`. If absent, it installs the appropriate distro runtime and rechecks. On Arch, it prefers the newer standalone `libatomic` package when it is in repository metadata, otherwise it falls back to `gcc-libs` for older layouts. If the runtime is still not available, bootstrap exits with an actionable error rather than reporting success. No extra package transaction is made when the runtime is already available.

| Family | Package when `libatomic.so.1` is missing |
|---|---|
| RHEL / AlmaLinux / Rocky / Fedora / CentOS Stream | `libatomic` |
| Debian / Ubuntu | `libatomic1` |
| openSUSE Leap / Tumbleweed | `libatomic1` |
| Arch Linux | `libatomic` (newer package layout); `gcc-libs` fallback |

**Fix an already provisioned AlmaLinux guest without rerunning bootstrap:**

```bash
# As root (or using sudo)
sudo dnf install -y libatomic
ldconfig -p | grep libatomic.so.1

# As the developer (with NVM loaded by ~/.zshrc)
nvm install --lts
node --version
```

You can also rerun the updated bootstrap with your existing username, e.g. `sudo ./lxc-dev-bootstrap.sh --user dev --no-upgrade`; it will make this dependency check without reinstalling a developer account. `--no-upgrade` is invalid on Arch.

This ensures only the **atomic shared-library prerequisite**. The script installs NVM but does **not** automatically install a Node.js version. Other compatibility restrictions (such as an older glibc or an unsupported CPU architecture) remain possible; `libatomic` cannot fix those.

## Important LXC, operational and security notes

1. Docker-in-LXC **depends on the host**. In Proxmox, nesting and suitable keyctl, storage, cgroups, security policy and host kernel features may be needed. The script cannot configure the Proxmox host. It verifies Docker CLI and Compose, but it does not run containers or claim the Docker daemon is functional. Check `systemctl status docker` and `docker info` yourself after provisioning.
2. It works when systemd is not running but does not start persistent services; startup responsibility belongs to your image/init configuration. Verify that SSH is accessible and firewall/network settings permit access. It generates only missing SSH host keys.
3. The default `NOPASSWD` sudo rule and membership of the `docker` group permit root-equivalent actions. Use only for trusted development users.
4. The official Docker repositories are third-party repositories over TLS with package-signature validation. Arch `yay` builds from the AUR (user code) and is deliberately opt-in with `--arch-yay`.
5. Do **not** use the unmaintained or incompatible distributions as a production support claim. OS/package support varies by release. Derivatives recognized through `ID_LIKE` use their family package manager, but some package names/repos may need local adjustment.
6. The script is **idempotent on routine reruns**: it avoids recreating users and Git checkouts, reuses existing repository files, preserves existing SSH host keys, deduplicates inserted public keys, and replaces only its own `.zshrc` block. It is not transactional: failures can leave partial installed packages or repo configuration; take a Proxmox snapshot before running.
7. To review the log, run `sudo less /var/log/lxc-dev-bootstrap.log` (permissions `0600`). A supplied password is never printed by the script.

The script does not harden SSH daemon config, set up firewall rules, install a Node.js runtime (only NVM and the OS-level `libatomic` prerequisite), run full container smoke tests, or configure Docker's rootless mode.

## Troubleshooting: `cannot determine current directory: stat .: permission denied`

Earlier versions used `runuser` while retaining the root shell's working directory. If bootstrap was launched from `/root` or another protected directory, the developer account could not inspect `.`. During **Verify installation**, `go version` then failed even though Go itself was installed correctly.

**Fixed:** `as_dev()` now changes to the developer's home in a subshell before invoking `runuser`, leaving the calling shell's working directory unchanged. This is a cross-distro fix, including AlmaLinux.

For a previously completed installation, verify without repeating the package upgrade (replace `dev` with your actual username):

```bash
cd /home/dev
sudo -u dev -- go version
sudo -u dev -- docker compose version
sudo -u dev -- sudo -n true
sudo systemctl is-active sshd docker
```

If re-running, replace your old copy with the updated script and use the same username and options. User account configuration and shell customization are repeatable. A full rerun still refreshes and upgrades OS packages unless `--no-upgrade` is supplied (Arch does not support that flag).

## Validation

```bash
bash -n lxc-dev-bootstrap.sh
python3 test_lxc_dev_bootstrap.py
```

The included Python tests use mocked package managers. They validate OS recognition, package mappings, upgrade commands and Docker-repository selection without modifying the system. These tests **do not** replace disposable LXC integration testing on each specific supported distribution/release.

### Reference documentation

- Docker Engine: [Ubuntu](https://docs.docker.com/engine/install/ubuntu/), [Debian](https://docs.docker.com/engine/install/debian/), [RHEL](https://docs.docker.com/engine/install/rhel/), [Fedora](https://docs.docker.com/engine/install/fedora/), [CentOS](https://docs.docker.com/engine/install/centos/)
- [Docker Compose plugin](https://docs.docker.com/compose/install/linux/), [Docker group security](https://docs.docker.com/engine/install/linux-postinstall/)
- [openSUSE Tumbleweed updates](https://doc.opensuse.org/documentation/tumbleweed/updating_upgrading_reverting/)
- [Arch partial-upgrade guidance](https://wiki.archlinux.org/title/System_maintenance)
- [NVM releases](https://github.com/nvm-sh/nvm/releases)
- [AlmaLinux `libatomic` errata/package](https://errata.almalinux.org/9/ALSA-2025-1346.html), [Fedora `libatomic` package](https://packages.fedoraproject.org/pkgs/gcc/libatomic/)
- [Debian `libatomic1`](https://packages.debian.org/libatomic1), [Ubuntu `libatomic1`](https://packages.ubuntu.com/libatomic1)
- [Arch `libatomic`](https://archlinux.org/packages/core/x86_64/libatomic/), [Arch `gcc-libs`](https://archlinux.org/packages/core/x86_64/gcc-libs/)
