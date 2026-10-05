# Typed dispatch resolution verification

Audience: maintainer verification.

This record supports the opt-in `bin/fm-dispatch-resolve.sh` contract owned by [`../configuration.md`](../configuration.md) ("Typed dispatch resolution") and the declared rule and profile fields owned there under "Crew dispatch profiles".
It records only facts that must be re-established when the typesafe.ai model, its API, or firstmate's dispatch rules change.
Task chronology, the captain's rules, and the briefs themselves stay in the private scout report.

## The API the tool depends on

Verified 2026-09-16 against `https://api.typesafe.ai`.
`GET /v1/models` listed `jev-latest` and `jev-preview`, both released 2026-09-10; a `jev-latest` request answered as `jev-1.13.0`.
`POST /v1/systemone` takes `{model, state, questions}`; a `choice` question returns `{choice, probabilities, confidence}` with the probabilities summing to 1.
Observed error shapes: 401 `authentication_error` for a bad key, 403 when the header is missing, 422 with a `detail[].loc` naming the offending field, 400 `api_usage_error` for an unknown model, 405 on GET.
No rate-limit headers were present on any response; every response carried `x-typesafe-request-id`.
Observed end-to-end latency from a Mac was 123 to 348 ms per request, with the server's own upstream time at 4 to 60 ms.

## Live rule match against real briefs

Run 2026-09-16 with the key injected for the one command through the vault (`av inject +TYPESAFE_API_KEY -- ...`), model `jev-latest`, confidence floor 0.6, timeout 5 s, one `quota-axi --json` snapshot for the whole run.
Rules: the captain's five-rule file with a captain-authored none option, one `approval: captain` rule, two rule floors on `model:fable`, and declared `provider` on the Pi profiles.
Briefs: 15 real briefs from this home's recent work plus 10 synthetic ones written to hit each rule.

| Measure | Result |
| --- | --- |
| Rule matched the hand label | 20 of 25 |
| Resolved to the hand-labeled profile | 20 of 25 |
| Outcomes: clear / ambiguous / escalate / error | 18 / 1 / 6 / 0 |
| Clear results with a wrong profile | 0 |
| API latency (min / median / max) | 152 / 214 / 348 ms |
| Wall time per call including jq (min / median / max) | 198 / 261 / 396 ms |
| Input tokens per brief (min / median / max) | 1,279 / 3,114 / 4,538 |
| Output tokens | 150 to 152 |
| API errors | 0 |

Of the five disagreements, one was a wrong hand label (the brief quoted the bug-fix rule's wording verbatim), three were real briefs the model read as the approval-gated design rule at 0.66 to 0.86 confidence and escalated by design, each of which the captain had in fact dispatched at the strongest-reasoning class, and one was a synthetic tweak that came back ambiguous at 0.41 confidence and was handed back to firstmate.
A lean request that asks only the rule Choice matched the full request (rule, profile, and status) on all 25 briefs, which is why the tool then asked one question and kept every gate in code; "Small questions beside the rule question" below records the five-question request sent when a rule declares `match`.
That table records the 2026-09-16 run with the captain-authored none option.
A second live run on 2026-09-17 used the same 25 briefs, held one quota snapshot constant through a fake `quota-axi`, and exercised a copy of this branch with the shipped neutral `No listed rule applies to this task.` option and option-free interface.

| Measure | Result |
| --- | --- |
| Rule matched the hand label | 20 of 25 |
| Resolved to the hand-labeled profile | 18 of 25 |
| Outcomes: clear / ambiguous / escalate / error | 17 / 2 / 6 / 0 |
| Clear results with a profile other than the hand label | 1 |
| API latency (min / median / max) | 137 / 220 / 1,795 ms |
| Input tokens per brief (min / median / max) | 754 / 2,589 / 4,013 |
| Output tokens | 60 to 62 |
| API errors | 0 |

The maximum latency was one outlier; the next slowest request was 309 ms.
The differing clear result was a synthetic small tweak that matched the simple-bug-fix rule at 0.90 and selected `cursor-grok-4.6-medium` instead of the hand-labeled `cursor-grok-4.6-high`: the tweak exemption removed from the none-option text belongs in that rule's own `when` text.
Two default-labeled briefs became ambiguous.

## Small questions beside the rule question

Run 2026-10-06 against `https://api.typesafe.ai`, model `jev-latest` answering as `jev-1.13.0`, timeout 5 s, floor 0.6, with the key read from a home `.env` by `fm_jev_key_load`.
Rules: a 19-rule file with two `approval: captain` rules, whose rules lead to 12 distinct outcomes.
Briefs: 12 synthetic briefs with a `# Task` section and one line of standing text after it, plus one real scaffolded brief of 16 KB.
Each brief was resolved three ways, twice: by the single-question tool at commit 08a3a5cd, by this tool with the rule file as it stood, and by this tool with a `match` added to 18 of the 19 rules.
The command was `FM_HOME=<scratch home> bin/fm-dispatch-resolve.sh <brief> --project demo`, and the figures were read back from each scratch home's `state/.dispatch-resolve.log`.

The table shows the selected rule's confidence in run 1; `same` means the same rule as the single-question tool.

| Brief | Single question | Five questions, no `match` | Five questions, `match` | `kind` answer |
| --- | --- | --- | --- | --- |
| Write a PRD | 0.97 | same, 0.97 | same, 1 | product_document 1.0 |
| Write a specification from notes | 0.99 | same, 1 | same, 1 | product_document 1.0 |
| Research competing products | 0.5, below the floor | none option, 0.46, below the floor | same, 1 | product_document 1.0 |
| Produce a study | 0.7 | same, 0.61 | same, 1 | product_document 0.95 |
| Open-ended architecture | 1.0 | same, 1 | same, 1 | design 1.0 |
| Small stated bug fix | 0.99 | same, 0.99 | same, 1 | bugfix 1.0 |
| Review of a risky migration | 0.99 | same, 1 | same, 1 | review 1.0 |
| Rename a function everywhere | 0.67 | same, 0.56, below the floor | same, 0.54, below the floor | refactor 0.83 |
| Failing pipeline | 1.0 | same, 1 | same, 1 | ops 1.0 |
| Password reset tokens | 0.99, approval stop | same, approval stop | same, approval stop | feature 0.77 |
| Raise test coverage | 1.0 | same, 1 | same, 1 | tests 1.0 |
| Locate behaviour, change nothing | 1.0 | same, 1 | same, 1 | lookup 0.99 |
| Real scaffolded brief | 0.65 | same, 0.49, below the floor | approval stop | feature 1.0 |

Run 2 differed by at most 0.05 on any confidence and changed no row's side of the floor.
All four product-document briefs selected the same rule at confidence 1 once that rule declared `match.kind` with `product_document`; the single-question tool left one of them below the floor in both runs.
The password-reset brief answered `security` `yes` at 1.0, and every other synthetic brief answered `no` at 0.75 or higher.
The real scaffolded brief answered `security` `yes` at 0.79 and 0.87, which met the `match` of the approval-gated security rule and stopped for approval; that brief's own text discusses API key handling and quotes the security question.
Sending only its task part lowered that brief's rule confidence from 0.65 to about 0.5.
The rename brief split between the mechanical-edit and wide-rename rules in every arrangement, and its single-question confidence was 0.67 and 0.62 across the two runs.
Each five-question request used 1,869 to 1,884 input tokens and 416 to 417 output tokens on the synthetic briefs and 2,960 input tokens on the real one, and latency was 308 to 475 ms on 51 of 52 requests, with one at 845 ms.
The vendor's published Choice confidence, `(p_max - 1/n) / (1 - 1/n)` over `n` options, is the formula the tool applies when it recounts.
That run predates the current selection, and it has not been repeated since, so the last column is not what the tool returns now.
The tool then dropped rules and the neutral option by `match` and recomputed the confidence over what was left, and it selected an approval-gated rule outright once its whole `match` was met; it does neither now.
A rule answer at or above the floor now stands, so each such row keeps the rule and confidence of the "Five questions, no `match`" column.
A row below the floor there (research, rename, the real brief) is now decided by the rules without an approval gate whose whole `match` the small answers meet, with the lowest of those answers' confidences, and is `ambiguous` when they do not agree on one outcome; what each of those rows returns under that rule is unmeasured.
The tool then asked all five questions of every rules file; a file with no `match` now gets the `rule` question alone, so the "Five questions, no `match`" column describes a request that is no longer sent, and the token figures apply only to a file that declares `match`.
The vendor formula above is now applied only when rules that lead to one outcome are counted as one answer.
The quota snapshot was unmeasured for every provider during both runs, so each selection above ended as `escalate` with `no rankable eligible candidate` in all three arrangements; calls made on the PRD, bug-fix, and locate briefs while quota was measured ended `clear`.

## Offline behavior

`tests/fm-dispatch-resolve.test.sh` drives the public interface with a fake `curl` that records argv, the request body, the header read from file descriptor 3, and whether the secret reached its environment, plus a fake `quota-axi` that performs the same environment check.
It proves firstmate can invoke the resolve path without a preflight, rules are snapshotted once from the isolated home's canonical `config/crew-dispatch.json`, and dynamic output fields are flattened to one line.
It proves the absent key (environment and `.env`) prints one stderr line, nothing on stdout, exits 0, and never invokes `curl` or `quota-axi`.
It proves absent, default-only, and empty-rules files return `no rules to match` without a model or quota request, while a broken rules-file symlink exits 2 as unreadable.
It proves the documented starter configuration resolves its Pi default through the declared Claude provider, a `.env` key turns the tool on, and the environment wins over it.
It proves the key is absent from child environments, never appears on `curl` argv, and arrives only as the bearer header on the descriptor.
It proves the request uses the fixed endpoint and model, carries only the project, brief, and rule Choice with one option per rule plus the fixed neutral none option, and never carries `why`, `use`, or quota.
It proves the clear, fixed-floor ambiguous with candidate evidence, escalate (approval with candidate evidence, unverifiable rule floor, tie, nothing rankable), known rule-floor fall-through, known and unverifiable profile-floor evidence, explicit-provider and provider-ID enforcement, authoritative Agy and explicit-provider Gemini routing, partial providers, eligible unranked candidates and their clear-result note, concrete quota vetoes and profile-floor shortfalls taking precedence over uncertainty, account-wide quota veto, limiting-bound ranking, missing-curl and quota-axi failures, HTTP 429 and 500, transport failure, malformed usage, zero-mass or malformed probabilities or confidence, malformed or duplicate profile, invalid selector, removed-option rejection, and out-of-range rule ID paths behave as the contract states, with configuration errors exiting 2 before any network call.
`tests/fm-bootstrap.test.sh` proves bootstrap ignores resolver-only fields without the typed key, validates each malformed shape when the environment or home `.env` activates typed resolution, and prevents an environment-provided key from reaching child processes.

```console
$ bash tests/fm-dispatch-resolve.test.sh | tail -1
# all fm-dispatch-resolve tests passed
```

A live run needs a key and is not part of the suite; rerun the table above by pointing the tool at a brief with the key injected for that one command.
