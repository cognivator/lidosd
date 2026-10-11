#!/bin/bash
# uninstall.sh - remove everything install.sh deployed and restore normal sleep.
#
#   sudo bash /Users/Shared/<reponame>/uninstall.sh
#
# Removes: lidosd, both launchd plists (after unloading them), the sudoers rule,
# llmserver's keep-awake script, and the lidosd state directory.
# Leaves in place: this source folder, /var/log/lidosd.log, and the (possibly
# shared) directories /usr/local/sbin and ~llmserver/bin (the latter is removed
# only if now empty).
# Unloading the lid daemon runs its shutdown handler (`pmset -a disablesleep 0`);
# this script also sets it explicitly as a safeguard.
#
# Hardening (same approach as install.sh): PATH and umask are fixed; environment
# overrides are ignored; files inside llmserver's home are removed BY llmserver
# (sudo -u), so a symlink planted there cannot make root delete something else.
# Best effort: a failing step is reported and the remaining steps still run.
#
# OWNER_USER is a constant below and must match install.sh.
#
# Test mode: UNINSTALL_TEST=1 plus DESTDIR enables the overrides DESTDIR,
# OWNER_USER, OWNER_HOME, LAUNCHCTL and PMSET (unset LAUNCHCTL / PMSET = skip
# that step). Without UNINSTALL_TEST=1 they are ignored.

PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH
umask 022
set -u

DAEMON_LABEL=com.llmserver.lidosd
AGENT_LABEL=com.llmserver.anythingllm-caffeinate
SUDO=/usr/bin/sudo

if [ "${UNINSTALL_TEST:-}" = 1 ]; then
    TEST_MODE=1
    OWNER_USER=${OWNER_USER:-llmserver}
    OWNER_HOME=${OWNER_HOME:-}
    DESTDIR=${DESTDIR:-}
    LAUNCHCTL=${LAUNCHCTL:-}
    PMSET=${PMSET:-}
    [ -n "$DESTDIR" ] || { echo "uninstall.sh: UNINSTALL_TEST=1 requires DESTDIR" >&2; exit 1; }
else
    TEST_MODE=0
    OWNER_USER=llmserver
    OWNER_HOME=
    DESTDIR=
    LAUNCHCTL=/bin/launchctl
    PMSET=/usr/bin/pmset
fi

say()  { echo "==> $*"; }
warn() { echo "WARNING: $*" >&2; }
die()  { echo "uninstall.sh: $*" >&2; exit 1; }

lctl() { if [ -n "$LAUNCHCTL" ]; then "$LAUNCHCTL" "$@"; else return 0; fi; }

as_owner() { "$SUDO" -n -u "$OWNER_USER" "$@"; }

wait_unloaded() {   # wait (max ~10s) until launchd forgets the service target
    local i=0
    [ -n "$LAUNCHCTL" ] || return 0
    while "$LAUNCHCTL" print "$1" >/dev/null 2>&1; do
        i=$((i + 1))
        if [ "$i" -gt 20 ]; then warn "$1 still loaded after 10s"; return 0; fi
        sleep 0.5
    done
}

main() {
    local SBIN DAEMONS SUDOERS_D OWNER_UID

    [ "$(id -u)" -eq 0 ] || exec "$SUDO" /bin/bash "$0" "$@"
    [ "$TEST_MODE" = 1 ] || [ "$(uname)" = Darwin ] || die "macOS only"
    [ "$OWNER_USER" != root ] || die "OWNER_USER must not be root"
    cd /

    SBIN=$DESTDIR/usr/local/sbin
    DAEMONS=$DESTDIR/Library/LaunchDaemons
    SUDOERS_D=$DESTDIR/etc/sudoers.d

    say "Removing sudoers rule"
    rm -f "$SUDOERS_D/lidosd"

    say "Stopping lid OSD daemon"
    lctl bootout "system/$DAEMON_LABEL" 2>/dev/null || true
    wait_unloaded "system/$DAEMON_LABEL"
    say "Making sure lid-close sleep is enabled (pmset disablesleep 0)"
    if [ -n "$PMSET" ]; then
        "$PMSET" -a disablesleep 0 || warn "pmset failed; check: pmset -g | grep SleepDisabled"
    fi

    say "Removing lid OSD files"
    rm -f "$DAEMONS/$DAEMON_LABEL.plist" "$SBIN/lidosd"
    rm -rf "$DESTDIR/var/db/lidosd"

    if id "$OWNER_USER" >/dev/null 2>&1; then
        if [ -z "$OWNER_HOME" ]; then
            OWNER_HOME=$(dscl . -read "/Users/$OWNER_USER" NFSHomeDirectory 2>/dev/null \
                         | tail -n 1 | sed -e 's/^NFSHomeDirectory: //' -e 's/^ //')
        fi
        OWNER_UID=$(id -u "$OWNER_USER")

        say "Stopping keep-awake agent for $OWNER_USER"
        if lctl print "gui/$OWNER_UID" >/dev/null 2>&1; then
            lctl bootout "gui/$OWNER_UID/$AGENT_LABEL" 2>/dev/null || true
            wait_unloaded "gui/$OWNER_UID/$AGENT_LABEL"
        fi

        case "$OWNER_HOME" in
            /?*)
                say "Removing keep-awake agent files (as $OWNER_USER)"
                as_owner /bin/rm -f "$DESTDIR$OWNER_HOME/Library/LaunchAgents/$AGENT_LABEL.plist" \
                                    "$DESTDIR$OWNER_HOME/bin/anythingllm-caffeinate.sh" \
                    || warn "could not remove one or more of $OWNER_USER's agent files"
                as_owner /bin/rmdir "$DESTDIR$OWNER_HOME/bin" 2>/dev/null || true   # only if now empty
                ;;
            *)
                warn "could not determine home of $OWNER_USER; its agent files were not removed"
                ;;
        esac
    else
        warn "user '$OWNER_USER' does not exist; skipped agent removal"
    fi

    cat <<EOF

Done. Verify:
  pmset -g | grep SleepDisabled      # expect 0
  pmset -g assertions                # no caffeinate from the keep-awake agent
  ls /usr/local/sbin/lidosd /etc/sudoers.d/lidosd   # both gone
EOF
}

main "$@"
exit $?
