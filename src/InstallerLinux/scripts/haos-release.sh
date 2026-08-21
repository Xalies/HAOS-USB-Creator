#!/bin/sh
set -eu

HAOS_RELEASE_API="${HAOS_RELEASE_API:-https://api.github.com/repos/home-assistant/operating-system/releases/latest}"
HAOS_ONLINE_DIR="${HAOS_ONLINE_DIR:-/tmp/haos-online}"
NETWORK_MODULES="
  af_packet
  e1000 e1000e igb igc ixgbe i40e ice
  r8169 atlantic alx tg3 bnx2 bnx2x qede
  mlx4_en mlx5_core be2net enic
  sky2 skge forcedeth via-rhine via-velocity tulip pcnet32
  8139too 8139cp sis900 natsemi
  virtio_net vmxnet3
  r8152 asix ax88179_178a cdc_ether smsc95xx dm9601 mcs7830
"

check_network() {
  log_info "Checking network connectivity."
  ensure_kernel_modules_available || true
  load_network_modules || true
  log_network_state "before network check"

  if curl --fail --silent --show-error --max-time 8 https://api.github.com/ >/tmp/haos-network-check.out 2>/tmp/haos-network-check.err; then
    return 0
  fi
  log_warn "Initial network check failed: $(cat /tmp/haos-network-check.err 2>/dev/null || true)"

  try_dhcp_once || true
  if curl --fail --silent --show-error --max-time 12 https://api.github.com/ >/tmp/haos-network-check.out 2>/tmp/haos-network-check.err; then
    return 0
  fi

  log_warn "Network check failed after DHCP: $(cat /tmp/haos-network-check.err 2>/dev/null || true)"
  return 1
}

ensure_kernel_modules_available() {
  if [ -d /lib/modules ]; then
    return 0
  fi

  log_warn "/lib/modules is missing; attempting to mount the Alpine module loop image."

  mount_boot_partition_for_modloop || true

  for modloop_path in \
    /media/*/boot/modloop-* \
    /run/media/*/*/boot/modloop-* \
    /mnt/haos-boot/boot/modloop-* \
    /mnt/*/boot/modloop-* \
    /boot/modloop-*; do
    [ -f "$modloop_path" ] || continue
    mount_modloop "$modloop_path" && return 0
  done

  log_warn "Could not find an Alpine modloop file to provide kernel modules."
  return 1
}

mount_boot_partition_for_modloop() {
  command -v blkid >/dev/null 2>&1 || return 1
  command -v mount >/dev/null 2>&1 || return 1

  boot_device="$(blkid -L HAOSINSTLR 2>/dev/null || blkid -L HAOS-INSTLR 2>/dev/null || blkid -L HAOS-BOOT 2>/dev/null || true)"
  [ -n "$boot_device" ] || return 1

  mkdir -p /mnt/haos-boot
  mountpoint -q /mnt/haos-boot 2>/dev/null && return 0

  log_info "Mounting HAOS installer boot partition from $boot_device."
  mount -o ro "$boot_device" /mnt/haos-boot 2>/dev/null || mount "$boot_device" /mnt/haos-boot
}

mount_modloop() {
  modloop_path="$1"

  mkdir -p /.modloop
  if ! mountpoint -q /.modloop 2>/dev/null; then
    log_info "Mounting Alpine module loop image: $modloop_path"
    if ! mount -t squashfs -o loop,ro "$modloop_path" /.modloop 2>/tmp/haos-modloop.err; then
      log_warn "Could not mount modloop $modloop_path: $(cat /tmp/haos-modloop.err 2>/dev/null || true)"
      return 1
    fi
  fi

  if [ -d /.modloop/modules ]; then
    mkdir -p /lib
    ln -sfn /.modloop/modules /lib/modules
  elif [ -d /.modloop/lib/modules ]; then
    mkdir -p /lib
    ln -sfn /.modloop/lib/modules /lib/modules
  fi

  if [ -d /lib/modules ]; then
    log_info "Kernel modules are available at /lib/modules."
    return 0
  fi

  log_warn "Modloop mounted but no modules directory was found inside it."
  return 1
}

load_network_modules() {
  command -v modprobe >/dev/null 2>&1 || {
    log_warn "modprobe is not available; cannot explicitly load network drivers."
    return 1
  }

  for module_name in $NETWORK_MODULES; do
    if modprobe "$module_name" >/tmp/haos-modprobe-"$module_name".out 2>/tmp/haos-modprobe-"$module_name".err; then
      log_info "Network driver module loaded or already available: $module_name"
    else
      error="$(cat /tmp/haos-modprobe-"$module_name".err 2>/dev/null || true)"
      case "$error" in
        *"not found"*|*"not found in directory"*) : ;;
        *) [ -n "$error" ] && log_warn "Could not load network module $module_name: $error" ;;
      esac
    fi
  done
}

log_network_state() {
  label="$1"
  interfaces="$(ls /sys/class/net 2>/dev/null | tr '\n' ' ' || true)"
  log_info "Network interfaces $label: ${interfaces:-none}"

  if command -v lspci >/dev/null 2>&1; then
    pci_net="$(lspci 2>/dev/null | grep -i -E 'ethernet|network|wireless|wi-fi' | tr '\n' ' ' || true)"
    log_info "PCI network devices $label: ${pci_net:-none}"
  fi

  if command -v lsusb >/dev/null 2>&1; then
    usb_net="$(lsusb 2>/dev/null | grep -i -E 'ethernet|network|realtek|asix|ax88|r815|lan' | tr '\n' ' ' || true)"
    log_info "USB network devices $label: ${usb_net:-none}"
  fi

  log_info "DNS config $label: $(cat /etc/resolv.conf 2>/dev/null | tr '\n' ' ' || true)"
}

try_dhcp_once() {
  dhcp_client=""
  if command -v udhcpc >/dev/null 2>&1; then
    dhcp_client="udhcpc"
  elif command -v busybox >/dev/null 2>&1 && busybox udhcpc --help >/dev/null 2>&1; then
    dhcp_client="busybox-udhcpc"
  elif command -v dhcpcd >/dev/null 2>&1; then
    dhcp_client="dhcpcd"
  fi

  if [ -z "$dhcp_client" ]; then
    log_warn "No DHCP client found. Cannot request a network lease."
    return 1
  fi

  log_network_state "before DHCP"
  found_iface=0

  for iface_path in /sys/class/net/*; do
    [ -e "$iface_path" ] || continue
    iface="$(basename "$iface_path")"
    [ "$iface" != "lo" ] || continue
    [ -n "$iface" ] || continue
    found_iface=1

    carrier="$(cat "$iface_path/carrier" 2>/dev/null || printf unknown)"
    operstate="$(cat "$iface_path/operstate" 2>/dev/null || printf unknown)"
    log_info "Network interface found: $iface (state=$operstate carrier=$carrier)."

    if command -v ip >/dev/null 2>&1; then
      ip link set "$iface" up >/dev/null 2>&1 || true
    elif command -v ifconfig >/dev/null 2>&1; then
      ifconfig "$iface" up >/dev/null 2>&1 || true
    fi

    log_info "Requesting DHCP lease on $iface using $dhcp_client."
    set +e
    if [ "$dhcp_client" = "udhcpc" ]; then
      udhcpc -q -n -t 4 -T 5 -i "$iface" >/tmp/haos-dhcp-"$iface".out 2>/tmp/haos-dhcp-"$iface".err
      dhcp_status="$?"
    elif [ "$dhcp_client" = "busybox-udhcpc" ]; then
      busybox udhcpc -q -n -t 4 -T 5 -i "$iface" >/tmp/haos-dhcp-"$iface".out 2>/tmp/haos-dhcp-"$iface".err
      dhcp_status="$?"
    else
      dhcpcd -4 -T "$iface" >/tmp/haos-dhcp-"$iface".out 2>/tmp/haos-dhcp-"$iface".err
      dhcpcd -4 "$iface" >/tmp/haos-dhcp-"$iface".out 2>>/tmp/haos-dhcp-"$iface".err
      dhcp_status="$?"
    fi
    set -e

    if [ "$dhcp_status" -eq 0 ]; then
      log_info "DHCP lease acquired on $iface."
      if command -v ip >/dev/null 2>&1; then
        log_info "Address state after DHCP: $(ip -o addr show dev "$iface" 2>/dev/null | tr '\n' ' ')"
        log_info "Route state after DHCP: $(ip route show 2>/dev/null | tr '\n' ' ')"
      fi
      log_info "DNS state after DHCP: $(cat /etc/resolv.conf 2>/dev/null | tr '\n' ' ')"
      return 0
    fi

    log_warn "DHCP failed on $iface: $(cat /tmp/haos-dhcp-"$iface".err 2>/dev/null || true)"
  done

  if [ "$found_iface" -eq 0 ]; then
    log_warn "No non-loopback network interfaces were found under /sys/class/net."
  fi

  log_network_state "after DHCP attempts"

  return 1
}

fetch_latest_haos_release() {
  mkdir -p "$HAOS_ONLINE_DIR"
  release_json="$HAOS_ONLINE_DIR/latest-release.json"
  release_info="$HAOS_ONLINE_DIR/latest-release.env"

  log_info "Fetching latest HAOS release metadata."
  if ! curl --fail --location --silent --show-error \
    --header "Accept: application/vnd.github+json" \
    --header "User-Agent: HAOSInstallerLinux/0.1" \
    "$HAOS_RELEASE_API" \
    -o "$release_json" 2>/tmp/haos-release-curl.err; then
    log_warn "Failed to fetch HAOS release metadata: $(cat /tmp/haos-release-curl.err 2>/dev/null || true)"
    return 1
  fi

  jq -r '
    .assets[]
    | select(.name | test("^haos_generic-x86-64-.+\\.img\\.xz$"))
    | {
        version: (.name | capture("^haos_generic-x86-64-(?<version>.+)\\.img\\.xz$").version),
        filename: .name,
        url: .browser_download_url,
        size: .size,
        sha256: ((.digest // "") | sub("^sha256:"; ""))
      }
    | @sh "ONLINE_VERSION=\(.version) ONLINE_FILENAME=\(.filename) ONLINE_URL=\(.url) ONLINE_SIZE=\(.size) ONLINE_SHA256=\(.sha256)"
  ' "$release_json" > "$release_info"

  if [ ! -s "$release_info" ]; then
    log_error "Latest release did not include a generic x86-64 HAOS image."
    return 1
  fi

  # shellcheck disable=SC1090
  . "$release_info"

  if [ -z "${ONLINE_SHA256:-}" ] || [ "${#ONLINE_SHA256}" -ne 64 ]; then
    log_error "Latest HAOS release metadata did not include a valid SHA-256 digest."
    return 1
  fi

  log_info "Latest HAOS generic x86-64 image: $ONLINE_FILENAME"
  printf '%s\n' "$release_info"
}

download_online_image() {
  release_info="$1"
  output_dir="${2:-$HAOS_ONLINE_DIR}"
  replace_old="${3:-0}"
  mkdir -p "$output_dir"

  # shellcheck disable=SC1090
  . "$release_info"

  image_path="$output_dir/$ONLINE_FILENAME"
  checksum_path="$output_dir/$ONLINE_FILENAME.sha256"

  log_info "Downloading online HAOS payload image: $ONLINE_FILENAME"
  printf '\nDownloading %s\n\n' "$ONLINE_FILENAME" >/dev/tty 2>/dev/null || true
  if ! curl --fail --location --show-error "$ONLINE_URL" -o "$image_path.download"; then
    log_warn "Failed to download online HAOS payload: $ONLINE_FILENAME"
    rm -f "$image_path.download"
    return 1
  fi
  mv "$image_path.download" "$image_path"

  printf '%s  %s\n' "$ONLINE_SHA256" "$ONLINE_FILENAME" > "$checksum_path"
  if ! (cd "$output_dir" && sha256sum -c "$ONLINE_FILENAME.sha256" >/tmp/haos-online-sha256.out 2>&1); then
    cat /tmp/haos-online-sha256.out >&2
    return 1
  fi

  file_size_bytes="$(wc -c < "$image_path" | tr -d ' ')"
  write_haos_manifest "$output_dir" "$ONLINE_VERSION" "$ONLINE_FILENAME" "$ONLINE_SHA256" "$ONLINE_URL" "$file_size_bytes"
  if [ "$replace_old" = "1" ]; then
    remove_old_cached_images "$output_dir" "$ONLINE_FILENAME"
  fi

  log_info "Online HAOS payload verified: $image_path"
  printf '%s\n' "$image_path"
}
