# Interactive selection defects — observed 2026-08-06 on a real syn6 sync

Both reproduce with the no-install one-off form:

    B2_... uvx --from git+https://github.com/markusstrasser/genome-sync@released \
      genome-sync --dest /Volumes/2TBPNY/syn6-genome syn6

## 1. The one-off form never asks results vs lab vs both — FIXED

Observed output: `Selection:   results and lab` — printed as a fact, never asked.

`download-genome.sh:459` sets `configured_selection="results and lab"` as the
fallback when neither `--only` nor `--exclude` is given. In the CONFIGURED path
that is a saved preference the donor chose at `setup`. In the ONE-OFF path there
is no config, so the same fallback silently commits the donor to both classes —
here, 17.5 GB of raw CRAM/gVCF they were never asked about.

Fix: in the one-off path, when stdin/stdout are a TTY and neither `--only` nor
`--exclude` was passed, prompt for results / lab / both before inventory. Keep the
current fallback for non-TTY and `--yes`.

**Fixed as described.** The section prompt's gate now fires for `one-off` as well as
`sync`, reusing the same prompt loop. A one-off has no saved answer, so it displays
`both` — Enter still gets everything, but as an answer rather than a fallback.
Non-TTY and `--yes` are untouched. Covered by
`test_one_off_run_asks_which_sections_to_sync` and
`test_one_off_honours_an_explicit_section_without_asking`.

## 2. The "largest optional payloads" list mixes lab and results — RESOLVED BY REMOVAL

Observed:

    1. [include] 14.5 GB · syn6sr/lab/...cram
    2. [include]  3.0 GB · syn6sr/lab/...gvcf.gz
    3. [include]  2.7 GB · syn6sr/results/opencravat/syn6sr.sqlite
    4. [include]  1.9 GB · syn6sr/results/opencravat/syn6sr.tsv
    5. [include]  1.4 GB · syn6sr/results/alphagenome/...parquet

The list is built at `download-genome.sh:~1988` from all selected rows sorted by
size, so the two lab payloads consume 2 of 5 slots. Lab is one CRAM plus one gVCF
— the donor already decided about those in (1). Spending the omit list on them
crowds out the results payloads it exists to trim, and there is no way to see the
6th-largest result.

Fix: compute the top-N list within the RESULTS class only. Lab is a class-level
choice, not a per-file one. If `--only lab` is selected, either skip the list
entirely or list lab payloads explicitly labelled as such — but never interleave
the two classes in one numbered set.

**Resolved by removing the feature, not by fixing the ranking.** The operator's call:
per-file picking was ceremony on every sync to serve a rare case, and the numbered
list was the wrong instrument for it either way. `--omit-large`, the ranking pass, the
list, and the `Numbers to omit` prompt are gone; a sync downloads the selected sections
whole. The config schema drops the saved-omission key (`v3` → `v4`; a v3 file on disk
still loads, ignoring the key). Manifest schema 5 is unchanged — `materialization`,
`omitted_files`, `unavailable_files` and `retained_files` are still written, and with
nothing omittable they simply report complete.

## Why these mattered together

(1) silently opted the donor into 17.5 GB, and (2) then denied them the tool to
trim what they did want. Section choice — now asked on every interactive path —
is the whole answer that remains: a donor who wants results-only can say so, and
per-file trimming is deliberately not offered.

Neither is a data-integrity defect: retention, hashing and the completion gate all
behaved correctly on the same run (985 superseded files were kept, not pruned;
plan a9994eaa6df6 matched the freshly published snapshot).

## Defect 3 — a missing donor arg silently uses the last-synced donor, even against a key scoped elsewhere

Observed 2026-08-06 by the operator, dogfooding syn6's donor command.

    uvx --from git+…@released genome-sync        # no positional donor
    →  Your genome data — jw
       Destination: /Volumes/2TBPNY/jw-genome
       Source:      b2://computational-genomics/jw/
    →  ERROR: unauthorized … restricted to files that start with 'syn6/'

`jw` came from `~/.config/genome-sync/config.json` (the operator's own saved setup),
not from anything remote. **No cross-donor exposure is possible:** with no config the
client exits at `download-genome.sh:177`, and a donor arg that contradicts the config is
refused at :410. There is no server-side donor discovery. The B2 key was additionally
prefix-restricted, so the listing failed server-side too.

The defect is the asymmetry: an explicit **mismatched** donor is refused, a **missing**
one is silently filled from config (:390). That is fine for a donor — one identity per
machine — and wrong for the operator, who holds several. With a master key rather than a
syn6-scoped one, this run would have silently synced jw with no error at all.

**Intended behaviour.** B2's own authorization response carries the key's `namePrefix`
(the failure message already prints it). Compare it to the selected donor before planning
and fail with the instruction rather than the symptom:

    this key is scoped to syn6/, but the saved configuration selects donor jw
    pass the donor explicitly:  genome-sync syn6

Fixing the message is enough; do not remove the config fallback, which is the normal
donor path. Requiring the positional donor whenever credentials are supplied through the
environment (the uvx one-off shape, which by design has no memory) is the stricter
alternative and also acceptable.
