#!/usr/bin/env python3
"""Install one AIO widget without touching other widgets or phone preferences."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
PACKAGE = "ru.execbit.aiolauncher"
REMOTE = f"/sdcard/Android/data/{PACKAGE}/files/"


class InstallError(Exception):
    pass


def run(command):
    result = subprocess.run(command, text=True, capture_output=True)
    if result.returncode:
        raise InstallError(result.stderr.strip() or result.stdout.strip() or "Command failed")
    return result.stdout.strip()


def version(value):
    match = re.match(r"(\d+)\.(\d+)(?:\.(\d+))?", value)
    if not match:
        raise InstallError(f"Unrecognized AIO version: {value}")
    return tuple(int(item or 0) for item in match.groups())


def target_name(names, filename):
    matches = [name for name in names if name == filename or name.endswith(":" + filename)]
    if len(matches) > 1:
        raise InstallError("Several installed copies match this widget: " + ", ".join(matches))
    return matches[0] if matches else filename


def lua_check(paths):
    lua = shutil.which(os.environ.get("LUA_BIN", "lua"))
    if not lua:
        raise InstallError("Lua is required for validation; set LUA_BIN to your interpreter.")
    for path in paths:
        expression = "assert(loadfile(" + json.dumps(str(path), ensure_ascii=False) + "))"
        run([lua, "-e", expression])


def install(args):
    filename = args.widget if args.widget.endswith(".lua") else args.widget + ".lua"
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]*\.lua", filename):
        raise InstallError("Use a widget name such as opencode-go, without a directory path.")
    widget = ROOT / "widgets" / filename
    if not widget.is_file():
        raise InstallError(f"Widget not found: {filename}")
    source = widget.read_text()
    if not re.search(r'^-- type = "widget"$', source, re.MULTILINE):
        raise InstallError("The selected file is missing widget-type metadata.")
    minimum = re.search(r'^-- aio_version = "([^"]+)"$', source, re.MULTILINE)
    if not minimum:
        raise InstallError("The widget is missing minimum AIO-version metadata.")
    shared = sorted((ROOT / "shared").glob("*.lua"))
    if any(not re.fullmatch(r"aio_widgets_[A-Za-z0-9_]+\.lua", path.name) for path in shared):
        raise InstallError("Shared Lua helpers must use an aio_widgets_ filename prefix.")
    paths = [*shared, widget]
    lua_check(paths)

    adb = os.environ.get("ADB_BIN", "adb")
    if args.dry_run:
        prefix = [adb, *(["-s", args.serial] if args.serial else [])]
        for path in paths:
            print(shlex.join([*prefix, "push", str(path), REMOTE + path.name]))
        return
    if not shutil.which(adb):
        raise InstallError("adb is required; install Android platform-tools or set ADB_BIN.")
    devices = []
    for line in run([adb, "devices", "-l"]).splitlines():
        fields = line.split()
        if len(fields) >= 2 and fields[1] == "device":
            devices.append(fields[0])
    if args.serial:
        if args.serial not in devices:
            raise InstallError("The selected phone is not connected and authorized for USB debugging.")
        serial = args.serial
    else:
        if len(devices) != 1:
            raise InstallError("Connect one authorized phone, or select one using --serial SERIAL.")
        serial = devices[0]
    prefix = [adb, "-s", serial]

    def shell(*parts):
        return run([*prefix, "shell", shlex.join(parts)])

    package = shell("dumpsys", "package", PACKAGE)
    installed = re.search(r"versionName=([^\s]+)", package)
    if not installed:
        raise InstallError("AIO Launcher is not installed on this phone.")
    if version(installed[1]) < version(minimum[1]):
        raise InstallError(f"AIO {installed[1]} is older than the required {minimum[1]}.")
    names = shell("ls", "-1", REMOTE).splitlines()
    remote_widget = target_name(names, filename)
    for path in paths:
        name = remote_widget if path == widget else path.name
        destination = REMOTE + name
        run([*prefix, "push", str(path), destination])
        expected = hashlib.sha256(path.read_bytes()).hexdigest()
        actual = shell("sha256sum", destination).split()[0]
        if actual != expected:
            raise InstallError(f"Copied file failed checksum verification: {name}")
        print(f"Installed and verified: {name}")
    if args.reload:
        shell("am", "force-stop", PACKAGE)
        shell("am", "start", "-a", "android.intent.action.MAIN", "-c", "android.intent.category.HOME", "-p", PACKAGE)
        print("Restarted AIO Launcher.")
    print("On first installation: Widgets → Scripts → select the widget → Add widget.")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("widget", help="Widget filename or name, such as opencode-go")
    parser.add_argument("--serial", help="ADB serial when multiple phones are connected")
    parser.add_argument("--reload", action="store_true", help="Restart AIO after installation")
    parser.add_argument("--dry-run", action="store_true", help="Validate locally and preview copy commands without a phone")
    args = parser.parse_args(argv)
    try:
        install(args)
    except (InstallError, OSError) as error:
        print(f"Install failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
