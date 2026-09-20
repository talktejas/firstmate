#!/usr/bin/env bash
# tests/fm-lavish-client-patch.test.sh - bin/fm-lavish-client-patch.sh: applies once, is a
# no-op on a second run, refuses without touching the file when the upstream code it targets
# has moved, and the patched output actually releases and reopens the SSE stream on tab
# visibility (docs/lavish-connection-limit.md).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PATCH_SCRIPT="$ROOT/bin/fm-lavish-client-patch.sh"
TMP_ROOT=$(fm_test_tmproot fm-lavish-client-patch-tests)

# A minimal stand-in for the section of the real lavish-axi chrome-client.js
# that bin/fm-lavish-client-patch.sh targets: the exact original code shape,
# with no-op stubs for every name it references so the file also runs standalone.
fixture_unpatched() {
  cat <<'JS'
function noop() {}
globalThis.fmCalls = [];
const resetFrame = () => {
  fmCalls.push("resetFrame");
  return Promise.resolve(false);
};
const refreshWhiteboardSource = noop;
const reloadAfterServerRestart = noop;
const shutdownEventReason = () => "";
const setChromeOutdated = noop;
const addChat = noop;
const noteAgentReply = noop;
const syncChat = noop;
const setAgentPresence = noop;
const setLayoutWarnings = noop;
const markSessionEnded = noop;
const refreshLayoutWarnings = noop;
const key = "testkey";

const events = new EventSource("/events/" + key);
events.addEventListener("reload", () => {
  resetFrame().then((reloaded) => {
    if (reloaded) refreshWhiteboardSource();
  });
});
events.addEventListener("chrome-reload", (event) => reloadAfterServerRestart(shutdownEventReason(event)));
// The replacement server serves a different artifact's review. This page keeps working against
// it; it is only running the previous version of the chrome, which is the user's to act on.
events.addEventListener("chrome-outdated", (event) => setChromeOutdated(true, shutdownEventReason(event)));
events.addEventListener("agent-reply", (event) => {
  const text = JSON.parse(event.data).text;
  addChat("agent", text);
  noteAgentReply(text);
});
events.addEventListener("chat-sync", (event) => syncChat(JSON.parse(event.data).chat || []));
events.addEventListener("agent-presence", (event) => setAgentPresence(JSON.parse(event.data).state));
events.addEventListener("layout-warnings", (event) => setLayoutWarnings(JSON.parse(event.data).warnings || []));
events.addEventListener("ended", () => markSessionEnded());
// A reconnecting stream means this chrome may have missed updates while it was away.
events.addEventListener("open", () => refreshLayoutWarnings());
JS
}

# make_npm_root <label> -> prints a directory laid out like a global npm root
# with the fixture client at lavish-axi/dist/chrome-client.js, and puts a
# fake `npm` on PATH so the script's `npm root -g` resolves to it.
make_npm_root() {
  local dir="$TMP_ROOT/$1" fakebin
  mkdir -p "$dir/lavish-axi/dist"
  fixture_unpatched > "$dir/lavish-axi/dist/chrome-client.js"
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/npm" <<SH
#!/usr/bin/env bash
echo "$dir"
SH
  chmod +x "$fakebin/npm"
  printf '%s\n' "$dir:$fakebin"
}

run_patch() {  # <npm-root>:<fakebin>
  local pair=$1 root fakebin
  root=${pair%%:*}
  fakebin=${pair##*:}
  PATH="$fakebin:$PATH" "$PATCH_SCRIPT"
}

client_path() {  # <npm-root>:<fakebin>
  local pair=$1
  printf '%s/lavish-axi/dist/chrome-client.js\n' "${pair%%:*}"
}

# --- case A: first run patches an unpatched client --------------------------
a=$(make_npm_root case-a)
out=$(run_patch "$a" 2>&1); rc=$?
client=$(client_path "$a")
expect_code 0 "$rc" "case A: first run exits 0"
assert_contains "$out" "patched $client" "case A: reports the file it patched"
node --check "$client" >/dev/null 2>&1 || fail "case A: patched file is not valid JavaScript"

# --- case B: a second run is a no-op -----------------------------------------
sha_once=$(sha256sum "$client" | cut -d' ' -f1)
out2=$(run_patch "$a" 2>&1); rc2=$?
sha_twice=$(sha256sum "$client" | cut -d' ' -f1)
expect_code 0 "$rc2" "case B: second run exits 0"
assert_contains "$out2" "already applied to $client" "case B: reports already-applied"
assert_equals "$sha_once" "$sha_twice" "case B: second run leaves the file byte-identical"

# --- case C: refuses without corrupting when the target code moved ----------
c=$(make_npm_root case-c)
client_c=$(client_path "$c")
sed -i 's/events.addEventListener("ended", () => markSessionEnded());/events.addEventListener("ended", () => markSessionEndedRenamed());/' "$client_c"
sha_before=$(sha256sum "$client_c" | cut -d' ' -f1)
out3=$(run_patch "$c" 2>&1); rc3=$?
sha_after=$(sha256sum "$client_c" | cut -d' ' -f1)
[ "$rc3" -ne 0 ] || fail "case C: expected a non-zero exit when the target code shape moved"
assert_contains "$out3" "expected code shape not found" "case C: names the reason for refusing"
assert_equals "$sha_before" "$sha_after" "case C: refusal leaves the file untouched"
node --check "$client_c" >/dev/null 2>&1 || fail "case C: file must remain valid JavaScript after a refused patch"

# --- behavior: the patched stream releases and reclaims a connection with tab visibility
d=$(make_npm_root case-d)
run_patch "$d" >/dev/null 2>&1
client_d=$(client_path "$d")
harness="$TMP_ROOT/harness.mjs"
{
  cat <<'JS'
class FakeEventSource {
  constructor(url) {
    this.url = url;
    this.readyState = 1;
    FakeEventSource.instances.push(this);
  }
  addEventListener() {}
  close() { this.readyState = FakeEventSource.CLOSED; }
}
FakeEventSource.CLOSED = 2;
FakeEventSource.instances = [];
globalThis.EventSource = FakeEventSource;

const visibilityListeners = [];
let hiddenState = process.env.FM_START_HIDDEN === "1";
globalThis.document = {
  get hidden() { return hiddenState; },
  addEventListener(type, fn) {
    if (type === "visibilitychange") visibilityListeners.push(fn);
  },
};
JS
  cat "$client_d"
  cat <<'JS'

const show = () => {
  hiddenState = false;
  visibilityListeners.forEach((fn) => fn());
};
const hide = () => {
  hiddenState = true;
  visibilityListeners.forEach((fn) => fn());
};

if (process.env.FM_START_HIDDEN === "1") {
  if (FakeEventSource.instances.length !== 0) {
    throw new Error("a page loaded into a background tab must hold no stream, got " + FakeEventSource.instances.length);
  }
  show();
  if (FakeEventSource.instances.length !== 1) {
    throw new Error("expected one stream once the background tab is shown, got " + FakeEventSource.instances.length);
  }
  console.log("hidden-start-behavior-ok");
} else {
  if (FakeEventSource.instances.length !== 1) {
    throw new Error("expected exactly one initial stream, got " + FakeEventSource.instances.length);
  }
  const first = FakeEventSource.instances[0];

  hide();
  if (first.readyState !== FakeEventSource.CLOSED) {
    throw new Error("expected the stream to close while the tab is hidden");
  }

  show();
  if (FakeEventSource.instances.length !== 2) {
    throw new Error("expected a fresh stream to open when the tab is shown again, got " + FakeEventSource.instances.length);
  }
  if (!fmCalls.includes("resetFrame")) {
    throw new Error("expected the artifact to resync on reconnect, since reloads pushed while hidden are not replayed");
  }
  console.log("visibility-behavior-ok");
}
JS
} > "$harness"
behavior_out=$(node "$harness" 2>&1); behavior_rc=$?
expect_code 0 "$behavior_rc" "behavior: patched harness ran without error ($behavior_out)"
assert_contains "$behavior_out" "visibility-behavior-ok" "behavior: hide/show closed the stream, reopened it, and resynced the artifact"

hidden_out=$(FM_START_HIDDEN=1 node "$harness" 2>&1); hidden_rc=$?
expect_code 0 "$hidden_rc" "behavior: patched harness ran without error when the page starts hidden ($hidden_out)"
assert_contains "$hidden_out" "hidden-start-behavior-ok" "behavior: a page opened in a background tab holds no stream until shown"

pass "fm-lavish-client-patch: apply-once, no-op-twice, refuse-on-drift, and visibility behavior all hold"
