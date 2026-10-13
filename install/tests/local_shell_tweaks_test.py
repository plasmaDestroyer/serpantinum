#!/usr/bin/env python3
"""Local power policy and updater checks. All updater writes/services use fixtures."""
from pathlib import Path
import json
import os
import re
import shutil
import signal
import socket
import subprocess
import tempfile
import threading
import unittest

REPO = Path(__file__).resolve().parents[2]
GIT = shutil.which("git")
SCRIPT = Path(os.environ.get("SERP_UPDATE_TEST_SCRIPT", str(Path.home() / ".local/bin/serp-update")))


class ShellPolicyTests(unittest.TestCase):
    def test_suspend_only_on_known_discharging_battery(self):
        idle = (REPO / "src/quickshell/idle/Idle.qml").read_text()
        body = re.search(r'id: suspendTimer.*?onTriggered: \{(.*?)\n        \}', idle, re.S).group(1)
        data = (REPO / "src/quickshell/singletons/info/SysData.qml").read_text()
        getter = re.search(r'readonly property bool onBattery: (.+)', data).group(1)
        js = r'''
const {body, getter} = JSON.parse(require('node:fs').readFileSync(0, 'utf8'));
const battery = new Function('UPower', 'UPowerDeviceState', 'return ' + getter);
const suspend = new Function('SysData', 'Quickshell', body);
for (const ready of [false, true]) for (let state = 0; state <= 6; state++) {
    const calls = [];
    const onBattery = battery({displayDevice: {ready, state}}, {Discharging: 2});
    suspend({onBattery}, {execDetached: args => calls.push(args)});
    const expected = ready && state === 2 ? [['systemctl', 'suspend']] : [];
    if (JSON.stringify(calls) !== JSON.stringify(expected)) throw new Error(JSON.stringify({ready, state, calls}));
}
'''
        subprocess.run(["node", "-e", js], input=json.dumps(dict(body=body, getter=getter)), text=True, check=True)

    def test_about_calls_interactive_updater_with_quoted_home(self):
        source = (REPO / "src/quickshell/guide/AboutTab.qml").read_text()
        declaration = re.search(r"let upd = .+;", source).group()
        command = subprocess.check_output(["node", "-e", declaration + "process.stdout.write(upd);"], text=True)
        import shlex
        command, = shlex.split(command)
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary) / "home with spaces"
            helper = home / ".local/bin/serp-update"
            helper.parent.mkdir(parents=True)
            helper.write_text('#!/bin/sh\nprintf "%s\\n" "$@"\n')
            helper.chmod(0o755)
            result = subprocess.run(["bash", "-c", command], env=dict(os.environ, HOME=str(home)), capture_output=True, text=True, check=True)
            self.assertEqual(result.stdout.splitlines(), ["--interactive"])


@unittest.skipUnless(SCRIPT.is_file() and GIT, "personal serp-update helper and Git required")
class UpdateReviewTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="serp-review-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.home = self.root / "home with spaces"
        self.home.mkdir()
        self.upstream = self.root / "upstream"
        self.remote = self.root / "origin.git"
        self.repo = self.home / "serpantinum"
        self.runner = self.root / "runner/serp-update"
        self.runner.parent.mkdir()
        shutil.copy2(SCRIPT, self.runner)
        self.git("init", "--bare", "-q", "-b", "master", str(self.remote))
        self.git("init", "-q", "-b", "master", str(self.upstream))
        self.identify(self.upstream)
        self.write(self.upstream / "install/modules/deps.sh", 'REQUIRED_PKGS=(\n "git"\n)\n')
        self.write(self.upstream / "compositors/hyprland/hyprland.lua", "return {}\n")
        self.write(self.upstream / "config/serpantinum/settings.json", "{}\n")
        self.write(self.upstream / "version.txt", "1.0.0\n")
        self.write(self.upstream / "src/value", "old\n")
        self.write(self.upstream / "src/assets/matugen/config.toml", "[config]\n[templates]\n")
        daemon = self.write(self.upstream / "bin/serpantinumd", '''#!/bin/sh
printf '%s\\n' "$1" >> "$TEST_SERVICE_LOG"
if [ "$1" = start ]; then
 sleep 0.2
 mkdir -p "$XDG_RUNTIME_DIR/quickshell/by-id/fixture"
 printf 'Configuration Loaded\\n' > "$XDG_RUNTIME_DIR/quickshell/by-id/fixture/log.log"
fi
''')
        daemon.chmod(0o755)
        self.old = self.commit(self.upstream)
        self.git("-C", str(self.upstream), "remote", "add", "origin", str(self.remote))
        self.git("-C", str(self.upstream), "push", "-q", "origin", "master")
        self.git("clone", "-q", str(self.remote), str(self.repo))
        self.identify(self.repo)
        self.git("-C", str(self.repo), "checkout", "-q", "-b", "local-v3")
        self.write(self.repo / "src/local", "local\n")
        self.installed = self.commit(self.repo)
        self.dest = self.home / ".local/share/serpantinum"
        for part in ("src", "bin"):
            shutil.copytree(self.repo / part, self.dest / part)
        shutil.copy2(self.repo / "version.txt", self.dest / "version.txt")
        self.state = self.home / ".local/state/serpantinum/version"
        self.write(self.state, f'SERPANTINUM_VERSION="1.0.0"\nSERPANTINUM_COMMIT="{self.installed}"\nSERPANTINUM_UPSTREAM_COMMIT="{self.old}"\n')
        self.write(self.home / ".config/serpantinum/settings.json", "{}\n")
        self.write(self.home / ".config/hypr/hyprland.lua", "return {}\n")
        self.write(self.upstream / "version.txt", "1.1.0\n")
        self.write(self.upstream / "src/value", "reviewed\n")
        self.new = self.commit(self.upstream)
        self.git("-C", str(self.upstream), "push", "-q", "origin", "master")
        runtime = self.root / "run"
        socket_path = runtime / "hypr/fixture/.socket.sock"
        socket_path.parent.mkdir(parents=True)
        self.socket = socket.socket(socket.AF_UNIX)
        self.socket.bind(str(socket_path))
        self.addCleanup(self.socket.close)
        self.stubs = self.root / "stubs"
        self.stubs.mkdir()
        wrapper = self.write(self.stubs / "git", '#!/bin/sh\nprintf "%s\\n" "$*" >> "$TEST_GIT_LOG"\nexec ' + GIT + ' "$@"\n')
        wrapper.chmod(0o755)
        self.env = dict(os.environ, HOME=str(self.home), PATH=str(self.stubs) + os.pathsep + os.environ["PATH"],
                        XDG_RUNTIME_DIR=str(runtime), HYPRLAND_INSTANCE_SIGNATURE="fixture",
                        TEST_GIT_LOG=str(self.root / "git.log"), TEST_SERVICE_LOG=str(self.root / "services.log"))
        self.env.pop("SERP_UPDATE_REVIEW", None)

    @staticmethod
    def write(path, text):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        return path

    @staticmethod
    def git(*args):
        return subprocess.check_output([GIT, *args], stderr=subprocess.PIPE, text=True).strip()

    def identify(self, repo):
        self.git("-C", str(repo), "config", "user.name", "Fixture")
        self.git("-C", str(repo), "config", "user.email", "fixture@example.invalid")

    def commit(self, repo):
        self.git("-C", str(repo), "add", ".")
        self.git("-C", str(repo), "commit", "-qm", "fixture")
        return self.git("-C", str(repo), "rev-parse", "HEAD")

    def run_review(self, answer="y\n", after_review=None, args=None):
        process = subprocess.Popen([str(self.runner), *(args or ["--interactive"])], env=self.env,
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                   text=True, bufsize=1, start_new_session=True)
        watchdog = threading.Timer(20, lambda: os.killpg(process.pid, signal.SIGKILL) if process.poll() is None else None)
        watchdog.start()
        output = []
        try:
            for line in process.stdout:
                output.append(line)
                if line.startswith("Dry run complete:"):
                    if after_review:
                        after_review()
                    if answer is not None:
                        process.stdin.write(answer)
                        process.stdin.flush()
                    process.stdin.close()
            code = process.wait(timeout=3)
        finally:
            watchdog.cancel()
            process.stdout.close()
            if not process.stdin.closed:
                process.stdin.close()
        return code, "".join(output)

    def assert_not_deployed(self):
        self.assertFalse((self.root / "services.log").exists())
        self.assertEqual((self.dest / "src/value").read_text(), "old\n")

    def test_yes_pins_target_when_remote_advances(self):
        later = []
        def advance():
            self.write(self.upstream / "src/value", "unreviewed\n")
            later.append(self.commit(self.upstream))
            self.git("-C", str(self.upstream), "push", "-q", "origin", "master")
        code, output = self.run_review(after_review=advance)
        self.assertEqual(code, 0, output)
        self.assertEqual((self.dest / "src/value").read_text(), "reviewed\n")
        self.assertEqual(self.git("-C", str(self.repo), "rev-parse", "origin/master"), self.new)
        self.assertIn(f'SERPANTINUM_UPSTREAM_COMMIT="{self.new}"', self.state.read_text())
        self.assertEqual(sum("fetch -q origin" in line for line in (self.root / "git.log").read_text().splitlines()), 1)
        self.assertEqual((self.root / "services.log").read_text().splitlines(), ["stop", "start"])

    def test_decline_or_eof_never_deploys(self):
        for answer in ("n\n", "\n", None):
            with self.subTest(answer=answer):
                code, output = self.run_review(answer=answer)
                self.assertEqual(code, 0, output)
                self.assert_not_deployed()
                self.assertEqual(self.git("-C", str(self.repo), "rev-parse", "HEAD"), self.installed)

    def test_changed_local_head_requires_new_review(self):
        def change():
            self.write(self.repo / "src/another-local", "new local work\n")
            self.commit(self.repo)
        code, output = self.run_review(after_review=change)
        self.assertNotEqual(code, 0, output)
        self.assertIn("changed after review", output)
        self.assert_not_deployed()

    def test_changed_installed_revision_requires_new_review(self):
        def change():
            self.state.write_text(self.state.read_text().replace(self.installed, self.old))
        code, output = self.run_review(after_review=change)
        self.assertNotEqual(code, 0, output)
        self.assertIn("changed after review", output)
        self.assert_not_deployed()

    def test_noop_never_deploys(self):
        code, output = self.run_review(args=["--interactive", self.old, self.old])
        self.assertEqual(code, 0, output)
        self.assertIn("Already up to date", output)
        self.assert_not_deployed()

    def test_failed_review_never_deploys(self):
        self.write(self.upstream / "install/modules/deps.sh", "changed unsupported format\n")
        self.commit(self.upstream)
        self.git("-C", str(self.upstream), "push", "-q", "origin", "master")
        code, output = self.run_review()
        self.assertNotEqual(code, 0, output)
        self.assert_not_deployed()

    def test_interactive_flag_collisions_stop(self):
        for flags in (["--interactive", "--dry-run"], ["--deps-reviewed", "--interactive"], ["--interactive", "--interactive"]):
            with self.subTest(flags=flags):
                code, output = self.run_review(args=flags)
                self.assertEqual(code, 2, output)
                self.assert_not_deployed()


if __name__ == "__main__":
    unittest.main(verbosity=2)
