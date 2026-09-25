#!/usr/bin/env python3
"""GTK desktop front end for the native Linux USB creator."""

import json
import os
import shutil
import subprocess
import threading
from pathlib import Path

import gi

gi.require_version("Gtk", "3.0")
from gi.repository import GLib, Gtk

from creator import download_release, latest_release, usb_disks, verify_boot_image


class CreatorWindow(Gtk.Window):
    def __init__(self):
        super().__init__(title="HAOS AIO USB Creator")
        self.set_default_size(660, 540)
        self.set_border_width(18)
        self.connect("destroy", Gtk.main_quit)
        self.disks = []

        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12)
        self.add(box)
        title = Gtk.Label()
        title.set_markup("<big><b>Create a Home Assistant OS installer USB</b></big>")
        title.set_xalign(0)
        box.pack_start(title, False, False, 0)
        note = Gtk.Label(label="For a dedicated generic x86-64 PC. The selected USB drive will be erased.")
        note.set_xalign(0)
        box.pack_start(note, False, False, 0)

        row = Gtk.Box(spacing=8)
        box.pack_start(row, False, False, 0)
        row.pack_start(Gtk.Label(label="USB drive"), False, False, 0)
        self.drive = Gtk.ComboBoxText()
        row.pack_start(self.drive, True, True, 0)
        refresh = Gtk.Button(label="Refresh")
        refresh.connect("clicked", self.refresh)
        row.pack_start(refresh, False, False, 0)

        row = Gtk.Box(spacing=8)
        box.pack_start(row, False, False, 0)
        row.pack_start(Gtk.Label(label="Boot image"), False, False, 0)
        self.image = Gtk.Entry()
        default = Path(os.environ.get("APPDIR") or Path(__file__).resolve().parent) / "boot-image" / "haos-installer-x86_64.img"
        if not default.exists():
            default = Path(__file__).resolve().parents[2] / "artifacts" / "installer-linux" / default.name
        self.image.set_text(str(default))
        row.pack_start(self.image, True, True, 0)
        browse = Gtk.Button(label="Browse…")
        browse.connect("clicked", self.browse)
        row.pack_start(browse, False, False, 0)

        self.unattended = Gtk.CheckButton(label="Unattended install (only when the target PC has one internal disk)")
        self.legacy = Gtk.CheckButton(label="Enable legacy BIOS support on the installed PC")
        self.ssh = Gtk.CheckButton(label="Enable SSH in the booted installer")
        for checkbox in (self.unattended, self.legacy, self.ssh):
            box.pack_start(checkbox, False, False, 0)
        self.password = Gtk.Entry()
        self.password.set_placeholder_text("SSH password, at least 8 characters")
        self.password.set_visibility(False)
        self.password.set_sensitive(False)
        self.ssh.connect("toggled", lambda button: self.password.set_sensitive(button.get_active()))
        box.pack_start(self.password, False, False, 0)

        self.progress = Gtk.ProgressBar()
        box.pack_start(self.progress, False, False, 0)
        scroll = Gtk.ScrolledWindow()
        scroll.set_policy(Gtk.PolicyType.AUTOMATIC, Gtk.PolicyType.AUTOMATIC)
        box.pack_start(scroll, True, True, 0)
        self.log = Gtk.TextView()
        self.log.set_editable(False)
        self.log.set_wrap_mode(Gtk.WrapMode.WORD)
        scroll.add(self.log)
        self.create = Gtk.Button(label="Create installer USB")
        self.create.connect("clicked", self.start)
        box.pack_start(self.create, False, False, 0)
        self.refresh()

    def message(self, text):
        GLib.idle_add(self._message, text)

    def _message(self, text):
        buffer = self.log.get_buffer()
        buffer.insert(buffer.get_end_iter(), text + "\n")
        self.log.scroll_to_iter(buffer.get_end_iter(), 0, False, 0, 0)
        if text.endswith("%"):
            try:
                self.progress.set_fraction(int(text.rsplit(": ", 1)[1][:-1]) / 100)
            except (ValueError, IndexError):
                pass

    def refresh(self, *_):
        self.drive.remove_all()
        try:
            self.disks = usb_disks()
            for disk in self.disks:
                size = disk["size"] / 1024**3
                self.drive.append_text(f"{disk['path']} — {disk['model']} — {size:.1f} GiB")
            if self.disks:
                self.drive.set_active(0)
            else:
                self.message("No eligible USB drives found. Connect one and click Refresh.")
        except Exception as error:
            self.message(f"Drive detection failed: {error}")

    def browse(self, *_):
        dialog = Gtk.FileChooserDialog(title="Select verified installer boot image", parent=self,
                                       action=Gtk.FileChooserAction.OPEN)
        dialog.add_buttons(Gtk.STOCK_CANCEL, Gtk.ResponseType.CANCEL,
                           Gtk.STOCK_OPEN, Gtk.ResponseType.OK)
        if dialog.run() == Gtk.ResponseType.OK:
            self.image.set_text(dialog.get_filename())
        dialog.destroy()

    def start(self, *_):
        index = self.drive.get_active()
        if index < 0:
            self.message("Select a USB drive first.")
            return
        disk = self.disks[index]
        if self.ssh.get_active() and len(self.password.get_text()) < 8:
            self.message("The SSH password must have at least 8 characters.")
            return
        if self.unattended.get_active() and not self.confirm(
                "Unattended mode will erase the only eligible internal disk on the target PC without a prompt. Continue?"):
            return
        if not self.confirm(f"Erase all data on {disk['path']} ({disk['model']}, {disk['size'] / 1024**3:.1f} GiB)?"):
            return
        request = {"disk": disk["path"], "id": disk["id"], "size": disk["size"],
                   "image": self.image.get_text(), "unattended": self.unattended.get_active(),
                   "legacy": self.legacy.get_active(),
                   "ssh_password": self.password.get_text() if self.ssh.get_active() else ""}
        if os.environ.get("APPIMAGE"):
            bundled = Path(os.environ["APPDIR"]) / "boot-image" / "haos-installer-x86_64.img"
            request["bundled_image"] = Path(request["image"]).resolve() == bundled.resolve()
        self.create.set_sensitive(False)
        self.progress.set_fraction(0)
        threading.Thread(target=self.worker, args=(request,), daemon=True).start()

    def confirm(self, text):
        dialog = Gtk.MessageDialog(transient_for=self, flags=0, message_type=Gtk.MessageType.WARNING,
                                   buttons=Gtk.ButtonsType.YES_NO, text=text)
        dialog.format_secondary_text("This cannot be undone.")
        result = dialog.run() == Gtk.ResponseType.YES
        dialog.destroy()
        return result

    def sudo_password(self):
        ready = threading.Event()
        answer = {}

        def prompt():
            dialog = Gtk.Dialog(title="Administrator password", transient_for=self, flags=0)
            dialog.add_buttons(Gtk.STOCK_CANCEL, Gtk.ResponseType.CANCEL,
                               "Continue", Gtk.ResponseType.OK)
            entry = Gtk.Entry()
            entry.set_visibility(False)
            entry.set_placeholder_text("Your Linux login password")
            dialog.get_content_area().add(entry)
            dialog.show_all()
            if dialog.run() == Gtk.ResponseType.OK:
                answer["password"] = entry.get_text()
            entry.set_text("")
            dialog.destroy()
            ready.set()
            return False

        GLib.idle_add(prompt)
        ready.wait()
        if not answer.get("password"):
            raise RuntimeError("Administrator authorization was cancelled.")
        return answer["password"]

    def worker(self, request):
        try:
            self.message("Verifying installer boot image…")
            verify_boot_image(request["image"])
            try:
                release = latest_release()
                payload = download_release(release, self.message)
                request.update(payload=str(payload), release=release)
            except Exception as error:
                self.message(f"Could not cache Home Assistant OS: {error}")
                self.message("The booted installer will need internet access to download Home Assistant OS.")
            self.message("Requesting administrator authorization to write the USB drive…")
            if os.environ.get("APPIMAGE"):
                command = [os.environ["APPIMAGE"]]
                if os.environ.get("HAOS_APPIMAGE_EXTRACTED"):
                    command.append("--appimage-extract-and-run")
                command.append("--write")
            else:
                command = ["/usr/bin/python3", str(Path(__file__).with_name("main.py")), "--write"]
            child_env = {key: value for key, value in os.environ.items() if not key.startswith("_PYI_")}
            child_env["PYINSTALLER_RESET_ENVIRONMENT"] = "1"
            child_env["LD_LIBRARY_PATH"] = child_env.get("LD_LIBRARY_PATH_ORIG", "")
            if os.geteuid() == 0:
                pass
            elif shutil.which("pkexec"):
                command.insert(0, "pkexec")
            elif shutil.which("sudo"):
                authorization = subprocess.run(
                    ["sudo", "-S", "-k", "-p", "", "-v"],
                    input=self.sudo_password() + "\n", text=True,
                    capture_output=True, env=child_env)
                if authorization.returncode:
                    raise RuntimeError("Administrator authentication failed.")
                command = ["sudo", "-n", *command]
            else:
                raise RuntimeError("Administrator authorization is unavailable (pkexec or sudo).")
            process = subprocess.Popen(command,
                                       stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                       stderr=subprocess.STDOUT, text=True, bufsize=1, env=child_env)
            process.stdin.write(json.dumps(request))
            process.stdin.close()
            for line in process.stdout:
                self.message(line.rstrip())
            if process.wait():
                raise RuntimeError("USB creation failed or administrator authorization was cancelled.")
        except Exception as error:
            self.message(f"Error: {error}")
        finally:
            GLib.idle_add(self.create.set_sensitive, True)


if __name__ == "__main__":
    window = CreatorWindow()
    window.show_all()
    Gtk.main()
