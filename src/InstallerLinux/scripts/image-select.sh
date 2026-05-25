#!/bin/sh
set -eu

version_key() {
  printf '%s\n' "$1" | awk -F. '{ printf "%04d%04d%04d\n", $1, $2, $3 }'
}

version_gt() {
  [ "$(version_key "$1")" -gt "$(version_key "$2")" ]
}

select_install_image() {
  log_info "Selecting newest verified HAOS payload image."
  tui_status "Home Assistant OS Image" "Checking for a downloaded Home Assistant OS image on the USB."

  cache_dir="$(find_cache_partition 2>/dev/null || true)"
  unattended=0
  if installer_unattended_enabled; then
    unattended=1
  fi

  cached_image=""
  cached_version=""
  if cached_image="$(verify_cached_image 2>/tmp/haos-cache-verify.err)"; then
    cached_version="$(cached_image_version_for_path "$cached_image")"
    log_info "Verified cached HAOS payload version: $cached_version"
  else
    log_warn "Cached HAOS payload is not available or not valid."
  fi

  tui_status "Network Check" "Checking internet access."
  if check_network; then
    tui_status "Network Check" "Internet access detected. Checking the latest Home Assistant OS release."
    if release_info="$(fetch_latest_haos_release)"; then
      # shellcheck disable=SC1090
      . "$release_info"

      if [ -z "$cached_image" ]; then
        log_info "No cached HAOS payload is available; downloading latest version $ONLINE_VERSION."
        cache_dir="$(find_writable_image_cache)"
        tui_status "Downloading Home Assistant OS" "Downloading $ONLINE_FILENAME into temporary memory, then verifying it before install.\n\nProgress and speed are shown on this screen."
        if online_image="$(download_online_image "$release_info" "$cache_dir" 0)"; then
          tui_status "Home Assistant OS Image" "Downloaded and verified $ONLINE_FILENAME."
          printf '%s\n' "$online_image"
          return 0
        fi
        log_warn "Online image download or verification failed."
      elif version_gt "$ONLINE_VERSION" "$cached_version"; then
        log_info "Online HAOS payload version $ONLINE_VERSION is newer than cached version $cached_version."
        if [ "$unattended" -eq 1 ]; then
          log_info "Unattended install enabled; downloading newer HAOS payload without prompting."
          cache_dir="$(find_writable_image_cache)"
          tui_status "Downloading Home Assistant OS" "Downloading $ONLINE_FILENAME, then verifying it before install.\n\nThe old cached image will be removed only after the new download is verified."
          if online_image="$(download_online_image "$release_info" "$cache_dir" 1)"; then
            tui_status "Home Assistant OS Image" "Downloaded and verified $ONLINE_FILENAME."
            printf '%s\n' "$online_image"
            return 0
          fi
          log_warn "Unattended online image download or verification failed; keeping verified cached image."
        elif tui_confirm \
          "Newer Home Assistant OS Available" \
          "The USB contains Home Assistant OS $cached_version.\n\nA newer generic x86-64 image is available:\n$ONLINE_VERSION\n\nDownload and use the newer image now?" \
          "Download" \
          "Use cached"; then
          cache_dir="$(find_writable_image_cache)"
          tui_status "Downloading Home Assistant OS" "Downloading $ONLINE_FILENAME, then verifying it before install.\n\nThe old cached image will be removed only after the new download is verified."
          if online_image="$(download_online_image "$release_info" "$cache_dir" 1)"; then
            tui_status "Home Assistant OS Image" "Downloaded and verified $ONLINE_FILENAME."
            printf '%s\n' "$online_image"
            return 0
          fi
          log_warn "Online image download or verification failed; keeping verified cached image."
          tui_message \
            "Download Failed" \
            "The newer Home Assistant OS image could not be downloaded or verified.\n\nThe verified cached image will be used instead."
        else
          log_info "User chose to continue with cached HAOS payload version $cached_version."
        fi
      else
        log_info "Cached HAOS payload version $cached_version is current; using cache."
      fi
    else
      log_warn "Online HAOS release lookup failed."
    fi
  else
    log_warn "Network unavailable; using cached image if possible."
  fi

  if [ -n "$cached_image" ]; then
    printf '%s\n' "$cached_image"
    return 0
  fi

  log_error "No verified HAOS payload image is available."
  tui_message \
    "No Home Assistant OS Image" \
    "No verified Home Assistant OS image is available.\n\nThe USB cache does not contain a valid image, and the installer could not download one from the internet.\n\nInstaller log:\n$(current_log_file)"
  return 1
}
