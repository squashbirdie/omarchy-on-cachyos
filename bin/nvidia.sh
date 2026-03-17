#!/usr/bin/env bash
set -Eeuo pipefail

log()  { printf "\033[1;34m[INFO]\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m[WARN]\033[0m %s\n" "$*"; }
err()  { printf "\033[1;31m[ERR ]\033[0m %s\n" "$*" >&2; }

rerun_with_sudo_if_needed() {
  if [[ "${EUID}" -ne 0 ]]; then
    log "Re-running with sudo..."
    exec sudo --preserve-env=HOME,USER,LOGNAME bash "${BASH_SOURCE[0]}" "$@"
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

get_gpu_line() {
  lspci -nn | grep -E 'VGA|3D|Display' | grep -i 'nvidia' | head -n1 || true
}

get_gpu_pci_id() {
  local line
  line="$(get_gpu_line)"
  grep -oP '(?<=\[10de:)[0-9a-fA-F]{4}(?=\])' <<<"$line" || true
}

has_nvidia_gpu() {
  [[ -n "$(get_gpu_pci_id)" ]]
}

is_rtx50_or_newer() {
  local line
  line="$(get_gpu_line)"
  grep -Eqi 'RTX 50|RTX 5[0-9]{3}|5050|5060|5070|5080|5090' <<<"$line"
}

get_target_user() {
  if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    printf '%s\n' "${SUDO_USER}"
  else
    printf '%s\n' "${USER:-root}"
  fi
}

get_target_home() {
  local user
  user="$(get_target_user)"
  getent passwd "$user" | cut -d: -f6
}

remove_conflicts_arch() {
  log "Removing conflicting NVIDIA packages"
  pacman -Rdd --noconfirm \
    nvidia \
    nvidia-lts \
    nvidia-dkms \
    nvidia-open-dkms \
    linux-cachyos-nvidia \
    linux-cachyos-lts-nvidia \
    linux-cachyos-nvidia-open \
    linux-cachyos-lts-nvidia-open \
    2>/dev/null || true
}

install_kernel_headers() {
  local installed=()

  while IFS= read -r pkg; do
    installed+=("$pkg")
  done < <(pacman -Qq | grep -E '^(linux|linux-lts|linux-zen|linux-hardened|linux-cachyos|linux-cachyos-lts)$' || true)

  if [[ ${#installed[@]} -eq 0 ]]; then
    warn "Could not detect installed kernel packages; skipping explicit header install"
    return
  fi

  local headers=()
  local k
  for k in "${installed[@]}"; do
    headers+=("${k}-headers")
  done

  log "Installing kernel headers: ${headers[*]}"
  pacman -S --needed --noconfirm "${headers[@]}" || warn "Some kernel headers were not found; continue if your kernel already has matching headers installed"
}

configure_modprobe() {
  log "Configuring NVIDIA module loading"
  mkdir -p /etc/modprobe.d /etc/modules-load.d

  cat >/etc/modules-load.d/nvidia.conf <<'EOF'
nvidia
nvidia_modeset
nvidia_uvm
nvidia_drm
EOF

  cat >/etc/modprobe.d/nvidia.conf <<'EOF'
options nvidia_drm modeset=1 fbdev=1
EOF
}

configure_uwsm_env() {
  local target_user target_home env_dir env_file
  target_user="$(get_target_user)"
  target_home="$(get_target_home)"
  env_dir="${target_home}/.config/uwsm"
  env_file="${env_dir}/env"

  mkdir -p "$env_dir"
  touch "$env_file"

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

  chown -R "$target_user":"$target_user" "$target_home/.config"
  log "Updated UWSM env: $env_file"
}

enable_nvidia_services() {
  log "Enabling NVIDIA power-management services"
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
    warn "No initramfs tool found; skipping rebuild"
  fi
}

update_bootloader_if_possible() {
  if has_cmd sdboot-manage; then
    log "Refreshing systemd-boot entries"
    sdboot-manage gen || true
  fi

  if has_cmd grub-mkconfig && [[ -d /boot/grub ]]; then
    log "Refreshing GRUB config"
    grub-mkconfig -o /boot/grub/grub.cfg || true
  fi

  if has_cmd limine-mkinitcpio; then
    log "Refreshing Limine initramfs integration"
    limine-mkinitcpio || true
  fi
}

install_common_userspace() {
  pacman -Syu --needed --noconfirm \
    nvidia-utils \
    nvidia-settings \
    lib32-nvidia-utils \
    egl-wayland \
    vulkan-icd-loader \
    lib32-vulkan-icd-loader \
    libva-utils
}

install_on_cachyos() {
  log "Detected CachyOS"

  if ! has_cmd chwd; then
    err "chwd is required on CachyOS but was not found"
    exit 1
  fi

  remove_conflicts_arch

  # Let CachyOS choose the proper driver profile.
  log "Running chwd auto-detection"
  chwd -a --noconfirm

  # Ensure common userspace packages are present.
  install_common_userspace

  configure_modprobe
  enable_nvidia_services
  rebuild_initramfs
  update_bootloader_if_possible
  configure_uwsm_env
}

install_on_arch_like() {
  log "Detected Omarchy/Arch-like system"

  remove_conflicts_arch
  install_kernel_headers

  if is_rtx50_or_newer; then
    log "RTX 50-series or newer detected; installing nvidia-open-dkms"
    pacman -Syu --needed --noconfirm nvidia-open-dkms
  else
    log "Installing nvidia-dkms"
    pacman -Syu --needed --noconfirm nvidia-dkms
  fi

  install_common_userspace
  configure_modprobe
  enable_nvidia_services
  rebuild_initramfs
  update_bootloader_if_possible
  configure_uwsm_env
}

verify_install() {
  echo
  log "Verification"
  if has_cmd nvidia-smi; then
    nvidia-smi || warn "nvidia-smi exists, but the driver may not be active until after reboot"
  else
    warn "nvidia-smi not found"
  fi

  if lsmod | grep -q '^nvidia'; then
    log "NVIDIA kernel modules are loaded"
  else
    warn "NVIDIA kernel modules are not loaded yet; reboot is likely required"
  fi
}

main() {
  rerun_with_sudo_if_needed "$@"

  if ! has_nvidia_gpu; then
    log "No NVIDIA GPU found. Skipping."
    exit 0
  fi

  local gpu_id gpu_line distro
  gpu_id="$(get_gpu_pci_id)"
  gpu_line="$(get_gpu_line)"
  distro="$(detect_distro)"

  log "Found NVIDIA PCI ID: $gpu_id"
  log "GPU: $gpu_line"
  log "Detected distro: $distro"

  case "$distro" in
    cachyos)
      install_on_cachyos
      ;;
    omarchy|arch|unknown)
      install_on_arch_like
      ;;
  esac

  verify_install
  log "Done. Reboot recommended."
}

main "$@"
