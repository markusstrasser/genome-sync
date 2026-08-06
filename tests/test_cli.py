from __future__ import annotations

import hashlib
import os
import signal
import subprocess
import time
from importlib import resources
from pathlib import Path

import pytest

from genome_sync import cli


def _fake_uv(directory: Path, body: str) -> Path:
    """Install a fake `uv` on PATH so no test ever reaches the network."""

    directory.mkdir(parents=True, exist_ok=True)
    executable = directory / "uv"
    executable.write_text(f"#!/usr/bin/env bash\n{body}\n", encoding="utf-8")
    executable.chmod(0o700)
    return executable


def test_source_tree_is_detected_as_a_development_checkout() -> None:
    # This is what keeps the suite off the network: an editable install resolves
    # to src/genome_sync/, whose grandparent holds pyproject.toml.
    assert cli._is_development_checkout() is True


def test_refresh_is_skipped_for_a_development_checkout(tmp_path: Path) -> None:
    marker = tmp_path / "ran"
    _fake_uv(tmp_path / "bin", f"touch {marker}")
    environment = dict(os.environ, PATH=str(tmp_path / "bin"))
    with pytest.MonkeyPatch.context() as patch:
        for name, value in environment.items():
            patch.setenv(name, value)
        patch.delenv(cli.DISABLE_VARIABLE, raising=False)
        cli._refresh_from_source()
    assert not marker.exists()


def test_refresh_is_skipped_when_explicitly_disabled(tmp_path: Path) -> None:
    marker = tmp_path / "ran"
    _fake_uv(tmp_path / "bin", f"touch {marker}")
    with pytest.MonkeyPatch.context() as patch:
        patch.setenv("PATH", str(tmp_path / "bin"))
        patch.setenv(cli.DISABLE_VARIABLE, "1")
        patch.setattr(cli, "_is_development_checkout", lambda: False)
        cli._refresh_from_source()
    assert not marker.exists()


@pytest.mark.parametrize(
    "body",
    [
        "exit 1",  # a failed publish or resolution error
        "echo 'fatal: unable to access' >&2; exit 128",  # GitHub unreachable
    ],
)
def test_refresh_failure_is_never_fatal(tmp_path: Path, body: str) -> None:
    # The donor's data lives in B2. A GitHub problem must cost them a newer
    # client, never the ability to synchronize.
    _fake_uv(tmp_path / "bin", body)
    with pytest.MonkeyPatch.context() as patch:
        patch.setenv("PATH", str(tmp_path / "bin"))
        patch.delenv(cli.DISABLE_VARIABLE, raising=False)
        patch.setattr(cli, "_is_development_checkout", lambda: False)
        cli._refresh_from_source()  # must return, not raise


def test_refresh_timeout_is_never_fatal(tmp_path: Path) -> None:
    _fake_uv(tmp_path / "bin", "sleep 30")
    with pytest.MonkeyPatch.context() as patch:
        patch.setenv("PATH", str(tmp_path / "bin"))
        patch.delenv(cli.DISABLE_VARIABLE, raising=False)
        patch.setattr(cli, "_is_development_checkout", lambda: False)
        patch.setattr(cli, "REFRESH_TIMEOUT_SECONDS", 1)
        started = time.monotonic()
        cli._refresh_from_source()  # must return, not hang or raise
        assert time.monotonic() - started < 20


def test_refresh_without_uv_on_path_is_never_fatal(tmp_path: Path) -> None:
    empty = tmp_path / "empty"
    empty.mkdir()
    with pytest.MonkeyPatch.context() as patch:
        patch.setenv("PATH", str(empty))
        patch.delenv(cli.DISABLE_VARIABLE, raising=False)
        patch.setattr(cli, "_is_development_checkout", lambda: False)
        cli._refresh_from_source()  # must return, not raise


def test_published_source_is_the_public_repository() -> None:
    assert cli.SOURCE == "git+https://github.com/markusstrasser/genome-sync"


def test_bundled_client_is_the_checkout_resource() -> None:
    checkout = Path(__file__).parents[1] / "src" / "genome_sync" / "download-genome.sh"
    installed = resources.files("genome_sync").joinpath("download-genome.sh").read_bytes()
    assert hashlib.sha256(installed).digest() == hashlib.sha256(checkout.read_bytes()).digest()


def test_console_preserves_bash_exit_code() -> None:
    command = Path(os.environ["VIRTUAL_ENV"]) / "bin" / "genome-sync"
    completed = subprocess.run(
        [command, "--definitely-not-an-option"],
        text=True,
        capture_output=True,
        check=False,
    )
    assert completed.returncode == 1
    assert "unknown option" in completed.stderr


def test_console_process_receives_signals_after_exec(tmp_path: Path) -> None:
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    fake_bash = fake_bin / "bash"
    fake_bash.write_text(
        "#!/usr/bin/python3\nimport time\ntime.sleep(60)\n",
        encoding="utf-8",
    )
    fake_bash.chmod(0o700)
    command = Path(os.environ["VIRTUAL_ENV"]) / "bin" / "genome-sync"
    environment = os.environ.copy()
    environment["PATH"] = str(fake_bin)
    process = subprocess.Popen([command, "--help"], env=environment)
    try:
        time.sleep(0.2)
        os.kill(process.pid, signal.SIGTERM)
        assert process.wait(timeout=5) == -signal.SIGTERM
    finally:
        if process.poll() is None:
            process.kill()
