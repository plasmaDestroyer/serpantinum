#!/usr/bin/env python3
"""Bundle and deployment checks; all writes and processes use temporary fixtures."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[2]


def write(path, text, executable=False):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)
    if executable:
        path.chmod(0o755)


class CoreBundleTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="serpantinum-bundle-test-"))
        self.addCleanup(shutil.rmtree, self.tmp)
        self.project = self.tmp / "project"
        self.bundle = self.tmp / "bundle"
        self.home = self.tmp / "home"
        self.stubs = self.tmp / "stubs"
        self.runtime = self.home / ".local/share/serpantinum"
        self.core = '''#!/usr/bin/env bash
if [ -e /proc/$$/fd/9 ]; then echo 'inherited shell lock' >&2; exit 2; fi
case "$1" in
    --version) echo 'serpantinum-core 0.3.0';;
    brightness) echo bundled;;
    *) echo "$1" >> "$TEST_CORE_LOG"
       [ "$1" = "${TEST_CORE_FAIL:-}" ] && exit 1
       exit 0;;
esac
'''
        # audio answers `version`, the others `--version`, like the real daemons
        self.daemons = {
            "serpantinum-core": self.core,
            "serpantinum-audio": "#!/bin/sh\n[ \"$1\" = version ] && echo 'serpantinum-audio 0.3.0'\nexit 0\n",
            "serpantinum-gamma": "#!/bin/sh\n[ \"$1\" = --version ] && echo 'serpantinum-gamma 0.3.0'\nexit 0\n",
        }
        self.archives = self.tmp / "archives"
        self.pins = {}
        for name, script in self.daemons.items():
            unpack = self.tmp / "unpack" / name
            write(unpack / f"usr/bin/{name}", script, True)
            write(unpack / f"usr/share/licenses/{name}/LICENSE", "test license")
            archive = self.archives / f"{name}-0.3.0-x86_64-linux.tar.gz"
            archive.parent.mkdir(parents=True, exist_ok=True)
            with tarfile.open(archive, "w:gz") as out:
                out.add(unpack / "usr", arcname="usr")
            self.pins[name] = {"version": "0.3.0", "sha256": hashlib.sha256(archive.read_bytes()).hexdigest()}
        write(self.project / "src/assets/daemons.json", json.dumps(self.pins))
        write(self.project / "version.txt", "2.4.2\n")
        write(self.project / "bin/serpantinum", "#!/bin/sh\necho shell\n", True)
        write(self.stubs / "curl", '''#!/bin/bash
url=""
while [ "$#" -gt 0 ]; do
    case "$1" in https://*) url="$1";; esac
    if [ "$1" = -o ]; then cp "$TEST_ARCHIVES/${url##*/}" "$2"; exit; fi
    shift
done
exit 1
''', True)
        # deploy_package links /usr/local/bin with sudo; never touch the host from a test
        write(self.stubs / "sudo", "#!/bin/sh\nexit 0\n", True)
        self.env = dict(os.environ, HOME=str(self.home),
                        PATH=f"{self.stubs}:{os.environ['PATH']}",
                        TEST_ARCHIVES=str(self.archives), TEST_PROJECT=str(self.project),
                        TEST_BUNDLE=str(self.bundle), TEST_CORE_LOG=str(self.tmp / "core.log"))
        self.env.pop("SERPANTINUM_DIR", None)
        self.env.pop("MAIN_QML", None)

    def shell(self, code, **kwargs):
        result = subprocess.run(["bash", "-c", code], env=self.env, text=True,
                                capture_output=True, timeout=15, **kwargs)
        return result

    def prepare(self):
        return self.shell(f'source "{REPO}/install/modules/bundle.sh"; bundle_daemons "$TEST_PROJECT" "$TEST_BUNDLE"')

    def deploy(self, old="unknown", new="unknown"):
        return self.shell(f'''set -e
source "{REPO}/install/modules/deploy.sh"
remove_settings_desktop_entry() {{ :; }}
setup_pam_service() {{ :; }}
BUNDLE_DIR="$TEST_BUNDLE"
deploy_package "$TEST_PROJECT" {old} {new} false current
''')

    def test_pins_match_arch_packages(self):
        pins = json.loads((REPO / "src/assets/daemons.json").read_text())
        for package in ("serpantinum", "serpantinum-git"):
            for name, pin in pins.items():
                with self.subTest(package=package, daemon=name):
                    var = "_" + name.removeprefix("serpantinum-") + "ver"
                    result = self.shell(f'''source "{REPO}/packaging/aur/{package}/PKGBUILD"
echo "${var}"
for i in "${{!source[@]}}"; do case "${{source[$i]}}" in {name}-*) echo "${{sha256sums[$i]}}";; esac; done
''')
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(result.stdout.splitlines(), [pin["version"], pin["sha256"]])

    def test_download_and_offline_bundle(self):
        result = self.prepare()
        self.assertEqual(result.returncode, 0, result.stderr)
        shutil.copytree(self.bundle / "bin", self.project / "bin", dirs_exist_ok=True)
        shutil.copytree(self.bundle / "licenses", self.project / "licenses")
        write(self.stubs / "curl", "#!/bin/sh\nexit 99\n", True)
        self.assertEqual(self.prepare().returncode, 0)
        self.assertEqual((self.bundle / "licenses/serpantinum-core/LICENSE").read_text(), "test license")

    def test_arch_packages_own_the_core_binary(self):
        for package in ("serpantinum", "serpantinum-git"):
            with self.subTest(package=package):
                srcdir = self.tmp / package / "src"
                pkgdir = self.tmp / package / "pkg"
                version = self.shell(f'source "{REPO}/packaging/aur/{package}/PKGBUILD"; echo "$pkgver"').stdout.strip()
                name = f"serpantinum-{version}" if package == "serpantinum" else package
                source = srcdir / name
                shutil.copytree(self.project, source)
                (source / "compositors").mkdir()
                (source / "config/sddm/themes/material-you").mkdir(parents=True)
                write(source / "LICENSE.md", "shell license")
                for daemon, script in self.daemons.items():
                    write(srcdir / f"usr/bin/{daemon}", script, True)
                result = self.shell(f'''set -e
source "{REPO}/packaging/aur/{package}/PKGBUILD"
srcdir="{srcdir}"
pkgdir="{pkgdir}"
cd "$srcdir"
package
''')
                self.assertEqual(result.returncode, 0, result.stderr)
                for daemon, script in self.daemons.items():
                    private = pkgdir / f"usr/share/serpantinum/bin/{daemon}"
                    self.assertEqual(private.read_text(), script)
                    self.assertEqual((pkgdir / f"usr/bin/{daemon}").resolve(), private)

    def test_bad_checksum_or_version_preserves_destination(self):
        write(self.bundle / "bin/serpantinum-core", "previous")
        for field, value in (("sha256", "0" * 64), ("version", "9.9.9")):
            with self.subTest(field=field):
                pins = dict(self.pins, **{"serpantinum-core": dict(self.pins["serpantinum-core"], **{field: value})})
                write(self.project / "src/assets/daemons.json", json.dumps(pins))
                # Also check Bash conditional callers cannot suppress validation failures.
                result = self.shell(f'''source "{REPO}/install/modules/bundle.sh"
if bundle_daemons "$TEST_PROJECT" "$TEST_BUNDLE"; then exit 99; fi
''')
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual((self.bundle / "bin/serpantinum-core").read_text(), "previous")
        write(self.project / "src/assets/daemons.json", json.dumps(self.pins))
        write(self.project / "bin/serpantinum-core", "#!/bin/sh\necho 'serpantinum-core 0.3.0'\nexit 2\n", True)
        write(self.project / "licenses/serpantinum-core/LICENSE", "test license")
        self.assertNotEqual(self.prepare().returncode, 0)
        self.assertEqual((self.bundle / "bin/serpantinum-core").read_text(), "previous")

    def test_failed_download_preserves_runtime(self):
        write(self.runtime / "bin/serpantinum-core", "old core")
        write(self.stubs / "curl", "#!/bin/sh\nexit 22\n", True)
        self.assertNotEqual(self.prepare().returncode, 0)
        self.assertNotEqual(self.deploy().returncode, 0)
        self.assertEqual((self.runtime / "bin/serpantinum-core").read_text(), "old core")

    def test_full_and_incremental_deploy_keep_previous_pair(self):
        git = ["git", "-C", str(self.project)]
        subprocess.run(git + ["init", "-q"], check=True)
        def commit():
            subprocess.run(git + ["add", "."], check=True)
            subprocess.run(git + ["-c", "user.name=Test", "-c", "user.email=test@example.invalid",
                                 "commit", "-qm", "fixture"], check=True)
            return subprocess.check_output(git + ["rev-parse", "HEAD"], text=True).strip()
        write(self.project / "src/removed.txt", "old source")
        old = commit()
        write(self.runtime / "bin/serpantinum-core", "old core")
        self.assertEqual(self.prepare().returncode, 0)
        result = self.deploy()
        self.assertEqual(result.returncode, 0, result.stderr)
        backups = list(self.runtime.parent.glob(".serpantinum-stage.*.previous"))
        self.assertEqual(len(backups), 1)
        self.assertEqual((backups[0] / "bin/serpantinum-core").read_text(), "old core")
        (self.project / "src/removed.txt").unlink()
        write(self.project / "src/new.txt", "new source")
        new = commit()
        write(self.project / "src/uncommitted.txt", "local source")
        result = self.deploy(old, new)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.runtime / "src/removed.txt").exists())
        self.assertEqual((self.runtime / "src/new.txt").read_text(), "new source")
        self.assertEqual((self.runtime / "src/uncommitted.txt").read_text(), "local source")
        self.assertEqual((self.runtime / "bin/serpantinum-core").read_text(), self.core)
        self.assertEqual(len(list(self.runtime.parent.glob(".serpantinum-stage.*.previous"))), 2)
        self.assertEqual((self.home / ".local/bin/serpantinum").resolve(), self.runtime / "bin/serpantinum")

    def test_activation_failure_restores_previous_pair(self):
        self.assertEqual(self.prepare().returncode, 0)
        write(self.runtime / "bin/serpantinum-core", "old core")
        # no atomic exchange here, so the two-rename fallback runs and its second rename fails
        write(self.stubs / "mv", '''#!/bin/bash
[ "$1" = --exchange ] && exit 1
if [[ "$3" == */.serpantinum-stage.* && "$3" != *.previous ]]; then exit 1; fi
exec /usr/bin/mv "$@"
''', True)
        result = self.deploy()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.runtime / "bin/serpantinum-core").read_text(), "old core")
        self.assertEqual(list(self.runtime.parent.glob(".serpantinum-stage.*")), [])

    def test_launchers_use_bundle_and_restart_core(self):
        self.assertEqual(self.prepare().returncode, 0)
        shutil.copy(self.bundle / "bin/serpantinum-core", self.project / "bin/serpantinum-core")
        for name in ("serpantinum", "serpantinumd"):
            source = (REPO / "bin" / name).read_text()
            source = source.replace("/tmp/serpantinumd", str(self.tmp / "serpantinumd"))
            write(self.project / "bin" / name, source, True)
        write(self.project / "src/scripts/caching.sh", 'export MAIN_QML="$SERPANTINUM_DIR/quickshell/Shell.qml"\n')
        write(self.project / "src/scripts/config.sh", '''get_setting() { echo '{"language":"en"}'; }
''')
        write(self.project / "src/scripts/i18n.sh", 't() { echo "$1"; }\n')
        for script in ("scripts/gamma.sh", "scripts/migrate_easyeffects.sh",
                       "quickshell/guide/wellbeing/launch_daemon.sh"):
            write(self.project / "src" / script, "#!/bin/sh\nexit 0\n", True)
        write(self.stubs / "serpantinum-core", "#!/bin/sh\necho wrong-core; exit 99\n", True)
        write(self.stubs / "pkill", "#!/bin/sh\nexit 0\n", True)
        write(self.stubs / "quickshell", '#!/bin/sh\necho shell >> "$TEST_CORE_LOG"\n', True)
        cli = self.shell('"$TEST_PROJECT/bin/serpantinum" brightness get')
        self.assertEqual(cli.returncode, 0, cli.stderr)
        self.assertEqual(cli.stdout.strip(), "bundled")
        daemon = self.shell('"$TEST_PROJECT/bin/serpantinumd" start')
        self.assertEqual(daemon.returncode, 0, daemon.stderr)
        self.assertEqual(Path(self.env["TEST_CORE_LOG"]).read_text().splitlines(), ["quit", "start", "shell", "quit"])
        self.env["TEST_CORE_FAIL"] = "start"
        daemon = self.shell('"$TEST_PROJECT/bin/serpantinumd" start')
        self.assertNotEqual(daemon.returncode, 0)
        self.assertEqual(Path(self.env["TEST_CORE_LOG"]).read_text().splitlines()[-2:], ["quit", "start"])


if __name__ == "__main__":
    unittest.main()
