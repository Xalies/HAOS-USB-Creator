#!/bin/sh
set -eu

tui_has_whiptail() {
  command -v whiptail >/dev/null 2>&1 && [ -r /dev/tty ] && [ -w /dev/tty ]
}

tui_message() {
  title="$1"
  message="$2"

  if tui_has_whiptail; then
    whiptail --title "$title" --msgbox "$message" 18 74 >/dev/tty 2>&1 || true
    return 0
  fi

  printf '\n============================================================\n' >/dev/tty 2>/dev/null || true
  printf ' %s\n' "$title" >/dev/tty 2>/dev/null || true
  printf '============================================================\n\n' >/dev/tty 2>/dev/null || true
  printf '%s\n\n' "$message" >/dev/tty 2>/dev/null || true
}

tui_status() {
  title="$1"
  message="$2"

  if tui_has_whiptail; then
    whiptail --title "$title" --infobox "$message" 8 74 >/dev/tty 2>&1 || true
    sleep 1
    return 0
  fi

  printf '%s\n' "$message" >/dev/tty 2>/dev/null || printf '%s\n' "$message" >&2
}

tui_confirm() {
  title="$1"
  message="$2"
  yes_label="${3:-Continue}"
  no_label="${4:-Back}"

  if tui_has_whiptail; then
    whiptail \
      --title "$title" \
      --yes-button "$yes_label" \
      --no-button "$no_label" \
      --yesno "$message" 20 74 \
      >/dev/tty 2>&1
    return $?
  fi

  while :; do
    printf '\n%s\n\n%s\n\n' "$title" "$message" >/dev/tty
    printf '[E] %s    [B] %s\n\nChoose E or B: ' "$yes_label" "$no_label" >/dev/tty
    read -r choice </dev/tty

    case "$choice" in
      e|E) return 0 ;;
      b|B) return 1 ;;
      *) printf '\nNothing has been changed. Choose E to continue or B to go back.\n' >/dev/tty ;;
    esac
  done
}

tui_menu() {
  title="$1"
  message="$2"
  shift 2

  if tui_has_whiptail; then
    whiptail \
      --title "$title" \
      --cancel-button "Back" \
      --menu "$message" 22 92 12 "$@" \
      3>&1 1>/dev/tty 2>&3
    return $?
  fi

  tui_menu_plain "$title" "$message" "$@"
}

tui_menu_plain() {
  title="$1"
  message="$2"
  shift 2

  printf '\n============================================================\n' >/dev/tty
  printf ' %s\n' "$title" >/dev/tty
  printf '============================================================\n\n' >/dev/tty
  printf '%s\n\n' "$message" >/dev/tty

  while [ "$#" -gt 0 ]; do
    tag="$1"
    item="$2"
    shift 2
    printf '%s. %s\n' "$tag" "$item" >/dev/tty
  done

  printf '\nEnter target number, or B to go back/reload: ' >/dev/tty
  read -r choice </dev/tty

  case "$choice" in
    b|B) return 1 ;;
    *) printf '%s\n' "$choice" ;;
  esac
}

tui_reboot_choice() {
  if tui_has_whiptail; then
    whiptail \
      --title "Installation Complete" \
      --yes-button "Reboot" \
      --no-button "Shell" \
      --yesno "Home Assistant OS has been written.\n\nRemove the USB installer after reboot.\n\nOpen Home Assistant at homeassistant.local:8123 after it starts." 18 74 \
      >/dev/tty 2>&1
    return $?
  fi

  printf '\nInstallation complete. Remove the USB installer after reboot.\n' >/dev/tty 2>/dev/null || true
  printf 'Open Home Assistant at homeassistant.local:8123 after it starts.\n\n' >/dev/tty 2>/dev/null || true
  printf 'Press Enter to reboot, or type shell to stay here: ' >/dev/tty 2>/dev/null || true
  read -r answer </dev/tty
  [ "$answer" = "shell" ] && return 1
  return 0
}
