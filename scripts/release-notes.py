#!/usr/bin/env python3
"""Print release notes for a tag using its actual Git history."""
import argparse
import re
import subprocess
from urllib.parse import quote


def git(*args):
    return subprocess.check_output(["git", *args], text=True).strip()


def notes(tag, repo):
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repo):
        raise ValueError("Expected repository in owner/name form")
    commit = git("rev-parse", "--verify", f"refs/tags/{tag}^{{commit}}")
    previous = subprocess.run(
        ["git", "describe", "--tags", "--abbrev=0", "--match", "*.*.*", commit + "^"],
        text=True, capture_output=True,
    )
    previous_tag = previous.stdout.strip() if previous.returncode == 0 else None
    revision = f"{previous_tag}..{commit}" if previous_tag else commit
    changes = git("log", "--reverse", "--format=%H%x09%s", revision).splitlines()
    url = f"https://github.com/{repo}"
    lines = ["## Changes", ""]
    for change in changes:
        sha, subject = change.split("\t", 1)
        subject = re.sub(r"([\\`*_{}\[\]<>])", r"\\\1", subject)
        lines.append(f"- {subject} ([{sha[:7]}]({url}/commit/{sha}))")
    if not changes:
        lines.append("No new commits since the previous tag.")
    if previous_tag:
        lines += ["", f"[Full changelog]({url}/compare/{quote(previous_tag, safe='')}...{quote(tag, safe='')})"]
    lines += ["", "## Installation", "",
              "Download the DMG, open it, and drag Tokloom to Applications.",
              "Apple Silicon · macOS 14+. Ad-hoc signed; not notarized.",
              "The accompanying SHA-256 file verifies the download."]
    return "\n".join(lines) + "\n"


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("tag")
    parser.add_argument("--repo", required=True)
    args = parser.parse_args()
    print(notes(args.tag, args.repo), end="")
