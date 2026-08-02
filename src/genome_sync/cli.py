"""Console entry point for the bundled genome-sync Bash client."""

from __future__ import annotations

import os
import shutil
import sys
from importlib import resources
from typing import NoReturn


def main() -> NoReturn:
    """Replace this process with Bash running the bundled client."""

    bash = shutil.which("bash")
    if bash is None:
        print("error: genome-sync requires Bash", file=sys.stderr)
        raise SystemExit(127)

    bundled_script = resources.files("genome_sync").joinpath("download-genome.sh")
    with resources.as_file(bundled_script) as script_path:
        os.execv(bash, [bash, str(script_path), *sys.argv[1:]])

    raise AssertionError("os.execv returned unexpectedly")
