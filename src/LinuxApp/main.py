#!/usr/bin/env python3
"""Single AppImage entry point for the desktop and privileged writer."""

import json
import os
import sys
from pathlib import Path


def main():
    if sys.argv[1:] == ["--write"]:
        from creator import write_usb

        try:
            request = json.load(sys.stdin)
            if request.get("bundled_image"):
                request["image"] = str(Path(os.environ["APPDIR"]) / "boot-image" / "haos-installer-x86_64.img")
            write_usb(request, lambda message: print(message, flush=True))
        except Exception as error:
            print(f"ERROR: {error}", flush=True)
            return 1
        return 0
    if sys.argv[1:] == ["--self-test"]:
        import gi
        import shutil

        gi.require_version("Gtk", "3.0")
        from gi.repository import Gtk
        from creator import usb_disks

        appdir = Path(os.environ["APPDIR"])
        for tool in ("lsblk", "sgdisk", "partx", "udevadm", "mount", "umount", "sync"):
            assert Path(shutil.which(tool)).is_relative_to(appdir), f"{tool} was not bundled"
        assert any(str(appdir) in line for line in Path("/proc/self/maps").read_text().splitlines()
                   if "libgtk-3.so.0" in line), "Bundled GTK library was not loaded"
        usb_disks()
        print(f"Bundled GTK {Gtk.MAJOR_VERSION} and Linux disk tools available")
        return 0
    if len(sys.argv) > 1:
        print("Unknown option", file=sys.stderr)
        return 2
    from gui import CreatorWindow, Gtk

    window = CreatorWindow()
    window.show_all()
    Gtk.main()
    return 0


if __name__ == "__main__":
    sys.exit(main())
