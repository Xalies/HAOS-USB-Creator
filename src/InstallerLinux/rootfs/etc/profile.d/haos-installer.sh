#!/bin/sh

if [ "$(tty 2>/dev/null || true)" = "/dev/tty1" ]; then
  printf 'To restart the HAOS AIO Installer USB, run: haos-installer-run\n'
fi

