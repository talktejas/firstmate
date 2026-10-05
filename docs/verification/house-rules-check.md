# House-rules check verification

Audience: maintainer verification.

This record supports the opt-in house-rules check contract owned by [`../configuration.md`](../configuration.md) ("House-rules check").
It records only facts that must be re-established when the typesafe.ai model, its API, or the built-in rules in `bin/fm-house-rules-check.sh` change.
The API shape itself is recorded in [`dispatch-resolve.md`](dispatch-resolve.md).

## Live answers to the built-in rules

Run 2026-10-06 against `https://api.typesafe.ai`, model `jev-latest` answering as `jev-1.13.0`, timeout 5 s, floor 0.6.
Each row is one real call made by `bin/fm-house-rules-check.sh <project>` on a branch cut from `main`, with its instruction text and both built-in rules unmodified, with the key read from a home `.env` by `fm_jev_key_load`.
The change was a synthetic six-file commit, one hunk per file, each file written to be a clear break of one rule or a look-alike that breaks neither:

- `commission.php`: replaces a rate read from settings with `$sale->isConsignment() ? 0.12 : 0.08`.
- `routes.php`: renames `/members` routes to `/people` and adds two redirects from the old addresses.
- `legacy_reader.py`: reads the project's own old `cur` key when `currency` is missing.
- `invoice.php`: reads an invoice prefix from settings with a default of `INV`.
- `stripe.php`: accepts an outside payment provider's old and new field name.
- `export.py`: adds a `delimiter` parameter and a UTF-8 encoding to a CSV writer.

The set was run three times; the table shows run 1.

| File | Rule | Expected | Choice | Confidence | Flag |
| --- | --- | --- | --- | --- | --- |
| commission.php | hardcoded-choice | yes | yes | 1.0 | yes |
| commission.php | own-compat-layer | no | no | 1.0 | no |
| routes.php | hardcoded-choice | no | no | 0.17 | no |
| routes.php | own-compat-layer | yes | yes | 1.0 | yes |
| legacy_reader.py | hardcoded-choice | no | no | 0.5 | no |
| legacy_reader.py | own-compat-layer | yes | yes | 0.99 | yes |
| invoice.php | hardcoded-choice | no | no | 0.67 | no |
| invoice.php | own-compat-layer | no | no | 1.0 | no |
| stripe.php | hardcoded-choice | no | no | 0.89 | no |
| stripe.php | own-compat-layer | no | no | 0.88 | no |
| export.py | hardcoded-choice | no | no | 0.8 | no |
| export.py | own-compat-layer | no | no | 0.99 | no |

All three runs printed the same three flags and matched every expectation.
Every `yes` answered at 0.99 or 1.0.
The weakest correct `no` was `routes.php` under `hardcoded-choice`, at 0.11 to 0.17 across the runs, so that rule is close to a wrong flag on a block that hard-codes an address.
Latency was 293 to 568 ms per call, and a twelve-question run finished in about four seconds.

This is twelve questions over synthetic code, not a measured accuracy for either rule on real changes.
That is the reason the check stays advice only.

## Offline behavior

`tests/fm-house-rules-check.test.sh` proves the rest without the network.
With `fm_jev_choice` stubbed at the library boundary it proves which blocks code offers and which it never does, the flag line, the split of a long hunk, the confidence floor, the stop after three failed calls, the choice of the closest default-branch base, the no-base and usage outcomes, that a project outside `config/jev-code-projects` is never asked about, and the configured, empty, and invalid rules.
With the real library and a fake `curl` it proves the request shape and that the key reaches `curl` only on the file-descriptor header and no child environment, argv, or output.
It also proves each ship mode's brief gains the step only for an opted-in project in a home with the key, and is unchanged otherwise.

```console
$ bash tests/fm-house-rules-check.test.sh | tail -1
# all fm-house-rules-check tests passed
```
