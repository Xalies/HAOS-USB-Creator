#!/usr/bin/env python3
"""Linux USB creation logic. Only --write runs with elevated privileges."""

import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

MAX_USB_BYTES = 128 * 1024**3
RELEASE_API = "https://api.github.com/repos/home-assistant/operating-system/releases/latest"
IMAGE_NAME = re.compile(r"^haos_generic-x86-64-([A-Za-z0-9._-]+)\.img\.xz$")
SYSTEM_MOUNTS = {"/", "/boot", "/boot/efi", "/home", "/var", "[SWAP]"}


def run(*args):
    result = subprocess.run(args, text=True, capture_output=True)
    if result.returncode:
        reason = (result.stderr or result.stdout).strip() or f"exit status {result.returncode}"
        raise RuntimeError(f"{args[0]} failed: {reason}")
    return result.stdout


def _nodes(tree):
    for node in tree:
        yield node
        yield from _nodes(node.get("children") or [])


def usb_disks():
    columns = "PATH,TYPE,TRAN,SIZE,MODEL,RM,MOUNTPOINTS,LABEL,MAJ:MIN"
    disks = json.loads(run("lsblk", "-J", "-b", "-o", columns))["blockdevices"]
    result = []
    for disk in disks:
        if disk.get("type") != "disk" or disk.get("tran") != "usb":
            continue
        size = int(disk.get("size") or 0)
        if not 0 < size <= MAX_USB_BYTES:
            continue
        mounts = [mount for node in _nodes([disk]) for mount in node.get("mountpoints") or [] if mount]
        if any(mount in SYSTEM_MOUNTS or mount.startswith(("/run/live/", "/cdrom", "/isodevice"))
               for mount in mounts):
            continue
        result.append({"path": disk["path"], "model": (disk.get("model") or "USB drive").strip(),
                       "size": size, "id": disk["maj:min"], "mounts": mounts})
    return result


def verify_file(path, expected):
    if not re.fullmatch(r"[a-fA-F0-9]{64}", expected):
        raise ValueError("A valid SHA-256 checksum is required.")
    digest = hashlib.sha256()
    with open(path, "rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    if digest.hexdigest() != expected.lower():
        raise ValueError(f"SHA-256 verification failed: {path}")


def verify_boot_image(path):
    image = Path(path).resolve(strict=True)
    if image.suffix != ".img" or not image.is_file():
        raise ValueError("Select a raw haos-installer .img file.")
    if image.stat().st_size == 0:
        raise ValueError("The installer boot image is empty.")
    checksum = Path(str(image) + ".sha256")
    expected = checksum.read_text(encoding="ascii").split()[0]
    verify_file(image, expected)
    return image


def latest_release():
    request = urllib.request.Request(RELEASE_API, headers={"User-Agent": "HAOS-USB-Creator-Linux"})
    with urllib.request.urlopen(request, timeout=30) as response:
        release = json.load(response)
    for asset in release["assets"]:
        match = IMAGE_NAME.fullmatch(asset["name"])
        digest = asset.get("digest") or ""
        if match and re.fullmatch(r"sha256:[a-fA-F0-9]{64}", digest):
            url = asset["browser_download_url"]
            if not url.startswith("https://github.com/home-assistant/operating-system/releases/download/"):
                raise ValueError("Unexpected Home Assistant OS download URL.")
            return {"version": match.group(1), "filename": asset["name"],
                    "url": url, "sha256": digest[7:].lower(), "size": int(asset["size"])}
    raise ValueError("The latest HAOS release has no verified generic x86-64 image.")


def download_release(release, progress):
    cache = Path(os.environ.get("XDG_CACHE_HOME") or Path.home() / ".cache") / "haos-usb-creator"
    cache.mkdir(parents=True, exist_ok=True)
    target = cache / release["filename"]
    if target.exists():
        try:
            verify_file(target, release["sha256"])
            progress("Using verified cached Home Assistant OS image")
            return target
        except ValueError:
            target.unlink()
    temporary = cache / (release["filename"] + ".part")
    progress(f"Downloading {release['filename']}")
    try:
        request = urllib.request.Request(release["url"], headers={"User-Agent": "HAOS-USB-Creator-Linux"})
        with urllib.request.urlopen(request, timeout=60) as remote, open(temporary, "wb") as local:
            digest = hashlib.sha256()
            copied = 0
            last_percent = 0
            started = time.monotonic()
            while chunk := remote.read(1024 * 1024):
                local.write(chunk)
                digest.update(chunk)
                copied += len(chunk)
                if release["size"]:
                    percent = min(100, copied * 100 // release["size"])
                    if percent >= last_percent + 5 or copied == release["size"]:
                        speed = copied / max(time.monotonic() - started, 0.001) / 1024**2
                        progress(f"Downloading Home Assistant OS: {percent}% ({speed:.1f} MiB/s)")
                        last_percent = percent
        if copied != release["size"] or digest.hexdigest() != release["sha256"]:
            raise ValueError("Downloaded Home Assistant OS image failed size or SHA-256 verification.")
        temporary.replace(target)
    finally:
        temporary.unlink(missing_ok=True)
    return target


def _copy(source, target, progress, label):
    size = Path(source).stat().st_size
    copied = 0
    last_percent = 0
    started = time.monotonic()
    with open(source, "rb") as src, open(target, "wb", buffering=0) as dst:
        while chunk := src.read(4 * 1024 * 1024):
            view = memoryview(chunk)
            while view:
                written = dst.write(view)
                if not written:
                    raise OSError(f"Write to {target} stopped unexpectedly.")
                view = view[written:]
            copied += len(chunk)
            percent = copied * 100 // size
            if copied < size and percent >= last_percent + 5:
                speed = copied / max(time.monotonic() - started, 0.001) / 1024**2
                progress(f"{label}: {percent}% ({speed:.1f} MiB/s)")
                last_percent = percent
        progress(f"{label}: flushing data to USB")
        os.fsync(dst.fileno())
    speed = copied / max(time.monotonic() - started, 0.001) / 1024**2
    progress(f"{label}: 100% ({speed:.1f} MiB/s)")


def _cache_partition(disk):
    for node in _nodes(json.loads(run("lsblk", "-J", "-o", "PATH,TYPE,LABEL", disk))["blockdevices"]):
        if node.get("type") == "part" and node.get("label") == "HAOS-CACHE":
            return node["path"]
    return None


def _update_partitions(disk):
    current = next((item for item in usb_disks() if item["path"] == disk["path"]
                    and item["id"] == disk["id"] and item["size"] == disk["size"]), None)
    if current is None:
        raise ValueError("The selected USB drive changed after writing the boot image.")
    for mount in sorted(current["mounts"], key=len, reverse=True):
        if mount.startswith("/"):
            run("umount", mount)
    run("partx", "--update", disk["path"])
    run("udevadm", "settle")


def write_usb(request, progress=print):
    if os.geteuid() != 0:
        raise PermissionError("USB writing requires administrator authorization.")
    disk = next((item for item in usb_disks() if item["path"] == request["disk"]
                 and item["id"] == request["id"] and item["size"] == request["size"]), None)
    if disk is None or not re.fullmatch(r"/dev/[a-zA-Z0-9_-]+", disk["path"]):
        raise ValueError("The selected USB drive changed or is no longer eligible. Refresh and select it again.")
    image = verify_boot_image(request["image"])
    if image.stat().st_size > disk["size"]:
        raise ValueError("The boot image is larger than the USB drive.")
    payload = request.get("payload")
    release = request.get("release")
    if payload:
        if not release or not IMAGE_NAME.fullmatch(release.get("filename", "")) \
                or Path(payload).name != release["filename"] \
                or not release.get("url", "").startswith(
                    "https://github.com/home-assistant/operating-system/releases/download/") \
                or not re.fullmatch(r"[a-fA-F0-9]{64}", release.get("sha256", "")):
            raise ValueError("Home Assistant OS image metadata does not match the selected file.")
        if not Path(payload).is_file():
            raise ValueError("Home Assistant OS image is not a regular file.")
        verify_file(payload, release["sha256"])
    for source in (image, payload, os.environ.get("APPIMAGE")):
        if source and any(Path(source).resolve().is_relative_to(mount) for mount in disk["mounts"] if mount.startswith("/")):
            raise ValueError("Source files cannot be stored on the USB drive being erased.")
    password = request.get("ssh_password") or ""
    if password and len(password) < 8:
        raise ValueError("The SSH password must have at least 8 characters.")

    for mount in sorted(disk["mounts"], key=len, reverse=True):
        if mount.startswith("/"):
            run("umount", mount)
    # Recheck the physical device after unmounting, immediately before erasing it.
    if not any(item["path"] == disk["path"] and item["id"] == disk["id"] and item["size"] == disk["size"]
               and not item["mounts"] for item in usb_disks()):
        raise ValueError("The selected USB drive changed before writing.")
    progress("Writing boot image: 0%")
    _copy(image, disk["path"], progress, "Writing boot image")
    progress("Finalising USB: This will take a moment…")
    run("sgdisk", "-e", disk["path"])
    _update_partitions(disk)
    cache_partition = None
    for _ in range(15):
        cache_partition = _cache_partition(disk["path"])
        if cache_partition:
            break
        time.sleep(1)
    if not cache_partition:
        raise RuntimeError("Boot image written, but its HAOS-CACHE partition did not appear.")

    # Desktop automounters may mount the new FAT partition as soon as udev finds it.
    partition = json.loads(run("lsblk", "-J", "-o", "MOUNTPOINTS", cache_partition))["blockdevices"][0]
    for existing_mount in partition.get("mountpoints") or []:
        if existing_mount:
            run("umount", existing_mount)

    with tempfile.TemporaryDirectory(prefix="haos-usb-") as mount:
        run("mount", "-t", "vfat", cache_partition, mount)
        try:
            cache = Path(mount) / "cache"
            cache.mkdir(exist_ok=True)
            config = {"schemaVersion": 1,
                      "unattended": {"enabled": bool(request.get("unattended")),
                                     "mode": "first-available-single-disk" if request.get("unattended") else "disabled",
                                     "runOnce": bool(request.get("unattended"))},
                      "ssh": {"enabled": bool(password), "password": password},
                      "legacyBiosBoot": {"enabled": bool(request.get("legacy"))}}
            (cache / "installer-config.json").write_text(json.dumps(config, indent=2) + "\n")
            if payload:
                if shutil.disk_usage(mount).free < Path(payload).stat().st_size + 16 * 1024 * 1024:
                    raise RuntimeError("The Home Assistant OS image does not fit in the USB cache partition.")
                destination = cache / release["filename"]
                _copy(payload, destination, progress, "Adding Home Assistant OS")
                (cache / (release["filename"] + ".sha256")).write_text(
                    f"{release['sha256']}  {release['filename']}\n")
                manifest = {"schemaVersion": 1, "imageType": "haos_generic-x86-64",
                            "version": release["version"], "filename": release["filename"],
                            "sha256": release["sha256"], "sourceUrl": release["url"],
                            "downloadedAtUtc": datetime.now(timezone.utc).isoformat(),
                            "createdBy": "HAOS USB Creator for Linux", "fileSizeBytes": Path(payload).stat().st_size}
                (cache / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
            progress("Synchronising USB: This may take a moment…")
            run("sync")
        finally:
            run("umount", mount)
    progress("USB ready. Safely remove it before booting the target PC.")


if __name__ == "__main__":
    if sys.argv[1:] != ["--write"]:
        sys.exit("Use gui.py to start the Linux desktop app.")
    try:
        write_usb(json.load(sys.stdin), lambda message: print(message, flush=True))
    except Exception as error:
        print(f"ERROR: {error}", flush=True)
        sys.exit(1)
