#!/bin/bash
# install.sh - deploy the AnythingLLM keep-awake pieces from THIS folder.
#
#   sudo bash /Users/Shared/<reponame>/install.sh
#
# The source folder is located from this script's own path, so the repo name does
# not matter. Safe to re-run: it stops the running pieces, redeploys, and starts
# them again. (Stopping the lid daemon disarms an armed OSD.)
#
# Deployed:
#   root       /usr/local/sbin/lidosd
#              /Library/LaunchDaemons/com.llmserver.lidosd.plist   (loaded)
#              /etc/sudoers.d/lidosd                               (validated)
#   llmserver  ~/bin/anythingllm-caffeinate.sh
#              ~/Library/LaunchAgents/com.llmserver.anythingllm-caffeinate.plist
#              (loaded now if llmserver has a GUI session, else at next login)
#
# Threat model: the account that runs AnythingLLM (OWNER_USER, "llmserver") must
# not be able to turn this install into root. Safeguards:
#   * PATH and umask are fixed; environment overrides are ignored (see below).
#   * Sources must be regular files (no symlinks), not group/other-writable, not
#     owned by OWNER_USER, not writable by OWNER_USER, and not reachable through a
#     directory OWNER_USER controls. They are copied to a private root-owned temp
#     dir and everything is validated and installed from that copy.
#   * Before AND after installing, OWNER_USER must be unable to write to the
#     root-run files or any directory above them. Failing after install removes
#     what was installed.
#   * Files in OWNER_USER's home are written BY OWNER_USER (sudo -u), never by
#     root, so a symlink planted there cannot redirect a root write.
#   * Existing shared directories (e.g. /usr/local/sbin) are never chown'd or
#     chmod'd; missing ones are created root:wheel 755.
#
# OWNER_USER is a constant below and must match lidosd, anythingllm-caffeinate.sh,
# lidosd.sudoers and the agent plist (checked before installing).
#
# Test mode: INSTALL_TEST=1 plus DESTDIR (stage under a prefix) enables the
# overrides DESTDIR, OWNER_USER, OWNER_HOME, ROOT_GROUP and LAUNCHCTL (unset
# LAUNCHCTL = skip all launchctl calls). Without INSTALL_TEST=1 they are ignored.

PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH
umask 022
set -eu

DAEMON_LABEL=com.llmserver.lidosd
AGENT_LABEL=com.llmserver.anythingllm-caffeinate
SUDO=/usr/bin/sudo

if [ "${INSTALL_TEST:-}" = 1 ]; then
    TEST_MODE=1
    OWNER_USER=${OWNER_USER:-llmserver}
    ROOT_GROUP=${ROOT_GROUP:-wheel}
    DESTDIR=${DESTDIR:-}
    LAUNCHCTL=${LAUNCHCTL:-}
    OWNER_HOME=${OWNER_HOME:-}
    [ -n "$DESTDIR" ] || { echo "install.sh: INSTALL_TEST=1 requires DESTDIR" >&2; exit 1; }
else
    TEST_MODE=0
    OWNER_USER=llmserver
    ROOT_GROUP=wheel
    DESTDIR=
    LAUNCHCTL=/bin/launchctl
    OWNER_HOME=
fi

STAGE=
SRC=
CHAIN_TOP=/

say()  { echo "==> $*"; }
warn() { echo "WARNING: $*" >&2; }
die()  { echo "install.sh: $*" >&2; exit 1; }

# ---------------------------------------------------------------- helpers
lctl() { if [ -n "$LAUNCHCTL" ]; then "$LAUNCHCTL" "$@"; else return 0; fi; }

as_owner() { "$SUDO" -n -u "$OWNER_USER" "$@"; }

# 0 = OWNER_USER can write $1, 1 = cannot. Dies if the answer is unknown (fail closed).
owner_can_write() {
    local out
    out=$(as_owner /bin/sh -c 'if test -w "$1"; then echo W; else echo N; fi' _ "$1" 2>/dev/null) \
        || die "cannot run commands as $OWNER_USER via sudo (needed to test permissions)"
    case "$out" in
        W) return 0 ;;
        N) return 1 ;;
        *) die "unexpected permission-probe output for $1: '$out'" ;;
    esac
}

group_or_other_writable() { [ -n "$(find "$1" -maxdepth 0 \( -perm -020 -o -perm -002 \) 2>/dev/null)" ]; }
is_sticky()               { [ -n "$(find "$1" -maxdepth 0 -perm -1000 2>/dev/null)" ]; }
owned_by_owner()          { [ -n "$(find "$1" -maxdepth 0 -user "$OWNER_USER" 2>/dev/null)" ]; }
phys_dir()                { ( cd "$1" 2>/dev/null && pwd -P ); }

# Fail (return 1) if OWNER_USER can write $1 (or its nearest existing ancestor)
# or any directory above it.
assert_root_only() {
    local p=$1 d
    while [ ! -e "$p" ] && [ "$p" != / ]; do p=$(dirname "$p"); done
    if [ -d "$p" ]; then
        d=$(phys_dir "$p")
    else
        d="$(phys_dir "$(dirname "$p")")/$(basename "$p")"
    fi
    [ -n "$d" ] || die "cannot resolve $1"
    while :; do
        if [ -n "$DESTDIR" ] && [ "$d" = "$CHAIN_TOP" ]; then break; fi
        if owner_can_write "$d"; then
            echo "SECURITY: $OWNER_USER can write to $d, which is part of the path of a root-run file ($1)." >&2
            return 1
        fi
        [ "$d" = / ] && break
        d=$(dirname "$d")
    done
    return 0
}

verify_root_paths() {
    local p rc=0
    for p in "$SBIN" "$SBIN/lidosd" "$DAEMONS" "$DAEMONS/$DAEMON_LABEL.plist" \
             "$SUDOERS_D" "$SUDOERS_D/lidosd"; do
        assert_root_only "$p" || rc=1
    done
    return $rc
}

check_src_item() {
    if group_or_other_writable "$1"; then die "$1 is writable by group or others; fix: chmod go-w '$1'"; fi
    if owned_by_owner "$1"; then die "$1 is owned by $OWNER_USER; root-installed sources must not be controlled by $OWNER_USER"; fi
    if owner_can_write "$1"; then die "$OWNER_USER can write to $1"; fi
}

# put_as_owner SRC DEST MODE : write DEST as OWNER_USER (atomic rename; root opens SRC)
put_as_owner() {
    as_owner /bin/sh -c 'cat > "$1.tmp" && chmod "$2" "$1.tmp" && mv -f "$1.tmp" "$1"' _ "$2" "$3" < "$1"
}

wait_unloaded() {   # wait_unloaded SERVICE-TARGET : wait (max ~10s) until launchd forgets it
    local i=0
    [ -n "$LAUNCHCTL" ] || return 0
    while "$LAUNCHCTL" print "$1" >/dev/null 2>&1; do
        i=$((i + 1))
        if [ "$i" -gt 20 ]; then warn "$1 still loaded after 10s"; return 0; fi
        sleep 0.5
    done
}

cleanup() { if [ -n "$STAGE" ]; then rm -rf "$STAGE"; fi; }

# ---------------------------------------------------------------- main
main() {
    local f d files

    [ "$(id -u)" -eq 0 ] || exec "$SUDO" /bin/bash "$0" "$@"

    [ "$TEST_MODE" = 1 ] || [ "$(uname)" = Darwin ] || die "macOS only"
    [ ! -L "$0" ] || die "run install.sh directly, not through a symlink"
    [ "$OWNER_USER" != root ] || die "OWNER_USER must not be root"
    id "$OWNER_USER" >/dev/null 2>&1 || die "user '$OWNER_USER' does not exist"
    OWNER_UID=$(id -u "$OWNER_USER")

    SRC=$(cd "$(dirname "$0")" && pwd -P)
    cd /
    [ -z "$DESTDIR" ] || CHAIN_TOP=$(phys_dir "$DESTDIR")

    if [ -z "$OWNER_HOME" ]; then
        OWNER_HOME=$(dscl . -read "/Users/$OWNER_USER" NFSHomeDirectory 2>/dev/null \
                     | tail -n 1 | sed -e 's/^NFSHomeDirectory: //' -e 's/^ //')
    fi
    case "$OWNER_HOME" in /?*) ;; *) die "cannot determine home directory of $OWNER_USER" ;; esac
    [ -d "$DESTDIR$OWNER_HOME" ] || die "home directory $DESTDIR$OWNER_HOME of $OWNER_USER does not exist"

    SBIN=$DESTDIR/usr/local/sbin
    DAEMONS=$DESTDIR/Library/LaunchDaemons
    SUDOERS_D=$DESTDIR/etc/sudoers.d
    AGENT_DIR=$DESTDIR$OWNER_HOME/Library/LaunchAgents
    OWNER_BIN=$DESTDIR$OWNER_HOME/bin

    # ---- sources: must be plain files that OWNER_USER cannot influence
    files="lidosd anythingllm-caffeinate.sh lidosd.sudoers $DAEMON_LABEL.plist $AGENT_LABEL.plist"
    for f in $files; do
        [ -f "$SRC/$f" ] && [ ! -L "$SRC/$f" ] || die "missing or not a regular file: $SRC/$f"
    done
    check_src_item "$SRC"
    for f in $files; do check_src_item "$SRC/$f"; done
    d=$(dirname "$SRC")
    while :; do
        if owned_by_owner "$d"; then die "$d (above the source folder) is owned by $OWNER_USER"; fi
        if owner_can_write "$d" || group_or_other_writable "$d"; then
            is_sticky "$d" || die "$d (above the source folder) is writable by others and not sticky"
        fi
        [ "$d" = / ] && break
        d=$(dirname "$d")
    done

    # ---- copy to a private root-owned dir; validate and install ONLY from the copy
    STAGE=$(mktemp -d /tmp/lidosd-install.XXXXXX)
    trap cleanup EXIT
    chmod 700 "$STAGE"
    for f in $files; do cp "$SRC/$f" "$STAGE/$f"; done
    chmod 755 "$STAGE/lidosd" "$STAGE/anythingllm-caffeinate.sh"
    chmod 644 "$STAGE/$DAEMON_LABEL.plist" "$STAGE/$AGENT_LABEL.plist"
    chmod 440 "$STAGE/lidosd.sudoers"

    /bin/bash -n "$STAGE/lidosd"                    || die "syntax error in lidosd"
    /bin/bash -n "$STAGE/anythingllm-caffeinate.sh" || die "syntax error in anythingllm-caffeinate.sh"
    if command -v plutil >/dev/null 2>&1; then
        plutil -lint "$STAGE/$DAEMON_LABEL.plist" "$STAGE/$AGENT_LABEL.plist" >/dev/null \
            || die "plist failed plutil -lint"
    fi
    if command -v visudo >/dev/null 2>&1; then
        visudo -cf "$STAGE/lidosd.sudoers" >/dev/null || die "lidosd.sudoers failed visudo check"
    fi

    # the user name and paths are hard-wired in several files; refuse if they disagree
    # grep -q "^$OWNER_USER[[:space:]]" "$STAGE/lidosd.sudoers" \
        # || die "lidosd.sudoers does not grant a rule to '$OWNER_USER'"
    grep -Eq "^([[:space:]]*|[^#=]*[[:space:],])$OWNER_USER[[:space:],][^=]*=" "$STAGE/lidosd.sudoers" \
        || die "lidosd.sudoers does not grant a rule to '$OWNER_USER'"
    grep -q "^OWNER_USER=$OWNER_USER\$" "$STAGE/lidosd" \
        || die "lidosd does not set OWNER_USER=$OWNER_USER"
    grep -Fq "OWNER_USER=\${OWNER_USER:-$OWNER_USER}" "$STAGE/anythingllm-caffeinate.sh" \
        || die "anythingllm-caffeinate.sh does not default OWNER_USER to '$OWNER_USER'"
    grep -Fq "$OWNER_HOME/bin/anythingllm-caffeinate.sh" "$STAGE/$AGENT_LABEL.plist" \
        || die "agent plist does not reference $OWNER_HOME/bin/anythingllm-caffeinate.sh"

    # ---- nothing has changed yet: refuse now if OWNER_USER could tamper with root-run paths
    verify_root_paths || die "refusing to install: fix ownership/permissions of the paths above (e.g. sudo chown root:wheel DIR; sudo chmod go-w DIR, or remove $OWNER_USER from the owning group), then re-run. Nothing was changed."   # PRE-CHECK

    # ---- stop
    say "Stopping running pieces (if any)"
    lctl bootout "system/$DAEMON_LABEL" 2>/dev/null || true
    if lctl print "gui/$OWNER_UID" >/dev/null 2>&1; then
        lctl bootout "gui/$OWNER_UID/$AGENT_LABEL" 2>/dev/null || true
    fi
    wait_unloaded "system/$DAEMON_LABEL"
    wait_unloaded "gui/$OWNER_UID/$AGENT_LABEL"

    # ---- root pieces
    say "Installing lid OSD (root-owned)"
    for d in "$SBIN" "$DAEMONS" "$SUDOERS_D"; do
        [ -d "$d" ] || install -d -o root -g "$ROOT_GROUP" -m 755 "$d"
    done
    install -o root -g "$ROOT_GROUP" -m 755 "$STAGE/lidosd" "$SBIN/lidosd"
    install -o root -g "$ROOT_GROUP" -m 644 "$STAGE/$DAEMON_LABEL.plist" "$DAEMONS/$DAEMON_LABEL.plist"
    if ! verify_root_paths; then
        rm -f "$SBIN/lidosd" "$DAEMONS/$DAEMON_LABEL.plist" "$SUDOERS_D/lidosd"
        die "root-run files are not safe from $OWNER_USER; removed lidosd, its plist and its sudoers rule (rolled back). Nothing was started."
    fi

    # ---- sudoers (back up any previous rule so a failed validation restores it)
    say "Installing sudoers rule"
    local prev=
    if [ -f "$SUDOERS_D/lidosd" ]; then
        prev=$STAGE/sudoers.prev
        cp -p "$SUDOERS_D/lidosd" "$prev"
    fi
    install -o root -g "$ROOT_GROUP" -m 440 "$STAGE/lidosd.sudoers" "$SUDOERS_D/lidosd"
    if [ "$TEST_MODE" != 1 ] && command -v visudo >/dev/null 2>&1; then
        if ! visudo -c >/dev/null 2>&1; then
            if [ -n "$prev" ]; then
                install -o root -g "$ROOT_GROUP" -m 440 "$prev" "$SUDOERS_D/lidosd"
            else
                rm -f "$SUDOERS_D/lidosd"
            fi
            die "sudoers failed full-config validation after install; previous state restored"
        fi
    fi

    # ---- llmserver pieces, written AS llmserver (a planted symlink gains it nothing)
    say "Installing keep-awake agent for $OWNER_USER (written as $OWNER_USER)"
    as_owner /usr/bin/install -d -m 755 "$OWNER_BIN" "$AGENT_DIR"
    put_as_owner "$STAGE/anythingllm-caffeinate.sh" "$OWNER_BIN/anythingllm-caffeinate.sh" 755
    put_as_owner "$STAGE/$AGENT_LABEL.plist" "$AGENT_DIR/$AGENT_LABEL.plist" 644

    # ---- start
    say "Starting lid OSD daemon"
    lctl bootstrap system "$DAEMONS/$DAEMON_LABEL.plist" \
        || die "launchctl bootstrap of $DAEMON_LABEL failed"

    if lctl print "gui/$OWNER_UID" >/dev/null 2>&1; then
        say "Starting keep-awake agent in $OWNER_USER's GUI session"
        lctl bootstrap "gui/$OWNER_UID" "$AGENT_DIR/$AGENT_LABEL.plist" \
            || warn "could not load the agent now; it will load at $OWNER_USER's next login"
    else
        warn "$OWNER_USER has no GUI session; the agent will start at their next login"
    fi

    cat <<EOF

Done. Verify:
  tail /var/log/lidosd.log
  sudo -u $OWNER_USER /usr/local/sbin/lidosd status
  pmset -g assertions        # while $OWNER_USER's AnythingLLM is running
To remove everything:  sudo bash '$SRC/uninstall.sh'
EOF
}

main "$@"
exit $?
