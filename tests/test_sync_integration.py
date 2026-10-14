from __future__ import annotations

import gzip
import hashlib
import json
import os
import re
import shutil
import subprocess
import zlib
from pathlib import Path

import pexpect
import pytest

from conftest import FakeGenomeSync


def _run(client: FakeGenomeSync, *arguments: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [client.command, *arguments],
        env=client.environment,
        text=True,
        capture_output=True,
        check=False,
    )


def _setup(
    client: FakeGenomeSync,
    *extra_arguments: str,
    destination: str | None = None,
) -> subprocess.CompletedProcess[str]:
    completed = _run(
        client,
        "setup",
        "--dest",
        destination if destination is not None else str(client.destination),
        "--only",
        "lab",
        "--yes",
        *extra_arguments,
        client.donor,
    )
    assert completed.returncode == 0, completed.stderr + completed.stdout
    return completed


def _manifest(client: FakeGenomeSync) -> dict[str, object]:
    return json.loads((client.destination / ".genome-manifest.json").read_text())


def _seed_legacy_result_records(client: FakeGenomeSync) -> dict[str, bytes]:
    contents = {
        "shortread/results/intact-result.bin": b"intact-result-payload",
        "shortread/results/corrupt-result.bin": b"corrupt-result-payload",
        "shortread/results/missing-result.bin": b"missing-result-payload",
    }
    manifest_path = client.destination / ".genome-manifest.json"
    manifest = json.loads(manifest_path.read_text())
    manifest["schema"] = 3
    manifest.pop("materialization", None)
    manifest.pop("omitted_files", None)
    manifest.pop("unavailable_files", None)
    for relative, content in contents.items():
        path = client.destination / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(content)
        manifest["files"][relative] = {
            "size": len(content),
            "remote_sha1": hashlib.sha1(content, usedforsecurity=False).hexdigest(),
            "sha256": hashlib.sha256(content).hexdigest(),
            "proof": "activated_plan_sha256_verified",
        }
    manifest["active_results"] = {
        "shortread": {
            "sample_id": "sample-001",
            "plan_sha256": "1" * 64,
            "authorized_at": "2026-07-31T00:00:00Z",
            "completion_sha256": "2" * 64,
            "local_path": "shortread/results",
        }
    }
    assay_root = client.destination / "shortread"
    (assay_root / "README.md").write_text(
        "# Assay: shortread\n\n- Local materialization includes every activated payload.\n"
    )
    (assay_root / "TOC.md").write_text("# shortread contents\n\nLocal materialization: complete\n")
    (client.destination / "TOC.md").write_text(
        "# Active genome bundles\n\n| shortread | complete |\n"
    )
    manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    os.chmod(manifest_path, 0o600)
    return contents


def _seed_absent_remote_lab_file(client: FakeGenomeSync, relative: str, content: bytes) -> None:
    """Record a managed lab file locally that the remote snapshot does not carry."""
    path = client.destination / relative
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(content)
    manifest_path = client.destination / ".genome-manifest.json"
    manifest = json.loads(manifest_path.read_text())
    manifest["files"][relative] = {
        "size": len(content),
        "remote_sha1": hashlib.sha1(content, usedforsecurity=False).hexdigest(),
        "sha256": hashlib.sha256(content).hexdigest(),
        "proof": "activated_plan_sha256_verified",
    }
    manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    os.chmod(manifest_path, 0o600)


@pytest.mark.parametrize(
    ("only", "expected"),
    [("results", "results"), ("lab", "lab"), ("", "results and lab")],
)
def test_v2_config_preserves_saved_section_choices(
    fake_genome_sync: FakeGenomeSync,
    only: str,
    expected: str,
) -> None:
    client = fake_genome_sync
    client.destination.mkdir()
    client.config_file.parent.mkdir(parents=True)
    client.config_file.write_text(
        json.dumps(
            {
                "schema_version": "genome-sync-config/v2",
                "donor": client.donor,
                "destination": str(client.destination),
                "only": only,
                "exclude": "",
            }
        )
        + "\n"
    )
    os.chmod(client.config_file, 0o600)

    completed = _run(client, "status")
    assert completed.returncode == 0, completed.stderr + completed.stdout
    assert f"destination={client.destination}" in completed.stdout
    assert f"default_selection={expected}" in completed.stdout


def test_v3_config_with_retired_selection_key_still_loads_and_syncs(
    fake_genome_sync: FakeGenomeSync,
) -> None:
    # Every donor who ran `setup` before the payload picker was removed holds a v3
    # file carrying its key. Refusing that file would be the regression.
    client = fake_genome_sync
    client.destination.mkdir()
    client.config_file.parent.mkdir(parents=True)
    client.config_file.write_text(
        json.dumps(
            {
                "schema_version": "genome-sync-config/v3",
                "donor": client.donor,
                "destination": str(client.destination),
                "only": "lab",
                "exclude": "",
                "omitted_large_paths": ["shortread/lab/payload-1.bin"],
            },
            sort_keys=True,
        )
        + "\n"
    )
    os.chmod(client.config_file, 0o600)

    status = _run(client, "status")
    assert status.returncode == 0, status.stderr + status.stdout
    assert "default_selection=lab" in status.stdout

    completed = _run(client, "sync", "--yes")
    assert completed.returncode == 0, completed.stderr + completed.stdout
    # The previously omitted payload is no longer omittable, so it lands.
    landed = client.destination / "shortread" / "lab" / "payload-1.bin"
    assert landed.read_bytes() == client.payloads["shortread/lab/payload-1.bin"]
    manifest = _manifest(client)
    assert manifest["materialization"]["complete"] is True
    assert manifest["omitted_files"] == {}

    rewritten = json.loads(client.config_file.read_text())
    assert rewritten["schema_version"] == "genome-sync-config/v4"
    assert "omitted_large_paths" not in rewritten
    assert rewritten["only"] == "lab"


def test_interactive_setup_and_sync_ask_only_for_sections(
    fake_genome_sync: FakeGenomeSync,
) -> None:
    client = fake_genome_sync
    setup = pexpect.spawn(
        str(client.command),
        ["setup", "--dest", str(client.destination), client.donor],
        env=client.environment,
        encoding="utf-8",
        timeout=15,
    )
    setup.expect("Sync results, lab, or both?.*\\[results\\]")
    setup.sendline("lab")
    setup.expect("Apply this verified update?.*\\[Y/n\\]")
    # The section question is the only selection question left: no payload list,
    # no numbered choices, no omit prompt between it and the confirmation.
    assert "optional payloads" not in setup.before
    assert "Numbers to omit" not in setup.before
    setup.sendline("y")
    setup.expect(pexpect.EOF)
    setup.close()
    assert setup.exitstatus == 0

    config = json.loads(client.config_file.read_text())
    assert config["schema_version"] == "genome-sync-config/v4"
    assert config["only"] == "lab"
    assert config["destination"] == str(client.destination)
    assert "omitted_large_paths" not in config
    assert _manifest(client)["materialization"]["complete"] is True

    sync = pexpect.spawn(
        str(client.command),
        [],
        env=client.environment,
        encoding="utf-8",
        timeout=15,
    )
    sync.expect("What should be synced?.*\\[lab only\\]")
    sync.sendline("")
    sync.expect("Apply this verified update?.*\\[Y/n\\]")
    assert "optional payloads" not in sync.before
    assert "Numbers to omit" not in sync.before
    sync.sendline("n")
    sync.expect("No files changed")
    sync.expect(pexpect.EOF)
    sync.close()
    assert sync.exitstatus == 0


def test_one_off_run_asks_which_sections_to_sync(
    fake_genome_sync: FakeGenomeSync,
) -> None:
    # A one-off run has no saved configuration. Before this it fell through to
    # "results and lab" and printed that as a fact, committing the donor to both
    # classes — on a real donor, 17.5 GB they were never asked about.
    client = fake_genome_sync
    one_off = pexpect.spawn(
        str(client.command),
        ["--dest", str(client.destination), client.donor],
        env=client.environment,
        encoding="utf-8",
        timeout=15,
    )
    one_off.expect("What should be synced?.*\\[both\\]")
    one_off.sendline("lab")
    one_off.expect("Selection:.*lab only")
    one_off.expect("Apply this verified update?.*\\[Y/n\\]")
    one_off.sendline("y")
    one_off.expect(pexpect.EOF)
    one_off.close()
    assert one_off.exitstatus == 0

    for relative, content in client.payloads.items():
        assert (client.destination / relative).read_bytes() == content, relative
    assert _manifest(client)["materialization"]["complete"] is True
    # A one-off saves nothing: no config, no stored credential.
    assert not client.config_file.exists()


def test_one_off_honours_an_explicit_section_without_asking(
    fake_genome_sync: FakeGenomeSync,
) -> None:
    client = fake_genome_sync
    one_off = pexpect.spawn(
        str(client.command),
        ["--dest", str(client.destination), "--only", "lab", "--yes", client.donor],
        env=client.environment,
        encoding="utf-8",
        timeout=15,
    )
    one_off.expect(pexpect.EOF)
    one_off.close()
    assert one_off.exitstatus == 0
    assert "What should be synced?" not in one_off.before


def test_destination_command_rewrites_the_config_without_syncing(
    fake_genome_sync: FakeGenomeSync,
) -> None:
    client = fake_genome_sync
    _setup(client)
    moved = client.destination.parent / "genome-moved"
    moved.mkdir()

    completed = _run(client, "destination", str(moved))
    assert completed.returncode == 0, completed.stderr + completed.stdout
    assert "No files were moved" in completed.stdout
    updated = json.loads(client.config_file.read_text())
    assert updated["schema_version"] == "genome-sync-config/v4"
    assert updated["destination"] == str(moved)
    assert updated["only"] == "lab"
    assert not any(moved.iterdir())


def test_omit_large_is_no_longer_an_option(fake_genome_sync: FakeGenomeSync) -> None:
    client = fake_genome_sync
    completed = _run(client, "sync", "--omit-large", "1", "--yes")
    assert completed.returncode == 1
    assert "unknown option: --omit-large" in completed.stderr


def test_repeated_setup_prefills_and_commits_only_after_confirmation(
    fake_genome_sync: FakeGenomeSync,
) -> None:
    client = fake_genome_sync
    _setup(client)
    original_config = client.config_file.read_bytes()

    repeated = pexpect.spawn(
        str(client.command),
        ["setup", client.donor],
        env=client.environment,
        encoding="utf-8",
        timeout=15,
    )
    repeated.expect("Sync results, lab, or both?.*\\[lab only\\]")
    repeated.sendline("")
    repeated.expect("Save your genome data where?.*" + re.escape(str(client.destination)))
    repeated.sendline("")
    repeated.expect("Apply this verified update?.*\\[Y/n\\]")
    repeated.sendline("n")
    repeated.expect("No files changed")
    repeated.expect(pexpect.EOF)
    repeated.close()
    assert repeated.exitstatus == 0
    assert client.config_file.read_bytes() == original_config

    completed = _run(client, "setup", "--yes", client.donor)
    assert completed.returncode == 0, completed.stderr + completed.stdout
    updated = json.loads(client.config_file.read_text())
    assert updated["schema_version"] == "genome-sync-config/v4"
    assert updated["destination"] == str(client.destination)
    assert updated["only"] == "lab"


def test_repeated_setup_failure_preserves_saved_configuration(
    fake_genome_sync: FakeGenomeSync,
) -> None:
    client = fake_genome_sync
    _setup(client)
    original_config = client.config_file.read_bytes()
    # Corrupt a landed payload so the next run must re-download exactly it.
    corrupted = client.destination / "shortread" / "lab" / "payload-1.bin"
    corrupted.write_bytes(b"X" * len(client.payloads["shortread/lab/payload-1.bin"]))
    failing_environment = dict(client.environment)
    failing_environment["FAKE_B2_FAIL_DOWNLOAD_SUFFIX"] = "payload-1.bin"

    completed = subprocess.run(
        [client.command, "setup", "--yes", client.donor],
        env=failing_environment,
        text=True,
        capture_output=True,
        check=False,
    )
    assert completed.returncode == 1
    assert "Download failed on shortread/lab/payload-1.bin" in completed.stdout
    assert client.config_file.read_bytes() == original_config


def test_lab_only_sync_audits_carried_results_and_normalizes_active_record(
    fake_genome_sync: FakeGenomeSync,
) -> None:
    client = fake_genome_sync
    _setup(client)
    contents = _seed_legacy_result_records(client)
    corrupt_relative = "shortread/results/corrupt-result.bin"
    missing_relative = "shortread/results/missing-result.bin"
    intact_relative = "shortread/results/intact-result.bin"
    (client.destination / corrupt_relative).write_bytes(b"X" * len(contents[corrupt_relative]))
    (client.destination / missing_relative).unlink()

    completed = _run(client, "sync", "--yes")
    assert completed.returncode == 0, completed.stderr + completed.stdout
    manifest = _manifest(client)
    assert manifest["schema"] == 6
    assert manifest["retained_files"] == {}
    active = manifest["active_results"]["shortread"]
    assert active["remote_activation_validated"] is True
    assert active["omitted_file_count"] == 0
    assert active["omitted_bytes"] == 0
    assert intact_relative in manifest["files"]
    assert intact_relative not in manifest["unavailable_files"]
    assert corrupt_relative not in manifest["files"]
    assert missing_relative not in manifest["files"]
    assert manifest["unavailable_files"][corrupt_relative]["reason"] == "local_sha256_mismatch"
    assert manifest["unavailable_files"][missing_relative]["reason"] == "missing_local_file"
    assert manifest["materialization"]["complete"] is False
    assert manifest["materialization"]["unavailable_file_count"] == 2
    assert active["local_materialization_complete"] is False
    assert active["unavailable_file_count"] == 2
    assert active["unavailable_bytes"] == (
        len(contents[corrupt_relative]) + len(contents[missing_relative])
    )
    assay_readme = (client.destination / "shortread" / "README.md").read_text()
    assay_toc = (client.destination / "shortread" / "TOC.md").read_text()
    root_toc = (client.destination / "TOC.md").read_text()
    assert "Local materialization is partial: 2 missing or corrupt." in assay_readme
    assert "Local materialization: partial" in assay_toc
    assert "| shortread | sample-001 | 2026-07-31T00:00:00Z | partial |" in root_toc


RETIRED_RELATIVE = "shortread/lab/retired-payload.bin"
RETIRED_CONTENT = b"retired-lab-payload"


RETIRED_ATTIC = f"_retained/{RETIRED_RELATIVE}"


def test_absent_remote_file_is_retired_to_attic_by_default(
    fake_genome_sync: FakeGenomeSync,
) -> None:
    client = fake_genome_sync
    _setup(client)
    _seed_absent_remote_lab_file(client, RETIRED_RELATIVE, RETIRED_CONTENT)
    retired_path = client.destination / RETIRED_RELATIVE
    attic_path = client.destination / RETIRED_ATTIC

    completed = _run(client, "sync", "--yes")
    assert completed.returncode == 0, completed.stderr + completed.stdout
    assert "1 to retire to _retained/" in completed.stdout
    assert "to remove" not in completed.stdout
    assert not retired_path.exists()
    assert attic_path.read_bytes() == RETIRED_CONTENT
    assert (client.destination / "_retained" / "README.md").is_file()

    manifest = _manifest(client)
    assert manifest["schema"] == 6
    assert RETIRED_RELATIVE not in manifest["files"]
    assert RETIRED_RELATIVE not in manifest["unavailable_files"]
    assert RETIRED_RELATIVE not in manifest["retained_files"]
    retained = manifest["retained_files"][RETIRED_ATTIC]
    assert retained["size"] == len(RETIRED_CONTENT)
    assert retained["sha256"] == hashlib.sha256(RETIRED_CONTENT).hexdigest()
    assert retained["proof"] == "activated_plan_sha256_verified"
    assert retained["reason"] == "absent_from_active_snapshot"
    assert retained["original_path"] == RETIRED_RELATIVE
    assert "_retained/README.md" in manifest["protected_local_paths"]
    assert manifest["materialization"]["retained_file_count"] == 1
    assert manifest["materialization"]["retained_bytes"] == len(RETIRED_CONTENT)
    assert manifest["materialization"]["complete"] is True

    repeated = _run(client, "sync", "--yes")
    assert repeated.returncode == 0, repeated.stderr + repeated.stdout
    assert "1 in _retained/" in repeated.stdout
    assert "to retire" not in repeated.stdout
    assert attic_path.read_bytes() == RETIRED_CONTENT
    assert RETIRED_ATTIC in _manifest(client)["retained_files"]


def test_snapshot_readding_a_retired_file_restores_it_from_the_attic(
    fake_genome_sync: FakeGenomeSync,
) -> None:
    from pathlib import Path as _Path

    from conftest import _write_lab_snapshot

    client = fake_genome_sync
    remote_root = _Path(client.environment["FAKE_B2_ROOT"])
    dropped_relative = sorted(client.payloads)[0]
    dropped_content = client.payloads[dropped_relative]
    _setup(client)

    shrunken = {
        relative: content
        for relative, content in client.payloads.items()
        if relative != dropped_relative
    }
    _write_lab_snapshot(remote_root, client.donor, shrunken)
    completed = _run(client, "sync", "--yes")
    assert completed.returncode == 0, completed.stderr + completed.stdout
    live_path = client.destination / dropped_relative
    attic_path = client.destination / "_retained" / dropped_relative
    assert not live_path.exists()
    assert attic_path.read_bytes() == dropped_content

    _write_lab_snapshot(remote_root, client.donor, dict(client.payloads))
    restored = _run(client, "sync", "--yes")
    assert restored.returncode == 0, restored.stderr + restored.stdout
    assert "reused" in restored.stdout
    assert live_path.read_bytes() == dropped_content
    manifest = _manifest(client)
    assert dropped_relative in manifest["files"]
    # The attic copy stays retained until an explicit --prune clears it.
    assert f"_retained/{dropped_relative}" in manifest["retained_files"]


def test_prune_removes_file_absent_from_active_snapshot(
    fake_genome_sync: FakeGenomeSync,
) -> None:
    client = fake_genome_sync
    _setup(client)
    _seed_absent_remote_lab_file(client, RETIRED_RELATIVE, RETIRED_CONTENT)
    retired_path = client.destination / RETIRED_RELATIVE

    completed = _run(client, "sync", "--prune", "--yes")
    assert completed.returncode == 0, completed.stderr + completed.stdout
    assert "1 to remove" in completed.stdout
    assert "to retire" not in completed.stdout
    assert not retired_path.exists()

    manifest = _manifest(client)
    assert manifest["retained_files"] == {}
    assert RETIRED_RELATIVE not in manifest["files"]
    assert RETIRED_RELATIVE not in manifest["unavailable_files"]
    assert manifest["materialization"]["retained_file_count"] == 0
    assert manifest["materialization"]["complete"] is True


def test_prune_empties_the_attic_and_removes_its_readme(
    fake_genome_sync: FakeGenomeSync,
) -> None:
    client = fake_genome_sync
    _setup(client)
    _seed_absent_remote_lab_file(client, RETIRED_RELATIVE, RETIRED_CONTENT)

    retained = _run(client, "sync", "--yes")
    assert retained.returncode == 0, retained.stderr + retained.stdout
    attic_path = client.destination / RETIRED_ATTIC
    assert attic_path.is_file()
    assert (client.destination / "_retained" / "README.md").is_file()

    pruned = _run(client, "sync", "--prune", "--yes")
    assert pruned.returncode == 0, pruned.stderr + pruned.stdout
    assert not attic_path.exists()
    assert not (client.destination / "_retained").exists()
    manifest = _manifest(client)
    assert manifest["retained_files"] == {}
    assert "_retained/README.md" not in manifest["protected_local_paths"]


def test_corrupt_retained_file_is_reported_unavailable(
    fake_genome_sync: FakeGenomeSync,
) -> None:
    client = fake_genome_sync
    _setup(client)
    _seed_absent_remote_lab_file(client, RETIRED_RELATIVE, RETIRED_CONTENT)
    retired_path = client.destination / RETIRED_RELATIVE
    corrupted = b"X" * len(RETIRED_CONTENT)
    retired_path.write_bytes(corrupted)

    completed = _run(client, "sync", "--yes")
    assert completed.returncode == 0, completed.stderr + completed.stdout
    attic_path = client.destination / RETIRED_ATTIC
    assert not retired_path.exists()
    assert attic_path.read_bytes() == corrupted

    manifest = _manifest(client)
    assert RETIRED_ATTIC not in manifest["retained_files"]
    assert RETIRED_RELATIVE not in manifest["files"]
    unavailable = manifest["unavailable_files"][RETIRED_ATTIC]
    assert unavailable["reason"] == "local_sha256_mismatch"
    assert unavailable["retained"] is True
    assert unavailable["original_path"] == RETIRED_RELATIVE
    assert unavailable["observed_sha256"] == hashlib.sha256(corrupted).hexdigest()
    assert manifest["materialization"]["retained_unavailable_file_count"] == 1
    assert manifest["materialization"]["unavailable_file_count"] == 0
    assert manifest["materialization"]["complete"] is True


def test_jobs_four_downloads_every_object_with_correct_bytes(
    fake_genome_sync: FakeGenomeSync,
) -> None:
    client = fake_genome_sync
    _setup(client, "--jobs", "4")

    for relative, content in client.payloads.items():
        landed = client.destination / relative
        assert landed.read_bytes() == content, relative
    # The plan and completion objects must land too, not just the payloads.
    assert (client.destination / "shortread/lab/lab_manifest.json").exists()
    assert (client.destination / "shortread/lab/_COMPLETE.json").exists()
    manifest = _manifest(client)
    assert manifest["materialization"]["complete"] is True
    for relative in client.payloads:
        assert relative in manifest["files"]


def test_jobs_one_and_four_produce_identical_file_records(
    fake_genome_sync: FakeGenomeSync,
) -> None:
    client = fake_genome_sync
    serial_destination = client.destination.parent / "genome-serial"
    parallel_destination = client.destination.parent / "genome-parallel"

    _setup(client, "--jobs", "1", destination=str(serial_destination))
    _setup(client, "--jobs", "4", destination=str(parallel_destination))

    serial_manifest = json.loads((serial_destination / ".genome-manifest.json").read_text())
    parallel_manifest = json.loads((parallel_destination / ".genome-manifest.json").read_text())
    assert serial_manifest["files"], "expected downloaded file records"
    assert serial_manifest["files"] == parallel_manifest["files"]


def test_jobs_four_mid_run_fetch_failure_fails_closed(
    fake_genome_sync: FakeGenomeSync,
) -> None:
    client = fake_genome_sync
    # A completed snapshot, then corrupt several payloads so a re-sync must
    # re-download them concurrently under --jobs 4.
    _setup(client, "--jobs", "4")
    preexisting = b"PRE-EXISTING-LOCAL-BYTES-DO-NOT-REPLACE"
    survivor_relative = "shortread/lab/payload-4.bin"
    for relative in (
        "shortread/lab/payload-2.bin",
        survivor_relative,
        "shortread/lab/payload-6.bin",
    ):
        (client.destination / relative).write_bytes(preexisting)

    failing_environment = dict(client.environment)
    failing_environment["FAKE_B2_FAIL_DOWNLOAD_SUFFIX"] = "payload-4.bin"
    completed = subprocess.run(
        [client.command, "sync", "--yes", "--jobs", "4"],
        env=failing_environment,
        text=True,
        capture_output=True,
        check=False,
    )

    assert completed.returncode != 0
    assert "Download failed on shortread/lab/payload-4.bin" in completed.stdout, (
        completed.stdout + completed.stderr
    )
    # The failed object's pre-existing on-disk copy was never atomically replaced.
    assert (client.destination / survivor_relative).read_bytes() == preexisting


@pytest.mark.parametrize("bad_jobs", ["0", "99", "abc"])
def test_jobs_rejects_out_of_range_or_non_numeric(
    fake_genome_sync: FakeGenomeSync,
    bad_jobs: str,
) -> None:
    client = fake_genome_sync
    completed = _run(client, "sync", "--jobs", bad_jobs, "--yes")
    assert completed.returncode != 0
    assert "--jobs must be" in completed.stderr, completed.stderr + completed.stdout


# --- donor-root-export-manifest/v4: gzip transport, plain files on disk ---------

ASSAY = "shortread"
ROOT_V3 = "donor-root-export-manifest/v3"
ROOT_V4 = "donor-root-export-manifest/v4"
RESULTS_ASSETS = {
    "AGENTS.md": b"# Agent guide\n",
    "CLAUDE.md": b"# Agent guide\n",
    "README.md": b"# Results\n",
}
BIG_TSV = b"".join(
    f"chr1\t{position}\tA\tG\t0.{position % 97:02d}\n".encode() for position in range(20000)
)
TABLE_JSON = json.dumps([{"gene": f"G{index}", "score": index / 7} for index in range(3000)]).encode()
SUMMARY_JSON = b'{"rows": 20000}\n'
# A stage output that is itself gzip bytes ships plain and must stay compressed.
CALLS_VCF_GZ = gzip.compress(b"##fileformat=VCFv4.2\n#CHROM\tPOS\n", mtime=0)
DROP = object()


def _sha256(content: bytes) -> str:
    return hashlib.sha256(content).hexdigest()


def _plain_text(text: str) -> str:
    return re.sub(r"\x1b\[[0-9;]*m", "", text)


def _plain(path: str, content: bytes) -> tuple[dict[str, object], bytes]:
    return {"path": path, "bytes": len(content), "sha256": _sha256(content)}, content


def _encoded(
    logical: str,
    content: bytes,
    *,
    stored: bytes | None = None,
    **overrides: object,
) -> tuple[dict[str, object], bytes]:
    """One v4 encoded object: bytes/sha256 describe the STORED gzip object (built
    from `stored` when given, e.g. a damaged stream), logical_* the plain file.
    `overrides` replace entry fields to build contract violations."""
    stored_bytes = gzip.compress(content, compresslevel=6, mtime=0) if stored is None else stored
    entry: dict[str, object] = {
        "path": logical + ".gz",
        "bytes": len(stored_bytes),
        "sha256": _sha256(stored_bytes),
        "encoding": "gzip",
        "logical_path": logical,
        "logical_bytes": len(content),
        "logical_sha256": _sha256(content),
    }
    entry.update(overrides)
    return entry, stored_bytes


def _v4_objects(*, big: tuple[dict[str, object], bytes] | None = None) -> list:
    return [
        _encoded("stage_a/big.tsv", BIG_TSV) if big is None else big,
        _plain("stage_a/calls.vcf.gz", CALLS_VCF_GZ),
        _plain("stage_a/summary.json", SUMMARY_JSON),
        _encoded("stage_b/table.json", TABLE_JSON),
    ]


def _selected_disposition(stage: str) -> dict[str, object]:
    return {
        "stage": stage,
        "state": "selected",
        "reason": "",
        "attempt_id": "attempt-1",
        "ran_at": "2026-10-01T00:00:00Z",
        "current_pointer_sha256": "3" * 64,
        "receipt_sha256": "4" * 64,
        "currency": {
            "decision_id": "5" * 64,
            "disposition": "CURRENT",
            "completion_eligible": True,
            "produced_identity_digest": "6" * 64,
            "current_identity_digest": "6" * 64,
            "unresolved_reason_codes": [],
            "semantic_judgment_id": "",
            "currentness_attestation_id": "",
            "identity_scheme": "execution_identity.v1",
            "action_key": "",
            "semantic_artifact_digest": "",
        },
        "blocked_by": "",
        "evidence_kind": "cass_current",
        "action_key": "",
        "semantic_artifact_digest": "",
    }


def _write_results_snapshot(
    client: FakeGenomeSync,
    objects: list,
    *,
    schema: str = ROOT_V4,
    published_at: str = "2026-10-01T00:00:00Z",
    root_overrides: dict[str, object] | None = None,
) -> None:
    """Replace the fake remote results prefix with one activated snapshot: root
    manifest, completion marker binding its stored object set, and the objects."""
    entries = sorted(
        [*objects, *(_plain(name, content) for name, content in RESULTS_ASSETS.items())],
        key=lambda item: str(item[0]["path"]),
    )
    root: dict[str, object] = {
        "schema_version": schema,
        "sample_id": "sample-001",
        "donor_id": client.donor,
        "assay_id": ASSAY,
        "selected_stages": ["stage_a"],
        "objects": [entry for entry, _content in entries],
        "object_count": len(entries),
        "object_bytes": sum(int(entry["bytes"]) for entry, _content in entries),
        "source_epoch_id": "7" * 64,
        "revision_equivalence_evidence_sha256": "8" * 64,
        "stage_dispositions": [_selected_disposition("stage_a")],
    }
    if schema == ROOT_V4:
        root["transport_codec"] = {
            "codec": "gzip",
            "level": 6,
            "zlib_runtime_version": zlib.ZLIB_RUNTIME_VERSION,
        }
    for key, value in (root_overrides or {}).items():
        if value is DROP:
            root.pop(key)
        else:
            root[key] = value
    manifest_bytes = (json.dumps(root, indent=2, sort_keys=True) + "\n").encode()
    object_set = sorted(
        [
            {"path": entry["path"], "bytes": entry["bytes"], "sha256": entry["sha256"]}
            for entry, _content in entries
        ]
        + [{"path": "manifest.json", "bytes": len(manifest_bytes), "sha256": _sha256(manifest_bytes)}],
        key=lambda item: str(item["path"]),
    )
    marker = {
        "schema_version": "donor-results-completion/v3",
        "sample_id": "sample-001",
        "donor_id": client.donor,
        "assay_id": ASSAY,
        "plan_sha256": _sha256(manifest_bytes),
        "destination": {
            "sink": "b2",
            "bucket": "computational-genomics",
            "prefix": f"{client.donor}/{ASSAY}/results",
            "representation": "flat",
        },
        "object_set_sha256": _sha256(
            json.dumps(object_set, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()
        ),
        "object_count": len(object_set),
        "object_bytes": sum(int(item["bytes"]) for item in object_set),
        "published_at": published_at,
    }
    files = {str(entry["path"]): content for entry, content in entries}
    files["manifest.json"] = manifest_bytes
    files["_COMPLETE.json"] = (json.dumps(marker, sort_keys=True) + "\n").encode()
    results_root = Path(client.environment["FAKE_B2_ROOT"]) / client.donor / ASSAY / "results"
    shutil.rmtree(results_root, ignore_errors=True)
    for relative, content in files.items():
        target = results_root / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(content)


def _sync_results(
    client: FakeGenomeSync,
    *arguments: str,
    environment: dict[str, str] | None = None,
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [
            client.command,
            "--dest",
            str(client.destination),
            "--only",
            "results",
            "--yes",
            *arguments,
            client.donor,
        ],
        env=client.environment if environment is None else environment,
        text=True,
        capture_output=True,
        check=False,
    )


def _no_transport_downloads(client: FakeGenomeSync) -> dict[str, str]:
    """Environment under which fetching any .gz object fails the sync."""
    return {**client.environment, "FAKE_B2_FAIL_DOWNLOAD_SUFFIX": ".gz"}


def _results_dir(client: FakeGenomeSync) -> Path:
    return client.destination / ASSAY / "results"


def _assert_no_temp_left(client: FakeGenomeSync) -> None:
    assert not list(client.destination.glob(".genome-download-tmp.*"))


@pytest.mark.parametrize("jobs", ["1", "4"])
def test_v4_package_installs_plain_files_at_logical_paths(
    fake_genome_sync: FakeGenomeSync,
    jobs: str,
) -> None:
    client = fake_genome_sync
    _write_results_snapshot(client, _v4_objects())

    completed = _sync_results(client, "--jobs", jobs)
    assert completed.returncode == 0, completed.stderr + completed.stdout
    results = _results_dir(client)
    for logical_path, content in (("stage_a/big.tsv", BIG_TSV), ("stage_b/table.json", TABLE_JSON)):
        assert (results / logical_path).read_bytes() == content
        assert not (results / f"{logical_path}.gz").exists()
    # A plain object that happens to be gzip bytes is installed exactly as shipped.
    assert (results / "stage_a/calls.vcf.gz").read_bytes() == CALLS_VCF_GZ
    _assert_no_temp_left(client)

    manifest = _manifest(client)
    assert manifest["schema"] == 6
    assert manifest["materialization"]["complete"] is True
    stored = gzip.compress(BIG_TSV, compresslevel=6, mtime=0)
    assert manifest["files"][f"{ASSAY}/results/stage_a/big.tsv"] == {
        "size": len(BIG_TSV),
        "sha256": _sha256(BIG_TSV),
        "remote_sha1": None,
        "proof": "activated_plan_gzip_decoded_sha256_verified",
        "transport": {
            "encoding": "gzip",
            "path": f"{ASSAY}/results/stage_a/big.tsv.gz",
            "bytes": len(stored),
            "sha256": _sha256(stored),
            "remote_sha1": hashlib.sha1(stored, usedforsecurity=False).hexdigest(),
        },
    }
    assert not any(path.endswith(("big.tsv.gz", "table.json.gz")) for path in manifest["files"])
    plain_record = manifest["files"][f"{ASSAY}/results/stage_a/calls.vcf.gz"]
    assert "transport" not in plain_record
    assert plain_record["sha256"] == _sha256(CALLS_VCF_GZ)
    assert plain_record["proof"] == "activated_plan_sha256_verified"
    log = (Path(client.environment["XDG_STATE_HOME"]) / "genome-sync" / "sync.log").read_text()
    assert f"file decode encoding=gzip stored_bytes={len(stored)} logical_bytes={len(BIG_TSV)}" in log
    assert "proof=activated_plan_gzip_decoded_sha256_verified" in log


def test_v4_second_sync_and_relocation_reuse_without_downloading(
    fake_genome_sync: FakeGenomeSync,
) -> None:
    client = fake_genome_sync
    _write_results_snapshot(client, _v4_objects())
    first = _sync_results(client)
    assert first.returncode == 0, first.stderr + first.stdout

    repeated = _sync_results(client, environment=_no_transport_downloads(client))
    assert repeated.returncode == 0, repeated.stderr + repeated.stdout
    assert "0 new · 0 updated" in _plain_text(repeated.stdout)
    record = _manifest(client)["files"][f"{ASSAY}/results/stage_a/big.tsv"]
    assert record["proof"] == "activated_plan_logical_sha256_verified"
    assert record["sha256"] == _sha256(BIG_TSV)
    assert record["transport"]["path"] == f"{ASSAY}/results/stage_a/big.tsv.gz"

    # A snapshot that moves the file is served from the local decoded bytes.
    relocated = [_encoded("stage_c/big.tsv", BIG_TSV), *_v4_objects()[1:]]
    _write_results_snapshot(client, relocated, published_at="2026-10-02T00:00:00Z")
    moved = _sync_results(client, environment=_no_transport_downloads(client))
    assert moved.returncode == 0, moved.stderr + moved.stdout
    assert "1 reused locally" in _plain_text(moved.stdout)
    results = _results_dir(client)
    assert (results / "stage_c/big.tsv").read_bytes() == BIG_TSV
    assert not (results / "stage_c/big.tsv.gz").exists()
    manifest = _manifest(client)
    moved_record = manifest["files"][f"{ASSAY}/results/stage_c/big.tsv"]
    assert moved_record["proof"] == "activated_plan_logical_sha256_verified"
    assert moved_record["transport"]["path"] == f"{ASSAY}/results/stage_c/big.tsv.gz"
    retired = manifest["retained_files"][f"_retained/{ASSAY}/results/stage_a/big.tsv"]
    assert retired["transport"]["path"] == f"{ASSAY}/results/stage_a/big.tsv.gz"


def test_v4_dropped_encoded_file_is_retired_to_attic_and_restored(
    fake_genome_sync: FakeGenomeSync,
) -> None:
    client = fake_genome_sync
    _write_results_snapshot(client, _v4_objects())
    assert _sync_results(client).returncode == 0

    dropped = [item for item in _v4_objects() if item[0]["path"] != "stage_a/big.tsv.gz"]
    _write_results_snapshot(client, dropped, published_at="2026-10-02T00:00:00Z")
    retired = _sync_results(client)
    assert retired.returncode == 0, retired.stderr + retired.stdout
    assert "1 to retire to _retained/" in _plain_text(retired.stdout)
    live = _results_dir(client) / "stage_a/big.tsv"
    attic = client.destination / "_retained" / ASSAY / "results/stage_a/big.tsv"
    assert not live.exists()
    assert attic.read_bytes() == BIG_TSV
    assert not list(client.destination.rglob("big.tsv.gz"))

    manifest = _manifest(client)
    record = manifest["retained_files"][f"_retained/{ASSAY}/results/stage_a/big.tsv"]
    assert record["original_path"] == f"{ASSAY}/results/stage_a/big.tsv"
    assert record["reason"] == "absent_from_active_snapshot"
    assert record["size"] == len(BIG_TSV)
    assert record["sha256"] == _sha256(BIG_TSV)
    assert record["transport"]["path"] == f"{ASSAY}/results/stage_a/big.tsv.gz"
    assert f"{ASSAY}/results/stage_a/big.tsv" not in manifest["files"]
    assert manifest["materialization"]["complete"] is True

    _write_results_snapshot(client, _v4_objects(), published_at="2026-10-03T00:00:00Z")
    restored = _sync_results(client, environment=_no_transport_downloads(client))
    assert restored.returncode == 0, restored.stderr + restored.stdout
    assert "reused locally" in _plain_text(restored.stdout)
    assert live.read_bytes() == BIG_TSV


def test_v4_wrong_logical_sha256_fails_closed_and_keeps_existing_files(
    fake_genome_sync: FakeGenomeSync,
) -> None:
    client = fake_genome_sync
    _write_results_snapshot(client, _v4_objects())
    assert _sync_results(client).returncode == 0
    local_manifest = client.destination / ".genome-manifest.json"
    manifest_before = local_manifest.read_bytes()
    results = _results_dir(client)
    payloads_before = {
        path: (results / path).read_bytes()
        for path in ("stage_a/big.tsv", "stage_a/summary.json", "stage_b/table.json")
    }

    changed = BIG_TSV + b"chr2\t1\tC\tT\t0.10\n"
    lying = _encoded("stage_a/big.tsv", changed, logical_sha256=_sha256(b"not the content"))
    _write_results_snapshot(
        client, _v4_objects(big=lying), published_at="2026-10-02T00:00:00Z"
    )
    failed = _sync_results(client)
    assert failed.returncode == 1
    assert (
        f"decoded SHA-256 violates activated plan for {ASSAY}/results/stage_a/big.tsv"
        in _plain_text(failed.stdout)
    ), failed.stdout + failed.stderr
    for path, content in payloads_before.items():
        assert (results / path).read_bytes() == content, path
    assert not (results / "stage_a/big.tsv.gz").exists()
    assert local_manifest.read_bytes() == manifest_before
    _assert_no_temp_left(client)


@pytest.mark.parametrize(
    ("label", "big", "stderr_fragment"),
    [
        (
            "decodes beyond logical_bytes",
            _encoded("stage_a/big.tsv", BIG_TSV, logical_bytes=len(BIG_TSV) - 1),
            "exceeds the activated logical size",
        ),
        (
            "truncated stream",
            _encoded(
                "stage_a/big.tsv",
                BIG_TSV,
                stored=gzip.compress(BIG_TSV, compresslevel=6, mtime=0)[:400],
            ),
            "not a valid gzip stream",
        ),
        (
            "corrupt CRC trailer",
            _encoded(
                "stage_a/big.tsv",
                BIG_TSV,
                stored=(lambda data: data[:-8] + bytes([data[-8] ^ 0xFF]) + data[-7:])(
                    gzip.compress(BIG_TSV, compresslevel=6, mtime=0)
                ),
            ),
            "not a valid gzip stream",
        ),
    ],
)
def test_v4_bad_transport_stream_fails_closed_at_decode(
    fake_genome_sync: FakeGenomeSync,
    label: str,
    big: tuple[dict[str, object], bytes],
    stderr_fragment: str,
) -> None:
    # The manifest's stored digest is built from these exact bytes, so download
    # verification passes and only the decode can catch the defect.
    client = fake_genome_sync
    _write_results_snapshot(client, _v4_objects(big=big))

    failed = _sync_results(client)
    assert failed.returncode == 1, label
    assert (
        f"gzip transport object failed to decode for {ASSAY}/results/stage_a/big.tsv"
        in _plain_text(failed.stdout)
    ), failed.stdout + failed.stderr
    assert stderr_fragment in failed.stderr, failed.stderr
    assert not (_results_dir(client) / "stage_a/big.tsv").exists()
    assert not (_results_dir(client) / "stage_a/big.tsv.gz").exists()
    assert not (client.destination / ".genome-manifest.json").exists()
    _assert_no_temp_left(client)


def test_v3_package_still_syncs_unchanged(fake_genome_sync: FakeGenomeSync) -> None:
    client = fake_genome_sync
    objects = [
        _plain("stage_a/big.tsv", BIG_TSV),
        _plain("stage_a/calls.vcf.gz", CALLS_VCF_GZ),
        _plain("stage_a/summary.json", SUMMARY_JSON),
    ]
    _write_results_snapshot(client, objects, schema=ROOT_V3)

    completed = _sync_results(client)
    assert completed.returncode == 0, completed.stderr + completed.stdout
    results = _results_dir(client)
    manifest = _manifest(client)
    for path, content in (
        ("stage_a/big.tsv", BIG_TSV),
        ("stage_a/calls.vcf.gz", CALLS_VCF_GZ),
        ("stage_a/summary.json", SUMMARY_JSON),
    ):
        assert (results / path).read_bytes() == content
        assert manifest["files"][f"{ASSAY}/results/{path}"] == {
            "size": len(content),
            "sha256": _sha256(content),
            "remote_sha1": hashlib.sha1(content, usedforsecurity=False).hexdigest(),
            "proof": "activated_plan_sha256_verified",
        }
    assert not any("transport" in record for record in manifest["files"].values())
    for asset, content in RESULTS_ASSETS.items():
        assert (client.destination / asset).read_bytes() == content


@pytest.mark.parametrize(
    ("objects", "schema", "stderr_fragment"),
    [
        (
            [_plain("stage_a/big.tsv", BIG_TSV), _encoded("stage_a/big.tsv", BIG_TSV)],
            ROOT_V4,
            "results logical path collides with another object",
        ),
        (
            [_encoded("stage_a/x", b"x" * 100), _encoded("stage_a/x.gz", b"y" * 100)],
            ROOT_V4,
            "results logical path collides with another object",
        ),
        (
            [_encoded("stage_a/big.tsv", BIG_TSV, logical_path="stage_a/other.tsv")],
            ROOT_V4,
            "transport path is not its logical path plus .gz",
        ),
        (
            [_encoded("manifest.json", b"{}" * 50)],
            ROOT_V4,
            "encodes a reserved name",
        ),
        (
            [_encoded("stage_a/big.tsv", BIG_TSV, encoding="zstd")],
            ROOT_V4,
            "unsupported transport encoding",
        ),
        (
            [_encoded("stage_a/big.tsv", BIG_TSV)],
            ROOT_V3,
            "results root manifest object has an unexpected schema",
        ),
    ],
    ids=[
        "plain-object-at-logical-path",
        "logical-path-names-stored-object",
        "path-not-logical-plus-gz",
        "reserved-name-encoded",
        "unsupported-encoding",
        "encoded-object-in-v3",
    ],
)
def test_v4_transport_invariant_violations_are_rejected(
    fake_genome_sync: FakeGenomeSync,
    objects: list,
    schema: str,
    stderr_fragment: str,
) -> None:
    client = fake_genome_sync
    _write_results_snapshot(client, objects, schema=schema)

    failed = _sync_results(client)
    assert failed.returncode == 1
    assert "violated the donor contract" in _plain_text(failed.stdout)
    assert stderr_fragment in failed.stderr, failed.stderr
    assert not (client.destination / ASSAY).exists()
    assert not (client.destination / ".genome-manifest.json").exists()


@pytest.mark.parametrize(
    ("transport_codec", "stderr_fragment"),
    [
        (DROP, "results root manifest has an unexpected schema"),
        ({"codec": "zstd", "level": 3}, "transport codec is not gzip"),
    ],
    ids=["missing", "not-gzip"],
)
def test_v4_requires_a_gzip_transport_codec(
    fake_genome_sync: FakeGenomeSync,
    transport_codec: object,
    stderr_fragment: str,
) -> None:
    client = fake_genome_sync
    _write_results_snapshot(
        client, _v4_objects(), root_overrides={"transport_codec": transport_codec}
    )

    failed = _sync_results(client)
    assert failed.returncode == 1
    assert "violated the donor contract" in _plain_text(failed.stdout)
    assert stderr_fragment in failed.stderr, failed.stderr
    assert not (client.destination / ".genome-manifest.json").exists()


def _system_python3_older_than_310() -> str | None:
    """The engine runs embedded Python on the donor's first python3; on macOS that
    can be the stock /usr/bin/python3 (3.9). Return it when it is pre-3.10."""
    candidate = Path("/usr/bin/python3")
    if not candidate.exists():
        return None
    probe = subprocess.run(
        [str(candidate), "-c", "import sys; print(sys.version_info < (3, 10))"],
        capture_output=True,
        text=True,
        check=False,
    )
    return str(candidate) if probe.stdout.strip() == "True" else None


def test_repeat_v4_sync_runs_on_a_pre_310_system_python3(
    fake_genome_sync: FakeGenomeSync,
    tmp_path: Path,
) -> None:
    # Regression: an unquoted `str | None` annotation in the local-index step made
    # every repeat sync into a non-empty folder die with TypeError on Python 3.9.
    stock = _system_python3_older_than_310()
    if stock is None:
        pytest.skip("no pre-3.10 system python3 on this machine")
    client = fake_genome_sync
    shim = tmp_path / "stock-python"
    shim.mkdir()
    (shim / "python3").symlink_to(stock)
    environment = {
        **client.environment,
        "PATH": f"{shim}{os.pathsep}{client.environment['PATH']}",
    }
    _write_results_snapshot(client, _v4_objects())
    first = _sync_results(client, environment=environment)
    assert first.returncode == 0, first.stderr + first.stdout
    repeated = _sync_results(client, environment=environment)
    assert repeated.returncode == 0, repeated.stderr + repeated.stdout
    assert "0 new · 0 updated" in _plain_text(repeated.stdout)
    assert (_results_dir(client) / "stage_a/big.tsv").read_bytes() == BIG_TSV
