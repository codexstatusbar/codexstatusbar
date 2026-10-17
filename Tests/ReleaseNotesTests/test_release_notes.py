import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("release_notes", Path(__file__).resolve().parents[2] / "scripts/release-notes.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class ReleaseNotesTests(unittest.TestCase):
    def setUp(self):
        self.original = Path.cwd()
        self.temp = tempfile.TemporaryDirectory()
        os.chdir(self.temp.name)
        self.git("init", "-q")
        self.git("config", "user.name", "Fixture")
        self.git("config", "user.email", "fixture@example.invalid")

    def tearDown(self):
        os.chdir(self.original)
        self.temp.cleanup()

    def git(self, *args):
        return subprocess.check_output(["git", *args], text=True).strip()

    def commit(self, title):
        self.git("commit", "--allow-empty", "-qm", title)
        return self.git("rev-parse", "HEAD")

    def test_first_release_includes_all_commits(self):
        first = self.commit("Initial implementation")
        self.git("tag", "0.0.1")
        result = module.notes("0.0.1", "owner/repo")
        self.assertIn(first, result)
        self.assertNotIn("/compare/", result)

    def test_range_uses_tag_history_not_current_head(self):
        old = self.commit("Old change")
        self.git("tag", "0.0.1")
        included = self.commit("Fix idle rates")
        self.git("tag", "0.0.2")
        future = self.commit("Unreleased work")
        result = module.notes("0.0.2", "owner/repo")
        self.assertIn(included, result)
        self.assertNotIn(old, result)
        self.assertNotIn(future, result)
        self.assertIn("/compare/0.0.1...0.0.2", result)

    def test_subject_is_text_and_missing_tag_fails(self):
        self.commit("Fix [link] <tag> *style*")
        self.git("tag", "0.0.1")
        result = module.notes("0.0.1", "owner/repo")
        self.assertIn(r"Fix \[link\] \<tag\> \*style\*", result)
        with self.assertRaises(subprocess.CalledProcessError):
            module.notes("missing", "owner/repo")
        with self.assertRaises(ValueError):
            module.notes("0.0.1", "invalid repo")
