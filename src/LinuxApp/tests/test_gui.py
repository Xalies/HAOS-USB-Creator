import sys
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from gui import CreatorWindow, Gtk


@unittest.skipUnless(Gtk.init_check()[0], "GTK display unavailable")
class ProgressTests(unittest.TestCase):
    def test_progress_and_final_result(self):
        with patch("gui.usb_disks", return_value=[]):
            window = CreatorWindow()
        window.show_all()
        self.assertEqual("welcome", window.pages.get_visible_child_name())
        self.assertEqual(640, window.get_default_size()[1])
        self.assertFalse(window.coffee_panel.get_visible())
        window._show_page("writing")
        window._message("Downloading Home Assistant OS: 25% (3.2 MiB/s)")
        self.assertEqual(0.25, window.write_bars[1].get_fraction())
        self.assertIn("3.2 MiB/s", window.write_statuses[1].get_text())
        window._skip_download("network unavailable")
        self.assertIn("network unavailable", window.write_statuses[1].get_text())
        window._message("Writing boot image: 99% (12.0 MiB/s)")
        self.assertEqual(0.99, window.write_bars[2].get_fraction())
        window._message("Writing boot image: flushing data to USB")
        self.assertEqual(2, window.pulsing_step)
        window._message("Writing boot image: 100% (11.5 MiB/s)")
        window._message("Finalising USB: This will take a moment…")
        self.assertEqual("Done", window.write_badges[2].get_text())
        self.assertEqual("Working…", window.write_badges[3].get_text())
        window._message("Adding Home Assistant OS: 25% (8.0 MiB/s)")
        self.assertEqual(0.25, window.write_bars[3].get_fraction())
        window._message("Synchronising USB: This may take a moment…")
        self.assertEqual(3, window.pulsing_step)
        window._finish(True, "/dev/sdb is ready.")
        self.assertEqual("Complete", window.write_bars[3].get_text())
        self.assertEqual("finish", window.pages.get_visible_child_name())
        self.assertEqual("https://buymeacoffee.com/xalies", window.coffee_link.get_uri())
        self.assertTrue(window.coffee_panel.get_visible())
        image = window.coffee_link.get_image().get_pixbuf()
        self.assertEqual((128, 36), (image.get_width(), image.get_height()))
        window._finish(False, "Write failed")
        self.assertEqual("Failed", window.write_badges[3].get_text())
        self.assertEqual("Write failed", window.write_statuses[3].get_text())
        self.assertEqual("writing", window.pages.get_visible_child_name())
        self.assertFalse(window.coffee_panel.get_visible())
