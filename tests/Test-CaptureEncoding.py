"""Real subprocess regressions for the encoding that broke item 3360376408."""
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("capture", Path(__file__).parents[1] / "CaptureScene.py")
capture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(capture)


class CaptureEncodingTests(unittest.TestCase):
    def test_utf8_diagnostics_and_invalid_bytes_do_not_break_pipe_draining(self):
        # More than a pipe buffer of stderr: a dead reader would block the child.
        child = (
            "import sys; "
            "sys.stderr.buffer.write(('scene \\u5251 \\u201d\\n'.encode('utf-8') + b'\\x9d\\n') * 10000); "
            "sys.stderr.flush(); print('out_time_us=1000000')"
        )
        progress = []
        capture.run_progress_process([sys.executable, "-c", child], 2, progress.append)
        self.assertEqual(progress, [0.5])

    def test_ffmpeg_failure_retains_diagnostics_without_reader_traceback(self):
        child = "import sys; sys.stderr.buffer.write(b'capture error \\xe2\\x80\\x9d \\x9d'); sys.exit(7)"
        with self.assertRaisesRegex(RuntimeError, "capture error") as error:
            capture.run_progress_process([sys.executable, "-c", child], 1, lambda _: None)
        self.assertIn("\u201d", str(error.exception))
        self.assertIn("\ufffd", str(error.exception))

    def test_other_backend_text_probes_get_safe_defaults(self):
        with patch.object(subprocess, "Popen", capture.Utf8Popen):
            result = subprocess.run(
                [sys.executable, "-c", "import sys; sys.stdout.buffer.write(b'\\xe2\\x80\\x9d \\x9d')"],
                capture_output=True, text=True, check=True,
            )
        self.assertEqual(result.stdout, "\u201d \ufffd")

    def test_binary_output_stays_binary(self):
        with patch.object(subprocess, "Popen", capture.Utf8Popen):
            result = subprocess.run(
                [sys.executable, "-c", "import sys; sys.stdout.buffer.write(b'\\x9d')"],
                capture_output=True, check=True,
            )
        self.assertEqual(result.stdout, b"\x9d")


class WallpaperSettingsTests(unittest.TestCase):
    def test_saved_checkboxes_zero_sliders_and_colors_survive_cross_library_matching(self):
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / "config.json"
            config.write_text(json.dumps({"profile": {"wproperties": {
                "D:/SteamLibrary/steamapps/workshop/content/431960/3360376408/scene.pkg": {
                    "Monitor0": {"clock": False, "volume": 0, "color": "1 0 0"},
                    "wp2video-123": {"clock": True},
                }
            }}}), encoding="utf-8")
            values, monitor = capture.saved_properties([str(config)],
                "C:/Steam/steamapps/workshop/content/431960/3360376408")
            self.assertEqual(values, {"clock": False, "volume": 0, "color": "1 0 0"})
            self.assertEqual(monitor, "Monitor0")
            self.assertEqual(capture.saved_properties([str(config)],
                "C:/Steam/steamapps/workshop/content/431960/111"), ({}, None))

    def test_explicit_monitor_and_profile_selection(self):
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / "config.json"
            config.write_text(json.dumps({"selected": {"wproperties": {
                "C:/Steam/steamapps/workshop/content/431960/111/project.json": {
                    "Monitor0": {"clock": False}, "Monitor1": {"clock": True}
                }
            }}}), encoding="utf-8")
            values, monitor = capture.saved_properties([str(config)],
                "C:/Steam/steamapps/workshop/content/431960/111", "Monitor1", "selected")
            self.assertEqual((values, monitor), ({"clock": True}, "Monitor1"))

    def test_properties_are_applied_only_to_capture_window_after_it_draws(self):
        with tempfile.TemporaryDirectory() as directory:
            overrides = Path(directory) / "properties.json"
            overrides.write_text('{"clock":false,"slider":{"value":0}}', encoding="utf-8")
            backend = SimpleNamespace(
                find_wallpaper_engine=lambda _: str(Path(directory) / "wallpaper64.exe"),
                steam_libraries=lambda: [], wait_until_drawn=lambda *_: True,
            )
            with patch.object(capture, "apply_properties") as apply, patch.object(capture.time, "sleep"):
                capture.configure_wallpaper_settings(backend, directory, str(overrides))
                self.assertTrue(backend.wait_until_drawn("ffmpeg", 123))
                self.assertTrue(backend.wait_until_drawn("ffmpeg", 123))
                apply.assert_called_once_with(str(Path(directory) / "wallpaper64.exe"),
                    f"wp2video-{capture.os.getpid()}", {"clock": False, "slider": 0})

    def test_property_command_uses_raw_json_and_named_window_without_shell(self):
        with patch.object(subprocess, "run") as run:
            capture.apply_properties("C:/Steam/wallpaper64.exe", "wp2video-123", {"clock": False})
        command = run.call_args.args[0]
        self.assertIn("-location wp2video-123", command)
        self.assertIn('RAW~({"clock":false})~END', command)
        self.assertNotIn("-monitor", command)
        self.assertNotIn("shell", run.call_args.kwargs)


if __name__ == "__main__":
    unittest.main()
