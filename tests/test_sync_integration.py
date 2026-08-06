from __future__ import annotations

import hashlib
import json
import os
import re
import subprocess

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
    assert manifest["schema"] == 5
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


def test_absent_remote_file_is_retained_by_default(
    fake_genome_sync: FakeGenomeSync,
) -> None:
    client = fake_genome_sync
    _setup(client)
    _seed_absent_remote_lab_file(client, RETIRED_RELATIVE, RETIRED_CONTENT)
    retired_path = client.destination / RETIRED_RELATIVE

    completed = _run(client, "sync", "--yes")
    assert completed.returncode == 0, completed.stderr + completed.stdout
    assert "1 kept (no longer in the active snapshot)" in completed.stdout
    assert "to remove" not in completed.stdout
    assert retired_path.read_bytes() == RETIRED_CONTENT

    manifest = _manifest(client)
    assert manifest["schema"] == 5
    assert RETIRED_RELATIVE not in manifest["files"]
    assert RETIRED_RELATIVE not in manifest["unavailable_files"]
    retained = manifest["retained_files"][RETIRED_RELATIVE]
    assert retained["size"] == len(RETIRED_CONTENT)
    assert retained["sha256"] == hashlib.sha256(RETIRED_CONTENT).hexdigest()
    assert retained["proof"] == "activated_plan_sha256_verified"
    assert retained["reason"] == "absent_from_active_snapshot"
    assert manifest["materialization"]["retained_file_count"] == 1
    assert manifest["materialization"]["retained_bytes"] == len(RETIRED_CONTENT)
    assert manifest["materialization"]["complete"] is True

    repeated = _run(client, "sync", "--yes")
    assert repeated.returncode == 0, repeated.stderr + repeated.stdout
    assert retired_path.read_bytes() == RETIRED_CONTENT
    assert RETIRED_RELATIVE in _manifest(client)["retained_files"]


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
    assert "kept (no longer in the active snapshot)" not in completed.stdout
    assert not retired_path.exists()

    manifest = _manifest(client)
    assert manifest["retained_files"] == {}
    assert RETIRED_RELATIVE not in manifest["files"]
    assert RETIRED_RELATIVE not in manifest["unavailable_files"]
    assert manifest["materialization"]["retained_file_count"] == 0
    assert manifest["materialization"]["complete"] is True


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
    assert retired_path.read_bytes() == corrupted

    manifest = _manifest(client)
    assert RETIRED_RELATIVE not in manifest["retained_files"]
    assert RETIRED_RELATIVE not in manifest["files"]
    unavailable = manifest["unavailable_files"][RETIRED_RELATIVE]
    assert unavailable["reason"] == "local_sha256_mismatch"
    assert unavailable["retained"] is True
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
