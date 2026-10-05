#!/usr/bin/env bash
# fm-launch-env-lib.sh - the environment names that must never be ambient in a
# launched agent or in a long-lived server firstmate starts.
#
# Each FM_ name is a setting one firstmate script hands exactly one child.
# CLAUDE_CODE_CHILD_SESSION is the marker Claude Code sets for its own hook and
# tool children, and a Claude session that inherits it stops saving its
# conversation. A server started from inside such a scope hands all of them to
# every later pane, so this list is the single owner for the three places that
# enforce it: the herdr server start (fm_backend_herdr_server_ensure in
# bin/backends/herdr.sh), every agent launch (bin/fm-spawn.sh), and the
# session-start report of what a primary inherited (bin/fm-session-start.sh).
#
# Sourced, never executed. Adding a name here is the whole change: the three
# enforcement points read the list.

# shellcheck disable=SC2034 # Read by the scripts that source this file.
FM_LAUNCH_SCRUB_ENV='FM_CREW_STATE_META_OVERRIDE FM_CREW_STATE_STATUS_OVERRIDE FM_SESSION_START_STAGE_FILE FM_HOME_SUMMARY_IF_IDLE FM_HOME_SUMMARY_WORKER_BEST_EFFORT CLAUDE_CODE_CHILD_SESSION'
