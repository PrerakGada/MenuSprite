#!/usr/bin/env python3
"""Audit the source publication boundary and all Git refs. Requires Gitleaks 8.30.1+."""
import argparse
import io
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]
PRIVATE = re.compile(
    r"(^|/)(?:_memory|ops|\.claude|\.codex|\.vercel|\.build|\.swiftpm|node_modules|"
    r"AGENTS\.md|CLAUDE\.md|auth\.json|accounts\.json|credentials\.json|secrets\.json|"
    r"[^/]*\.app)(/|$)|"
    r"(?:\.(?:p8|p12|pfx|pem|key|mobileprovision|provisionprofile|db|sqlite3?|log|jsonl)"
    r"(?:-(?:wal|shm|journal))?$)|(^|/)\.env(?!\.example$)"
)
EMAIL = re.compile(rb"[A-Za-z0-9._%+\-]+@([A-Za-z0-9.\-]+\.[A-Za-z]{2,})")
PERSONAL_PATH = re.compile(rb"/Users/(?!example/|test/)[A-Za-z0-9_.\-]+/")
HOSTING_ID = re.compile(rb"\b(?:dpl_|prj_|team_)[A-Za-z0-9]{16,}\b")
ALLOWED_EMAIL_DOMAINS = {b"example.com", b"example.org", b"example.net", b"users.noreply.github.com"}
issues = []


def git(*args):
    return subprocess.check_output(["git", "-C", str(ROOT), *args])


def inspect(name, data, depth=0):
    if PRIVATE.search(name):
        issues.append(f"Private/generated path: {name}")
    if name.endswith(".zip"):
        if depth >= 5:
            issues.append(f"Archive nesting exceeds audit limit: {name}")
            return
        try:
            with zipfile.ZipFile(io.BytesIO(data)) as archive:
                if sum(entry.file_size for entry in archive.infolist()) > 50_000_000:
                    issues.append(f"Archive exceeds source audit size limit: {name}")
                    return
                for entry in archive.infolist():
                    if not entry.is_dir():
                        inspect(f"{name}!/{entry.filename}", archive.read(entry), depth + 1)
        except (ValueError, RuntimeError, zipfile.BadZipFile):
            issues.append(f"Unreadable archive: {name}")
        return
    if b"\0" in data:
        return
    # Report locations only; never echo a credential or private address.
    for match in EMAIL.finditer(data):
        if match.group(1).lower() not in ALLOWED_EMAIL_DOMAINS:
            issues.append(f"Review non-example email: {name}:{data[:match.start()].count(bytes([10])) + 1}")
    for pattern, label in [(PERSONAL_PATH, "Personal home path"), (HOSTING_ID, "Private hosting ID")]:
        for match in pattern.finditer(data):
            issues.append(f"{label}: {name}:{data[:match.start()].count(bytes([10])) + 1}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--history", action="store_true", help="also inspect every reachable commit and blob")
    parser.add_argument("--staged", action="store_true", help="scan the exact index, not working copies")
    args = parser.parse_args()
    configured = subprocess.run(["git", "-C", str(ROOT), "config", "--get", "menusprite.gitleaksPath"],
                                capture_output=True, text=True).stdout.strip()
    scanner = os.environ.get("GITLEAKS_BIN") or shutil.which("gitleaks") or configured
    if not scanner:
        sys.exit("Gitleaks is required. Install it or set GITLEAKS_BIN; no partial pass is reported.")
    with tempfile.TemporaryDirectory(prefix="menusprite-source-audit-") as directory:
        snapshot = Path(directory)
        command = ["ls-files", "--cached", "-z"]
        if not args.staged:
            command += ["--others", "--exclude-standard"]
        names = sorted(set(git(*command).decode().split("\0")) - {""})
        count = 0
        for name in names:
            path = ROOT / name
            if args.staged:
                mode = git("ls-files", "-s", "--", name).split(b" ", 1)[0]
                if mode in (b"120000", b"160000"):
                    issues.append(f"Review symlink/submodule before publication: {name}")
                    continue
                data = git("show", f":{name}")
            else:
                if path.is_symlink():
                    issues.append(f"Review symlink before publication: {name}")
                    continue
                if not path.is_file():
                    continue
                data = path.read_bytes()
            inspect(name, data)
            target = snapshot / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
            count += 1
        subprocess.run([scanner, "dir", str(snapshot), "--redact=100", "--no-banner",
                        "--max-archive-depth=5"], check=True)
    if args.history:
        for line in git("rev-list", "--objects", "--all").decode().splitlines():
            oid, _, name = line.partition(" ")
            kind = git("cat-file", "-t", oid).strip()
            if kind == b"blob":
                inspect(f"history/{oid[:12]}/{name}", git("cat-file", "blob", oid))
            elif kind == b"commit":
                inspect(f"commit/{oid[:12]}", git("cat-file", "commit", oid))
        # Check every historical path too: a blob reused at two names appears once in rev-list.
        paths = git("log", "--all", "--format=", "--name-only").decode().splitlines()
        for name in sorted(set(paths) - {""}):
            if PRIVATE.search(name):
                issues.append(f"Private path remains in Git history: {name}")
        subprocess.run([scanner, "git", str(ROOT), "--redact=100", "--no-banner",
                        "--log-opts=--all --full-history", "--max-archive-depth=5"], check=True)
    if issues:
        print("\n".join(sorted(set(issues))), file=sys.stderr)
        sys.exit(1)
    print(f"Publication audit passed: {count} source files" + (" and all Git refs." if args.history else "."))


if __name__ == "__main__":
    main()
