#!/bin/sh
set -eu

installer_ssh_enabled() {
  config="$(find_installer_config 2>/dev/null || true)"
  if [ -z "$config" ]; then
    log_info "SSH is not enabled because installer-config.json was not found."
    return 1
  fi

  jq -e '.ssh.enabled == true and (.ssh.password // "" | length > 0)' "$config" >/dev/null
}

installer_ssh_password() {
  config="$(find_installer_config 2>/dev/null || true)"
  [ -n "$config" ] || return 1

  jq -r '.ssh.password // empty' "$config"
}

find_installer_config() {
  cache_dir="$(find_cache_partition)"
  config="$cache_dir/installer-config.json"

  [ -f "$config" ] || return 1
  printf '%s\n' "$config"
}

restore_or_create_ssh_host_keys() {
  cache_dir="$(find_cache_partition 2>/dev/null || true)"
  key_dir="$cache_dir/ssh"

  mkdir -p /etc/ssh
  if [ -n "$cache_dir" ] && [ -d "$key_dir" ]; then
    cp "$key_dir"/ssh_host_*_key* /etc/ssh/ >/dev/null 2>&1 || true
    chmod 600 /etc/ssh/ssh_host_*_key 2>/dev/null || true
    chmod 644 /etc/ssh/ssh_host_*_key.pub 2>/dev/null || true
  fi

  ssh-keygen -A >/tmp/haos-ssh-keygen.out 2>/tmp/haos-ssh-keygen.err || {
    log_warn "Could not generate SSH host keys: $(cat /tmp/haos-ssh-keygen.err 2>/dev/null || true)"
    return 1
  }

  if [ -n "$cache_dir" ]; then
    mkdir -p "$key_dir" 2>/dev/null || return 0
    cp /etc/ssh/ssh_host_*_key* "$key_dir"/ >/dev/null 2>&1 || true
    log_info "SSH host keys are stored on the USB cache partition."
  fi
}

start_configured_ssh() {
  installer_ssh_enabled || return 0

  if ! command -v sshd >/dev/null 2>&1; then
    log_warn "SSH was enabled, but sshd is not installed in this boot image."
    return 1
  fi

  password="$(installer_ssh_password)"
  [ -n "$password" ] || return 1

  config="$(find_installer_config)"
  log_info "SSH access is enabled by USB creator configuration: $config"
  ensure_kernel_modules_available || true
  load_network_modules || true
  try_dhcp_once || log_warn "Could not obtain DHCP before starting SSH."

  restore_or_create_ssh_host_keys || return 1

  printf 'root:%s\n' "$password" | chpasswd >/tmp/haos-chpasswd.out 2>/tmp/haos-chpasswd.err || {
    log_warn "Could not set SSH password: $(cat /tmp/haos-chpasswd.err 2>/dev/null || true)"
    return 1
  }
  {
    printf '\n# HAOS installer temporary SSH access\n'
    printf 'PermitRootLogin yes\n'
    printf 'PasswordAuthentication yes\n'
    printf 'PubkeyAuthentication no\n'
    printf 'KbdInteractiveAuthentication no\n'
    printf 'ForceCommand /usr/local/bin/haos-installer-ssh\n'
  } >> /etc/ssh/sshd_config

  mkdir -p /run/sshd
  /usr/sbin/sshd -t >/tmp/haos-sshd-test.out 2>/tmp/haos-sshd-test.err || {
    log_warn "sshd configuration test failed: $(cat /tmp/haos-sshd-test.err 2>/dev/null || true)"
    return 1
  }

  /usr/sbin/sshd >/tmp/haos-sshd.out 2>/tmp/haos-sshd.err || {
    log_warn "sshd failed to start: $(cat /tmp/haos-sshd.err 2>/dev/null || true)"
    return 1
  }

  if command -v ip >/dev/null 2>&1; then
    log_info "Installer IP addresses after SSH start: $(ip -o addr show 2>/dev/null | tr '\n' ' ')"
    log_info "Installer routes after SSH start: $(ip route show 2>/dev/null | tr '\n' ' ')"
  fi

  log_info "SSH started. Connect as root to the installer IP address."
}
