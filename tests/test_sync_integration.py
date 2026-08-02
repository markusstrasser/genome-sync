from __future__ import annotations

import json
import os
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


def _setup(client: FakeGenomeSync, omit: str) -> subprocess.CompletedProcess[str]:
    completed = _run(
        client,
        "setup",
        "--dest",
        str(client.destination),
        "--only",
        "lab",
        "--omit-large",
        omit,
        "--yes",
        client.donor,
    )
    assert completed.returncode == 0, completed.stderr + completed.stdout
    return completed


def _manifest(client: FakeGenomeSync) -> dict[str, object]:
    return json.loads((client.destination / ".genome-manifest.json").read_text())


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
    assert "omitted_large_paths=[]" in completed.stdout


def test_interactive_setup_and_sync_prefill_saved_choices(
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
    setup.expect("Largest optional payloads:")
    setup.expect("Numbers to omit.*\\[none\\]")
    setup.sendline("1,3")
    setup.expect("Apply this verified update?.*\\[Y/n\\]")
    setup.sendline("y")
    setup.expect(pexpect.EOF)
    setup.close()
    assert setup.exitstatus == 0

    config = json.loads(client.config_file.read_text())
    assert config["only"] == "lab"
    assert config["destination"] == str(client.destination)
    assert config["omitted_large_paths"] == [
        "shortread/lab/payload-1.bin",
        "shortread/lab/payload-3.bin",
    ]

    sync = pexpect.spawn(
        str(client.command),
        [],
        env=client.environment,
        encoding="utf-8",
        timeout=15,
    )
    sync.expect("What should be synced?.*\\[lab only\\]")
    sync.sendline("")
    sync.expect("Largest optional payloads:")
    sync.expect("Numbers to omit.*\\[1,3\\]")
    assert "[omit]" in sync.before
    assert "payload-1.bin" in sync.before
    sync.sendline("")
    sync.expect("Apply this verified update?.*\\[Y/n\\]")
    sync.sendline("n")
    sync.expect("No files changed")
    sync.expect(pexpect.EOF)
    sync.close()
    assert sync.exitstatus == 0


def test_omitted_payload_can_be_added_later(fake_genome_sync: FakeGenomeSync) -> None:
    client = fake_genome_sync
    _setup(client, "1")
    largest = client.destination / "shortread" / "lab" / "payload-1.bin"
    assert not largest.exists()
    partial = _manifest(client)
    assert partial["materialization"]["complete"] is False
    assert "shortread/lab/payload-1.bin" in partial["omitted_files"]
    assert "shortread/lab/payload-1.bin" not in partial["files"]
    assert partial["materialization"]["verified_remote_file_count"] == len(
        partial["files"]
    ) + len(partial["omitted_files"])
    assert "shortread/lab/lab_manifest.json" in partial["files"]
    assert "shortread/lab/_COMPLETE.json" in partial["files"]

    completed = _run(client, "sync", "--omit-large", "none", "--yes")
    assert completed.returncode == 0, completed.stderr + completed.stdout
    assert largest.read_bytes() == client.payloads["shortread/lab/payload-1.bin"]
    complete = _manifest(client)
    assert complete["materialization"]["complete"] is True
    assert complete["omitted_files"] == {}
    config = json.loads(client.config_file.read_text())
    assert config["omitted_large_paths"] == []


def test_deselecting_downloaded_payload_never_deletes_it(
    fake_genome_sync: FakeGenomeSync,
) -> None:
    client = fake_genome_sync
    _setup(client, "none")
    largest = client.destination / "shortread" / "lab" / "payload-1.bin"
    original = largest.read_bytes()

    completed = _run(client, "sync", "--omit-large", "1", "--yes")
    assert completed.returncode == 0, completed.stderr + completed.stdout
    assert largest.read_bytes() == original
    assert "to remove" not in completed.stdout
    partial = _manifest(client)
    assert partial["materialization"]["complete"] is False
    assert "shortread/lab/payload-1.bin" in partial["omitted_files"]
    assert "shortread/lab/payload-1.bin" not in partial["files"]
