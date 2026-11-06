#!/bin/bash
# lidosd-logic-test.sh - logic tests for the repo `lidosd` (container check, -l limit, daemon)
#
# Run as root, because lidosd insists on a root-owned state directory:
#     sudo /bin/bash lidosd-logic-test.sh [PATH-TO-lidosd]
# (default: the repo's lidosd, one level above this script). The script copies lidosd into
# a root-owned scratch tree under /private/tmp and drives that copy through its
# test-mode hooks, with fake pmset, ioreg, sudo and docker. The real pmset (except one
# read-only `pmset -g` at the start and the end), the live daemon and /var/db/lidosd
# are never written. The scratch tree is removed on success and kept on failure.
#
# Covered: argument parsing through the real script, the canonical arguments a
# non-root caller sends to sudo (run as user nobody), the container check (exact
# "true", failure, hang, a hang that ignores TERM), the limit (deadline file, status
# text), and the daemon (container stops, transient failures, expiry, damaged or
# expired deadline at startup, SIGTERM, lid closed).
# NOT covered (needs the real reinstall): real sudo and sudoers matching, launchd,
# the real docker CLI, the real pmset.

SRC=${1:-$(cd "$(dirname "$0")/.." && pwd)/lidosd}     # default: the repo's lidosd, one level above tests/

if [ "$(id -u)" -ne 0 ]; then echo "run as root: sudo /bin/bash $0" >&2; exit 1; fi
[ -f "$SRC" ] || { echo "no such file: $SRC" >&2; exit 1; }

T=$(/usr/bin/mktemp -d /private/tmp/lidosd-test.XXXXXX) || exit 1
case "$T" in /private/tmp/lidosd-test.??????) ;; *) echo "unexpected scratch dir: $T" >&2; exit 1 ;; esac
chmod 755 "$T"            # 755 so user nobody can run the copy (section 7)
S=$T/state
pass=0; fail=0; f0=0; DPID=

# ---- live system, read only: compared again at the end
live_sig() { /usr/bin/stat -f '%N %m %z' /var/db/lidosd/state /var/db/lidosd/deadline 2>&1; }
live_sd()  { /usr/bin/pmset -g 2>/dev/null | /usr/bin/awk '/SleepDisabled/ {print $2}'; }
LIVE0=$(live_sig); LIVESD0=$(live_sd)

# ---- the copy under test
/bin/cp "$SRC" "$T/lidosd" && chmod 755 "$T/lidosd" || exit 1
if ! /bin/bash -n "$T/lidosd"; then echo "bash -n failed on $SRC" >&2; rm -rf "$T"; exit 1; fi

# ---- fakes (the @T@ placeholder becomes the scratch path)
mkfake() { /usr/bin/sed "s|@T@|$T|g" > "$T/$1"; chmod 755 "$T/$1"; }

mkfake pmset <<'EOF'
#!/bin/bash
T=@T@
echo "$*" >> "$T/pmset.log"
case "$*" in
    "-a disablesleep 1") echo 1 > "$T/sd" ;;
    "-a disablesleep 0") echo 0 > "$T/sd" ;;
    "-g")                echo "  SleepDisabled        $(cat "$T/sd" 2>/dev/null || echo 0)" ;;
esac
EOF

mkfake ioreg <<'EOF'
#!/bin/bash
T=@T@
if [ "$(cat "$T/lid" 2>/dev/null)" = closed ]; then
    echo '    | |   "AppleClamshellState" = Yes'
else
    echo '    | |   "AppleClamshellState" = No'
fi
EOF

# sudo.mode exec: behave like `sudo -n -u USER -H CMD...` (drop the options, run CMD)
# sudo.mode log : only record the arguments (what lidosd would send to the real sudo)
mkfake sudo <<'EOF'
#!/bin/bash
T=@T@
echo "$*" >> "$T/sudo.calls"
[ "$(cat "$T/sudo.mode" 2>/dev/null)" = log ] && exit 0
while [ $# -gt 0 ]; do
    case "$1" in
        -n|-H) shift ;;
        -u)    shift 2 ;;
        *)     break ;;
    esac
done
exec "$@"
EOF

mkfake docker <<'EOF'
#!/bin/bash
T=@T@
echo "$*" >> "$T/docker.calls"
case "$(cat "$T/docker.mode" 2>/dev/null)" in
    true)     echo true ;;
    false)    echo false ;;
    fail)     echo "Error: No such object: testbox" >&2; exit 1 ;;
    junk)     echo "true x" ;;
    hang)     exec sleep 30 ;;
    hangterm) trap '' TERM; while :; do sleep 1; done ;;
    flaky)    n=$(cat "$T/docker.count" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > "$T/docker.count"
              if [ "$n" -le 2 ]; then echo false; else echo true; fi ;;
    *)        exit 1 ;;
esac
EOF

# ---- how lidosd is invoked: test mode on, every tool replaced, SUDO_USER removed
# (lidosd ignores test mode whenever SUDO_USER is set, so `env -u` is needed)
LENV=( /usr/bin/env -u SUDO_USER LIDOSD_TEST=1 LIDOSD_OWNER_USER=llmtest
       LIDOSD_STATE_DIR="$S" LIDOSD_PMSET="$T/pmset" LIDOSD_IOREG="$T/ioreg"
       LIDOSD_SUDO="$T/sudo" LIDOSD_DOCKER="$T/docker" LIDOSD_CONTAINER=testbox
       LIDOSD_POLL=1 LIDOSD_CHECK_TIMEOUT=1 )
L()  { "${LENV[@]}" "$T/lidosd" "$@"; }
LN() { /usr/bin/sudo -u nobody "${LENV[@]}" "$T/lidosd" "$@"; }

# ---- helpers
ok()      { pass=$((pass+1)); printf 'PASS  %s\n' "$1"; }
bad()     { fail=$((fail+1)); printf 'FAIL  %s\n' "$1"; }
check()   { local d=$1; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi; }
nocheck() { local d=$1; shift; if "$@" >/dev/null 2>&1; then bad "$d"; else ok "$d"; fi; }
section() { printf '\n== %s\n' "$1"; }

state()     { if [ -f "$S/state" ]; then cat "$S/state"; else echo idle; fi; }
dl_exists() { [ -e "$S/deadline" ] || [ -L "$S/deadline" ]; }
sd()        { cat "$T/sd"; }
logged()    { grep -qF -- "$1" "$T/daemon.log"; }
mkstate()   { mkdir -p "$S" && chmod 755 "$S"; }
now()       { date +%s; }
runrc()     { "$@" >/dev/null 2>&1; rc=$?; }

# dl_within MIN MAX : the deadline is between MIN and MAX seconds ahead
dl_within() {
    local d n
    d=$(cat "$S/deadline" 2>/dev/null) || return 1
    n=$(now)
    [ "$d" -ge $((n + $1)) ] && [ "$d" -le $((n + $2)) ]
}

# wait_state WANT SECONDS
wait_state() {
    local i=0
    while [ "$i" -lt "$2" ]; do
        [ "$(state)" = "$1" ] && return 0
        sleep 1; i=$((i+1))
    done
    [ "$(state)" = "$1" ]
}

startd() { "${LENV[@]}" "$T/lidosd" daemon >>"$T/daemon.log" 2>&1 & DPID=$!; sleep 1; }
stop_daemon() {
    if [ -n "$DPID" ]; then kill "$DPID" 2>/dev/null; wait "$DPID" 2>/dev/null; fi
    DPID=
}

reset() {
    stop_daemon
    rm -rf "$S"
    : > "$T/pmset.log"; : > "$T/docker.calls"; : > "$T/sudo.calls"; : > "$T/daemon.log"
    echo 0 > "$T/sd"; echo open > "$T/lid"; echo true > "$T/docker.mode"
    echo exec > "$T/sudo.mode"; echo 0 > "$T/docker.count"
}

begin() { printf '\n-- %s\n' "$1"; reset; f0=$fail; }
end_() {
    stop_daemon
    if [ "$fail" -gt "$f0" ]; then
        echo "---- daemon.log (tail)"; tail -n 20 "$T/daemon.log"
        echo "---- pmset.log (tail)";  tail -n 10 "$T/pmset.log"
        echo "----"
    fi
}

cleanup() {
    stop_daemon
    if [ "$fail" -gt 0 ]; then echo "scratch tree kept: $T"; else rm -rf "$T"; fi
}
trap cleanup EXIT

# ---- canary: a read-only call that must reach the FAKE pmset. If it does not, the
# ---- hooks are not in effect and nothing state-changing may be run.
section "0. test-mode hooks"
reset
L status >/dev/null 2>&1
if ! grep -qx -- '-g' "$T/pmset.log"; then
    echo "ABORT: test-mode hooks not honored (the fake pmset was not called)." >&2
    echo "       Nothing else was run and nothing was changed." >&2
    fail=1; exit 1
fi
ok "the fake pmset is used (hooks honored)"

# ---------------------------------------------------------------------------
section "1. command line, through the real script (as root)"
reset
runrc L -l 1441;     check "-l 1441 refused (exit 2)"      [ "$rc" -eq 2 ]
runrc L disarm -l 5; check "disarm -l 5 refused (exit 2)"  [ "$rc" -eq 2 ]
runrc L bogus;       check "bogus refused (exit 2)"        [ "$rc" -eq 2 ]
nocheck "the refusals changed nothing (no disablesleep call)" grep -q disablesleep "$T/pmset.log"

# ---------------------------------------------------------------------------
section "2. arm is refused unless the container answers exactly true"
for mode in false fail junk hang hangterm; do
    reset; echo "$mode" > "$T/docker.mode"
    SECONDS=0
    err=$(L arm 2>&1 >/dev/null); rc=$?
    el=$SECONDS
    check   "$mode: exit 1" [ "$rc" -eq 1 ]
    check   "$mode: refusal message" grep -qF "container testbox is not running (checked as llmtest); not arming." <<<"$err"
    check   "$mode: state is not armed" [ "$(state)" = idle ]
    nocheck "$mode: sleep was not disabled" grep -q "disablesleep 1" "$T/pmset.log"
    nocheck "$mode: no deadline written" dl_exists
    case "$mode" in hang|hangterm) check "$mode: gave up within 5 s (took ${el} s)" [ "$el" -le 5 ] ;; esac
done

# ---------------------------------------------------------------------------
section "3. arm with a healthy container"
reset
runrc L arm;  check "arm exit 0" [ "$rc" -eq 0 ]
check   "state is armed" [ "$(state)" = armed ]
check   "sleep disabled (fake pmset)" [ "$(sd)" = 1 ]
nocheck "no -l: no deadline file" dl_exists
check   "docker asked as the owner, absolute path, exact format" \
        grep -qxF -- "-n -u llmtest -H $T/docker inspect --format {{.State.Running}} testbox" "$T/sudo.calls"

# ---------------------------------------------------------------------------
section "4. the -l limit"
reset
runrc L arm -l 1;         check "arm -l 1: exit 0" [ "$rc" -eq 0 ]
check "deadline about 60 s ahead" dl_within 50 60
check "status: 1 min left" grep -qF "limit:         1 min left" <<<"$(L status)"
runrc L arm -l 05;        check "-l 05 canonicalized: deadline about 300 s ahead" dl_within 290 300
runrc L arm --limit=0010; check "--limit=0010: deadline about 600 s ahead" dl_within 590 600
check "status: 10 min left" grep -qF "limit:         10 min left" <<<"$(L status)"
runrc L arm -l 0;         nocheck "-l 0 clears the limit" dl_exists
check "status: limit none" grep -qF "limit:         none" <<<"$(L status)"
runrc L arm -l 5; runrc L arm
nocheck "a plain arm clears an earlier limit" dl_exists
runrc L arm -l 5; old=$(cat "$S/deadline")
echo false > "$T/docker.mode"; runrc L arm -l 9
check "refused re-arm: exit 1" [ "$rc" -eq 1 ]
check "refused re-arm: the old deadline is untouched" [ "$(cat "$S/deadline")" = "$old" ]
echo true > "$T/docker.mode"
runrc L disarm
check   "disarm: state idle" [ "$(state)" = idle ]
check   "disarm: sleep enabled" [ "$(sd)" = 0 ]
nocheck "disarm: deadline removed" dl_exists

# ---------------------------------------------------------------------------
section "5. status"
reset
nocheck "idle: no limit line" grep -q "limit:" <<<"$(L status)"
mkstate; echo armed > "$S/state"
echo abc > "$S/deadline"
check "garbage deadline: invalid" grep -qF "limit:         invalid (the daemon will disarm)" <<<"$(L status)"
echo 99999999999999 > "$S/deadline"
check "14-digit deadline: invalid" grep -qF "limit:         invalid (the daemon will disarm)" <<<"$(L status)"
echo 1 > "$S/deadline"
check "past deadline: expired" grep -qF "limit:         expired (the daemon will disarm)" <<<"$(L status)"
rm -f "$S/deadline"; ln -s /nonexistent "$S/deadline"
check "symlink deadline: invalid" grep -qF "limit:         invalid (the daemon will disarm)" <<<"$(L status)"

# ---------------------------------------------------------------------------
section "6. the daemon (poll 1 s, check timeout 1 s)"

begin "6.1 the container stops while armed"
runrc L arm; startd; sleep 2
check "healthy container: stays armed" [ "$(state)" = armed ]
echo false > "$T/docker.mode"
check "disarmed within 12 s" wait_state idle 12
check "log: 3 consecutive checks" logged "not running (3 consecutive checks)"
check "sleep enabled again" [ "$(sd)" = 0 ]
end_

begin "6.2 two failed checks in a row do not disarm"
runrc L arm; startd
echo 0 > "$T/docker.count"; echo flaky > "$T/docker.mode"     # false, false, then true
sleep 6
check   "still armed" [ "$(state)" = armed ]
nocheck "no disarm in the log" logged "consecutive checks"
check   "the daemon kept polling (at least 4 docker calls)" [ "$(cat "$T/docker.count")" -ge 4 ]
end_

begin "6.3 the limit runs out while armed"
runrc L arm; echo $(( $(now) + 3 )) > "$S/deadline"; startd
check   "disarmed within 10 s" wait_state idle 10
check   "log: limit reached" logged "limit reached (or deadline file invalid); disarming"
nocheck "it was the loop, not the startup path" logged "at startup"
nocheck "deadline removed" dl_exists
check   "sleep enabled again" [ "$(sd)" = 0 ]
end_

for kind in garbage expired symlink; do
    begin "6.4 startup with a $kind deadline"
    runrc L arm
    case "$kind" in
        garbage) echo xyz > "$S/deadline" ;;
        expired) echo $(( $(now) - 5 )) > "$S/deadline" ;;
        symlink) ln -s /nonexistent "$S/deadline" ;;
    esac
    startd
    check   "$kind: idle at once" [ "$(state)" = idle ]
    check   "$kind: log says at startup" logged "limit reached (or deadline file invalid) at startup; disarming"
    nocheck "$kind: deadline removed" dl_exists
    end_
done

begin "6.5 startup while the container is down"
runrc L arm; echo false > "$T/docker.mode"; startd
check "idle at once" [ "$(state)" = idle ]
check "log: not running at startup" logged "not running at startup"
end_

begin "6.6 startup healthy, then SIGTERM"
runrc L arm; startd
check "stays armed" [ "$(state)" = armed ]
check "log: daemon started, state=armed" logged "state=armed"
stop_daemon
check "SIGTERM: state idle" [ "$(state)" = idle ]
check "SIGTERM: sleep enabled" [ "$(sd)" = 0 ]
end_

begin "6.7 the limit runs out while the lid is closed"
runrc L arm; echo closed > "$T/lid"; startd
check "state becomes closed within 6 s" wait_state closed 6
echo $(( $(now) + 2 )) > "$S/deadline"
check "disarmed within 10 s" wait_state idle 10
check "log: limit reached" logged "limit reached (or deadline file invalid); disarming"
end_

begin "6.8 a hung container check counts as a failure"
runrc L arm; startd
echo hang > "$T/docker.mode"
check "disarmed within 25 s" wait_state idle 25
check "log: 3 consecutive checks" logged "not running (3 consecutive checks)"
end_

# ---------------------------------------------------------------------------
section "7. what a non-root caller sends to sudo (run as user nobody, fake sudo only logs)"
reset
if ! /usr/bin/sudo -u nobody /usr/bin/true 2>/dev/null; then
    echo "SKIP  cannot run commands as user nobody here"
else
    echo log > "$T/sudo.mode"
    chmod 666 "$T/sudo.calls"           # nobody has to be able to append to it

    # form "TYPED ARGS" "EXPECTED ARGS AFTER THE PATH"
    form() {
        local typed=$1 args=$2 got want
        : > "$T/sudo.calls"
        LN $typed >/dev/null 2>&1
        got=$(cat "$T/sudo.calls")
        want="-n /Library/PrivilegedHelperTools/lidosd${args:+ $args}"
        check "[${typed}] -> sudo -n <path>${args:+ $args}" [ "$got" = "$want" ]
    }
    # noform "TYPED ARGS" : refused with exit 2 before any sudo call
    noform() {
        local rc
        : > "$T/sudo.calls"
        LN $1 >/dev/null 2>&1; rc=$?
        check "[$1] refused with exit 2" [ "$rc" -eq 2 ]
        check "[$1] no sudo call" [ ! -s "$T/sudo.calls" ]
    }

    form ""             ""
    form "arm"          ""
    form "disarm"       "disarm"
    form "-l 5"         "-l 5"
    form "arm -l 05"    "-l 5"
    form "--limit=0010" "-l 10"
    form "--limit 7"    "-l 7"
    form "-l5"          "-l 5"
    form "-l 0"         "-l 0"
    form "-l 0000"      "-l 0"
    form "-l 1440"      "-l 1440"
    noform "-l 1441"
    noform "-l 00005"
    noform "disarm -l 5"
    noform "-l"
    noform "-l x"
    echo exec > "$T/sudo.mode"
fi

# ---------------------------------------------------------------------------
section "8. the live system was not touched"
check "live state and deadline files unchanged" [ "$(live_sig)" = "$LIVE0" ]
check "live SleepDisabled unchanged (${LIVESD0:-?})" [ "$(live_sd)" = "$LIVESD0" ]

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
