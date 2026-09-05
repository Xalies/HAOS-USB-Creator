#!/bin/sh
set -eu

bios_boot_partition_label="HAOS BIOS Boot"

configure_legacy_bios_boot() {
  target_disk="$1"

  installer_legacy_bios_enabled || return 0

  log_warn "Legacy BIOS boot support is enabled for $target_disk."

  if [ "${HAOS_DRY_RUN:-0}" != "0" ]; then
    log_info "DRY RUN: add legacy GRUB partition and install i386-pc GRUB to $target_disk"
    return 0
  fi

  for command_name in grub-editenv grub-install jq mount sgdisk sync umount; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
      log_error "Legacy BIOS support requires missing command: $command_name"
      return 1
    fi
  done

  run_step "Adding legacy BIOS boot support." install_legacy_grub "$target_disk"
}

install_legacy_grub() {
  target_disk="$1"

  sgdisk -e "$target_disk"
  sgdisk -n "0:-4M:0" -t "0:EF02" -c "0:$bios_boot_partition_label" "$target_disk"
  reread_partition_table "$target_disk"
  udevadm settle >/dev/null 2>&1 || true

  bios_boot_partition="$(wait_for_partition_by_label "$target_disk" "$bios_boot_partition_label")"
  if [ -z "$bios_boot_partition" ]; then
    log_error "Could not find the BIOS boot partition after creating it."
    return 1
  fi

  efi_partition="$(find_efi_partition "$target_disk")"
  if [ -z "$efi_partition" ]; then
    log_error "Could not find HAOS EFI partition for legacy GRUB chainload."
    return 1
  fi

  efi_mount="$(mktemp -d)"
  trap 'umount "$efi_mount" >/dev/null 2>&1 || true; rmdir "$efi_mount" >/dev/null 2>&1 || true' EXIT

  mount "$efi_partition" "$efi_mount"
  mkdir -p "$efi_mount/boot/grub"
  cat > "$efi_mount/boot/grub/grub.cfg" <<'GRUBCFG'
search --no-floppy --set=root --file /EFI/BOOT/grub.cfg
configfile /EFI/BOOT/grub.cfg
GRUBCFG

  grub-install --target=i386-pc --boot-directory="$efi_mount/boot" --recheck "$target_disk"
  haos_grub_cfg="$(find_haos_efi_grub_cfg "$efi_mount")"
  patch_haos_grubenv_paths "$haos_grub_cfg"
  reset_haos_grubenv_attempts "$haos_grub_cfg"

  sync
  umount "$efi_mount"
  rmdir "$efi_mount"
  trap - EXIT

  log_info "Legacy BIOS GRUB boot support installed on $target_disk."
}

reset_haos_grubenv_attempts() {
  grub_cfg="$1"
  grubenv_path="$(dirname "$grub_cfg")/grubenv"

  if [ ! -f "$grubenv_path" ]; then
    log_warn "HAOS GRUB environment not found at $grubenv_path; legacy boot may enter rescue after failed attempts."
    return 0
  fi

  grub-editenv "$grubenv_path" set A_TRY=0 B_TRY=0 A_OK=1 ORDER="A B"
}

find_haos_efi_grub_cfg() {
  efi_mount="$1"

  for grub_cfg in \
    "$efi_mount/EFI/BOOT/grub.cfg" \
    "$efi_mount/efi/boot/grub.cfg" \
    "$efi_mount/EFI/boot/grub.cfg" \
    "$efi_mount/efi/BOOT/grub.cfg"; do
    if [ -f "$grub_cfg" ]; then
      printf '%s\n' "$grub_cfg"
      return 0
    fi
  done

  printf '%s\n' "$efi_mount/EFI/BOOT/grub.cfg"
}

find_partition_by_label() {
  target_disk="$1"
  label="$2"

  partition_path="$(lsblk -J -o PATH,PARTLABEL "$target_disk" \
    | jq -r --arg label "$label" '.blockdevices[0].children[]? | select(.partlabel == $label) | .path' \
    | head -n 1)"
  if [ -n "$partition_path" ]; then
    printf '%s\n' "$partition_path"
    return 0
  fi

  partition_number="$(sgdisk -p "$target_disk" 2>/dev/null | awk -v label="$label" 'index($0, label) { print $1; exit }')"
  [ -n "$partition_number" ] || return 1

  case "$target_disk" in
    *[0-9]) partition_path="${target_disk}p${partition_number}" ;;
    *) partition_path="${target_disk}${partition_number}" ;;
  esac

  [ -b "$partition_path" ] || return 1
  printf '%s\n' "$partition_path"
}

wait_for_partition_by_label() {
  target_disk="$1"
  label="$2"

  for _ in 1 2 3 4 5 6 7 8 9 10; do
    partition_path="$(find_partition_by_label "$target_disk" "$label" 2>/dev/null || true)"
    if [ -n "$partition_path" ]; then
      printf '%s\n' "$partition_path"
      return 0
    fi

    reread_partition_table "$target_disk"
    udevadm settle >/dev/null 2>&1 || true
    sleep 1
  done

  return 1
}

patch_haos_grubenv_paths() {
  grub_cfg="$1"

  if [ ! -f "$grub_cfg" ]; then
    log_warn "HAOS EFI GRUB config not found at $grub_cfg; legacy boot may not preserve HAOS slot failover state."
    return 0
  fi

  cp "$grub_cfg" "$grub_cfg.haos-installer.bak"
  awk '
    $1 == "load_env" {
      print "load_env --file (hd0,gpt1)/efi/boot/grubenv"
      next
    }
    $1 == "save_env" {
      sub(/^save_env[[:space:]]+/, "save_env --file (hd0,gpt1)/efi/boot/grubenv ")
    }
    { print }
  ' "$grub_cfg" > "$grub_cfg.tmp"
  mv "$grub_cfg.tmp" "$grub_cfg"

  if ! grep -q 'load_env --file' "$grub_cfg"; then
    log_error "Could not patch HAOS GRUB environment path in $grub_cfg."
    return 1
  fi
}
