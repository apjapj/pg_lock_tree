#!/usr/bin/env python3
"""Generate PGXN metadata and a package from a release tag.

    scripts/pgxn-meta.py --check
    scripts/pgxn-meta.py --check --tag v1.2.1
    scripts/pgxn-meta.py --package build/pgxn/pg_lock_tree-1.2.1.zip --tag v1.2.1
    scripts/pgxn-meta.py --output build/pgxn/META.json --tag v1.2.1

Release fields come from pg_lock_tree.control and the tag; the stable identity fields come from
pgxn.toml. The generated META.json and pgxn.toml are checked for private hostnames and addresses,
because META.json is published and permanent.

No network, no credentials, no database.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time
import tomllib
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CONTROL = None  # the single *.control file, resolved at run time
PGXN = ROOT / "pgxn.toml"
META_URL = "https://pgxn.org/meta/spec.txt"
META_VERSION = "1.0.0"

# Anything that identifies a private host must never reach a published file. The bare tokens catch
# the common short names; the address patterns catch the literals.
PRIVATE_PATTERNS = [
    (re.compile(r"\bforgejo(?:\.lan)?\b", re.I), "forgejo"),
    (re.compile(r"\blocalhost\b", re.I), "localhost"),
    (re.compile(r"\b[a-z0-9._-]+\.lan\b", re.I), "*.lan hostname"),
    (re.compile(r"\b[a-z0-9._-]+\.local\b", re.I), "*.local hostname"),
    (re.compile(r"\bregistry\b", re.I), "registry host"),
    # Split literals: a scanner that looks for dotted addresses must not match this source file.
    (re.compile(r"\b" + "127" + r"\.\d{1,3}\.\d{1,3}\.\d{1,3}\b"), "loopback address"),
    (re.compile(r"\b" + "192" + r"\." + "168" + r"\.\d{1,3}\.\d{1,3}\b"), "RFC1918 class C address"),
    (re.compile(r"\b" + "10" + r"\.\d{1,3}\.\d{1,3}\.\d{1,3}\b"), "RFC1918 class A address"),
    (re.compile(r"\b" + "172" + r"\.(?:1[6-9]|2\d|3[01])\.\d{1,3}\.\d{1,3}\b"), "RFC1918 class B address"),
]


def fail(message: str) -> "NoReturn":
    print(f"pgxn-meta: {message}", file=sys.stderr)
    raise SystemExit(1)


def control() -> tuple[str, str, str]:
    """(extension name, default version, comment) from the .control file."""
    global CONTROL
    if CONTROL is None:
        found = sorted(ROOT.glob("*.control"))
        if len(found) != 1:
            fail("expected exactly one *.control file in the repository root")
        CONTROL = found[0]
    text = CONTROL.read_text(encoding="utf-8")
    version = re.search(r"^default_version\s*=\s*'([^']+)'", text, re.M)
    comment = re.search(r"^comment\s*=\s*'([^']+)'", text, re.M)
    if not version or not comment:
        fail(f"{CONTROL} must have default_version and comment")
    return CONTROL.stem, version.group(1), comment.group(1)


def stable() -> dict:
    if not PGXN.is_file():
        fail(f"{PGXN} is missing")
    with PGXN.open("rb") as handle:
        return tomllib.load(handle)


def metadata(tag: str | None) -> dict:
    name, version, comment = control()
    conf = stable()
    for key in ("maintainer", "license", "postgresql", "resources"):
        if not conf.get(key):
            fail(f"{PGXN} is missing {key}")
    if tag is not None and tag != f"v{version}":
        fail(f"tag {tag} does not match the control version {version} (expected v{version})")

    if "CHANGE-ME" in conf["maintainer"]:
        print("pgxn-meta: warning: maintainer is still the placeholder; "
              "a real publish must refuse until the slonik.vip alias is set", file=sys.stderr)

    resources = conf["resources"]
    for key in ("homepage", "bugtracker", "repository", "web"):
        if not resources.get(key):
            fail(f"{PGXN} resources is missing {key}")

    meta = {
        "name": name,
        "abstract": comment,
        "version": version,
        "maintainer": conf["maintainer"],
        "license": conf["license"],
        "provides": {
            name: {
                "file": f"{name}--{version}.sql",
                "version": version,
            }
        },
        "prereqs": {
            "runtime": {
                "requires": {
                    "PostgreSQL": conf["postgresql"],
                }
            }
        },
        "resources": {
            "homepage": resources["homepage"],
            "bugtracker": {"web": resources["bugtracker"]},
            "repository": {
                "type": "git",
                "url": resources["repository"],
                "web": resources["web"],
            },
        },
        "meta-spec": {
            "version": META_VERSION,
            "url": META_URL,
        },
    }
    return meta


def private_lint(meta: dict) -> None:
    """Refuse a published file that names a private host."""
    text = PGXN.read_text(encoding="utf-8") + "\n" + json.dumps(meta, indent=2)
    for pattern, label in PRIVATE_PATTERNS:
        match = pattern.search(text)
        if match:
            fail(f"private host in published metadata: {label} ({match.group(0)!r})")


def validate_shape(meta: dict) -> None:
    for key in ("name", "abstract", "version", "maintainer", "license",
                "provides", "prereqs", "resources", "meta-spec"):
        if not meta.get(key):
            fail(f"generated META.json has no {key}")
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", meta["version"]):
        fail(f"version {meta['version']!r} is not x.y.z")


def write_meta(meta: dict, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(meta, indent=2) + "\n", encoding="utf-8")


def build_package(meta: dict, tag: str, out: Path) -> None:
    if subprocess.run(["git", "-C", str(ROOT), "rev-parse", "--verify", f"{tag}^{{commit}}"],
                      capture_output=True).returncode != 0:
        fail(f"tag {tag} does not exist")
    name, version, _ = control()
    prefix = f"{name}-{version}"
    out.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as tmp:
        tmpdir = Path(tmp)
        archive = subprocess.run(["git", "-C", str(ROOT), "archive", "--format=tar", f"--prefix={prefix}/", tag],
                                 check=True, capture_output=True).stdout
        with tarfile.open(fileobj=__import__("io").BytesIO(archive)) as tar:
            tar.extractall(tmpdir)
        write_meta(meta, tmpdir / prefix / "META.json")
        # Reproducible zip: the same tag must give the same bytes, so every entry carries the
        # tag's own commit time rather than the time this script ran.
        stamp = int(subprocess.run(["git", "-C", str(ROOT), "show", "-s", "--format=%ct", f"{tag}^{{commit}}"],
                                   check=True, capture_output=True, text=True).stdout.strip())
        stamp = max(stamp, 315532800)  # the zip format cannot represent before 1980
        date_time = time.gmtime(stamp)[:6]
        with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
            for path in sorted((tmpdir / prefix).rglob("*")):
                if path.is_file():
                    rel = str(path.relative_to(tmpdir))
                    info = zipfile.ZipInfo(rel, date_time=date_time)
                    info.compress_type = zipfile.ZIP_DEFLATED
                    info.external_attr = 0o644 << 16
                    z.writestr(info, path.read_bytes())
    digest = hashlib.sha256(out.read_bytes()).hexdigest()
    print(f"package: {out}")
    print(f"sha256:  {digest}")
    print(f"tag:     {tag}")


def main() -> int:
    parser = argparse.ArgumentParser(description="Generate and validate PGXN metadata.")
    parser.add_argument("--tag", help="release tag; required for --package and checked when given")
    parser.add_argument("--output", help="write META.json here")
    parser.add_argument("--package", help="write a PGXN zip here (requires --tag)")
    parser.add_argument("--check", action="store_true", help="validate shape and private hosts")
    parser.add_argument("--unreleased", action="store_true",
                        help="current control version with no tag yet; metadata only, no package")
    args = parser.parse_args()

    if args.unreleased and args.package:
        fail("--unreleased cannot build a package; a package needs a tag")
    meta = metadata(None if args.unreleased else args.tag)
    private_lint(meta)
    validate_shape(meta)

    if args.output:
        write_meta(meta, Path(args.output))
        print(f"wrote {args.output}")
    if args.package:
        if not args.tag:
            fail("--package needs --tag")
        build_package(meta, args.tag, Path(args.package))
    if args.check or not (args.output or args.package):
        print(json.dumps(meta, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
