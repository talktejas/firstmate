#!/usr/bin/env bash
# Claude Stop hook: record the turn's captain-facing message, without anyone
# choosing to.
#
# Registered in tracked .claude/settings.json as a synchronous Stop command
# hook, so it fires right as a Claude primary ends a turn - after the message
# is already on screen. A synchronous hook holds the turn end for as long as it
# runs, so it is registered with a 5-second timeout and bounds itself at 4:
# adding nothing to the captain's wait is a promise only a ceiling keeps. All
# it does is hand the payload to bin/fm-captain-message-sweep.py --from-payload,
# which sweeps THE TRANSCRIPT THE PAYLOAD NAMES and nothing else - one file,
# from where it was last read - and appends whatever is not yet in
# data/captain-messages.jsonl; the sweep's own header owns dedupe, the floor,
# and the honesty record the command center reads.
#
# That path is also the only one that knows for certain where this session
# writes: everything else derives the directory from the home's path, which is
# wrong for a session started anywhere else. bin/command-center.py sweeps that
# derived directory plus every transcript a payload has named, so a turn that
# ends without a Stop (interrupt, crash, kill) is still captured - and so is a
# turn whose sweep here ran out of its bound, because the next sweep reads the
# same transcript from the same cursor.
#
# Scope: only a genuine primary checkout (plain checkout or validly marked
# secondmate home) - the exact fm-turnend-guard.sh scope. Child crew/scout
# worktrees stay inert, and a Cursor-delivered payload stands down because
# Cursor also loads the tracked Claude settings (bin/fm-hook-host-lib.sh).
#
# This hook never blocks the Stop decision: it always exits 0 and prints
# nothing. A failed sweep is reported by the capture record, not by this hook.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-hook-host-lib.sh
. "$SCRIPT_DIR/fm-hook-host-lib.sh"
# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

# Consume the payload so a slow writer can never wedge on a full pipe.
PAYLOAD=$(cat 2>/dev/null || true)
fm_hook_payload_is_foreign_host "$PAYLOAD" && exit 0

fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

printf '%s' "$PAYLOAD" | fm_run_timed 4 python3 \
  "$SCRIPT_DIR/fm-captain-message-sweep.py" --home "$FM_HOME" --from-payload \
  >/dev/null 2>&1 || true
exit 0
