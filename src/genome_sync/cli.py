"""Console entry point for the bundled genome-sync Bash client.

Donors run this once every few months and never upgrade anything by hand, so the
client refreshes itself from the published source before each sync. The refresh
is deliberately best-effort: `uv tool install --force` re-resolves the tracked
branch on every call, but the already-installed client runs with no resolution at
all, so an unreachable GitHub costs the donor a newer client — never the ability
to synchronize data that lives in B2.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
from importlib import resources
from pathlib import Path
from typing import NoReturn

# Donors track `released`, never `main`. `main` is a candidate branch: a commit only
# reaches a donor once `just donor-client-release` (in the genomics repo) has run both
# this package's suite and the producer-consumer contract suite against it. That gate
# exists because a commit can pass this repository's tests and still be wrong — the
# 2026-08-06 prefetch change leaked b2 processes and only the contract suite caught it.
# Rollback is `git branch -f released <good-sha>`, with no new code.
SOURCE = "git+https://github.com/markusstrasser/genome-sync@released"
DISABLE_VARIABLE = "GENOME_SYNC_NO_SELF_UPDATE"
REFRESH_TIMEOUT_SECONDS = 60


def _is_development_checkout() -> bool:
    """True when imported from the source tree rather than an installed tool.

    An installed wheel lives at `<env>/lib/pythonX.Y/site-packages/genome_sync/`,
    whose grandparent holds no `pyproject.toml`. The `src/genome_sync/` checkout's
    grandparent is the repository root, which does. Refreshing from there would
    install the published client over a developer's working copy.
    """

    return (Path(__file__).resolve().parents[2] / "pyproject.toml").is_file()


def _refresh_from_source() -> None:
    """Best-effort upgrade to the newest published client.

    Every failure mode here is non-fatal by design: no `uv`, no network, a GitHub
    outage, a timeout, or a broken publish must not stop a donor from syncing the
    client they already have.
    """

    if os.environ.get(DISABLE_VARIABLE):
        return
    if _is_development_checkout():
        return
    uv_executable = shutil.which("uv")
    if uv_executable is None:
        return
    try:
        subprocess.run(
            [uv_executable, "tool", "install", "--force", "--quiet", SOURCE],
            timeout=REFRESH_TIMEOUT_SECONDS,
            capture_output=True,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return


def main() -> NoReturn:
    """Refresh the client, then replace this process with Bash running it."""

    bash = shutil.which("bash")
    if bash is None:
        print("error: genome-sync requires Bash", file=sys.stderr)
        raise SystemExit(127)

    # `--help` stays instant, and the refresh cannot mask a usage error.
    arguments = sys.argv[1:]
    if not any(argument in {"-h", "--help"} for argument in arguments):
        _refresh_from_source()

    # Resolved after the refresh so the exec picks up replaced bytes. A refresh
    # that changes this file takes effect now; one that changes the Python
    # wrapper takes effect on the next invocation.
    bundled_script = resources.files("genome_sync").joinpath("download-genome.sh")
    with resources.as_file(bundled_script) as script_path:
        if not script_path.is_file():
            print(f"error: bundled client is missing: {script_path}", file=sys.stderr)
            raise SystemExit(127)
        os.execv(bash, [bash, str(script_path), *arguments])

    raise AssertionError("os.execv returned unexpectedly")
