import contextlib
import hashlib
import importlib.util
import io
from pathlib import Path
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("installer", ROOT / "tools/install.py")
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)


class InstallerTests(unittest.TestCase):
    def execute(self, *, names="opencode-go.lua", devices=("PHONE",), aio_version="7.6.0", dry=False):
        commands = []
        digest = hashlib.sha256((ROOT / "widgets/opencode-go.lua").read_bytes()).hexdigest()

        def fake_run(command):
            commands.append(command)
            if command[1:3] == ["devices", "-l"]:
                return "List of devices attached\n" + "\n".join(name + " device" for name in devices)
            if "push" in command:
                return "pushed"
            text = command[-1]
            if text.startswith("dumpsys package"):
                return "versionName=" + aio_version
            if text.startswith("ls -1"):
                return names
            if text.startswith("sha256sum"):
                return digest + "  file"
            raise AssertionError(command)

        output = io.StringIO()
        with patch.object(installer, "run", side_effect=fake_run), patch.object(installer, "lua_check"), patch.object(installer.shutil, "which", return_value="adb"), contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
            result = installer.main(["opencode-go", *(["--dry-run"] if dry else [])])
        return result, commands, output.getvalue()

    def test_updates_existing_alias_without_reinstalling_under_a_new_name(self):
        result, commands, _ = self.execute(names="other.lua\nmain:opencode-go.lua")
        self.assertEqual(result, 0)
        pushes = [cmd for cmd in commands if "push" in cmd]
        self.assertEqual(len(pushes), 1)
        self.assertEqual(pushes[0][-1], installer.REMOTE + "main:opencode-go.lua")
        self.assertFalse(any("force-stop" in cmd[-1] for cmd in commands))

    def test_ambiguous_copies_are_rejected_before_writing(self):
        result, commands, _ = self.execute(names="opencode-go.lua\nmain:opencode-go.lua")
        self.assertEqual(result, 1)
        self.assertFalse(any("push" in cmd for cmd in commands))

    def test_multiple_devices_are_rejected_before_writing(self):
        result, commands, _ = self.execute(devices=("ONE", "TWO"))
        self.assertEqual(result, 1)
        self.assertFalse(any("push" in cmd for cmd in commands))

    def test_unsupported_launcher_is_rejected_before_writing(self):
        result, commands, _ = self.execute(aio_version="7.5.0")
        self.assertEqual(result, 1)
        self.assertFalse(any("push" in cmd for cmd in commands))

    def test_dry_run_never_contacts_the_phone(self):
        result, commands, output = self.execute(dry=True)
        self.assertEqual(result, 0)
        self.assertEqual(commands, [])
        self.assertIn("adb push", output)


if __name__ == "__main__":
    unittest.main()
