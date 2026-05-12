#!/bin/sh
set -eu

validate_target_disk() {
  targets_json="$1"
  selected_disk="$2"

  if [ -z "$selected_disk" ]; then
    log_error "No target disk selected."
    return 1
  fi

  if [ ! -s "$targets_json" ]; then
    log_error "Target disk candidate list is missing or empty: $targets_json"
    return 1
  fi

  if jq -e --arg selected "$selected_disk" '
    length == 1 and .[0].path == $selected
  ' "$targets_json" >/dev/null; then
    log_info "Validated only install target candidate: $selected_disk"
    return 0
  fi

  if jq -e --arg selected "$selected_disk" '
    length > 1 and any(.[]; .path == $selected)
  ' "$targets_json" >/dev/null; then
    log_info "Validated selected install target: $selected_disk"
    return 0
  fi

  log_error "Selected disk is not in the safe install target candidate list: $selected_disk"
  return 1
}

select_target_disk() {
  targets_json="$1"

  if [ -n "${HAOS_TEST_TARGET_DISK:-}" ]; then
    validate_target_disk "$targets_json" "$HAOS_TEST_TARGET_DISK"
    printf '%s\n' "$HAOS_TEST_TARGET_DISK"
    return 0
  fi

  count="$(jq 'length' "$targets_json")"
  if [ "$count" -eq 0 ]; then
    log_error "No safe internal install targets were detected."
    return 1
  fi

  if installer_unattended_enabled; then
    select_unattended_target "$targets_json"
    return $?
  fi

  selected_disk="$(select_target_with_prompt "$targets_json")"

  validate_target_disk "$targets_json" "$selected_disk"
  printf '%s\n' "$selected_disk"
}

select_unattended_target() {
  targets_json="$1"
  count="$(jq 'length' "$targets_json")"

  if [ "$count" -ne 1 ]; then
    log_error "Unattended install refused: detected $count eligible internal target disks."
    log_error "Unattended mode only runs when exactly one internal target disk is available after excluding the installer USB."
    return 1
  fi

  selected_disk="$(jq -r '.[0].path // empty' "$targets_json")"
  validate_target_disk "$targets_json" "$selected_disk"
  log_warn "Unattended install enabled. Automatically selected only eligible target disk: $selected_disk"
  printf '%s\n' "$selected_disk"
}

select_target_with_prompt() {
  targets_json="$1"

  stty sane </dev/tty >/dev/tty 2>/dev/null || true

  if command -v tui_menu >/dev/null 2>&1; then
    menu_items="$(mktemp)"
    jq -r 'to_entries[] |
      (.key + 1 | tostring) + "\t" +
      (.value.path + " | " + (.value.model // "Unknown") + " | " + (.value.size // "unknown") + " | " + (.value.tran // "unknown") +
      (if .value.hasWindowsPartitions then " | WINDOWS DATA DETECTED" else "" end))
    ' "$targets_json" > "$menu_items"

    set -- 
    while IFS="$(printf '\t')" read -r tag description; do
      set -- "$@" "$tag" "$description"
    done < "$menu_items"
    rm -f "$menu_items"

    set +e
    choice="$(tui_menu \
      "Select Target Disk" \
      "Choose the internal disk to erase and install Home Assistant OS onto." \
      "$@")"
    status="$?"
    set -e

    if [ "$status" -ne 0 ]; then
      log_info "User returned from target selection."
      return 2
    fi

    case "$choice" in
      ''|*[!0-9]*)
        log_error "Invalid target selection: $choice"
        return 1
        ;;
    esac

    jq -r --argjson index "$((choice - 1))" '.[$index].path // empty' "$targets_json"
    return 0
  fi

  printf '\n' >/dev/tty
  printf '============================================================\n' >/dev/tty
  printf ' SELECT TARGET DISK\n' >/dev/tty
  printf '============================================================\n\n' >/dev/tty
  printf 'Choose the internal disk to erase and install Home Assistant OS onto.\n' >/dev/tty
  printf '\n' >/dev/tty

  jq -r 'to_entries[] |
    "\(.key + 1). \(.value.path) | \(.value.model // "Unknown") | \(.value.size // "unknown") | \(.value.tran // "unknown")" +
    (if .value.hasWindowsPartitions then " | WINDOWS DATA DETECTED" else "" end) +
    "\n   Partitions: \(.value.partitionSummary // "none")"
  ' "$targets_json" >/dev/tty

  printf '\nEnter target number, or B to go back/reload: ' >/dev/tty
  read -r choice </dev/tty

  case "$choice" in
    b|B)
      log_info "User returned from target selection."
      return 2
      ;;
    ''|*[!0-9]*)
      log_error "Invalid target selection: $choice"
      return 1
      ;;
  esac

  jq -r --argjson index "$((choice - 1))" '.[$index].path // empty' "$targets_json"
}

confirm_target_erase() {
  target_disk="$1"
  targets_json="$2"

  target_summary="$(jq -r --arg selected "$target_disk" '
    .[] | select(.path == $selected) |
    "Disk: \(.path)\nModel: \(.model // "Unknown")\nSize: \(.size // "unknown")\nBus: \(.tran // "unknown")\nPartitions: \(.partitionSummary // "none")\nWindows markers: \(if .hasWindowsPartitions then "YES" else "no" end)"
  ' "$targets_json")"

  stty sane </dev/tty >/dev/tty 2>/dev/null || true

  if installer_unattended_enabled; then
    log_warn "Unattended install confirmed by USB creator configuration."
    log_warn "Proceeding without an interactive target confirmation because exactly one eligible internal target was detected."
    return 0
  fi

  while :; do
    if command -v tui_confirm >/dev/null 2>&1; then
      if tui_confirm \
        "Confirm Target Disk" \
        "This will erase the selected disk and install Home Assistant OS.\n\n$target_summary" \
        "Erase Disk" \
        "Back"; then
        return 0
      fi

      log_info "User returned from erase confirmation to disk selection."
      return 2
    else
      printf '\n' >/dev/tty
      printf '============================================================\n' >/dev/tty
      printf ' CONFIRM TARGET DISK\n' >/dev/tty
      printf '============================================================\n\n' >/dev/tty
      printf 'This will erase the selected disk and install Home Assistant OS.\n\n' >/dev/tty
      printf '%s\n\n' "$target_summary" >/dev/tty
      printf '[E] Erase disk    [B] Back to disk selection\n\n' >/dev/tty
      printf 'Choose E or B: ' >/dev/tty
      read -r choice </dev/tty

      case "$choice" in
        e|E)
          return 0
          ;;
        b|B)
          log_info "User returned from erase confirmation to disk selection."
          return 2
          ;;
        *)
          printf '\nNothing has been erased. Choose E to continue or B to go back.\n' >/dev/tty
          ;;
      esac
    fi
  done
}
