import hashlib
import io
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import call, patch

import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import creator
import main


class CreatorTests(unittest.TestCase):
    def test_partition_update_unmounts_before_partx(self):
        disk = {"path": "/dev/sdb", "id": "8:16", "size": 8000,
                "mounts": ["/media/HAOS-CACHE"]}
        with patch.object(creator, "usb_disks", return_value=[disk]), \
             patch.object(creator, "run") as run:
            creator._update_partitions(disk)
        self.assertEqual([call("umount", "/media/HAOS-CACHE"),
                          call("partx", "--update", "/dev/sdb"),
                          call("udevadm", "settle")], run.call_args_list)

    def test_copy_reports_complete_after_sync(self):
        with tempfile.TemporaryDirectory() as temp:
            source = Path(temp) / "source.img"
            target = Path(temp) / "target.img"
            source.write_bytes(b"installer")
            events = []
            with patch.object(creator.os, "fsync", side_effect=lambda _: events.append("synced")):
                creator._copy(source, target, events.append, "Writing boot image")
            self.assertEqual("synced", events[-2])
            self.assertTrue(events[-1].startswith("Writing boot image: 100%"))

    def test_command_error_shows_device_reason(self):
        failure = subprocess.CompletedProcess(("sgdisk", "-e", "/dev/sdb"), 1, "",
                                              "sgdisk: /dev/sdb: Device or resource busy\n")
        with patch.object(creator.subprocess, "run", return_value=failure):
            with self.assertRaisesRegex(RuntimeError, "sgdisk.*Device or resource busy"):
                creator.run("sgdisk", "-e", "/dev/sdb")

    def test_usb_discovery_excludes_system_disk_and_non_usb(self):
        disks = {"blockdevices": [
            {"path": "/dev/sda", "type": "disk", "tran": "sata", "size": 32 * 1024**3,
             "model": "internal", "maj:min": "8:0", "mountpoints": ["/"], "children": []},
            {"path": "/dev/sdb", "type": "disk", "tran": "usb", "size": 8 * 1024**3,
             "model": "live USB", "maj:min": "8:16", "mountpoints": [None],
             "children": [{"mountpoints": ["/"]}]},
            {"path": "/dev/sdc", "type": "disk", "tran": "usb", "size": 8 * 1024**3,
             "model": "installer USB", "maj:min": "8:32", "mountpoints": [None],
             "children": [{"mountpoints": ["/media/user/USB"]}]},
        ]}
        with patch.object(creator, "run", return_value=json.dumps(disks)):
            self.assertEqual(["/dev/sdc"], [disk["path"] for disk in creator.usb_disks()])

    def test_boot_image_requires_valid_checksum(self):
        with tempfile.TemporaryDirectory() as temp:
            image = Path(temp) / "haos-installer-x86_64.img"
            image.write_bytes(b"boot image")
            checksum = Path(str(image) + ".sha256")
            checksum.write_text(hashlib.sha256(image.read_bytes()).hexdigest() + "  " + image.name)
            self.assertEqual(image, creator.verify_boot_image(image))
            image.write_bytes(b"tampered")
            with self.assertRaisesRegex(ValueError, "SHA-256"):
                creator.verify_boot_image(image)

    def test_writer_rejects_changed_device_before_erasure(self):
        with patch.object(creator.os, "geteuid", return_value=0), \
             patch.object(creator, "usb_disks", return_value=[]), \
             patch.object(creator, "run") as run:
            with self.assertRaisesRegex(ValueError, "changed"):
                creator.write_usb({"disk": "/dev/sdc", "id": "8:32", "size": 8000,
                                   "image": "/tmp/boot.img"})
            run.assert_not_called()

    def test_privileged_appimage_uses_its_own_boot_image(self):
        request = {"disk": "/dev/sdc", "image": "/tmp/other-mount/boot-image/haos-installer-x86_64.img",
                   "bundled_image": True}
        with patch.object(main.sys, "argv", ["main", "--write"]), \
             patch.object(main.sys, "stdin", io.StringIO(json.dumps(request))), \
             patch.dict(os.environ, {"APPDIR": "/tmp/root-mount"}), \
             patch.object(creator, "write_usb") as writer:
            self.assertEqual(0, main.main())
            self.assertEqual("/tmp/root-mount/boot-image/haos-installer-x86_64.img",
                             writer.call_args.args[0]["image"])

    def test_writer_rejects_appimage_on_target_usb(self):
        disk = {"path": "/dev/sdc", "id": "8:32", "size": 8000,
                "model": "USB", "mounts": ["/media/usb"]}
        with tempfile.TemporaryDirectory() as temp, \
             patch.object(creator.os, "geteuid", return_value=0), \
             patch.object(creator, "usb_disks", return_value=[disk]), \
             patch.object(creator, "verify_boot_image", return_value=Path(temp) / "boot.img"), \
             patch.dict(os.environ, {"APPIMAGE": "/media/usb/creator.AppImage"}), \
             patch.object(creator, "run") as run:
            (Path(temp) / "boot.img").write_bytes(b"boot")
            with self.assertRaisesRegex(ValueError, "Source files"):
                creator.write_usb({"disk": disk["path"], "id": disk["id"],
                                   "size": disk["size"], "image": str(Path(temp) / "boot.img")})
            run.assert_not_called()


if __name__ == "__main__":
    unittest.main()
