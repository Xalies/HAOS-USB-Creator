#!/bin/sh
set -eu

DEFAULT_LOG_FILE="/tmp/haos-installer.log"

current_log_file() {
  printf '%s\n' "${HAOS_INSTALLER_LOG:-$DEFAULT_LOG_FILE}"
}

configure_usb_logging() {
  cache_path="$1"
  [ -n "$cache_path" ] || return 1

  case "$cache_path" in
    */cache) usb_root="$(dirname "$cache_path")" ;;
    *) usb_root="$cache_path" ;;
  esac

  log_dir="$usb_root/logs"
  mkdir -p "$log_dir" 2>/dev/null || return 1

  old_log_file="$(current_log_file)"
  case "$old_log_file" in
    "$log_dir"/*.log) return 0 ;;
  esac

  timestamp="$(date -u '+%Y%m%dT%H%M%SZ')"
  new_log_file="$log_dir/haos-installer-$timestamp.log"

  if [ "$old_log_file" != "$new_log_file" ] && [ -f "$old_log_file" ]; then
    cp "$old_log_file" "$new_log_file" 2>/dev/null || true
  fi

  export HAOS_INSTALLER_LOG="$new_log_file"
  log_info "Persistent installer log enabled: $HAOS_INSTALLER_LOG"
}

log_info() {
  printf '%s INFO %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" | tee -a "$(current_log_file)" >/dev/null
}

log_warn() {
  printf '%s WARN %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" | tee -a "$(current_log_file)" >/dev/null
}

log_error() {
  printf '%s ERROR %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" | tee -a "$(current_log_file)" >&2
}
