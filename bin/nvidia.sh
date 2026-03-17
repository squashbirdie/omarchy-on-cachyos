#!/usr/bin/env bash
set -Eeuo pipefail

log()  { printf "\033[1;34m[INFO]\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m[WARN]\033[0m %s\n" "$*"; }
err()  { printf "\033[1;31m[ERR ]\033[0m %s\n" "$*" >&2; }

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    err "Run as root: sudo $0"
    exit 1
  fi
}

has_cmd() {
  command -v "$1" >/dev/null 2>&1
}

detect_distro() {
  local id="" id_like=""
  if [[ -r /etc/os-release ]]; then
    . /etc/os-release
    id="${ID:-}"
    id_like="${ID_LIKE:-}"
  fi

  if [[ "$id" == "cachyos" ]] || [[ "$id_like" == *"cachyos"* ]]; then
    echo "cachyos"
    return
  fi

  if [[ -f /etc/omarchy-release ]] || grep -Rqi "omarchy" /etc 2>/dev/null; then
    echo "omarchy"
    return
  fi

  if [[ "$id" == "arch" ]] || [[ "$id_like" == *"arch"* ]]; then
    echo "arch"
    return
  fi

  echo "unknown"
}

get_gpu_info() {
  # First NVIDIA VGA/3D controller line
  lspci -nn | grep -E 'NVIDIA|10de:' | grep -E 'VGA|3D' | head -n1
}

get_gpu_pci_id() {
  local line
  line="$(get_gpu_info || true)"
  grep -oP '(?<=\[10de:)[0-9a-fA-F]{4}(?=\])' <<<"$line" || true
}

is_rtx50_or_newer() {
  local line
  line="$(get_gpu_info || true)"

  # Best-effort name check. Hyprland's current NVIDIA guidance says
  # 50xx and newer require the open kernel modules with proprietary userspace.
  grep -Eq 'RTX 50|RTX 5[0-9]{3}|5070|5080|5090' <<<"$line"
}

remove_conflicts() {
  log "Removing conflicting NVIDIA/open-driver package combinations"
  pacman -Rdd --noconfirm \
    linux-cachyos-nvidia-open \
    linux-cachyos-lts-nvidia-open \
    nvidia-open-dkms \
    linux-cachyos-nvidia \
    linux-cachyos-lts-nvidia \
    nvidia-dkms \
    nvidia \
    nvidia-lts \
    2>/dev/null || true
}

install_libva_utils() {
  pacman -S --needed --noconfirm libva-utils
}

configure_uwsm_env() {
  local target_home="${SUDO_USER:+$(getent passwd "$SUDO_USER" | cut -d: -f6)}"
  target_home="${target_home:-$HOME}"

  local env_dir="$target_home/.config/uwsm"
  local env_file="$env_dir/env"

  mkdir -p "$env_dir"
  touch "$env_file"

  # Remove previously managed NVIDIA block, then rewrite it once.
  sed -i '/^# BEGIN MANAGED NVIDIA ENV$/,/^# END MANAGED NVIDIA ENV$/d' "$env_file"

  cat >>"$env_file" <<'EOF'
# BEGIN MANAGED NVIDIA ENV
export LIBVA_DRIVER_NAME=nvidia
export GBM_BACKEND=nvidia-drm
export __GLX_VENDOR_LIBRARY_NAME=nvidia
export NVD_BACKEND=direct
export MOZ_DISABLE_RDD_SANDBOX=1
# END MANAGED NVIDIA ENV
EOF

  if [[ -n "${SUDO_USER:-}" ]]; then
    chown "$SUDO_USER":"$SUDO_USER" "$env_file"
  fi

  log "Updated UWSM NVIDIA environment: $env_file"
}

configure_modprobe() {
  mkdir -p /etc/modprobe.d /etc/modules-load.d

  cat >/etc/modules-load.d/nvidia.conf <<'EOF'
nvidia
nvidia_modeset
nvidia_uvm
nvidia_drm
EOF

  cat >/etc/modprobe.d/nvidia.conf <<'EOF'
options nvidia_drm modeset=1
EOF
}

enable_nvidia_services() {
  systemctl enable nvidia-suspend.service 2>/dev/null || true
  systemctl enable nvidia-resume.service 2>/dev/null || true
  systemctl enable nvidia-hibernate.service 2>/dev/null || true
}

rebuild_initramfs() {
  if has_cmd mkinitcpio; then
    log "Rebuilding initramfs with mkinitcpio"
    mkinitcpio -P
  elif has_cmd dracut; then
    log "Rebuilding initramfs with dracut"
    dracut --regenerate-all --force
  else
    warn "No mkinitcpio/dracut found; skipping initramfs rebuild"
  fi
}

install_on_cachyos() {
  log "Detected CachyOS"

  if ! has_cmd chwd; then
    err "CachyOS detected, but chwd is not installed."
    exit 1
  fi

  remove_conflicts

  if is_rtx50_or_newer; then
    warn "Detected likely RTX 50-series GPU; preferring open kernel module path where supported."
    # Remove proprietary profile if present, then let chwd auto-detect again.
    chwd -r nvidia-dkms --noconfirm 2>/dev/null || true
    chwd -r nvidia --noconfirm 2>/dev/null || true
    chwd -a --noconfirm
  else
    chwd -r nvidia-open-dkms --noconfirm 2>/dev/null || true
    chwd -a --noconfirm
  fi

  install_libva_utils
  configure_modprobe
  enable_nvidia_services
  rebuild_initramfs
  configure_uwsm_env
}

install_on_arch_like() {
  log "Detected Omarchy/Arch-like system"

  remove_conflicts

  if is_rtx50_or_newer; then
    log "Installing NVIDIA open kernel module stack for RTX 50-series/newer"
    pacman -Syu --needed --noconfirm \
      nvidia-open-dkms \
      nvidia-utils \
      nvidia-settings \
      lib32-nvidia-utils \
      egl-wayland \
      libva-utils
  else
    log "Installing proprietary NVIDIA DKMS stack"
    pacman -Syu --needed --noconfirm \
      nvidia-dkms \
      nvidia-utils \
      nvidia-settings \
      lib32-nvidia-utils \
      egl-wayland \
      libva-utils
  fi

  configure_modprobe
  enable_nvidia_services
  rebuild_initramfs
  configure_uwsm_env
}

verify() {
  echo
  log "Verification"
  if has_cmd nvidia-smi; then
    nvidia-smi || warn "nvidia-smi exists, but the driver may need a reboot to become active"
  else
    warn "nvidia-smi not found"
  fi

  lsmod | grep -E '^nvidia' || warn "NVIDIA kernel modules are not loaded yet; reboot is probably required"
}

main() {
  require_root

  local gpu_id
  gpu_id="$(get_gpu_pci_id)"

  if [[ -z "$gpu_id" ]]; then
    log "No NVIDIA GPU found. Skipping."
    exit 0
  fi

  log "Found NVIDIA PCI ID: $gpu_id"
  log "GPU line: $(get_gpu_info)"

  local distro
  distro="$(detect_distro)"
  log "Detected distro: $distro"

  case "$distro" in
    cachyos)
      install_on_cachyos
      ;;
    omarchy|arch|unknown)
      install_on_arch_like
      ;;
  esac

  verify
  log "Done. Reboot recommended."
}

main "$@"
