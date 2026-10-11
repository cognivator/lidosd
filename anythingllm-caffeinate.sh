#!/bin/bash
# anythingllm-caffeinate.sh
#
# Holds idle-sleep (-i) and system-sleep (-s) assertions for exactly as long as
# the AnythingLLM main process OWNED BY $OWNER_USER is alive. AnythingLLM
# processes of other users are ignored. No display assertion (-d) is taken, so
# the display may sleep without causing idle or system sleep.
#
# Process identity = exact process name ($APP_NAME) AND owning user ($OWNER_USER):
#     pgrep -x -u llmserver AnythingLLM
#   -x  exact name match (excludes "AnythingLLM Helper (...)" Electron helpers)
#   -u  effective user (name or uid); for a GUI app this is the launching user
# Keep APP_NAME / OWNER_USER in sync with the same constants in lidosd.
#
# Runs as llmserver (LaunchAgent, GUI session). Install: ~/bin/anythingllm-caffeinate.sh
#
# BEFORE USING, as llmserver:
#     pgrep -lx -u llmserver AnythingLLM     # should print exactly one PID
#     pgrep -fl AnythingLLM                  # all users' processes, incl. helpers
#
# Note: lidosd reverts to `idle` when this process exits; that is done by the
# lidosd daemon itself (it watches the same process), not by this script.

APP_NAME=${APP_NAME:-AnythingLLM}
OWNER_USER=${OWNER_USER:-llmserver}
CAFFEINATE=${CAFFEINATE:-/usr/bin/caffeinate}
PGREP=${PGREP:-/usr/bin/pgrep}
POLL=${POLL:-5}

while true; do
    # lowest matching PID among this user's processes
    pid=$("$PGREP" -x -u "$OWNER_USER" "$APP_NAME" | /usr/bin/head -1)

    if [ -n "$pid" ]; then
        # Blocks until $pid exits; assertions are released automatically.
        # -s only takes effect on AC power; -i covers battery.
        "$CAFFEINATE" -i -s -w "$pid"
        sleep 1     # guard against a hot loop if caffeinate fails instantly
    else
        sleep "$POLL"   # app not running: hold nothing, poll for it
    fi
done
