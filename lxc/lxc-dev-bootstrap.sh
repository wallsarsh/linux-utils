#!/usr/bin/env bash
# Cross-distribution Linux LXC development environment bootstrap.
# Supported families: Debian/Ubuntu, RHEL/Fedora, openSUSE, Arch Linux.
# Run as root inside a trusted, newly provisioned container or VM.
set -Eeuo pipefail

LOG_FILE=${LXC_BOOTSTRAP_LOG:-/var/log/lxc-dev-bootstrap.log}
NVM_VERSION=${NVM_VERSION:-v0.40.8}
DEV_USER=''
PASSWORD_STDIN=false
SSH_KEY_FILE=''
SUDO_MODE=nopasswd
INSTALL_DOCKER=true
START_SERVICES=true
UPGRADE=true
REFRESH_ARCH_MIRRORS=true
INSTALL_YAY=false
DOCKER_SOURCE=auto
FAMILY=''
OS_ID=''
OS_VERSION=''
DEV_HOME=''
PKG=''
ACCOUNT_PASSWORD=''
CREATED_ACCOUNT=false
USERNAME_SUPPLIED=false

log()  { printf '\n\033[1;32m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33mWARNING: %s\033[0m\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
trap 'warn "Bootstrap failed at line $LINENO. Review $LOG_FILE"' ERR

usage() {
  cat <<'HELP'
Usage: lxc-dev-bootstrap.sh [developer-username] [options]
       lxc-dev-bootstrap.sh --user NAME [options]

  --user NAME              Developer account (otherwise prompt on a TTY)
  --password-stdin         Read one password line from stdin (never logged)
  --ssh-key-file PATH      Add public SSH key(s) to authorized_keys
  --sudo-mode MODE         'nopasswd' (default) or 'password'
  --docker-source SOURCE   'auto' (default), 'official', or 'distro'
  --no-docker              Do not install Docker / Docker Compose
  --no-services            Do not enable/start system services
  --no-upgrade             Skip OS upgrade (not supported on Arch)
  --no-arch-mirrors        Retain Arch mirrorlist (no reflector refresh)
  --arch-yay               Install Arch AUR helper yay (opt-in, untrusted AUR)
  -h, --help              Show this help

Examples:
  bash lxc-dev-bootstrap.sh                       # Interactive account setup
  bash lxc-dev-bootstrap.sh dev --ssh-key-file /root/dev.pub
  printf '%s\n' "$SECRET" | bash lxc-dev-bootstrap.sh --user dev --password-stdin

A username alone is NONINTERACTIVE: new accounts keep a locked password
until one is set via passwd, unless an SSH key or --password-stdin is supplied.
The script sets up passwordless sudo by default, matching the Arch predecessor.
HELP
}

valid_username() {
  [[ $1 =~ ^[a-z_][a-z0-9_-]*$ ]] && [[ $1 != root ]] && (( ${#1} <= 32 ))
}

parse_args() {
  while (($#)); do
    case "$1" in
      --user)
        (($# >= 2)) || die '--user requires a value.'
        [[ -z $DEV_USER ]] || die 'Specify developer username only once.'
        DEV_USER=$2; USERNAME_SUPPLIED=true; shift 2 ;;
      --password-stdin) PASSWORD_STDIN=true; shift ;;
      --ssh-key-file)
        (($# >= 2)) || die '--ssh-key-file requires a path.'
        SSH_KEY_FILE=$2; shift 2 ;;
      --sudo-mode)
        (($# >= 2)) || die '--sudo-mode requires a value.'
        SUDO_MODE=$2; shift 2 ;;
      --docker-source)
        (($# >= 2)) || die '--docker-source requires a value.'
        DOCKER_SOURCE=$2; shift 2 ;;
      --no-docker) INSTALL_DOCKER=false; shift ;;
      --no-services) START_SERVICES=false; shift ;;
      --no-upgrade) UPGRADE=false; shift ;;
      --no-arch-mirrors) REFRESH_ARCH_MIRRORS=false; shift ;;
      --arch-yay) INSTALL_YAY=true; shift ;;
      -h|--help) usage; exit 0 ;;
      --*) die "Unknown option: $1" ;;
      *)
        [[ -z $DEV_USER ]] || die 'Specify developer username only once.'
        DEV_USER=$1; USERNAME_SUPPLIED=true; shift ;;
    esac
  done
  [[ $SUDO_MODE == nopasswd || $SUDO_MODE == password ]] || die 'Invalid --sudo-mode.'
  [[ $DOCKER_SOURCE == auto || $DOCKER_SOURCE == official || $DOCKER_SOURCE == distro ]] || die 'Invalid --docker-source.'
  [[ $NVM_VERSION =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die 'Invalid NVM_VERSION; expected vX.Y.Z.'
  [[ $EUID -eq 0 ]] || die 'Run this script as root.'
  [[ -r /etc/os-release ]] || die '/etc/os-release is required.'
  if [[ -z $DEV_USER ]]; then
    [[ -t 0 ]] || die 'No TTY: supply --user NAME.'
    while :; do
      read -r -p 'Developer username: ' DEV_USER
      valid_username "$DEV_USER" && break
      warn 'Use a lowercase username (max 32 characters, not root).'
    done
  fi
  valid_username "$DEV_USER" || die 'Invalid developer username.'
  if [[ -n $SSH_KEY_FILE ]]; then
    [[ -f $SSH_KEY_FILE && -r $SSH_KEY_FILE && -s $SSH_KEY_FILE ]] || die 'SSH public key file is missing, empty, or unreadable.'
    # Only public keys, not certificates, comments or arbitrary SSH config.
    if ! awk 'NF && $1 !~ /^#/ && $1 !~ /^(ssh-(ed25519|rsa)|ecdsa-sha2-|sk-ssh-ed25519|sk-ecdsa-sha2-)/ {exit 1} END {if (NR == 0) exit 1}' "$SSH_KEY_FILE"; then
      die 'SSH key file must contain public keys (one per line).'
    fi
  fi
  if [[ $PASSWORD_STDIN == true ]]; then
    IFS= read -r ACCOUNT_PASSWORD || die 'Failed to read password from stdin.'
    [[ -n $ACCOUNT_PASSWORD && $ACCOUNT_PASSWORD != *:* ]] || die 'Invalid password from stdin.'
  fi
}

detect_os() {
  # os-release is a specification-defined shell assignment file.
  # shellcheck source=/dev/null
  source /etc/os-release
  OS_ID=${ID,,}
  OS_VERSION=${VERSION_ID:-unknown}
  local tokens=" ${ID_LIKE:-} "
  case "$OS_ID" in
    arch|manjaro|endeavouros|artix) FAMILY=arch ;;
    debian|ubuntu|raspbian|linuxmint|pop|kali|neon) FAMILY=debian ;;
    fedora|rhel|centos|rocky|almalinux|ol|oracle) FAMILY=redhat ;;
    opensuse*|sles|sled) FAMILY=suse ;;
    *)
      if [[ $tokens =~ (\ |^)(arch)(\ |$) ]]; then FAMILY=arch
      elif [[ $tokens =~ (\ |^)(debian|ubuntu)(\ |$) ]]; then FAMILY=debian
      elif [[ $tokens =~ (\ |^)(rhel|fedora|centos)(\ |$) ]]; then FAMILY=redhat
      elif [[ $tokens =~ (\ |^)(suse|opensuse)(\ |$) ]]; then FAMILY=suse
      else die "Unsupported distribution: ${PRETTY_NAME:-$OS_ID}"; fi ;;
  esac
  case "$FAMILY" in
    debian) PKG=apt-get ;;
    redhat)
      if command -v dnf >/dev/null 2>&1; then PKG=dnf
      elif command -v yum >/dev/null 2>&1; then PKG=yum
      else die 'Missing DNF/YUM.'; fi ;;
    suse) PKG=zypper ;;
    arch) PKG=pacman ;;
  esac
  command -v "$PKG" >/dev/null 2>&1 || die "Missing package manager: $PKG"
  if [[ $INSTALL_YAY == true && $FAMILY != arch ]]; then
    die '--arch-yay is valid only on Arch-based distributions.'
  fi
  if [[ $FAMILY == arch && $UPGRADE == false ]]; then
    die 'Arch cannot skip the full upgrade: partial upgrades are unsupported.'
  fi
  log "Detected ${PRETTY_NAME:-$OS_ID} ($FAMILY / $PKG)"
}

pkg_install() {
  case "$FAMILY" in
    debian) DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@" ;;
    redhat) "$PKG" -y install "$@" ;;
    suse) zypper --non-interactive install --no-recommends "$@" ;;
    arch) pacman -S --needed --noconfirm "$@" ;;
  esac
}

pkg_has() {
  case "$FAMILY" in
    debian) apt-cache show "$1" >/dev/null 2>&1 ;;
    redhat) "$PKG" -q info "$1" >/dev/null 2>&1 ;;
    suse) zypper --non-interactive info "$1" >/dev/null 2>&1 ;;
    arch) pacman -Si "$1" >/dev/null 2>&1 ;;
  esac
}

upgrade_system() {
  log 'Refresh package metadata and upgrade system'
  case "$FAMILY" in
    debian)
      apt-get update
      if [[ $UPGRADE == true ]]; then
        DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
      fi ;;
    redhat)
      if [[ $UPGRADE == true ]]; then "$PKG" -y upgrade
      else "$PKG" -y makecache; fi ;;
    suse)
      zypper --non-interactive refresh
      if [[ $UPGRADE == true ]]; then
        if [[ $OS_ID == *tumbleweed* ]]; then zypper --non-interactive dup
        else zypper --non-interactive update; fi
      fi ;;
    arch)
      if [[ ! -s /etc/pacman.d/gnupg/pubring.gpg ]]; then
        pacman-key --init
        pacman-key --populate archlinux
      fi
      pacman -Sy --needed --noconfirm archlinux-keyring
      pacman -Su --noconfirm ;;
  esac
}

configure_arch_pacman() {
  [[ $FAMILY == arch ]] || return 0
  local conf=/etc/pacman.conf
  [[ -f $conf ]] || return 0
  if [[ ! -e $conf.bootstrap.bak ]]; then cp -p "$conf" "$conf.bootstrap.bak"; fi
  # Only manage the setting once; preserve all other user configuration.
  sed -i -E '/^[[:space:]]*#?[[:space:]]*ParallelDownloads[[:space:]]*=/d' "$conf"
  sed -i '/^\[options\]/a ParallelDownloads = 15' "$conf"
}

refresh_arch_mirrors() {
  [[ $FAMILY == arch && $REFRESH_ARCH_MIRRORS == true ]] || return 0
  [[ -f /etc/pacman.d/mirrorlist ]] || { warn 'Arch mirrorlist unavailable; skipping.'; return 0; }
  if ! pkg_has reflector; then warn 'Reflector unavailable; retaining existing mirrors.'; return 0; fi
  pkg_install reflector
  local tmp args=(--protocol https --latest 30 --sort rate --number 15)
  [[ -z ${REFLECTOR_COUNTRY:-} ]] || args+=(--country "$REFLECTOR_COUNTRY")
  tmp=$(mktemp)
  if reflector "${args[@]}" --save "$tmp" && grep -q '^Server' "$tmp"; then
    if [[ ! -e /etc/pacman.d/mirrorlist.bootstrap.bak ]]; then
      cp -p /etc/pacman.d/mirrorlist /etc/pacman.d/mirrorlist.bootstrap.bak
    fi
    install -m 0644 "$tmp" /etc/pacman.d/mirrorlist
    log 'Arch mirrors refreshed; complete full upgrade on new mirrors'
    pacman -Syyu --noconfirm
  else
    warn 'Reflector did not return usable mirrors; old mirrorlist retained.'
  fi
  rm -f "$tmp"
}

install_tools() {
  log 'Install development tools, Python, Go, Zsh and OpenSSH'
  case "$FAMILY" in
    debian)
      pkg_install ca-certificates curl wget sudo git gcc g++ make pkg-config \
        zip unzip python3 python3-pip golang-go zsh openssh-server \
        less nano vim passwd util-linux ;;
    redhat)
      pkg_install ca-certificates curl wget sudo git gcc gcc-c++ make pkgconf-pkg-config \
        zip unzip python3 python3-pip golang zsh openssh-server \
        less nano vim passwd shadow-utils util-linux ;;
    suse)
      pkg_install ca-certificates curl wget sudo git gcc gcc-c++ make pkg-config \
        zip unzip python3 python3-pip go zsh openssh \
        less nano vim shadow util-linux ;;
    arch)
      pkg_install base-devel go git zip unzip python python-pip zsh sudo curl wget \
        ca-certificates openssh less nano vim shadow util-linux ;;
  esac
  command -v runuser >/dev/null 2>&1 || die 'runuser is required.'
  command -v visudo >/dev/null 2>&1 || die 'visudo is required.'
}

# NVM installs upstream Node.js binaries, which can dynamically require
# libatomic.so.1. Minimal LXC images (notably AlmaLinux/RHEL-family) may lack it.
# Avoid pulling in extra packages when the correct runtime is already present.
libatomic_available() {
  command -v ldconfig >/dev/null 2>&1 || return 1
  ldconfig -p 2>/dev/null | grep -E '^[[:space:]]*libatomic\.so\.1[[:space:]]+\(' >/dev/null
}

install_node_runtime_deps() {
  log 'Ensure GNU libatomic runtime is available for NVM-managed Node.js'
  if libatomic_available; then
    log 'libatomic.so.1 is already available; no additional package required'
    return 0
  fi

  local atomic_pkg
  case "$FAMILY" in
    redhat) atomic_pkg=libatomic ;;
    debian|suse) atomic_pkg=libatomic1 ;;
    arch)
      # Arch recently split libatomic from gcc-libs. Support older mirrors too.
      if pkg_has libatomic; then atomic_pkg=libatomic
      else atomic_pkg=gcc-libs; fi ;;
    *) die "No libatomic package mapping for $FAMILY" ;;
  esac

  log "Install Node.js runtime dependency: $atomic_pkg"
  pkg_install "$atomic_pkg"
  command -v ldconfig >/dev/null 2>&1 || die 'ldconfig unavailable: cannot verify libatomic.so.1'
  ldconfig
  libatomic_available || die "libatomic.so.1 still missing after installing $atomic_pkg; inspect package repositories and linker configuration."
}

setup_apt_docker_repo() {
  local flavor=$1 codename arch tmp
  # Docker's official apt repositories are distribution/codename-specific.
  if [[ $OS_ID == ubuntu ]]; then codename=${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}
  else codename=${VERSION_CODENAME:-}; fi
  [[ $codename =~ ^[a-z0-9]+$ ]] || die 'Cannot determine Docker repository codename.'
  arch=$(dpkg --print-architecture)
  install -d -m 0755 /etc/apt/keyrings
  if [[ ! -f /etc/apt/keyrings/docker.asc ]]; then
    tmp=$(mktemp)
    curl -fsSL "https://download.docker.com/linux/$flavor/gpg" -o "$tmp"
    install -m 0644 "$tmp" /etc/apt/keyrings/docker.asc
    rm -f "$tmp"
  fi
  if [[ ! -e /etc/apt/sources.list.d/docker.sources ]]; then
    cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/$flavor
Suites: $codename
Components: stable
Architectures: $arch
Signed-By: /etc/apt/keyrings/docker.asc
EOF
  fi
  apt-get update
}

setup_rpm_docker_repo() {
  local flavor=$1 tmp
  [[ -f /etc/yum.repos.d/docker-ce.repo ]] && return 0
  install -d -m 0755 /etc/yum.repos.d
  tmp=$(mktemp)
  curl -fsSL "https://download.docker.com/linux/$flavor/docker-ce.repo" -o "$tmp"
  grep -q '^\[docker-ce-stable\]' "$tmp" || die 'Invalid Docker RPM repo configuration.'
  install -m 0644 "$tmp" /etc/yum.repos.d/docker-ce.repo
  rm -f "$tmp"
}

install_distro_docker() {
  case "$FAMILY" in
    debian)
      pkg_install docker.io
      if pkg_has docker-compose-v2; then pkg_install docker-compose-v2
      elif pkg_has docker-compose-plugin; then pkg_install docker-compose-plugin
      else die 'No Compose V2 package in distro repos. Use official Docker packages on Debian/Ubuntu.'; fi ;;
    redhat)
      if pkg_has moby-engine; then pkg_install moby-engine
      elif pkg_has docker; then pkg_install docker
      else die 'No distro Docker engine found. Use --docker-source official on supported RPM distributions.'; fi
      if pkg_has docker-compose-plugin; then pkg_install docker-compose-plugin
      elif pkg_has docker-compose; then pkg_install docker-compose
      else die 'No distro Compose package found. Use official Docker packages.'; fi ;;
    suse) pkg_install docker docker-compose ;;
    arch) pkg_install docker docker-compose ;;
  esac
}

install_docker() {
  [[ $INSTALL_DOCKER == true ]] || { log 'Docker installation skipped'; return 0; }
  log 'Install Docker Engine and Compose V2'
  local source=$DOCKER_SOURCE flavor=''
  if [[ $source == auto ]]; then
    case "$OS_ID" in
      debian|ubuntu|fedora|rhel|centos|rocky|almalinux) source=official ;;
      *) source=distro ;;
    esac
  fi
  if [[ $source == official ]]; then
    case "$FAMILY:$OS_ID" in
      debian:debian|debian:ubuntu)
        setup_apt_docker_repo "$OS_ID"
        pkg_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin ;;
      redhat:fedora|redhat:rhel|redhat:centos|redhat:rocky|redhat:almalinux)
        case "$OS_ID" in
          fedora|rhel|centos) flavor=$OS_ID ;;
          rocky|almalinux) flavor=centos ;;
        esac
        setup_rpm_docker_repo "$flavor"
        pkg_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin ;;
      *) die "Official Docker repository mapping not defined for $OS_ID; use --docker-source distro." ;;
    esac
  else
    install_distro_docker
  fi
  command -v docker >/dev/null 2>&1 || die 'Docker CLI not found after installation.'
  docker compose version >/dev/null 2>&1 || die 'Docker Compose V2 is unavailable after installation.'
}

# runuser inherits the caller's working directory (e.g., private /root).
# Enter the developer home before switching UID; the subshell preserves the
# calling shell's working directory for subsequent root-only operations.
as_dev() (
  cd -- "$DEV_HOME" || return 1
  runuser -u "$DEV_USER" -- env HOME="$DEV_HOME" USER="$DEV_USER" LOGNAME="$DEV_USER" "$@"
)

setup_account() {
  log "Configure developer account: $DEV_USER"
  if id "$DEV_USER" >/dev/null 2>&1; then
    [[ $(id -u "$DEV_USER") -ne 0 ]] || die 'Developer UID must not be root.'
  else
    useradd -m -U -s "$(command -v zsh)" "$DEV_USER"
    CREATED_ACCOUNT=true
  fi
  usermod -s "$(command -v zsh)" "$DEV_USER"
  DEV_HOME=$(getent passwd "$DEV_USER" | cut -d: -f6)
  [[ -d $DEV_HOME && $DEV_HOME == /* && $DEV_HOME != / ]] || die "Invalid user home: $DEV_HOME"
  # Group grants no sudo by itself; our managed sudoers rule is authoritative.
  local admin_group
  case "$FAMILY" in debian) admin_group=sudo ;; *) admin_group=wheel ;; esac
  if getent group "$admin_group" >/dev/null; then usermod -aG "$admin_group" "$DEV_USER"; fi

  if [[ $PASSWORD_STDIN == true ]]; then
    printf '%s:%s\n' "$DEV_USER" "$ACCOUNT_PASSWORD" | chpasswd
    unset ACCOUNT_PASSWORD
  elif [[ -t 0 && $USERNAME_SUPPLIED == false ]]; then
    passwd "$DEV_USER"
  elif [[ $CREATED_ACCOUNT == true ]]; then
    warn "Account $DEV_USER has no password; use passwd $DEV_USER or SSH public key authentication."
  fi

  local sudo_rule tmp
  sudo_rule="/etc/sudoers.d/20-lxc-dev-bootstrap-$DEV_USER"
  tmp=$(mktemp)
  if [[ $SUDO_MODE == nopasswd ]]; then
    printf '%s ALL=(ALL:ALL) NOPASSWD: ALL\n' "$DEV_USER" > "$tmp"
  else
    printf '%s ALL=(ALL:ALL) ALL\n' "$DEV_USER" > "$tmp"
  fi
  chmod 0440 "$tmp"
  visudo -cf "$tmp" >/dev/null
  [[ -d /etc/sudoers.d ]] || install -d -m 0755 /etc/sudoers.d
  install -m 0440 "$tmp" "$sudo_rule"
  rm -f "$tmp"

  if [[ $INSTALL_DOCKER == true ]]; then
    getent group docker >/dev/null || groupadd docker
    usermod -aG docker "$DEV_USER"
  fi
  if [[ -n $SSH_KEY_FILE ]]; then
    as_dev install -d -m 0700 "$DEV_HOME/.ssh"
    as_dev touch "$DEV_HOME/.ssh/authorized_keys"
    while IFS= read -r key || [[ -n $key ]]; do
      [[ -z $key || $key == \#* ]] && continue
      if ! as_dev grep -Fxq -- "$key" "$DEV_HOME/.ssh/authorized_keys"; then
        printf '%s\n' "$key" | as_dev tee -a "$DEV_HOME/.ssh/authorized_keys" >/dev/null
      fi
    done < "$SSH_KEY_FILE"
    as_dev chmod 0600 "$DEV_HOME/.ssh/authorized_keys"
  fi
}

install_arch_yay() {
  [[ $INSTALL_YAY == true ]] || return 0
  [[ $SUDO_MODE == nopasswd ]] || die '--arch-yay requires --sudo-mode nopasswd for noninteractive makepkg dependencies.'
  log "Install yay AUR helper as $DEV_USER (explicitly opted in)"
  if command -v yay >/dev/null 2>&1; then return 0; fi
  if pkg_has yay; then
    pkg_install yay
    return 0
  fi
  local dir="$DEV_HOME/.cache/yay-bootstrap"
  as_dev mkdir -p "$DEV_HOME/.cache"
  if [[ ! -d "$dir/.git" ]]; then
    [[ ! -e "$dir" ]] || die "$dir exists but is not a Git checkout."
    as_dev git clone --depth 1 https://aur.archlinux.org/yay.git "$dir"
  fi
  # makepkg must never run as root. AUR PKGBUILDs are third-party code.
  as_dev bash -c 'cd "$1" && makepkg -si --needed --noconfirm' _ "$dir"
}

setup_user_shell() {
  log "Configure Oh My Zsh, autosuggestions and NVM for $DEV_USER"
  as_dev mkdir -p "$DEV_HOME/.local/share"
  if [[ ! -e $DEV_HOME/.oh-my-zsh ]]; then
    as_dev git clone --depth 1 https://github.com/ohmyzsh/ohmyzsh.git "$DEV_HOME/.oh-my-zsh"
  fi
  if [[ ! -e $DEV_HOME/.local/share/zsh-autosuggestions ]]; then
    as_dev git clone --depth 1 https://github.com/zsh-users/zsh-autosuggestions.git \
      "$DEV_HOME/.local/share/zsh-autosuggestions"
  fi
  if [[ ! -e $DEV_HOME/.nvm ]]; then
    as_dev git clone --depth 1 --branch "$NVM_VERSION" https://github.com/nvm-sh/nvm.git "$DEV_HOME/.nvm"
  fi
  [[ -f $DEV_HOME/.nvm/nvm.sh ]] || die 'NVM installation is incomplete.'
  [[ -f $DEV_HOME/.oh-my-zsh/oh-my-zsh.sh ]] || die 'Oh My Zsh installation is incomplete.'
  [[ -f $DEV_HOME/.local/share/zsh-autosuggestions/zsh-autosuggestions.zsh ]] || die 'Zsh autosuggestions installation is incomplete.'

  as_dev touch "$DEV_HOME/.zshrc"
  # Remove either older Arch marker or this script's marker. Preserve user edits.
  as_dev sed -i \
    -e '/^# BEGIN arch-lxc-bootstrap$/,/^# END arch-lxc-bootstrap$/d' \
    -e '/^# BEGIN lxc-dev-bootstrap$/,/^# END lxc-dev-bootstrap$/d' \
    "$DEV_HOME/.zshrc"
  as_dev tee -a "$DEV_HOME/.zshrc" >/dev/null <<'ZSHRC'
# BEGIN lxc-dev-bootstrap
export ZSH="$HOME/.oh-my-zsh"
[[ -f "$ZSH/oh-my-zsh.sh" ]] && source "$ZSH/oh-my-zsh.sh"
[[ -f "$HOME/.local/share/zsh-autosuggestions/zsh-autosuggestions.zsh" ]] && source "$HOME/.local/share/zsh-autosuggestions/zsh-autosuggestions.zsh"
export NVM_DIR="$HOME/.nvm"
[[ -s "$NVM_DIR/nvm.sh" ]] && source "$NVM_DIR/nvm.sh"
# END lxc-dev-bootstrap
ZSHRC
}

start_service() {
  local service
  for service in "$@"; do
    if systemctl cat "$service" >/dev/null 2>&1; then
      if systemctl enable --now "$service"; then return 0; fi
      warn "Could not start $service; inspect journalctl -u $service"
      return 1
    fi
  done
  warn "Service unit not found: $*"
  return 1
}

configure_services() {
  log 'Prepare OpenSSH host keys'
  ssh-keygen -A
  if [[ $START_SERVICES != true ]]; then
    warn 'Service management disabled with --no-services.'
  elif [[ ! -d /run/systemd/system ]] || ! command -v systemctl >/dev/null 2>&1; then
    warn 'systemd is not running; SSH/Docker installed but services were not started.'
  else
    log 'Enable and start SSH'
    start_service sshd.service ssh.service || true
    if [[ $INSTALL_DOCKER == true ]]; then
      log 'Enable and start Docker'
      start_service docker.service || true
    fi
  fi
}

verify_setup() {
  log 'Verify installation'
  as_dev python3 --version
  as_dev git --version
  as_dev go version
  as_dev zsh --version
  if [[ $INSTALL_YAY == true ]]; then as_dev yay --version; fi
  if [[ $INSTALL_DOCKER == true ]]; then
    as_dev docker --version
    as_dev docker compose version
    if [[ -d /run/systemd/system && $START_SERVICES == true ]]; then
      systemctl is-active --quiet docker.service || warn 'Docker service is not active; LXC nesting/keyctl/cgroup settings may be required.'
    fi
  fi
  if [[ $SUDO_MODE == nopasswd ]]; then
    as_dev sudo -n true || die 'Passwordless sudo verification failed.'
  else
    visudo -cf "/etc/sudoers.d/20-lxc-dev-bootstrap-$DEV_USER" >/dev/null
  fi
  printf '\nBootstrap complete\nDistribution: %s\nDeveloper: %s\nGroups: %s\nLogin: su - %s\nLog: %s\n' \
    "$OS_ID $OS_VERSION" "$DEV_USER" "$(id -nG "$DEV_USER")" "$DEV_USER" "$LOG_FILE"
  warn 'Docker group membership grants root-level privileges. Passwordless sudo is also root-equivalent.'
  warn 'Re-login is required for new group membership and default shell changes.'
}

main() {
  parse_args "$@"
  # Do not expose any stdin password in process args or output.
  install -d -m 0755 "$(dirname "$LOG_FILE")"
  touch "$LOG_FILE"
  chmod 0600 "$LOG_FILE"
  exec > >(tee -a "$LOG_FILE") 2>&1
  detect_os
  configure_arch_pacman
  upgrade_system
  refresh_arch_mirrors
  install_tools
  install_node_runtime_deps
  install_docker
  setup_account
  install_arch_yay
  setup_user_shell
  configure_services
  verify_setup
}
main "$@"
