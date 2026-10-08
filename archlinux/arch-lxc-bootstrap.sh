#!/usr/bin/env bash
# Arch Linux LXC development container bootstrap. Run once as root.
set -Eeuo pipefail

LOG_FILE=/var/log/arch-lxc-bootstrap.log
PACMAN_CONF=/etc/pacman.conf
MIRRORLIST=/etc/pacman.d/mirrorlist

log() { printf '\n\033[1;32m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33mWARNING: %s\033[0m\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
trap 'warn "Command failed at line $LINENO. See $LOG_FILE"' ERR

[[ $EUID -eq 0 ]] || die 'Run as root.'
[[ -f /etc/arch-release ]] || die 'Arch Linux only.'
[[ -t 0 ]] || die 'Run interactively (a terminal is required for username and password prompts).'
exec > >(tee -a "$LOG_FILE") 2>&1

# The developer is REQUIRED: yay/makepkg must never run as root.
while :; do
  read -r -p 'Developer username: ' DEV_USER
  [[ $DEV_USER =~ ^[a-z_][a-z0-9_-]*$ ]] && [[ $DEV_USER != root ]] && break
  warn 'Use a lowercase Linux username (letters, digits, underscores or hyphens).'
done

log 'Configure pacman for 15 parallel downloads'
cp -n "$PACMAN_CONF" "$PACMAN_CONF.bootstrap.bak" || true
sed -i -E '/^[[:space:]]*#?[[:space:]]*ParallelDownloads[[:space:]]*=/d' "$PACMAN_CONF"
sed -i '/^\[options\]/a ParallelDownloads = 15' "$PACMAN_CONF"

log 'Initialize and update Arch Linux keyring'
if [[ ! -s /etc/pacman.d/gnupg/pubring.gpg ]]; then
  pacman-key --init
  pacman-key --populate archlinux
fi
pacman -Sy --noconfirm archlinux-keyring
pacman -Syu --noconfirm

log 'Install mirror manager and essential utilities'
pacman -S --needed --noconfirm reflector ca-certificates curl sudo git
cp -n "$MIRRORLIST" "$MIRRORLIST.bootstrap.bak" || true
TMP_MIRROR=$(mktemp)
REFLECTOR_ARGS=(--protocol https --latest 30 --sort rate --number 15)
[[ -z ${REFLECTOR_COUNTRY:-} ]] || REFLECTOR_ARGS+=(--country "$REFLECTOR_COUNTRY")
if reflector "${REFLECTOR_ARGS[@]}" --save "$TMP_MIRROR" && grep -q '^Server' "$TMP_MIRROR"; then
  cp "$TMP_MIRROR" "$MIRRORLIST"
else
  warn 'Reflector failed; retaining previous mirrors.'
fi
rm -f "$TMP_MIRROR"
pacman -Syyu --noconfirm

log 'Install system packages (root-only operations)'
pacman -S --needed --noconfirm \
  base-devel go git zip unzip python python-pip zsh zsh-autosuggestions \
  sudo curl wget openssh less nano vim

if id "$DEV_USER" &>/dev/null; then
  log "Using existing developer account: $DEV_USER"
  [[ $(id -u "$DEV_USER") -ne 0 ]] || die 'Developer must be a non-root account.'
else
  log "Create development account: $DEV_USER"
  useradd -m -U -s /bin/zsh "$DEV_USER"
fi
usermod -s /bin/zsh "$DEV_USER"
DEV_HOME=$(getent passwd "$DEV_USER" | cut -d: -f6)
[[ -d $DEV_HOME ]] || die "Home directory does not exist: $DEV_HOME"

# passwd reads securely from the terminal; never store credentials in variables/logs.
log "Set password for $DEV_USER (input not echoed)"
passwd "$DEV_USER"

log 'Configure passwordless sudo and Docker group membership'
getent group docker >/dev/null || groupadd docker
usermod -aG wheel,docker "$DEV_USER"
SUDOERS_FILE="/etc/sudoers.d/20-arch-lxc-dev-${DEV_USER}"
printf '%s ALL=(ALL:ALL) NOPASSWD: ALL\n' "$DEV_USER" > "$SUDOERS_FILE"
chmod 0440 "$SUDOERS_FILE"
visudo -cf "$SUDOERS_FILE"
# Remove a rule from an older revision if it exists.
if [[ -f /etc/sudoers.d/10-wheel-dev ]] &&
   grep -qx '%wheel ALL=(ALL:ALL) ALL' /etc/sudoers.d/10-wheel-dev; then
  rm -f /etc/sudoers.d/10-wheel-dev
fi

# All user-level commands are launched with the developer's real UID/HOME.
# runuser is called by root, but the commands it executes run as DEV_USER.
as_dev() { runuser -u "$DEV_USER" -- "$@"; }

log "Build/install yay as $DEV_USER"
if ! command -v yay >/dev/null 2>&1; then
  if pacman -Si yay >/dev/null 2>&1; then
    # Official package management must stay with root.
    pacman -S --needed --noconfirm yay
  else
    # Work in the user's home to avoid /tmp ownership complications.
    as_dev mkdir -p "$DEV_HOME/.cache"
    if [[ ! -d "$DEV_HOME/.cache/yay-bootstrap/.git" ]]; then
      as_dev git clone --depth 1 https://aur.archlinux.org/yay.git "$DEV_HOME/.cache/yay-bootstrap"
    fi
    # makepkg uses the developer's passwordless sudo for dependency installation.
    as_dev bash -c 'cd "$1" && makepkg -si --needed --noconfirm' _ "$DEV_HOME/.cache/yay-bootstrap"
  fi
fi

log "Install nvm, Docker and Docker Compose using yay as $DEV_USER"
# yay calls sudo for system package transactions. Never invoke yay as root.
as_dev yay -S --needed --noconfirm nvm docker docker-compose

log "Configure Oh My Zsh for $DEV_USER"
if [[ ! -d "$DEV_HOME/.oh-my-zsh" ]]; then
  as_dev git clone --depth 1 https://github.com/ohmyzsh/ohmyzsh.git "$DEV_HOME/.oh-my-zsh"
fi
as_dev touch "$DEV_HOME/.zshrc"
# Re-run safely: replace our managed block, preserving user's other settings.
as_dev sed -i '/^# BEGIN arch-lxc-bootstrap$/,/^# END arch-lxc-bootstrap$/d' "$DEV_HOME/.zshrc"
as_dev tee -a "$DEV_HOME/.zshrc" >/dev/null <<'ZSHCONFIG'
# BEGIN arch-lxc-bootstrap
export ZSH="$HOME/.oh-my-zsh"
[[ -f "$ZSH/oh-my-zsh.sh" ]] && source "$ZSH/oh-my-zsh.sh"
[[ -f /usr/share/zsh/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh ]] && source /usr/share/zsh/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh
export NVM_DIR="$HOME/.nvm"
[[ -f /usr/share/nvm/init-nvm.sh ]] && source /usr/share/nvm/init-nvm.sh
# END arch-lxc-bootstrap
ZSHCONFIG

if [[ -e /run/systemd/system ]]; then
  log 'Enable Docker system service (root-only operation)'
  systemctl enable --now docker || warn 'Docker did not start. Proxmox LXC may need nesting/keyctl and suitable host settings.'
else
  warn 'systemd is unavailable; Docker daemon was installed but not started.'
fi

log 'Verify installations'
as_dev yay --version
as_dev python --version
as_dev docker --version
as_dev docker compose version
as_dev sudo -n true || die 'Passwordless sudo verification failed.'
printf '\nBootstrap complete. Developer: %s\nGroups: %s\nLogin: su - %s\nLog: %s\n' \
  "$DEV_USER" "$(id -nG "$DEV_USER")" "$DEV_USER" "$LOG_FILE"
warn 'Passwordless sudo and Docker group membership provide root-equivalent access.'
