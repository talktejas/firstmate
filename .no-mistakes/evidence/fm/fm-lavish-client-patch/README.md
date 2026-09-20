# Live six-connection check — lavish-axi client patch

Isolated environment: pristine `lavish-axi@0.1.63` installed into a temp prefix, eight
disposable Lavish sessions served on port **14387** (never the captain's 4387), driven by a
Playwright-bundled headless Chromium with its own throwaway profile (never the captain's browser).
Eight tabs opened one after another; the non-active tabs report `visibilityState: "hidden"`,
exactly like the captain's background review tabs.

| run | client | review pages that loaded | browser→server connections held |
|-----|--------|--------------------------|----------------------------------|
| before | stock 0.1.63 | **6 of 8** (tabs 7 and 8 blank, never painted) | 6 (the per-origin ceiling) |
| after  | same client patched by `bin/fm-lavish-client-patch.sh` | **8 of 8** | 2 |

- `unpatched-8-tabs.json` / `patched-8-tabs.json` — per-tab readyState, visibility, title, body size.
- `unpatched-tab6-last-page-that-loads.png` — the sixth page, the last one that renders unpatched
  (tabs 7 and 8 could not even be screenshotted: the renderer never painted a document).
- `patched-tab7-review-page-7.png`, `patched-tab8-review-page-8.png` — the seventh and eighth review
  pages rendering fully with the patch in place.
