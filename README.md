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

## Configure and synchronize

```bash
B2_APPLICATION_KEY_ID=... B2_APPLICATION_KEY=... \
  genome-sync setup donor-id

genome-sync
genome-sync status
```

Setup preserves the existing destination and `results`, `lab`, or `both`
preference. Every later interactive sync displays those saved choices. After
the remote activation records and manifests have been validated, it also shows
the five largest optional payloads. The prompt accepts comma-separated numbers
to omit; pressing Enter keeps the previous omission set, and `none` includes
everything.

Automation can make the same choice explicitly:

```bash
genome-sync sync --omit-large 1,3 --yes
genome-sync sync --omit-large none --yes
```

An omitted payload can be added on any later run. Deselecting one never removes
an already downloaded copy. `.genome-manifest.json` schema 5 separates the
validated remote activation from local materialization through
`materialization`, `omitted_files`, `unavailable_files`, `retained_files`, and
per-assay `local_materialization_complete` fields. Omitted payloads are not
included in the manifest's `files` map. Files carried from a section outside the
current sync are rehashed before being carried forward; missing or corrupt files
move to `unavailable_files` and force materialization incomplete. Activation
markers and remote manifests are control files: they remain mandatory and cannot
be deselected.

Retention is the default. A previously managed file that the new active snapshot
no longer names stays on disk and moves to `retained_files` — recorded apart from
`files` so nothing reads it as part of that snapshot, and never citable as
activated evidence. Deleting those files is a separate explicit choice:

```bash
genome-sync sync --prune
```

This exists because unconditional pruning is not safe against a bad remote plan:
on 2026-07-29 a broken 32-stage active plan pruned a donor's 15.15 GB local
snapshot down to 0.78 GB.

## Concurrent downloads

Object downloads run concurrently. `--jobs N` (default 4, range 1..16) bounds how
many objects are fetched in parallel:

```bash
genome-sync sync --jobs 8 --yes
```

Only the network fetch is parallel. Worker processes download each object into a
private temp file under the download workspace and never touch the destination
tree; the main process still consumes items in snapshot order and runs the same
serial size + SHA-1 + SHA-256 verification, no-follow tree validation, and atomic
replacement for every object, exactly as it did serially. A worker fetch failure
fails the whole sync closed, leaving existing files unreplaced. Prefetch depth is
capped at N objects, so temp usage never exceeds the serial peak by more than the
extra in-flight objects. `--jobs 1` is the fully serial path. Each `b2 file
download` also uses `--max-download-streams-per-file`, so a single large object is
fetched over multiple streams even at `--jobs 1`.

The existing security boundary remains in the bundled client: canonical donor
and relative paths, no-follow destination traversal, private atomic config and
log writes, OS credential storage, exact B2 prefix checks, activation rollback
protection, and size/SHA verification before atomic replacement.

## Development

```bash
uv build
uv run pytest
```

The integration suite uses a deterministic local B2 double. It covers saved
choices, partial-manifest honesty, adding an omitted payload later, the
no-delete-on-deselect invariant, retention-by-default (kept across repeated
syncs, removed only under `--prune`, corrupt leftovers disclosed as unavailable),
and concurrent downloads (`--jobs 4` lands every object with correct bytes,
`--jobs 4` and `--jobs 1` produce identical manifest records, a mid-run fetch
failure still fails closed without replacing pre-existing files, and out-of-range
or non-numeric `--jobs` values are rejected) without contacting Backblaze.
