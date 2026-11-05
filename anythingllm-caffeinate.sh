#!/bin/bash
# anythingllm-caffeinate.sh
#
# Holds idle-sleep (-i) and system-sleep (-s) assertions for exactly as long as
# the AnythingLLM Docker container is running. `caffeinate` wraps `docker wait`,
# which blocks until the container stops, so the assertions end when the
# container does (or if the Docker connection drops). No display assertion (-d).
# -s only takes effect on AC power; -i covers battery.
#
# The container's process lives inside Docker Desktop's Linux VM and has no macOS
# PID, so `docker wait` is the nearest macOS-side stand-in for its lifetime.
#
# Runs as llmserver (LaunchAgent, GUI session). Install: ~/.local/bin/anythingllm-caffeinate.sh
# lidosd has its own, separate check (still Desktop-based; to be updated).

PATH=/usr/bin:/bin:/usr/sbin:/sbin
DOCKER=${DOCKER:-/usr/local/bin/docker}
CONTAINER=${CONTAINER:-anythingllm}
CAFFEINATE=${CAFFEINATE:-/usr/bin/caffeinate}
POLL=${POLL:-10}

cpid=
trap '[ -n "$cpid" ] && kill "$cpid" 2>/dev/null; exit 0' TERM INT

running() { [ "$("$DOCKER" inspect --format '{{.State.Running}}' "$CONTAINER" 2>/dev/null)" = true ]; }

while true; do
    if running; then
        "$CAFFEINATE" -i -s "$DOCKER" wait "$CONTAINER" >/dev/null 2>&1 &
        cpid=$!
        wait "$cpid"          # returns when the container stops or the connection drops
        cpid=
    fi
    sleep "$POLL" & wait $!   # also the guard against a hot loop
done
