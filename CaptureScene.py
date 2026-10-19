"""Run the pinned scene backend with safe decoding of native process output."""
import argparse
import importlib.util
import json
import ntpath
import os
import re
import subprocess
import sys
import threading
import time


def same_wallpaper(saved_file, folder):
    saved = ntpath.normcase(ntpath.normpath(ntpath.dirname(saved_file)))
    wanted = ntpath.normcase(ntpath.normpath(folder))
    if saved == wanted:
        return 0
    pattern = r"[\\/]workshop[\\/]content[\\/]431960[\\/](\d+)(?:[\\/]|$)"
    left, right = re.search(pattern, saved, re.I), re.search(pattern, wanted, re.I)
    if left and right and left[1] == right[1]:
        return 1
    return None


def property_values(properties):
    if not isinstance(properties, dict):
        raise ValueError("Wallpaper properties must be a JSON object.")
    return {key: value["value"] if isinstance(value, dict) and "value" in value else value
            for key, value in properties.items()}


def saved_properties(config_paths, folder, location=None, profile=None):
    candidates = []
    for config_index, path in enumerate(dict.fromkeys(config_paths)):
        if not os.path.isfile(path):
            continue
        with open(path, encoding="utf-8-sig") as stream:
            config = json.load(stream)
        for name, user in config.items():
            if not isinstance(user, dict) or (profile and name != profile):
                continue
            entries = user.get("wproperties", {})
            if not isinstance(entries, dict):
                continue
            for wallpaper_file, monitors in entries.items():
                match = same_wallpaper(wallpaper_file, folder)
                if match is None or not isinstance(monitors, dict):
                    continue
                for monitor, values in monitors.items():
                    if (location and monitor != location) or monitor.startswith("wp2video-"):
                        continue
                    if not isinstance(values, dict) or not values:
                        continue
                    rank = {"MonitorPositionL0T0": 0, "Monitor0": 1}.get(monitor, 2)
                    candidates.append(((match, rank, config_index, name, monitor), values, monitor))
    if not candidates:
        return {}, None
    candidates.sort(key=lambda item: item[0])
    _, properties, selected_location = candidates[0]
    return property_values(properties), selected_location


def apply_properties(engine, window, properties):
    payload = json.dumps(properties, ensure_ascii=True, separators=(",", ":"))
    if ")~END" in payload:
        raise ValueError("Wallpaper property text contains Wallpaper Engine's command delimiter.")
    # The RAW delimiter is parsed by Wallpaper Engine itself. Use a command string
    # with shell=False so Python does not add backslashes before the JSON quotes.
    command = subprocess.list2cmdline([engine, "-control", "applyProperties", "-location", window])
    command += " -properties RAW~(" + payload + ")~END"
    subprocess.run(command, check=True, creationflags=0x08000000 if os.name == "nt" else 0)


def configure_wallpaper_settings(backend, folder, overrides=None, location=None, profile=None):
    engine = backend.find_wallpaper_engine(folder)
    configs = [os.path.join(os.path.dirname(engine), "config.json")]
    configs += [os.path.join(library, "steamapps", "common", "wallpaper_engine", "config.json")
                for library in backend.steam_libraries()]
    properties, selected = saved_properties(configs, folder, location, profile)
    if selected:
        print(f"Using {len(properties)} saved wallpaper settings from {selected}.")
    else:
        print("No saved settings found for this wallpaper; using its defaults.")
    if overrides:
        with open(overrides, encoding="utf-8-sig") as stream:
            explicit = property_values(json.load(stream))
        properties.update(explicit)
        print(f"Applying {len(explicit)} explicit wallpaper property overrides.")
    if not properties:
        return
    original_wait = backend.wait_until_drawn
    applied = False

    def wait_with_settings(*args, **kwargs):
        nonlocal applied
        ready = original_wait(*args, **kwargs)
        if ready and not applied:
            apply_properties(engine, f"wp2video-{os.getpid()}", properties)
            applied = True
            time.sleep(0.5)
        return ready

    backend.wait_until_drawn = wait_with_settings


class Utf8Popen(subprocess.Popen):
    """Native diagnostic text must not depend on the Windows ANSI code page."""

    def __init__(self, *args, **kwargs):
        if kwargs.get("text") or kwargs.get("universal_newlines") or kwargs.get("encoding"):
            kwargs["encoding"] = kwargs.get("encoding") or "utf-8"
            kwargs["errors"] = kwargs.get("errors") or "replace"
        super().__init__(*args, **kwargs)


def run_progress_process(command, seconds, progress):
    """Drain both pipes, including non-UTF-8 diagnostics, before checking exit status."""
    process = subprocess.Popen(
        command,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        encoding="utf-8",
        errors="replace",
        creationflags=0x08000000 if os.name == "nt" else 0,
    )
    errors = []
    reader = threading.Thread(target=lambda: errors.extend(process.stderr), daemon=True)
    reader.start()
    try:
        for line in process.stdout:
            key, _, value = line.strip().partition("=")
            if key == "out_time_us" and value.isdigit():
                progress(min(1.0, int(value) / 1_000_000 / seconds))
        process.wait()
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()
        reader.join()
        process.stdout.close()
        process.stderr.close()
    if process.returncode:
        raise RuntimeError("ffmpeg failed:\n" + "".join(errors)[-800:])


def run_ffmpeg(command, seconds, progress):
    run_progress_process(
        command[:1] + ["-progress", "pipe:1", "-nostats"] + command[1:], seconds, progress
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("backend")
    parser.add_argument("wallpaper")
    parser.add_argument("resolution", choices=("1080p", "1440p", "4K"))
    parser.add_argument("fps", choices=("30", "60"))
    parser.add_argument("seconds", type=float)
    parser.add_argument("format", choices=("mp4",))
    parser.add_argument("output")
    parser.add_argument("--seamless", action="store_true")
    parser.add_argument("--properties", help="Wallpaper Engine Share JSON file; overrides saved values")
    parser.add_argument("--location", help="Saved monitor location to use (default: primary monitor)")
    parser.add_argument("--profile", help="Wallpaper Engine config profile to use")
    args = parser.parse_args()
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    # Covers the backend's other text-mode probes too (ffmpeg headers, tasklist, etc.).
    subprocess.Popen = Utf8Popen
    spec = importlib.util.spec_from_file_location("wp2video_backend", args.backend)
    backend = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(backend)
    backend.run_ffmpeg = run_ffmpeg
    configure_wallpaper_settings(backend, args.wallpaper, args.properties, args.location, args.profile)
    output = backend.export(
        args.wallpaper, args.resolution, args.fps, args.seconds, args.format, args.output,
        status=print, progress=lambda value: None, seamless=args.seamless,
    )
    print("saved:", output)


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"Scene capture failed: {error}", file=sys.stderr)
        sys.exit(1)
