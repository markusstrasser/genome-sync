from __future__ import annotations

import hashlib
import os
import signal
import subprocess
import time
from importlib import resources
from pathlib import Path


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
