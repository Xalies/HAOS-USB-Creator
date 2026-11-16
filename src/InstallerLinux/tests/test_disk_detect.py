"""Test target selection without accessing physical disks."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


class DiskDetectionTests(unittest.TestCase):
    def test_accepts_virtio_targets_and_keeps_installer_media_excluded(self):
        virtio = {"type": "disk", "tran": None, "subsystems": "block:virtio:pci", "rm": False}
        devices = [
            {**virtio, "path": "/dev/vda"},
            {**virtio, "path": "/dev/sda", "subsystems": "block:scsi:virtio:pci"},
            {**virtio, "path": "/dev/vdb"},
            {**virtio, "path": "/dev/vdc", "children": [{"label": "HAOS-CACHE"}]},
            {**virtio, "path": "/dev/vdd", "rm": True},
            {**virtio, "path": "/dev/sdb", "tran": "usb", "subsystems": "block:scsi:usb:pci"},
            {**virtio, "path": "/dev/sdc", "tran": "usb", "subsystems": "block:scsi:usb:virtio:pci"},
            {**virtio, "path": "/dev/sr0", "type": "rom"},
            {"path": "/dev/nvme0n1", "type": "disk", "tran": "nvme"},
        ]
        script = Path(__file__).resolve().parents[1] / "scripts/disk-detect.sh"
        with tempfile.TemporaryDirectory() as directory:
            fixture = Path(directory) / "disks.json"
            fixture.write_text(json.dumps({"blockdevices": devices}), encoding="utf-8")
            result = subprocess.run(
                ["sh", "-c", 'log_info() { :; }; . "$1"; list_install_targets', "sh", str(script)],
                env={**os.environ, "HAOS_FAKE_LSBLK": str(fixture), "HAOS_BOOT_USB": "/dev/vdb"},
                capture_output=True, text=True, check=True,
            )

        self.assertEqual(
            [(disk["path"], disk["tran"]) for disk in json.loads(result.stdout)],
            [("/dev/vda", "virtio"), ("/dev/sda", "virtio"), ("/dev/nvme0n1", "nvme")],
        )


if __name__ == "__main__":
    unittest.main()
