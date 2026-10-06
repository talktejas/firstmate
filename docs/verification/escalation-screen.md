# Escalation screen verification

Audience: maintainer verification.

This record supports the opt-in escalation screen owned by [`../configuration.md`](../configuration.md) ("Escalation screen").
It records only facts that must be re-established when the typesafe.ai model, its API, or the instruction and criteria text in `bin/fm-escalation-screen.sh` change.
The API shape itself is recorded in [`dispatch-resolve.md`](dispatch-resolve.md).

## Live screens

Run 2026-10-06 against `https://api.typesafe.ai`, model `jev-latest`, timeout 5 s, floor 0.6.
Each row is one real request made by `bin/fm-escalation-screen.sh "<question>"` with its instruction and criteria text unmodified, in an empty fixture home with the key passed in the environment.
The questions were synthetic, each written to be a clear case of one kind.
The set was run three times; the table shows run 1.

| Question | Expected | Choice | Confidence | Printed |
| --- | --- | --- | --- | --- |
| When a consignor returns unsold stock, is their commission clawed back or kept? | trade | trade | 0.92 | captain's |
| Should the making charge be priced per gram or as a percentage of the metal value? | trade | trade | 0.8 | captain's |
| The public URL for a member profile: /m/&lt;id&gt; or /members/&lt;slug&gt;? It is printed on membership cards. | costly-to-undo | costly-to-undo | 0.91 | captain's |
| Doing this properly needs a new sync service and roughly doubles the task. Go ahead or keep it narrow? | costly-to-undo | costly-to-undo | 0.86 | captain's |
| Should dates show as DD/MM/YYYY or MM/DD/YYYY? | setting-with-default | setting-with-default | 0.86 | yours |
| Should the low-stock alert fire at 5 units or 10 units? | setting-with-default | trade | 0.39 | captain's |
| Should the helper live in utils.py or in a new export module? | cheap-to-reverse | cheap-to-reverse | 0.98 | yours |
| Should the empty-state text say "No members yet" or "Nothing here"? | cheap-to-reverse | cheap-to-reverse | 1.0 | yours |
| Which one do you prefer? | unclear | unclear | 0.95 | by hand |

All three runs printed the same nine lines, with confidences within 0.05 of run 1.
Eight of nine matched the expectation.
The miss, the low-stock threshold, was a weak `trade` answer at 0.35 to 0.39 in every run, which prints `captain's` and so costs one question that could have been a setting, never a decision taken from the captain.
Each request finished in 316 to 416 ms of wall time.

This is nine questions written to be clear, not a measured accuracy on real questions, which often sit between two kinds.
That is the reason the screen stays advice only and firstmate's own reading of the question wins.

## Offline behavior

`tests/fm-escalation-screen.test.sh` proves the rest without the network; none of the following was exercised live.
With `fm_jev_choice` stubbed at the library boundary it proves that a home without the key is never asked about, the `yours`, `captain's`, and `by hand` lines, that the confidence floor alone decides a `yours`, that `trade` and `costly-to-undo` are the captain's at any confidence, a failed call, that the state holds only the question's words, and that a question naming a merge, an approval, or a destructive or security-sensitive act, a review-gate line, and an over-long question are each decided without a call.
With the real library and a fake `curl` it proves the request shape, that a malformed answer is by hand, that a credential line is withheld, that the key reaches `curl` only on the file-descriptor header and no child environment, argv, or output, and that nothing is written into the home.

```console
$ bash tests/fm-escalation-screen.test.sh | tail -1
# all fm-escalation-screen tests passed
```
