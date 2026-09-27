#!/usr/bin/env python3
"""GTK desktop front end for the native Linux USB creator."""

import json
import os
import re
import shutil
import subprocess
import threading
from pathlib import Path

import gi

gi.require_version("Gtk", "3.0")
gi.require_version("GdkPixbuf", "2.0")
from gi.repository import GdkPixbuf, GLib, Gtk

from creator import download_release, latest_release, usb_disks, verify_boot_image


class CreatorWindow(Gtk.Window):
    def __init__(self):
        super().__init__(title="HAOS AIO USB Creator")
        self.set_default_size(980, 640)
        self.set_border_width(18)
        self.connect("destroy", Gtk.main_quit)
        self.disks = []
        self.pulsing_step = None
        root = Gtk.Box(spacing=24)
        self.add(root)
        sidebar = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=16)
        sidebar.set_size_request(170, -1)
        root.pack_start(sidebar, False, False, 0)
        brand = Gtk.Label()
        brand.set_markup("<big><b>HAOS AIO</b></big>\nUSB Creator")
        brand.set_xalign(0)
        sidebar.pack_start(brand, False, False, 8)
        sidebar.pack_start(Gtk.Separator(), False, False, 8)
        self.nav_labels = []
        for _ in ("Welcome", "USB drive", "Review", "Writing"):
            item = Gtk.Label()
            item.set_xalign(0)
            sidebar.pack_start(item, False, False, 0)
            self.nav_labels.append(item)
        self.coffee_panel = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=7)
        self.coffee_panel.set_no_show_all(True)
        coffee = Gtk.Label(label="If this saved you some time")
        self.coffee_panel.pack_start(coffee, False, False, 0)
        image_path = Path(__file__).resolve().parent / "assets" / "bmc-button.png"
        if not image_path.exists():
            image_path = Path(__file__).resolve().parents[1] / "WindowsApp" / "src" / "HAOSInstaller.App" / "Assets" / "bmc-button.png"
        pixbuf = GdkPixbuf.Pixbuf.new_from_file_at_scale(str(image_path), 128, 36, True)
        self.coffee_link = Gtk.LinkButton.new_with_label("https://buymeacoffee.com/xalies", "")
        self.coffee_link.set_image(Gtk.Image.new_from_pixbuf(pixbuf))
        self.coffee_link.set_always_show_image(True)
        self.coffee_link.set_tooltip_text("If this saved you some time, feel free to buy me a coffee!")
        self.coffee_panel.pack_start(self.coffee_link, False, False, 0)
        coffee.show()
        self.coffee_link.show_all()
        sidebar.pack_end(self.coffee_panel, False, False, 4)
        root.pack_start(Gtk.Separator(orientation=Gtk.Orientation.VERTICAL), False, False, 0)
        self.pages = Gtk.Stack()
        self.pages.set_transition_type(Gtk.StackTransitionType.SLIDE_LEFT_RIGHT)
        root.pack_start(self.pages, True, True, 0)

        welcome = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=16)
        self.pages.add_named(welcome, "welcome")
        title = Gtk.Label()
        title.set_markup("<big><b>Create an all-in-one HAOS install USB</b></big>")
        title.set_xalign(0)
        welcome.pack_start(title, False, False, 0)
        intro = Gtk.Label(label="Create a bootable installer for a dedicated generic x86-64 PC.")
        intro.set_xalign(0)
        welcome.pack_start(intro, False, False, 0)
        for line in ("The selected USB drive will be erased.",
                     "The latest verified Home Assistant OS image is copied to the USB when available.",
                     "Boot the target PC from the USB to begin installation."):
            item = Gtk.Label(label="• " + line)
            item.set_xalign(0)
            item.set_line_wrap(True)
            welcome.pack_start(item, False, False, 0)
        next_button = Gtk.Button(label="Continue")
        next_button.connect("clicked", lambda *_: self._show_page("drive"))
        welcome.pack_end(next_button, False, False, 0)

        drive_page = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12)
        self.pages.add_named(drive_page, "drive")
        heading = Gtk.Label()
        heading.set_markup("<big><b>Choose a USB drive</b></big>")
        heading.set_xalign(0)
        drive_page.pack_start(heading, False, False, 0)
        row = Gtk.Box(spacing=8)
        drive_page.pack_start(row, False, False, 0)
        row.pack_start(Gtk.Label(label="USB drive"), False, False, 0)
        self.drive = Gtk.ComboBoxText()
        row.pack_start(self.drive, True, True, 0)
        refresh = Gtk.Button(label="Refresh")
        refresh.connect("clicked", self.refresh)
        row.pack_start(refresh, False, False, 0)

        row = Gtk.Box(spacing=8)
        drive_page.pack_start(row, False, False, 0)
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
            drive_page.pack_start(checkbox, False, False, 0)
        self.password = Gtk.Entry()
        self.password.set_placeholder_text("SSH password, at least 8 characters")
        self.password.set_visibility(False)
        self.password.set_sensitive(False)
        self.ssh.connect("toggled", lambda button: self.password.set_sensitive(button.get_active()))
        drive_page.pack_start(self.password, False, False, 0)
        self.drive_feedback = Gtk.Label()
        self.drive_feedback.set_xalign(0)
        drive_page.pack_start(self.drive_feedback, False, False, 0)
        drive_actions = Gtk.Box(spacing=8)
        back = Gtk.Button(label="Back")
        back.connect("clicked", lambda *_: self._show_page("welcome"))
        drive_actions.pack_start(back, False, False, 0)
        next_button = Gtk.Button(label="Review")
        next_button.connect("clicked", self._go_review)
        drive_actions.pack_end(next_button, False, False, 0)
        drive_page.pack_end(drive_actions, False, False, 0)

        review = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=16)
        self.pages.add_named(review, "review")
        heading = Gtk.Label()
        heading.set_markup("<big><b>Review your choices</b></big>")
        heading.set_xalign(0)
        review.pack_start(heading, False, False, 0)
        self.review_summary = Gtk.Label()
        self.review_summary.set_xalign(0)
        self.review_summary.set_line_wrap(True)
        review.pack_start(self.review_summary, False, False, 0)
        warning = Gtk.Label(label="All data on the selected USB drive will be erased.")
        warning.set_xalign(0)
        review.pack_start(warning, False, False, 0)
        review_actions = Gtk.Box(spacing=8)
        back = Gtk.Button(label="Back")
        back.connect("clicked", lambda *_: self._show_page("drive"))
        review_actions.pack_start(back, False, False, 0)
        start_button = Gtk.Button(label="Start write")
        start_button.connect("clicked", self.start)
        review_actions.pack_end(start_button, False, False, 0)
        review.pack_end(review_actions, False, False, 0)

        writing = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        self.pages.add_named(writing, "writing")
        heading = Gtk.Label()
        heading.set_markup("<big><b>Creating the install USB</b></big>")
        heading.set_xalign(0)
        writing.pack_start(heading, False, False, 0)
        note = Gtk.Label(label="Do not remove the USB drive or close this window.")
        note.set_xalign(0)
        writing.pack_start(note, False, False, 0)
        self.write_badges = []
        self.write_statuses = []
        self.write_bars = []
        for title in ("1 - Prepare installer", "2 - Download Home Assistant OS",
                      "3 - Write boot image", "4 - Finalise USB"):
            card = Gtk.Frame()
            content = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
            content.set_border_width(8)
            row = Gtk.Box(spacing=8)
            name = Gtk.Label(label=title)
            name.set_xalign(0)
            row.pack_start(name, True, True, 0)
            badge = Gtk.Label(label="Waiting")
            row.pack_end(badge, False, False, 0)
            self.write_badges.append(badge)
            content.pack_start(row, False, False, 0)
            status = Gtk.Label(label="Waiting")
            status.set_xalign(0)
            status.set_line_wrap(True)
            self.write_statuses.append(status)
            content.pack_start(status, False, False, 0)
            bar = Gtk.ProgressBar()
            bar.set_show_text(True)
            bar.set_text("Waiting")
            self.write_bars.append(bar)
            content.pack_start(bar, False, False, 0)
            card.add(content)
            writing.pack_start(card, False, False, 0)
        self.active_step = 0
        self.create = Gtk.Button(label="Try again")
        self.create.connect("clicked", self.start)
        self.create.set_no_show_all(True)
        self.create.hide()
        writing.pack_end(self.create, False, False, 0)

        finish = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=16)
        self.pages.add_named(finish, "finish")
        heading = Gtk.Label()
        heading.set_markup("<big><b>Install USB is ready</b></big>")
        heading.set_xalign(0)
        finish.pack_start(heading, False, False, 0)
        self.finish_summary = Gtk.Label()
        self.finish_summary.set_xalign(0)
        self.finish_summary.set_line_wrap(True)
        finish.pack_start(self.finish_summary, False, False, 0)
        next_step = Gtk.Label(label="Safely remove the USB, then boot the target PC from it to start installation.")
        next_step.set_xalign(0)
        next_step.set_line_wrap(True)
        finish.pack_start(next_step, False, False, 0)
        start_over = Gtk.Button(label="Start over")
        start_over.connect("clicked", lambda *_: self._show_page("welcome"))
        finish.pack_end(start_over, False, False, 0)

        self._show_page("welcome")
        GLib.timeout_add(150, self._pulse)
        self.refresh()

    def _show_page(self, page):
        self.pages.set_visible_child_name(page)
        if page == "finish":
            self.coffee_panel.show()
        else:
            self.coffee_panel.hide()
        active = {"welcome": 0, "drive": 1, "review": 2, "writing": 3, "finish": 3}[page]
        for index, label in enumerate(self.nav_labels):
            title = ("Welcome", "USB drive", "Review", "Writing")[index]
            label.set_markup(f"<b>{index + 1}. {title}</b>" if index == active else f"{index + 1}. {title}")

    def _go_review(self, *_):
        index = self.drive.get_active()
        if index < 0:
            self.drive_feedback.set_text("Select a USB drive first.")
            return
        if self.ssh.get_active() and len(self.password.get_text()) < 8:
            self.drive_feedback.set_text("The SSH password must have at least 8 characters.")
            return
        self.drive_feedback.set_text("")
        disk = self.disks[index]
        options = ["Unattended install" if self.unattended.get_active() else "Guided install",
                   "Legacy BIOS enabled" if self.legacy.get_active() else "UEFI boot",
                   "SSH enabled" if self.ssh.get_active() else "SSH disabled"]
        self.review_summary.set_text(
            f"USB drive: {disk['path']} — {disk['model']} — {disk['size'] / 1024**3:.1f} GiB\n"
            f"Installer image: {self.image.get_text()}\n" + " • ".join(options))
        self._show_page("review")

    def _pulse(self):
        if self.pulsing_step is not None:
            self.write_bars[self.pulsing_step].pulse()
        return True

    def status(self, stage, detail="", percent=None, step=None):
        GLib.idle_add(self._status, stage, detail, percent, step)

    def _status(self, stage, detail="", percent=None, step=None):
        if step is not None:
            for index, badge in enumerate(self.write_badges):
                if index < step and badge.get_text() != "Skipped":
                    badge.set_text("Done")
                    self.write_bars[index].set_fraction(1)
                    self.write_bars[index].set_text("Complete")
                elif index == step:
                    badge.set_text("Working…")
            self.active_step = step
        self.write_statuses[self.active_step].set_text(f"{stage}: {detail}" if detail else stage)
        bar = self.write_bars[self.active_step]
        bar.set_fraction(percent / 100 if percent is not None else 0)
        bar.set_text(f"{percent}%" if percent is not None else "Working…")
        self.pulsing_step = self.active_step if percent is None else None

    def _skip_download(self, error):
        self.write_badges[1].set_text("Skipped")
        self.write_statuses[1].set_text(f"Download unavailable: {error}. The target PC will need internet access.")
        self.write_bars[1].set_fraction(0)
        self.write_bars[1].set_text("Skipped")

    def _finish(self, success, detail):
        self.pulsing_step = None
        self.write_statuses[self.active_step].set_text("USB ready" if success else detail)
        if success:
            self.write_bars[self.active_step].set_fraction(1)
        self.write_bars[self.active_step].set_text("Complete" if success else "Failed")
        self.write_badges[self.active_step].set_text("Done" if success else "Failed")
        if success:
            self.finish_summary.set_text(detail)
            self._show_page("finish")
        else:
            self.create.show()
            self._show_page("writing")

    def message(self, text):
        GLib.idle_add(self._message, text)

    def _message(self, text):
        match = re.fullmatch(r"(Downloading Home Assistant OS|Writing boot image|Adding Home Assistant OS): (\d+)%(?: \(([^)]+)\))?", text)
        if match:
            step = {"Downloading Home Assistant OS": 1, "Writing boot image": 2,
                    "Adding Home Assistant OS": 3}[match[1]]
            self._status(match[1], f"{match[2]}%" + (f" at {match[3]}" if match[3] else ""),
                         int(match[2]), step)
        elif text.endswith(": flushing data to USB"):
            step = 2 if text.startswith("Writing boot image:") else 3
            self._status("Flushing written data", "This can take a moment…", step=step)
        elif text.startswith("Finalising USB:"):
            self._status("Finalising USB", "This will take a moment…", step=3)
        elif text.startswith("Synchronising USB:"):
            self._status("Synchronising USB", "This may take a moment…", step=3)

    def refresh(self, *_):
        self.drive.remove_all()
        try:
            self.disks = usb_disks()
            for disk in self.disks:
                size = disk["size"] / 1024**3
                self.drive.append_text(f"{disk['path']} — {disk['model']} — {size:.1f} GiB")
            if self.disks:
                self.drive.set_active(0)
                self.drive_feedback.set_text("")
            else:
                self.drive_feedback.set_text("No eligible USB drives found. Connect one and click Refresh.")
        except Exception as error:
            self.drive_feedback.set_text(f"Drive detection failed: {error}")

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
            self._show_page("drive")
            self.drive_feedback.set_text("Select a USB drive first.")
            return
        disk = self.disks[index]
        if self.ssh.get_active() and len(self.password.get_text()) < 8:
            self._show_page("drive")
            self.drive_feedback.set_text("The SSH password must have at least 8 characters.")
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
        self.create.hide()
        for index, badge in enumerate(self.write_badges):
            badge.set_text("Waiting")
            self.write_statuses[index].set_text("Waiting")
            self.write_bars[index].set_fraction(0)
            self.write_bars[index].set_text("Waiting")
        self._show_page("writing")
        self._status("Checking boot image", "Verifying the bundled installer…", step=0)
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
            verify_boot_image(request["image"])
            try:
                self.status("Finding Home Assistant OS", "Checking the latest release and local cache…", step=1)
                release = latest_release()
                self.status("Downloading Home Assistant OS", "Preparing a verified image for the USB drive…", step=1)
                payload = download_release(release, self.message)
                request.update(payload=str(payload), release=release)
                self.status("Home Assistant OS ready", "Verified image is ready for the USB drive.", 100, 1)
            except Exception as error:
                GLib.idle_add(self._skip_download, str(error))
            self.status("Awaiting administrator access", "Authorization is required to write the USB drive.", step=2)
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
            self.status("Preparing USB drive", "Checking the drive and installer files before writing…", step=2)
            last_error = None
            for line in process.stdout:
                line = line.rstrip()
                self.message(line)
                if line.startswith("ERROR: "):
                    last_error = line[7:]
            if process.wait():
                raise RuntimeError(last_error or "USB creation failed or administrator authorization was cancelled.")
            detail = (f"{request['disk']} is ready. Safely remove it, then boot the target PC from it."
                      if request.get("payload") else
                      f"{request['disk']} is ready. The target PC will need internet access to install Home Assistant OS. Safely remove the USB drive.")
            GLib.idle_add(self._finish, True, detail)
        except Exception as error:
            GLib.idle_add(self._finish, False, str(error))


if __name__ == "__main__":
    window = CreatorWindow()
    window.show_all()
    Gtk.main()
