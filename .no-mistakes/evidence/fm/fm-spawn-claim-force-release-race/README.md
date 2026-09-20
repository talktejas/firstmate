# Live drive: pooled-copy refusal + collision deadlock

Both scenarios were driven against the real `bin/fm-spawn.sh` and
`bin/fm-teardown.sh` CLIs (fake `treehouse`/`tmux` on PATH stand in for the
pool and the terminal, the same fakes the repo's own suites use), at the target
commit and again at the base commit `c57090f` for before/after contrast.

| file | what it shows |
|---|---|
| `spawn-refusals-target.txt` | spawn refuses a pooled copy a live record still names — force-released claim, cross-home record, and an unreadable registered home (claim returned) |
| `spawn-refusals-base.txt` | same three inputs at the base commit: every one LAUNCHES into the copy |
| `teardown-deadlock-target.txt` | the 2026-09-20 pair: the record the slot claim disowns retires cleanly, then the owner's own teardown succeeds |
| `teardown-deadlock-base.txt` | same pair at the base commit: cleanup REFUSES in both directions, each citing the other |
| `driver-spawn.sh`, `driver-teardown.sh` | the drivers used (run as `bash driver-spawn.sh <repo-root> <label> <outdir>`) |
