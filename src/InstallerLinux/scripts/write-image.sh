#!/bin/sh
set -eu

show_message() {
  title="$1"
  message="$2"

  if installer_unattended_enabled; then
    log_info "$title: $message"
    return 0
  fi

  if command -v tui_message >/dev/null 2>&1; then
    tui_message "$title" "$message"
    return 0
  fi

  printf '\n============================================================\n' >/dev/tty 2>/dev/null || true
  printf ' %s\n' "$title" >/dev/tty 2>/dev/null || true
  printf '============================================================\n\n' >/dev/tty 2>/dev/null || true
  printf '%s\n\n' "$message" >/dev/tty 2>/dev/null || true
}

check_write_dependencies() {
  missing=""

  for command_name in dd lsblk sync umount wc wipefs xz; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
      missing="$missing $command_name"
    fi
  done

  if [ -n "$missing" ]; then
    log_error "Installer is missing required write command(s):$missing"
    return 1
  fi

  if ! command -v pv >/dev/null 2>&1; then
    log_warn "pv is not available; write progress will fall back to dd output."
  fi

  if ! command -v sgdisk >/dev/null 2>&1; then
    log_warn "sgdisk is not available; continuing with wipefs and image overwrite."
  fi
}

ensure_target_is_block_device() {
  target_disk="$1"

  if [ ! -b "$target_disk" ]; then
    log_error "Target is not a block device: $target_disk"
    return 1
  fi
}

ensure_target_not_mounted() {
  target_disk="$1"

  mounted_children="$(lsblk -nr -o PATH,MOUNTPOINT "$target_disk" 2>/dev/null | awk '$2 != "" { print $1 " mounted at " $2 }')"
  if [ -n "$mounted_children" ]; then
    log_error "Refusing to write because part of the target disk is mounted: $mounted_children"
    return 1
  fi
}

run_step() {
  title="$1"
  shift

  log_info "$title"
  if command -v tui_status >/dev/null 2>&1; then
    tui_status "Installing Home Assistant OS" "$title"
  else
    printf '%s\n' "$title" >/dev/tty 2>/dev/null || printf '%s\n' "$title" >&2
  fi

  "$@"
}

decompress_image_to_stdout() {
  image_path="$1"

  if command -v xzcat >/dev/null 2>&1; then
    xzcat "$image_path"
    return
  fi

  xz -dc "$image_path"
}

clear_partition_tables() {
  target_disk="$1"

  wipefs --all --force "$target_disk"

  if command -v sgdisk >/dev/null 2>&1; then
    sgdisk --zap-all "$target_disk"
  else
    log_warn "Skipping sgdisk partition-table zap because sgdisk is not installed."
  fi
}

reread_partition_table() {
  target_disk="$1"

  if command -v blockdev >/dev/null 2>&1; then
    blockdev --rereadpt "$target_disk" >/dev/null 2>&1 || true
  fi

  if command -v partprobe >/dev/null 2>&1; then
    partprobe "$target_disk" >/dev/null 2>&1 || true
  fi
}

write_with_progress() {
  image_path="$1"
  target_disk="$2"
  compressed_size="$(wc -c < "$image_path" | tr -d ' ')"

  if command -v pv >/dev/null 2>&1; then
    printf 'Writing %s to %s. Do not power off this computer.\n' "$image_path" "$target_disk" >/dev/tty 2>/dev/null || true
    pv -prb -s "$compressed_size" "$image_path" | xz -dc | dd of="$target_disk" bs=16M status=none conv=fsync
    return
  fi

  log_warn "Progress gauge unavailable; falling back to dd status output."
  decompress_image_to_stdout "$image_path" | dd of="$target_disk" bs=16M status=progress conv=fsync
}

write_image_to_disk() {
  image_path="$1"
  target_disk="$2"
  dry_run="${HAOS_DRY_RUN:-0}"

  if [ -z "$image_path" ] || [ -z "$target_disk" ]; then
    log_error "write_image_to_disk requires image path and target disk."
    return 1
  fi

  if [ ! -f "$image_path" ]; then
    log_error "Refusing to write missing image: $image_path"
    return 1
  fi

  log_warn "Target disk will be erased: $target_disk"
  check_write_dependencies

  if [ "$dry_run" != "0" ]; then
    log_info "DRY RUN: wipefs --all '$target_disk'"
    log_info "DRY RUN: sgdisk --zap-all '$target_disk' if available"
    log_info "DRY RUN: xz -dc '$image_path' | dd of='$target_disk' bs=16M status=progress conv=fsync"
    log_info "DRY RUN: sync"
    return 0
  fi

  ensure_target_is_block_device "$target_disk"
  ensure_target_not_mounted "$target_disk"

  run_step "Checking compressed HAOS image before erasing." xz -t "$image_path"
  run_step "Unmounting any stale target partitions." sh -c "umount ${target_disk}* >/dev/null 2>&1 || true"
  run_step "Wiping old filesystem and partition signatures." clear_partition_tables "$target_disk"
  run_step "Writing Home Assistant OS image." write_with_progress "$image_path" "$target_disk"
  run_step "Flushing disk writes." sync
  reread_partition_table "$target_disk"

  log_info "Home Assistant OS image was written to $target_disk."
}
