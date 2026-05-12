#!/bin/sh
set -eu

check_uefi_mode() {
  if [ -d /sys/firmware/efi ]; then
    log_info "System appears booted in UEFI mode."
    return 0
  fi

  log_warn "System does not appear booted in UEFI mode."
  return 1
}

check_secure_boot() {
  log_info "TODO: detect Secure Boot state using mokutil, efivarfs, or distro-supported method."
  return 0
}

repair_uefi_boot_entry() {
  target_disk="$1"
  if ! command -v efibootmgr >/dev/null 2>&1; then
    log_warn "efibootmgr is not available; cannot set UEFI BootNext."
    return 1
  fi

  if [ ! -d /sys/firmware/efi ]; then
    log_warn "System is not booted in UEFI mode; cannot set UEFI BootNext."
    return 1
  fi

  efi_partition="$(find_efi_partition "$target_disk")"
  if [ -z "$efi_partition" ]; then
    log_warn "Could not find an EFI partition on $target_disk; skipping BootNext."
    return 1
  fi

  partition_number="${efi_partition##*[!0-9]}"
  if [ -z "$partition_number" ]; then
    log_warn "Could not determine EFI partition number from $efi_partition."
    return 1
  fi

  create_or_set_bootnext "$target_disk" "$partition_number"
}

find_efi_partition() {
  target_disk="$1"

  lsblk -nr -o PATH,FSTYPE,PARTLABEL "$target_disk" 2>/dev/null \
    | awk '
      tolower($2) == "vfat" && (tolower($3) ~ /efi/ || found == "") {
        found = $1
      }
      END {
        if (found != "") print found
      }
    '
}

create_or_set_bootnext() {
  target_disk="$1"
  partition_number="$2"

  before="$(efibootmgr 2>/dev/null || true)"
  if efibootmgr -c -d "$target_disk" -p "$partition_number" -L "Home Assistant OS" -l '\EFI\BOOT\BOOTX64.EFI' >/tmp/haos-efibootmgr-create.out 2>&1; then
    after="$(efibootmgr 2>/dev/null || true)"
    bootnum="$(printf '%s\n' "$after" | awk '/Home Assistant OS/ { gsub(/^Boot|[* ].*/, "", $1); value=$1 } END { print value }')"
    if [ -n "$bootnum" ]; then
      efibootmgr -n "$bootnum" >/tmp/haos-efibootmgr-bootnext.out 2>&1 || {
        cat /tmp/haos-efibootmgr-bootnext.out >&2
        return 1
      }
      log_info "Set UEFI BootNext to Home Assistant OS entry Boot$bootnum."
      return 0
    fi

    log_warn "Created a UEFI entry but could not identify its boot number."
    printf '%s\n' "$before" >/dev/null
    return 1
  fi

  cat /tmp/haos-efibootmgr-create.out >&2 2>/dev/null || true
  log_warn "Could not create UEFI BootNext entry for $target_disk partition $partition_number."
  return 1
}

boot_installed_system_or_stop() {
  target_disk="$1"

  if repair_uefi_boot_entry "$target_disk"; then
    log_info "Rebooting to installed Home Assistant OS using UEFI BootNext."
    reboot
  fi

  completed_install_fallback "$target_disk"
}

completed_install_fallback() {
  target_disk="$1"

  log_warn "Install appears complete on $target_disk, but BootNext could not be set."
  log_warn "Refusing to reinstall. Remove the USB installer and boot the internal disk."

  if [ -r /dev/tty ] && [ -w /dev/tty ]; then
    printf '\n============================================================\n' >/dev/tty
    printf ' INSTALLATION COMPLETE\n' >/dev/tty
    printf '============================================================\n\n' >/dev/tty
    printf 'Home Assistant OS appears to be installed on %s.\n\n' "$target_disk" >/dev/tty
    printf 'The installer could not set UEFI BootNext on this machine.\n' >/dev/tty
    printf 'Nothing will be erased or written again.\n\n' >/dev/tty
    printf 'Remove the USB installer, then press Enter to reboot.\n' >/dev/tty
    printf 'Type shell to stay here: ' >/dev/tty
    read -r answer </dev/tty || answer=""
    if [ "$answer" = "shell" ]; then
      exit 0
    fi
    reboot
  fi

  while :; do
    sleep 3600
  done
}

reboot_after_install() {
  target_disk="$1"

  if repair_uefi_boot_entry "$target_disk"; then
    log_info "Unattended install complete. Rebooting to installed Home Assistant OS using UEFI BootNext."
    reboot
  fi

  completed_install_fallback "$target_disk"
  exit 0
}
