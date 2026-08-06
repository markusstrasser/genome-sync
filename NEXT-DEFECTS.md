# Interactive selection defects — observed 2026-08-06 on a real syn6 sync

Both reproduce with the no-install one-off form:

    B2_... uvx --from git+https://github.com/markusstrasser/genome-sync@released \
      genome-sync --dest /Volumes/2TBPNY/syn6-genome syn6

## 1. The one-off form never asks results vs lab vs both

Observed output: `Selection:   results and lab` — printed as a fact, never asked.

`download-genome.sh:459` sets `configured_selection="results and lab"` as the
fallback when neither `--only` nor `--exclude` is given. In the CONFIGURED path
that is a saved preference the donor chose at `setup`. In the ONE-OFF path there
is no config, so the same fallback silently commits the donor to both classes —
here, 17.5 GB of raw CRAM/gVCF they were never asked about.

Fix: in the one-off path, when stdin/stdout are a TTY and neither `--only` nor
`--exclude` was passed, prompt for results / lab / both before inventory. Keep the
current fallback for non-TTY and `--yes`.

## 2. The "largest optional payloads" list mixes lab and results

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

## Why these matter together

(1) silently opts the donor into 17.5 GB, and (2) then denies them the tool to
trim what they did want. A donor who wants results-only and no 2.7 GB sqlite
currently cannot express that interactively at all.

Neither is a data-integrity defect: retention, hashing and the completion gate all
behaved correctly on the same run (985 superseded files were kept, not pruned;
plan a9994eaa6df6 matched the freshly published snapshot).
