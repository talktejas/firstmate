# Intake routing verification

Audience: maintainer verification.

This record supports the opt-in intake routing owned by [`../configuration.md`](../configuration.md) ("Intake routing").
It records only facts that must be re-established when the typesafe.ai model, its API, or the instruction and criteria text in `bin/fm-intake-route.sh` change.
The API shape itself is recorded in [`dispatch-resolve.md`](dispatch-resolve.md).

## Live routing

Run 2026-10-06 at commit `672abc8f` plus this change, against `https://api.typesafe.ai`, model `jev-latest`, timeout 5 s, floor 0.6.
Each run is one real request made by `bin/fm-intake-route.sh` with its instruction and criteria text unmodified, the request on stdin, and the key in the fixture home's `.env`.
The registries were synthetic: four unfinished projects (`storefront`, an online shop; `ledger`, an accounting service; `fieldapp`, a technicians' mobile app; `catalogue-scrape`, a `local-only` scraper), one `finished` project (`oldblog`), and two second mates (`shop`, scoped to the storefront, and `books`, scoped to accounting).
The set was run three times; the table shows run 1.

| Request | Expected | `project:` | `secondmate:` |
| --- | --- | --- | --- |
| Checkout fails with a 500 when the cart holds more than twenty items. | storefront, shop | storefront (1.0) | shop (1.0) |
| The quarterly tax report double counts credit notes. | ledger, books | ledger (1.0) | books (1.0) |
| Technicians cannot save a site visit when the phone is offline. | fieldapp, main | fieldapp (1.0) | main (no scope fits, 1.0) |
| Collect the remaining exhibitors from hall 7 into the spreadsheet. | catalogue-scrape, main | catalogue-scrape (1.0) | main (catalogue-scrape is local-only) |
| Fix the typo in the latest blog post. | by hand: only the finished project fits | by hand (no single project fits, 1.0) | main (no scope fits, 1.0) |
| Add a dark mode. | by hand: fits several projects | by hand (no single project fits, 0.88) | main (no scope fits, 0.76) |
| Customers want an invoice PDF emailed after they pay at checkout. | by hand: sits between two | storefront (0.63) | by hand (shop below the confidence floor, 0.15) |

All three runs printed the same lines for the first five requests, apart from one confidence of 0.99 in place of 1.0.
"Add a dark mode." stayed by hand in every run, at 0.86 to 0.91 for the project and 0.71 to 0.83 for the second mate.
The last request, written to sit between the shop and the accounting service, named `storefront` at 0.61 to 0.63 in every run, just above the floor, while its second-mate line stayed by hand at 0.10 to 0.15 with the guess changing between `shop` and `books`.
The request about the retired blog was never routed to `oldblog`, which is not offered.
One request carried both questions, and five timed runs finished in 410 to 473 ms of wall time.

This is seven requests written against four projects with clearly different descriptions, not a measured accuracy on real requests.
A project answer barely above the floor on a request that spans two projects is the reason the routing stays advice only and firstmate resolves the project and owner itself.

## Offline behavior

`tests/fm-intake-route.test.sh` proves the rest without the network; none of the following was exercised live.
It proves that `bin/fm-project-mode.sh --list` prints only unfinished registry entries and that `finished` changes no registered posture.
With `fm_jev_choices` stubbed at the library boundary it proves that a home without the key is never asked about and prints nothing, that the options are exactly the unfinished projects plus `none` and the parseable second-mate records plus `main`, that the state holds only the request and those registry fields, the floor on each line, the `local-only` override and that an unsure project does not trigger it, an off-list or missing answer, a failed call, that no second-mate question is asked when none is registered, and that an empty request, a request over the size bound, and a registry with no unfinished project are left by hand without a call.
With the real library and a fake `curl` it proves the request shape, that a malformed answer to one question leaves only that line by hand, that a credential-looking line in the request text or a registry is withheld, that the key reaches `curl` only on the file-descriptor header and no child environment, argv, or output, and that nothing in the home is written.

```console
$ bash tests/fm-intake-route.test.sh | tail -1
# all fm-intake-route tests passed
```
