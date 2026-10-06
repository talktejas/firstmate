# Already-exists search verification

Audience: maintainer verification.

This record supports the opt-in already-exists search contract owned by [`../configuration.md`](../configuration.md) ("Already-exists search").
It records only facts that must be re-established when the typesafe.ai model, its API, or the instruction text, function pattern, or ordering in `bin/fm-exists-search.sh` change.
The API shape itself is recorded in [`dispatch-resolve.md`](dispatch-resolve.md).

## Live answers

Run 2026-10-06 against `https://api.typesafe.ai`, model `jev-latest` answering as `jev-1.13.0`, timeout 5 s, floor 0.6, with the key read from a home `.env` by `fm_jev_key_load` and this repository opted in through a `jev-code-projects` file.
Every call was made by the unmodified script on the branch that adds it.

### A question

Each question was asked of the 70 functions of `bin/fm-jev-lib.sh`, `bin/fm-house-rules-check.sh`, `bin/fm-finding-sort.sh`, `bin/fm-commit-check.sh`, `bin/fm-pr-risk-lib.sh`, `bin/fm-check-sort-lib.sh`, and `bin/fm-dispatch-resolve.sh`, nine requests a run, three runs.

| Question | Expected | Printed | `yes` over three runs |
| --- | --- | --- | --- |
| Does this function decide whether a file path is one whose name says it holds secrets? | `fm_jev_secret_path` | `fm_jev_secret_path` only | 0.87 to 0.90 |
| Does this function pick the default-branch merge base closest to HEAD? | `house_rules_base` | `house_rules_base` only | 0.97 to 0.98 |
| Does this function check whether a project is opted in to sending its code to Jev? | `fm_jev_code_allowed` | `fm_jev_code_allowed` only | 0.99 |
| Does this function load the API key from the environment or the .env file? | `fm_jev_key_load` | `fm_jev_key_load` only | 0.92 to 0.94 |
| Does this function cut a diff into blocks of a bounded number of lines? | `house_rules_blocks` | the awk `function start()` eight lines inside it, only | 0.95 to 0.96 |
| Does this function work out commission per item? | nothing | nothing | - |

All three runs printed the same lines.
Four of the five functions that exist were named exactly, the fifth was named by a helper inside it rather than by its own opening line, and the question with no answer in the code printed nothing; no other function was printed for any question.
A run took 3.6 to 4.0 seconds.

The same six questions over all of `bin/` (3,746 functions, of which the first 200 by word overlap are asked in 25 requests, about 13 seconds a run) printed the first four functions and nothing for the other two.
The expected functions sat at positions 1, 12, 1, 2, and 4 of that order, so the miss on the fifth question there was the model's answer, not the bound.

### A change

The worktree added four functions to `bin/fm-env-lib.sh`, uncommitted, on top of this branch's own sixteen: three written to repeat an existing function under another name and one that repeats nothing.
Each added function was compared with the 16 existing functions closest to it, three runs.

| Added function | Repeats | Printed |
| --- | --- | --- |
| `project_is_opted_in` (a whole-line `grep` of `config/jev-code-projects`) | `fm_jev_code_allowed` | `fm_jev_code_allowed`, 0.98 |
| `print_help_from_header` (the header-comment `awk`) | every script's usage function | `usage()` of `bin/fm-brief.sh` at 1.0, and `cmd_drain()` of `bin/fm-inbox.sh` at 0.97 to 0.98, whose text window runs into that script's usage function |
| `lowercase_secret_name` (lower-cases a name and tests it against secret-file patterns) | `fm_jev_secret_path` | nothing |
| `count_words_in_file` | nothing | nothing |

All three runs printed the same lines for these four.
The miss is a real limit: `fm_jev_secret_path` keeps its pattern in a variable, so its text does not show what it matches, and it was compared (first in the order) and answered `no`.
Of this branch's own functions, the run named its usage function as a repeat of thirteen other scripts' usage functions and one test helper as a repeat of two identical helpers in other test files, all of which are true; one run of the three also named a second test helper at 0.8.

This is six questions and four planted functions over this repository's shell code, not a measured accuracy for finding duplicates in any project.
That is the reason the search stays advice only and the brief still asks for the search by hand.

## Offline behavior

`tests/fm-exists-search.test.sh` proves the rest without the network.
With `fm_jev_choices` stubbed at the library boundary it proves which functions code offers and which it never does, the order they are asked in, the cut of a long function, the match line and its ranking, the path limit, the confidence floor, the 200-function bound, the stop after three failed requests, the change run's choice of added functions and candidates, the no-base and usage outcomes, and that a project outside `config/jev-code-projects` is never asked about.
With the real library and a fake `curl` it proves the request shape, that a line that looks like a credential is withheld, and that the key reaches `curl` only on the file-descriptor header and no child environment, argv, or output.
It also proves that a ship or scout brief gains the search lines only for an opted-in project in a home with the key, and that the section is unchanged otherwise.

```console
$ bash tests/fm-exists-search.test.sh | tail -1
# all fm-exists-search tests passed
```
