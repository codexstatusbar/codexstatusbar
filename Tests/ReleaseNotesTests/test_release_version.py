import importlib.util
from pathlib import Path
import subprocess
import sys
import unittest

SCRIPT = Path(__file__).resolve().parents[2] / "scripts/release-version.py"
spec = importlib.util.spec_from_file_location("release_version", SCRIPT)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class ReleaseVersionTests(unittest.TestCase):
    def test_a_tag_is_the_app_version_and_the_build_number_grows_with_it(self):
        self.assertEqual(module.parse("0.0.26"), ("0.0.26", 26))
        self.assertEqual(module.parse("0.1.0"), ("0.1.0", 1000))
        self.assertEqual(module.parse("1.2.3"), ("1.2.3", 1002003))
        builds = [module.parse(tag)[1] for tag in ["0.0.9", "0.0.10", "0.0.99", "0.1.0", "0.9.9", "1.0.0"]]
        self.assertEqual(builds, sorted(builds))
        self.assertEqual(len(set(builds)), len(builds))

    def test_anything_that_is_not_a_plain_x_y_z_tag_is_rejected(self):
        for tag in ["v1.0.0", "1.0", "1.0.0.0", "1.0.0-rc1", "01.0.0", "1.00.0", "1000.0.0", "0.0.1000", "", "1.0.0 ", "1.0.0\n", "1.0.0; rm -rf /", "$(id).0.0", "-1.0.0"]:
            with self.assertRaises(ValueError, msg=repr(tag)):
                module.parse(tag)

    def test_the_command_prints_version_and_build_and_fails_on_a_bad_tag(self):
        ok = subprocess.run([sys.executable, str(SCRIPT), "0.0.26"], capture_output=True, text=True)
        self.assertEqual((ok.returncode, ok.stdout.split()), (0, ["0.0.26", "26"]))
        bad = subprocess.run([sys.executable, str(SCRIPT), "v1.0.0"], capture_output=True, text=True)
        self.assertEqual((bad.returncode, bad.stdout), (2, ""))


if __name__ == "__main__":
    unittest.main()
