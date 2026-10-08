#!/usr/bin/env bash
# Arch Linux LXC development-container bootstrap
set -Eeuo pipefail

LOG_FILE=/var/log/arch-lxc-bootstrap.log
MIRRORLIST=/etc/pacman.d/mirrorlist
PACMAN_CONF=/etc/pacman.conf
AUR_USER=''
DEV_USER=''
ENABLE_DOCKER='yes'

log() { printf '\n\033[1;32m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33mWARNING: %s\033[0m\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
trap 'warn "Command failed at line $LINENO. See $LOG_FILE"' ERR

[[ $EUID -eq 0 ]] || die 'Run this script as root.'
[[ -f /etc/arch-release ]] || die 'This script supports Arch Linux only.'
[[ -e /run/systemd/system ]] || warn 'systemd is not PID 1; Docker service activation may need manual handling.'
exec > >(tee -a "$LOG_FILE") 2>&1

read -r -p 'Create/configure a development user? [Y/n]: ' CREATE_USER
CREATE_USER=${CREATE_USER:-Y}
if [[ $CREATE_USER =~ ^[Yy]$ ]]; then
  read -r -p 'Username: ' DEV_USER
  [[ $DEV_USER =~ ^[a-z_][a-z0-9_-]*$ ]] || die 'Invalid Linux username.'
  if id "$DEV_USER" &>/dev/null; then
    log "Using existing user: $DEV_USER"
  else
    useradd -m -U -s /bin/zsh "$DEV_USER" 2>/dev/null || {
      # zsh may not exist until after initial package installation
      useradd -m -U -s /bin/bash "$DEV_USER"
    }
  fi
  log "Set password for $DEV_USER (interactive; not logged)"
  passwd "$DEV_USER"
  AUR_USER=$DEV_USER
else
  AUR_USER=aurbuilder
  if ! id "$AUR_USER" &>/dev/null; then
    useradd -m -U -s /bin/bash "$AUR_USER"
    passwd -l "$AUR_USER" >/dev/null
  fi
  log "Using locked-password build account '$AUR_USER' for yay/AUR operations"
fi

log 'Configure pacman: 15 parallel downloads'
cp -n "$PACMAN_CONF" "$PACMAN_CONF.bootstrap.bak" || true
sed -i -E '/^[[:space:]]*#?[[:space:]]*ParallelDownloads[[:space:]]*=/d' "$PACMAN_CONF"
sed -i '/^\[options\]/a ParallelDownloads = 15' "$PACMAN_CONF"

log 'Initialize pacman signing keys if needed'
if [[ ! -s /etc/pacman.d/gnupg/pubring.gpg ]]; then
  pacman-key --init
  pacman-key --populate archlinux
fi

log 'Refresh repository databases and upgrade Arch keyring'
pacman -Sy --noconfirm archlinux-keyring
log 'Upgrade all installed packages (avoid partial upgrades)'
pacman -Syu --noconfirm

log 'Install reflector and bootstrap utilities'
pacman -S --needed --noconfirm reflector ca-certificates curl sudo git
log 'Update mirrorlist with current HTTPS mirrors'
cp -n "$MIRRORLIST" "$MIRRORLIST.bootstrap.bak" || true
TMP_MIRROR=$(mktemp)
# Optional reflector-country override: REFLECTOR_COUNTRY='India,Singapore'
REFLECTOR_ARGS=(--protocol https --latest 30 --sort rate --number 15)
if [[ -n "${REFLECTOR_COUNTRY:-}" ]]; then
  REFLECTOR_ARGS+=(--country "$REFLECTOR_COUNTRY")
fi
if reflector "${REFLECTOR_ARGS[@]}" --save "$TMP_MIRROR" && grep -q '^Server' "$TMP_MIRROR"; then
  cp "$TMP_MIRROR" "$MIRRORLIST"
else
  warn 'Reflector failed; preserving the existing mirrorlist.'
fi
rm -f "$TMP_MIRROR"
pacman -Syyu --noconfirm

log 'Install developer tools, shells and container tooling'
pacman -S --needed --noconfirm \
  base-devel go git zip unzip python python-pip zsh zsh-autosuggestions \
  sudo curl wget openssh less nano vim

if [[ -n "$DEV_USER" ]]; then
  usermod -s /bin/zsh "$DEV_USER"
  # Arch Linux uses the wheel group for sudo administration.
  # Grant passwordless sudo only to this development user, not the whole wheel group.
  usermod -aG wheel "$DEV_USER"
  SUDOERS_FILE="/etc/sudoers.d/20-arch-lxc-dev-${DEV_USER}"
  printf '%s ALL=(ALL:ALL) NOPASSWD: ALL\n' "$DEV_USER" > "$SUDOERS_FILE"
  chmod 440 "$SUDOERS_FILE"
  visudo -cf "$SUDOERS_FILE"
  # Remove the older bootstrap policy, if created by a previous version.
  if [[ -f /etc/sudoers.d/10-wheel-dev ]] &&
     grep -qx '%wheel ALL=(ALL:ALL) ALL' /etc/sudoers.d/10-wheel-dev; then
    rm -f /etc/sudoers.d/10-wheel-dev
  fi
fi

# Makepkg/yay require a non-root account. The provisioning script runs as root.
install -d -o "$AUR_USER" -g "$(id -gn "$AUR_USER")" "/home/$AUR_USER/.cache"
log "Install yay (AUR helper) using $AUR_USER"
if ! command -v yay >/dev/null 2>&1; then
  # Prefer official binary package if repo provides one; otherwise build from AUR.
  if pacman -Si yay >/dev/null 2>&1; then
    pacman -S --needed --noconfirm yay
  else
    BUILD_DIR=$(mktemp -d /tmp/yay-build.XXXXXX)
    chown "$AUR_USER:$(id -gn "$AUR_USER")" "$BUILD_DIR"
    runuser -u "$AUR_USER" -- git clone --depth 1 https://aur.archlinux.org/yay.git "$BUILD_DIR/yay"
    # Compile without granting the AUR user passwordless root permissions.
    runuser -u "$AUR_USER" -- bash -c 'cd "$1" && makepkg -s --noconfirm --needed' _ "$BUILD_DIR/yay"
    mapfile -t YAY_PKGS < <(find "$BUILD_DIR/yay" -maxdepth 1 -type f -name 'yay-*.pkg.tar.*' ! -name '*.sig')
    ((${#YAY_PKGS[@]} > 0)) || die 'yay build did not produce a package.'
    pacman -U --noconfirm "${YAY_PKGS[@]}"
    rm -rf "$BUILD_DIR"
  fi
fi

log 'Install nvm, Docker and Docker Compose using yay'
# yay cannot run as root. Give the dedicated provisioning user temporary pacman-only sudo,
# then revoke it immediately; do not use this workflow with untrusted AUR packages.
YAY_SUDOERS=/etc/sudoers.d/99-arch-lxc-yay-temporary
cleanup_yay_sudo() { rm -f "$YAY_SUDOERS"; }
trap 'cleanup_yay_sudo; warn "Command failed at line $LINENO. See $LOG_FILE"' ERR
printf '%s ALL=(root) NOPASSWD: /usr/bin/pacman\n' "$AUR_USER" > "$YAY_SUDOERS"
chmod 440 "$YAY_SUDOERS"
visudo -cf "$YAY_SUDOERS"
if ! runuser -u "$AUR_USER" -- env SUDO_ASKPASS=/bin/false yay -S --needed --noconfirm nvm docker docker-compose; then
  cleanup_yay_sudo
  die 'yay installation failed; no fallback that hides an error.'
fi
cleanup_yay_sudo
trap 'warn "Command failed at line $LINENO. See $LOG_FILE"' ERR

setup_shell() {
  local username="$1" home_dir groupname
  home_dir=$(getent passwd "$username" | cut -d: -f6)
  groupname=$(id -gn "$username")
  [[ -d "$home_dir" ]] || return 0
  if [[ ! -d "$home_dir/.oh-my-zsh" ]]; then
    log "Install Oh My Zsh for $username"
    runuser -u "$username" -- git clone --depth 1 https://github.com/ohmyzsh/ohmyzsh.git "$home_dir/.oh-my-zsh"
  fi
  if [[ ! -f "$home_dir/.zshrc" ]]; then
    if [[ -f "$home_dir/.oh-my-zsh/templates/zshrc.zsh-template" ]]; then
      printf '# Shell configuration managed by arch-lxc-bootstrap\n' > "$home_dir/.zshrc"
    else
      touch "$home_dir/.zshrc"
    fi
  fi
  # Add an idempotent, distro-aware zsh config block.
  local begin='# BEGIN arch-lxc-bootstrap' end='# END arch-lxc-bootstrap'
  sed -i "/^${begin}$/,/^${end}$/d" "$home_dir/.zshrc"
  cat >> "$home_dir/.zshrc" <<'ZSHCONFIG'
# BEGIN arch-lxc-bootstrap
export ZSH="$HOME/.oh-my-zsh"
[[ -f "$ZSH/oh-my-zsh.sh" ]] && source "$ZSH/oh-my-zsh.sh"
[[ -f /usr/share/zsh/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh ]] && source /usr/share/zsh/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh
export NVM_DIR="$HOME/.nvm"
[[ -f /usr/share/nvm/init-nvm.sh ]] && source /usr/share/nvm/init-nvm.sh
# END arch-lxc-bootstrap
ZSHCONFIG
  chown "$username:$groupname" "$home_dir/.zshrc"
}

if [[ -n "$DEV_USER" ]]; then
  setup_shell "$DEV_USER"
  log "Add $DEV_USER to docker group"
  getent group docker >/dev/null || groupadd docker
  usermod -aG docker "$DEV_USER"
  warn 'Passwordless sudo and Docker group membership grant root-equivalent access.'
else
  warn 'No development user selected: Oh My Zsh will not be installed for a login user.'
fi

if [[ -e /run/systemd/system ]]; then
  log 'Enable and start Docker daemon'
  if ! systemctl enable --now docker; then
    warn 'Docker failed to start. Docker-in-LXC needs host-side nesting/keyctl and suitable storage/security settings.'
  fi
else
  warn 'systemd unavailable. Docker daemon was installed but not started.'
fi

log 'Check installed versions'
pacman --version | head -n 2
yay --version || true
python --version || true
docker --version || true
docker compose version || true
log 'Bootstrap complete'
printf 'Development user: %s\nAUR build user: %s\nLog: %s\n' "${DEV_USER:-none}" "$AUR_USER" "$LOG_FILE"
if [[ -n "$DEV_USER" ]]; then
  printf 'Switch to user: su - %s\n' "$DEV_USER"
  printf 'Groups: %s\nPasswordless sudo: enabled (user-specific sudoers rule)\n' "$(id -nG "$DEV_USER")"
fi