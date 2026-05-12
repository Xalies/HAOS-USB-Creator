#!/bin/sh
set -eu

lsblk_json() {
  if [ -n "${HAOS_FAKE_LSBLK:-}" ]; then
    cat "$HAOS_FAKE_LSBLK"
    return 0
  fi

  lsblk -J -o NAME,PATH,TYPE,SIZE,MODEL,SERIAL,WWN,TRAN,RM,ROTA,FSTYPE,LABEL,PARTLABEL,MOUNTPOINTS
}

detect_boot_usb() {
  if [ -n "${HAOS_BOOT_USB:-}" ]; then
    printf '%s\n' "$HAOS_BOOT_USB"
    return 0
  fi

  boot_by_label="$(lsblk -nr -o PKNAME,LABEL 2>/dev/null \
    | awk '$2 == "HAOSINSTLR" || $2 == "HAOS-INSTLR" || $2 == "HAOS-BOOT" || $2 == "HAOS-CACHE" { print "/dev/" $1; exit }')"
  if [ -n "$boot_by_label" ]; then
    printf '%s\n' "$boot_by_label"
    return 0
  fi

  boot_source="$(findmnt -n -o SOURCE / 2>/dev/null || true)"
  [ -n "$boot_source" ] || return 1
  lsblk -no PKNAME "$boot_source" 2>/dev/null | awk '{ print "/dev/" $1 }'
}

list_install_targets() {
  boot_usb="$(detect_boot_usb || true)"
  log_info "Detecting install target disks. Boot USB: ${boot_usb:-unknown}"

  lsblk_json | jq --arg boot_usb "$boot_usb" '
    def windows_like:
      (.fstype // "" | test("ntfs|BitLocker"; "i"))
      or (.partlabel // "" | test("EFI System|Microsoft|Recovery|Windows"; "i"))
      or (.label // "" | test("Windows|Recovery"; "i"));
    def haos_like:
      (.fstype // "" | test("vfat|ext4|squashfs"; "i"))
      or (.partlabel // "" | test("hassos|haos|home assistant|EFI System|kernel|system|data|boot"; "i"))
      or (.label // "" | test("hassos|haos|home assistant|kernel|system|data|boot"; "i"));
    def haos_installer_usb:
      ([ .children[]? | select((.label // "") == "HAOSINSTLR" or (.label // "") == "HAOS-INSTLR" or (.label // "") == "HAOS-BOOT" or (.label // "") == "HAOS-CACHE") ] | length > 0);

    [
      .blockdevices[]
      | select(.type == "disk")
      | select(.path != $boot_usb)
      | select(haos_installer_usb | not)
      | select((.tran // "") | test("nvme|sata|ata|mmc"; "i"))
      | {
          path,
          model: (.model // "Unknown"),
          serial: (.serial // ""),
          wwn: (.wwn // ""),
          size,
          tran: (.tran // "unknown"),
          removable: (.rm // false),
          hasWindowsPartitions: ([ .children[]? | select(windows_like) ] | length > 0),
          hasHaosLikePartitions: ([ .children[]? | select(haos_like) ] | length > 0),
          partitionCount: ([ .children[]? ] | length),
          partitionSummary: ([ .children[]? | "\(.name):\(.fstype // "unknown"):\(.partlabel // .label // "")" ] | join(", "))
        }
    ]
  '
}
