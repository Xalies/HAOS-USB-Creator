#!/bin/sh
set -eu

find_cache_partition() {
  if [ -n "${HAOS_CACHE_DIR:-}" ]; then
    mkdir -p "$HAOS_CACHE_DIR" 2>/dev/null || true
    configure_usb_logging "$HAOS_CACHE_DIR" >/dev/null 2>&1 || true
    printf '%s\n' "$HAOS_CACHE_DIR"
    return 0
  fi

  mount_cache_partition_by_label || true

  for candidate in /run/media/*/*/cache /media/*/*/cache /mnt/haos-cache/cache /mnt/*/cache /run/media/*/* /media/*/* /mnt/haos-cache /mnt/*; do
    [ -d "$candidate" ] || continue
    if [ -f "$candidate/manifest.json" ] || [ -f "$candidate/installer-config.json" ]; then
      configure_usb_logging "$candidate" >/dev/null 2>&1 || true
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  log_warn "No mounted HAOS cache partition found."
  return 1
}

find_writable_image_cache() {
  cache_dir="$(find_cache_partition 2>/dev/null || true)"
  if [ -n "$cache_dir" ] && [ -d "$cache_dir" ] && [ -w "$cache_dir" ]; then
    printf '%s\n' "$cache_dir"
    return 0
  fi

  cache_dir="${HAOS_MEMORY_CACHE_DIR:-/tmp/haos-cache}"
  mkdir -p "$cache_dir"
  export HAOS_CACHE_DIR="$cache_dir"
  log_warn "Using temporary memory-backed image cache at $cache_dir. This is expected when booted from the standalone ISO."
  printf '%s\n' "$cache_dir"
}

initialize_cache_logging() {
  if [ -n "${HAOS_CACHE_DIR:-}" ] && [ -d "$HAOS_CACHE_DIR" ]; then
    configure_usb_logging "$HAOS_CACHE_DIR" || true
    return 0
  fi

  mount_cache_partition_by_label || true

  for candidate in /run/media/*/*/cache /media/*/*/cache /mnt/haos-cache/cache /mnt/*/cache /run/media/*/* /media/*/* /mnt/haos-cache /mnt/*; do
    [ -d "$candidate" ] || continue
    if [ -f "$candidate/manifest.json" ] || [ -f "$candidate/installer-config.json" ]; then
      configure_usb_logging "$candidate" || true
      return 0
    fi
  done

  return 1
}

mount_cache_partition_by_label() {
  command -v blkid >/dev/null 2>&1 || return 1
  command -v mount >/dev/null 2>&1 || return 1

  cache_device="$(blkid -L HAOS-CACHE 2>/dev/null || true)"
  [ -n "$cache_device" ] || return 1

  mkdir -p /mnt/haos-cache
  if mountpoint -q /mnt/haos-cache 2>/dev/null; then
    return 0
  fi

  log_info "Mounting HAOS-CACHE partition from $cache_device."
  mount -o rw "$cache_device" /mnt/haos-cache 2>/dev/null || mount -o ro "$cache_device" /mnt/haos-cache
}

read_cached_manifest() {
  cache_dir="$(find_cache_partition)"
  manifest="$cache_dir/manifest.json"

  if [ ! -f "$manifest" ]; then
    log_warn "Cached manifest not found at $manifest."
    return 1
  fi

  jq -e '
    .schemaVersion == 1
    and .imageType == "haos_generic-x86-64"
    and (.filename | type == "string")
    and (.sha256 | test("^[a-fA-F0-9]{64}$"))
    and (.version | type == "string")
  ' "$manifest" >/dev/null

  printf '%s\n' "$manifest"
}

find_cached_image_file() {
  cache_dir="$(find_cache_partition)"

  for image_path in "$cache_dir"/haos_generic-x86-64-*.img.xz; do
    [ -f "$image_path" ] || continue
    printf '%s\n' "$image_path"
    return 0
  done

  log_warn "No cached HAOS image file found in $cache_dir."
  return 1
}

cached_version_from_filename() {
  image_path="$1"
  basename "$image_path" | sed -n 's/^haos_generic-x86-64-\(.*\)\.img\.xz$/\1/p'
}

checksum_for_cached_image() {
  image_path="$1"
  cache_dir="$(dirname "$image_path")"
  filename="$(basename "$image_path")"
  checksum_file="$cache_dir/$filename.sha256"

  if [ -f "$checksum_file" ]; then
    checksum="$(awk -v name="$filename" '
      $1 ~ /^[a-fA-F0-9]{64}$/ && ($2 == name || $2 == "*" name || NF == 1) { print $1; exit }
    ' "$checksum_file")"
    if [ -n "$checksum" ]; then
      printf '%s\n' "$checksum"
      return 0
    fi
    log_warn "Cached checksum file exists but does not contain a valid SHA-256 for $filename: $checksum_file"
  fi

  manifest="$cache_dir/manifest.json"
  if [ -f "$manifest" ]; then
    checksum="$(jq -r --arg filename "$filename" '
      if (.filename // "") == $filename and (.sha256 // "" | test("^[a-fA-F0-9]{64}$")) then
        .sha256
      else
        empty
      end
    ' "$manifest" 2>/dev/null || true)"
    if [ -n "$checksum" ]; then
      printf '%s\n' "$checksum"
      return 0
    fi
  fi

  log_warn "No valid SHA-256 checksum found for cached image $image_path."
  return 1
}

read_installer_config() {
  cache_dir="$(find_cache_partition)"
  config="$cache_dir/installer-config.json"

  if [ ! -f "$config" ]; then
    return 1
  fi

  jq -e '
    .schemaVersion == 1
    and (.unattended.enabled | type == "boolean")
    and (.unattended.mode | type == "string")
  ' "$config" >/dev/null

  printf '%s\n' "$config"
}

installer_unattended_enabled() {
  if [ "${HAOS_UNATTENDED:-0}" = "1" ]; then
    return 0
  fi

  config="$(read_installer_config 2>/dev/null || true)"
  [ -n "$config" ] || return 1

  jq -e '
    .unattended.enabled == true
    and .unattended.mode == "first-available-single-disk"
  ' "$config" >/dev/null
}

install_complete_marker_path() {
  cache_dir="$(find_cache_partition)"
  printf '%s\n' "$cache_dir/install-complete.json"
}

install_complete_marker_exists() {
  marker="$(install_complete_marker_path 2>/dev/null || true)"
  [ -n "$marker" ] && [ -f "$marker" ]
}

write_install_complete_marker() {
  target_disk="$1"
  targets_json="$2"
  image_path="$3"

  marker="$(install_complete_marker_path)"
  cache_dir="$(dirname "$marker")"
  mkdir -p "$cache_dir"

  image_filename="$(basename "$image_path")"
  image_sha256="$(sha256sum "$image_path" 2>/dev/null | awk '{ print $1 }' || true)"

  jq -n \
    --arg completedAtUtc "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    --arg targetDisk "$target_disk" \
    --arg imageFilename "$image_filename" \
    --arg imageSha256 "$image_sha256" \
    --slurpfile targets "$targets_json" '
    {
      schemaVersion: 1,
      completedAtUtc: $completedAtUtc,
      targetDisk: $targetDisk,
      image: {
        filename: $imageFilename,
        sha256: $imageSha256
      },
      target: (($targets[0] // [])[]? | select(.path == $targetDisk))
    }
  ' > "$marker"

  sync "$marker" 2>/dev/null || sync
  log_info "Install completion marker written to $marker."
}

unattended_completed_install_matches() {
  targets_json="$1"

  install_complete_marker_exists || return 1

  jq -e '
    length == 1
    and .[0].partitionCount > 0
    and (.[0].hasWindowsPartitions | not)
    and .[0].hasHaosLikePartitions == true
  ' "$targets_json" >/dev/null
}

unattended_target_already_looks_installed() {
  targets_json="$1"

  jq -e '
    length == 1
    and .[0].partitionCount > 0
    and (.[0].hasWindowsPartitions | not)
    and .[0].hasHaosLikePartitions == true
  ' "$targets_json" >/dev/null
}

cached_image_path() {
  manifest="$1"
  cache_dir="$(dirname "$manifest")"
  filename="$(jq -r '.filename' "$manifest")"
  printf '%s\n' "$cache_dir/$filename"
}

cached_image_version() {
  jq -r '.version' "$1"
}

cached_image_version_for_path() {
  image_path="$1"
  cache_dir="$(dirname "$image_path")"
  filename="$(basename "$image_path")"
  manifest="$cache_dir/manifest.json"

  if [ -f "$manifest" ]; then
    version="$(jq -r --arg filename "$filename" '
      if (.filename // "") == $filename and (.version // "" | type == "string") then
        .version
      else
        empty
      end
    ' "$manifest" 2>/dev/null || true)"
    if [ -n "$version" ]; then
      printf '%s\n' "$version"
      return 0
    fi
  fi

  cached_version_from_filename "$image_path"
}

write_haos_manifest() {
  cache_dir="$1"
  version="$2"
  filename="$3"
  sha256="$4"
  source_url="$5"
  file_size_bytes="$6"

  jq -n \
    --arg version "$version" \
    --arg filename "$filename" \
    --arg sha256 "$sha256" \
    --arg sourceUrl "$source_url" \
    --arg downloadedAtUtc "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    --argjson fileSizeBytes "$file_size_bytes" '
    {
      schemaVersion: 1,
      imageType: "haos_generic-x86-64",
      version: $version,
      filename: $filename,
      sha256: $sha256,
      sourceUrl: $sourceUrl,
      downloadedAtUtc: $downloadedAtUtc,
      createdBy: "HAOS AIO USB Creator",
      fileSizeBytes: $fileSizeBytes
    }
  ' > "$cache_dir/manifest.json"
}

remove_old_cached_images() {
  cache_dir="$1"
  keep_filename="$2"

  for old_path in "$cache_dir"/haos_generic-x86-64-*.img.xz; do
    [ -f "$old_path" ] || continue
    [ "$(basename "$old_path")" != "$keep_filename" ] || continue
    log_info "Removing older cached HAOS image: $old_path"
    rm -f "$old_path" "$old_path.sha256"
  done
}

verify_cached_image() {
  manifest="$(read_cached_manifest 2>/tmp/haos-cache-manifest.err || true)"
  if [ -n "$manifest" ]; then
    cache_dir="$(dirname "$manifest")"
    image_path="$(cached_image_path "$manifest")"
  else
    cat /tmp/haos-cache-manifest.err >&2 2>/dev/null || true
    image_path="$(find_cached_image_file)" || return 1
    cache_dir="$(dirname "$image_path")"
  fi

  filename="$(basename "$image_path")"
  sha256="$(checksum_for_cached_image "$image_path")"

  if [ ! -f "$image_path" ]; then
    log_warn "Cached HAOS payload image missing: $image_path"
    return 1
  fi

  printf '%s  %s\n' "$sha256" "$filename" > /tmp/haos-cache-selected.sha256
  if ! (cd "$cache_dir" && sha256sum -c /tmp/haos-cache-selected.sha256 >/tmp/haos-cache-sha256.out 2>&1); then
    cat /tmp/haos-cache-sha256.out >&2
    return 1
  fi
  log_info "Cached HAOS payload verified: $image_path"
  printf '%s\n' "$image_path"
}
