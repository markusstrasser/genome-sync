from __future__ import annotations

import hashlib
import json
import os
import stat
from dataclasses import dataclass
from pathlib import Path

import pytest


@dataclass(frozen=True)
class FakeGenomeSync:
    command: Path
    destination: Path
    environment: dict[str, str]
    config_file: Path
    donor: str
    payloads: dict[str, bytes]


def _write_executable(path: Path, content: str) -> None:
    path.write_text(content, encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


def _write_lab_snapshot(
    remote_root: Path,
    donor: str,
    payloads: dict[str, bytes] | None = None,
) -> dict[str, bytes]:
    """Write (or rewrite) the fake remote lab snapshot for `payloads`, deriving
    the lab manifest and completion marker from them, and dropping any remote
    payload object the new snapshot no longer names."""
    assay = "shortread"
    if payloads is None:
        payloads = {
            f"{assay}/lab/payload-{index}.bin": bytes([64 + index]) * size
            for index, size in enumerate((60, 50, 40, 30, 20, 10), start=1)
        }
    objects = []
    for relative, content in sorted(payloads.items()):
        suffix = relative.removeprefix(f"{assay}/lab/")
        objects.append(
            {
                "relative_path": suffix,
                "role": "sequencing_payload",
                "bytes": len(content),
                "sha256": hashlib.sha256(content).hexdigest(),
            }
        )
    lab_manifest = {
        "schema_version": "donor-lab-plan/v1",
        "mode": "lab",
        "disposition": "publish",
        "donor_id": donor,
        "assay_id": assay,
        "sample_id": "sample-001",
        "selected_object_count": len(objects),
        "selected_bytes": sum(len(content) for content in payloads.values()),
        "objects": objects,
    }
    manifest_bytes = (
        json.dumps(lab_manifest, sort_keys=True, separators=(",", ":")) + "\n"
    ).encode()
    completion = {
        "schema_version": "donor-lab-completion/v1",
        "sink": "b2",
        "sample_id": "sample-001",
        "plan_sha256": hashlib.sha256(manifest_bytes).hexdigest(),
        "object_count": len(objects),
        "selected_bytes": sum(len(content) for content in payloads.values()),
    }
    all_files = {
        **payloads,
        f"{assay}/lab/lab_manifest.json": manifest_bytes,
        f"{assay}/lab/_COMPLETE.json": (
            json.dumps(completion, sort_keys=True, separators=(",", ":")) + "\n"
        ).encode(),
    }
    donor_root = remote_root / donor
    lab_root = donor_root / assay / "lab"
    if lab_root.is_dir():
        for stale in lab_root.iterdir():
            if stale.is_file() and f"{assay}/lab/{stale.name}" not in all_files:
                stale.unlink()
    for relative, content in all_files.items():
        path = donor_root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(content)
    return payloads


@pytest.fixture
def fake_genome_sync(tmp_path: Path) -> FakeGenomeSync:
    donor = "tester"
    remote_root = tmp_path / "remote"
    payloads = _write_lab_snapshot(remote_root, donor)
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    _write_executable(
        fake_bin / "uvx",
        """#!/usr/bin/env python3
import hashlib
import json
import os
import shutil
import sys
from pathlib import Path

arguments = sys.argv[1:]
try:
    b2_index = arguments.index("b2")
except ValueError:
    raise SystemExit("fake uvx expected b2")
arguments = arguments[b2_index + 1 :]
remote_root = Path(os.environ["FAKE_B2_ROOT"])

if arguments[:2] == ["account", "authorize"]:
    raise SystemExit(0)
if arguments[:3] == ["ls", "--recursive", "--json"]:
    donor = arguments[3].rstrip("/").rsplit("/", 1)[-1]
    rows = []
    for path in sorted((remote_root / donor).rglob("*")):
        if not path.is_file():
            continue
        content = path.read_bytes()
        relative = path.relative_to(remote_root).as_posix()
        rows.append(
            {
                "fileName": relative,
                "size": len(content),
                "contentSha1": hashlib.sha1(content, usedforsecurity=False).hexdigest(),
            }
        )
    print(json.dumps(rows, sort_keys=True, separators=(",", ":")))
    raise SystemExit(0)
if arguments[:2] == ["file", "download"]:
    source_uri, destination = arguments[-2:]
    prefix = "b2://computational-genomics/"
    if not source_uri.startswith(prefix):
        raise SystemExit("fake uvx received the wrong bucket")
    source = remote_root / source_uri.removeprefix(prefix)
    failure_suffix = os.environ.get("FAKE_B2_FAIL_DOWNLOAD_SUFFIX", "")
    if failure_suffix and source.as_posix().endswith(failure_suffix):
        print("injected fake B2 download failure", file=sys.stderr)
        raise SystemExit(9)
    shutil.copyfile(source, destination)
    raise SystemExit(0)
raise SystemExit(f"unsupported fake b2 invocation: {arguments!r}")
""",
    )
    _write_executable(
        fake_bin / "uv",
        """#!/usr/bin/env python3
import sys

operation = sys.argv[-3]
if operation == "get":
    print("fake-key-id")
    print("fake-application-key", end="")
elif operation == "status":
    print("credential_backend=fake.test")
    print("credential_present=true")
elif operation not in {"set", "delete"}:
    raise SystemExit(f"unsupported fake uv invocation: {sys.argv[1:]!r}")
""",
    )

    project_command = Path(os.environ["VIRTUAL_ENV"]) / "bin" / "genome-sync"
    home = tmp_path / "home"
    home.mkdir()
    config_home = tmp_path / "config"
    state_home = tmp_path / "state"
    environment = os.environ.copy()
    environment.update(
        {
            "PATH": f"{fake_bin}{os.pathsep}{environment['PATH']}",
            "HOME": str(home),
            "XDG_CONFIG_HOME": str(config_home),
            "XDG_STATE_HOME": str(state_home),
            "FAKE_B2_ROOT": str(remote_root),
            "B2_APPLICATION_KEY_ID": "setup-key-id",
            "B2_APPLICATION_KEY": "setup-application-key",
            "NO_COLOR": "1",
        }
    )
    return FakeGenomeSync(
        command=project_command,
        destination=tmp_path / "genome",
        environment=environment,
        config_file=config_home / "genome-sync" / "config.json",
        donor=donor,
        payloads=payloads,
    )
