#!/bin/sh
set -eu

installer_ssh_enabled() {
  config="$(read_installer_config 2>/dev/null || true)"
  [ -n "$config" ] || return 1

  jq -e '.ssh.enabled == true and (.ssh.password // "" | length > 0)' "$config" >/dev/null
}

installer_ssh_password() {
  config="$(read_installer_config 2>/dev/null || true)"
  [ -n "$config" ] || return 1

  jq -r '.ssh.password // empty' "$config"
}

start_configured_ssh() {
  installer_ssh_enabled || return 0

  if ! command -v sshd >/dev/null 2>&1; then
    log_warn "SSH was enabled, but sshd is not installed in this boot image."
    return 1
  fi

  password="$(installer_ssh_password)"
  [ -n "$password" ] || return 1

  log_info "SSH access is enabled by USB creator configuration."
  try_dhcp_once || log_warn "Could not obtain DHCP before starting SSH."

  ssh-keygen -A >/tmp/haos-ssh-keygen.out 2>/tmp/haos-ssh-keygen.err || {
    log_warn "Could not generate SSH host keys: $(cat /tmp/haos-ssh-keygen.err 2>/dev/null || true)"
    return 1
  }

  printf 'root:%s\n' "$password" | chpasswd
  {
    printf '\n# HAOS installer temporary SSH access\n'
    printf 'PermitRootLogin yes\n'
    printf 'PasswordAuthentication yes\n'
  } >> /etc/ssh/sshd_config

  mkdir -p /run/sshd
  /usr/sbin/sshd
  log_info "SSH started. Connect as root to the installer IP address."
}
