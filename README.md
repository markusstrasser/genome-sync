# genome-sync

`genome-sync` installs the fail-closed donor download client as a normal Python
console command while keeping the synchronization engine in its audited Bash
form. The Python entry point replaces itself with Bash, so signals and exit
codes come directly from the bundled client.

The initial bundled resource was copied byte-for-byte from the tracked
`scripts/donor/download-genome.sh` in the genomics repository. Its baseline
SHA-256 is recorded in `src/genome_sync/UPSTREAM_SHA256`; later package changes
extend that client in place.

## Install from this checkout

```bash
uv tool install /Users/alien/Projects/genome-sync
genome-sync --help
```

This repository currently supports local-path installation. It is not yet
published to a package index.

## Development

```bash
uv build
uv run pytest
```
