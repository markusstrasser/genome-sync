# genome-sync

`genome-sync` installs the fail-closed donor download client as a normal Python
console command while keeping the synchronization engine in its audited Bash
form. The Python entry point replaces itself with Bash, so signals and exit
codes come directly from the bundled client.

This repository is the client's only home. It began as a copy of a downloader
tracked in the genomics repository; that copy and its secret-gist delivery path
were deleted on 2026-08-06, because maintaining the same client in three places
produced three different versions and shipped donors bytes that could never be
updated.

## Install

**Nothing to install.** `uvx` fetches and runs the published client in one command:

```bash
B2_APPLICATION_KEY_ID=... B2_APPLICATION_KEY=... \
  uvx --from git+https://github.com/markusstrasser/genome-sync@released \
  genome-sync --dest ~/Downloads/donor-id-genome donor-id --dry-run
```

Drop `--dry-run` to write. That is the whole client — no install step, no
`setup`, no stored credential; the key is supplied per invocation and the
destination is explicit. This is the fastest way to get a donor their data and
the fastest way to test a change.

`@released` is the pin donors resolve. A push to `main` ships nothing; promoting
`main` to `released` is the release.

### Installing instead (optional, for offline resilience)

```bash
uv tool install --force git+https://github.com/markusstrasser/genome-sync@released
genome-sync setup donor-id      # stores the key in the OS credential service
```

The only thing installing buys is working **offline**: `uvx --from git+https://…`
resolves the repository on every run and hard-fails without network even with a
warm cache, whereas an installed client runs with no resolution at all. Online —
the normal case — the two are equivalent, and `uvx` was verified against a real
donor snapshot on 2026-08-06 producing byte-identical output to the installed
client.

An installed client still re-resolves this repository on each invocation, so
donors never upgrade by hand; that refresh is best-effort and its failure costs a
newer client, never the ability to sync. `GENOME_SYNC_NO_SELF_UPDATE=1` disables
it.

## Configure and synchronize

```bash
B2_APPLICATION_KEY_ID=... B2_APPLICATION_KEY=... \
  genome-sync setup donor-id

genome-sync
genome-sync status
```

Which sections to sync — `results`, `lab`, or `both` — is the only selection.
Setup asks it and remembers the answer alongside the destination; every later
interactive sync shows that saved answer and accepts a one-run override. The
one-off form asks the same question, defaulting to `both`, so a run that was
never configured still states what it is about to download rather than assuming
it. Automation passes `--only` / `--exclude`, or `--yes` to take the saved
answer unprompted.

Setup also asks where to save the data. A first setup suggests
`<donor>-genome` inside the operating system's own Downloads folder: macOS
`~/Downloads`, the Windows Downloads known folder (which may have been moved to
another drive or OneDrive), or the XDG download directory on Linux. When that
folder does not exist, as on a headless machine, it suggests
`~/<donor>-genome`. A repeated setup suggests the saved destination.

The selected sections are downloaded whole. There is no per-file picking: a
donor either has a section or does not.

Large text files travel compressed and are unpacked and verified on arrival. A
`donor-root-export-manifest/v4` snapshot may ship one gzip-encoded; the client
checks the download, unpacks it with Python's standard library (capped at the
declared size), and installs the plain file only once its size and SHA-256
match the pipeline's. The local folder holds plain readable files, never `.gz`
transport copies; the file's `.genome-manifest.json` record describes the plain
bytes and names the stored object under `transport`.

```bash
genome-sync sync --only results --yes
genome-sync --dest ~/Downloads/donor-id-genome donor-id      # asks results / lab / both
```

`.genome-manifest.json` schema 6 separates the validated remote activation from
local materialization through `materialization`, `unavailable_files`,
`retained_files`, and per-assay `local_materialization_complete` fields. Files
carried from a section outside the current sync are rehashed before being
carried forward; missing or corrupt files move to `unavailable_files` and force
materialization incomplete.

The client checks package currency before downloading results and rechecks the
activation evidence before writing the local descriptor. A remote
`<assay>/results/_WITHDRAWN.json` names the exact withdrawn or superseded plan and
its reason. Sync refuses that plan and preserves the notice privately in
`.genome-withdrawals.json`, even when `_COMPLETE.json` has been removed. A notice
already observed locally continues to block that same plan if the remote notice
later disappears. `--dry-run` reports the refusal without recording it.

Notices remain as history when a different verified plan replaces the withdrawn
one, and `--prune` does not delete them. Read this file together with the exact
`active_results[assay].plan_sha256` before interpreting a local copy. Raw/lab-only
sync is independent of results withdrawal. An offline copy cannot learn a
withdrawal until it reconnects. Downloads replace individual files; a failed
final currency check leaves no new activation descriptor and does not promise
an atomic rollback of already transferred files. Before changing selected
results, the client atomically marks the prior descriptor's global
`materialization.complete` and prior active-result validation/materialization
flags false, retaining the old plan identities and file records as history.
An interrupted update may leave mixed bytes: require
`active_results[assay].remote_activation_validated=true` before treating local
results as activated. A false completeness flag forbids a whole-package
completeness claim; when remote validation is true, explicitly verified present
files remain usable under the partial-materialization rules. Only a successful
results recheck and hash-based descriptor rebuild restore validation and
completeness. Lab-only updates cannot recertify interrupted results.

Retention is the default, and retained files live in a **retention attic**. A
previously managed file that the new active snapshot no longer names keeps its
bytes but is moved to `_retained/<original path>` and recorded in
`retained_files` (keyed by attic path, carrying `original_path`). After a
validated, complete sync the live tree outside `_retained/` matches the active
snapshot. Readers must check the descriptor flags before relying on that claim;
retained bytes are outside the activation. `_retained/README.md` states this in
place. A snapshot that re-adds a
retained file restores it from the attic without re-downloading. Deleting
retained bytes is a separate explicit choice:

```bash
genome-sync sync --prune
```

This split exists because unconditional pruning is not safe against a bad remote
plan: on 2026-07-29 a broken 32-stage active plan pruned a donor's 15.15 GB
local snapshot down to 0.78 GB. A move is reversible where a delete is not, so
the attic keeps the incident-guard while keeping the live tree honest. Pre-attic
(schema 5) manifests migrate on the next sync of each section: in-place retained
files are moved into the attic then.

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
choices, the section question on both the configured and one-off paths, reading
a pre-v4 config, retention-by-default (retired into `_retained/` and kept across
repeated syncs, restored from the attic when a snapshot re-adds a file, removed
only under `--prune`, corrupt leftovers disclosed as unavailable),
and concurrent downloads (`--jobs 4` lands every object with correct bytes,
`--jobs 4` and `--jobs 1` produce identical manifest records, a mid-run fetch
failure still fails closed without replacing pre-existing files, and out-of-range
or non-numeric `--jobs` values are rejected) without contacting Backblaze. It
also covers v4 gzip transport: decoded installs at logical paths, decode
failures that leave existing files untouched (wrong digest, oversized output,
truncated or corrupt stream), reuse without re-downloading, the attic, and
rejected manifests.
