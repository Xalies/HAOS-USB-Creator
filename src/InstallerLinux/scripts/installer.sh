#!/bin/sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"

. "$SCRIPT_DIR/logging.sh"
. "$SCRIPT_DIR/tui.sh"
. "$SCRIPT_DIR/uefi.sh"
. "$SCRIPT_DIR/legacy-bios.sh"
. "$SCRIPT_DIR/disk-detect.sh"
. "$SCRIPT_DIR/haos-release.sh"
. "$SCRIPT_DIR/image-cache.sh"
. "$SCRIPT_DIR/ssh.sh"
. "$SCRIPT_DIR/image-select.sh"
. "$SCRIPT_DIR/target-select.sh"
. "$SCRIPT_DIR/write-image.sh"

check_runtime_dependencies() {
  missing=""

  for command_name in blkid curl findmnt jq lsblk mount mountpoint sha256sum; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
      missing="$missing $command_name"
    fi
  done

  if [ -n "$missing" ]; then
    log_error "Installer is missing required runtime command(s):$missing"
    return 1
  fi

  check_write_dependencies
}

main() {
  log_info "Starting HAOS AIO Installer USB Linux flow."
  if [ -f /etc/haos-installer-build ]; then
    log_info "Boot image build info: $(tr '\n' ' ' </etc/haos-installer-build)"
  else
    log_warn "Boot image build info file is missing."
  fi

  check_runtime_dependencies
  check_uefi_mode || log_warn "Installer should continue only with explicit user acknowledgement in a later milestone."
  check_secure_boot || true
  initialize_cache_logging || log_warn "Could not enable persistent USB logging."
  start_configured_ssh || log_warn "Configured SSH could not be started."

  if installer_unattended_enabled; then
    export HAOS_UNATTENDED=1
    log_warn "Unattended install mode is enabled by USB creator configuration."
    log_warn "Installer will continue without prompts only if exactly one eligible internal target disk is detected."
  else
    log_warn "This installer can erase the selected target disk after explicit confirmation."
    tui_message \
      "HAOS AIO Installer USB" \
      "This installer will install Home Assistant OS onto a dedicated internal disk.\n\nIt will check for a downloaded image on this USB, look online for a newer image when possible, then ask you to choose the disk to erase."
  fi

  targets_json="${HAOS_TARGETS_JSON:-/tmp/haos-install-targets.json}"
  list_install_targets > "$targets_json"
  log_info "Install target candidates written to $targets_json."

  if installer_unattended_enabled && unattended_completed_install_matches "$targets_json"; then
    target_disk="$(jq -r '.[0].path' "$targets_json")"
    log_warn "Unattended install completion marker matches the only eligible internal disk: $target_disk"
    log_warn "Skipping reinstall to avoid an unattended install loop."
    boot_installed_system_or_stop "$target_disk"
  fi

  if installer_unattended_enabled && unattended_target_already_looks_installed "$targets_json"; then
    target_disk="$(jq -r '.[0].path' "$targets_json")"
    log_warn "The only eligible internal disk already looks like a Home Assistant OS install: $target_disk"
    log_warn "Unattended reinstall is blocked to avoid an install loop. Use manual mode to reinstall over an existing HAOS disk."
    boot_installed_system_or_stop "$target_disk"
  fi

  image_path="$(select_install_image || true)"
  if [ -z "$image_path" ]; then
    log_error "No install image selected."
    exit 1
  fi
  image_path="$(printf '%s\n' "$image_path" | tail -n 1)"
  if [ ! -f "$image_path" ]; then
    log_error "Selected HAOS image does not exist: $image_path"
    log_error "Cache verification details:"
    cat /tmp/haos-cache-verify.err >&2 2>/dev/null || true
    exit 1
  fi
  log_info "Selected HAOS image for install: $image_path"

  while :; do
    set +e
    target_disk="$(select_target_disk "$targets_json")"
    target_status="$?"
    set -e

    if [ "$target_status" -eq 2 ]; then
      list_install_targets > "$targets_json"
      continue
    fi

    if [ "$target_status" -ne 0 ]; then
      exit "$target_status"
    fi

    set +e
    confirm_target_erase "$target_disk" "$targets_json"
    confirm_status="$?"
    set -e

    if [ "$confirm_status" -eq 2 ]; then
      continue
    fi

    if [ "$confirm_status" -ne 0 ]; then
      exit "$confirm_status"
    fi

    break
  done

  write_image_to_disk "$image_path" "$target_disk"
  configure_legacy_bios_boot "$target_disk"
  if installer_unattended_enabled; then
    list_install_targets > "$targets_json"
    if ! write_install_complete_marker "$target_disk" "$targets_json" "$image_path"; then
      log_error "Could not write the unattended completion marker to the USB."
      log_error "Stopping instead of rebooting to avoid a possible unattended install loop."
      completed_install_fallback "$target_disk"
    fi
  fi

  log_info "Installer flow complete."
  if installer_unattended_enabled; then
    reboot_after_install "$target_disk"
  fi

  repair_uefi_boot_entry "$target_disk" || true
  tui_reboot_choice || exit 0
  reboot
}

main "$@"
