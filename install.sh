#!/bin/bash
# install.sh - deploy the AnythingLLM keep-awake pieces from THIS folder.
#
#   sudo bash /Users/Shared/<reponame>/install.sh --group NAME
#
# --group NAME (required): the group whose members may run lidosd and
# lidosd disarm without a password (substituted into the sudoers rule). The
# installer does not create the group or add members; it only warns.
#
# The source folder is located from this script's own path, so the repo name does
# not matter. Safe to re-run: it stops the running pieces, redeploys, and starts
# them again. (Stopping the lid daemon disarms an armed OSD.)
#
# Deployed:
#   root       /Library/PrivilegedHelperTools/lidosd
#              /Library/LaunchDaemons/com.llmserver.lidosd.plist   (loaded)
#              /etc/sudoers.d/lidosd                               (validated; grants group NAME)
#   llmserver  ~/.local/bin/anythingllm-caffeinate.sh
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
#   * Existing shared directories (e.g. /Library/PrivilegedHelperTools) are never chown'd or
#     chmod'd; missing ones are created root:wheel 755.
#
# OWNER_USER is a constant below and must match lidosd (checked before installing).
# The agent plist must name the script under OWNER_HOME/.local/bin (also checked).
#
# Test mode: INSTALL_TEST=1 plus DESTDIR (stage under a prefix) enables the
# overrides DESTDIR, OWNER_USER, OWNER_HOME, ROOT_GROUP and LAUNCHCTL (unset
# LAUNCHCTL = skip all launchctl calls). Without INSTALL_TEST=1 they are ignored.
# --group is a command-line flag in both modes, never an environment variable.

PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH
umask 022
set -eu

DAEMON_LABEL=com.llmserver.lidosd
AGENT_LABEL=com.llmserver.anythingllm-caffeinate
HELPER_DIR=/Library/PrivilegedHelperTools
SLEEP_GROUP=
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

usage() {
    echo "usage: sudo bash $0 --group NAME" >&2
    echo "  NAME: an existing group whose members may run lidosd without a password" >&2
    echo "        (1-32 characters: a-z, 0-9, _ and -; not starting with a digit or -)" >&2
    exit 2
}

# Parse and validate the command line. Runs before the sudo re-exec, so a missing
# or bad --group fails without a password prompt.
parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --group)
                [ $# -ge 2 ] || { echo "install.sh: --group needs a value" >&2; usage; }
                SLEEP_GROUP=$2
                shift 2 ;;
            --group=*)
                SLEEP_GROUP=${1#--group=}
                shift ;;
            *)
                echo "install.sh: unknown argument: $1" >&2
                usage ;;
        esac
    done
    [ -n "$SLEEP_GROUP" ] || { echo "install.sh: --group NAME is required" >&2; usage; }
    case "$SLEEP_GROUP" in
        [!abcdefghijklmnopqrstuvwxyz_]*|*[!abcdefghijklmnopqrstuvwxyz0123456789_-]*)
            die "invalid group name '$SLEEP_GROUP': use a-z, 0-9, _ and - only, starting with a letter or _" ;;
    esac
    [ "${#SLEEP_GROUP}" -le 32 ] || die "group name '$SLEEP_GROUP' is longer than 32 characters"
}

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

# Action items, not errors (D1): the installer neither creates the group nor adds members.
group_warnings() {
    local gid
    if ! dscl . -read "/Groups/$SLEEP_GROUP" >/dev/null 2>&1; then
        warn "group '$SLEEP_GROUP' does not exist, so the sudoers rule grants nobody anything yet. Create it: sudo dseditgroup -o create $SLEEP_GROUP"
        return 0
    fi
    if ! dseditgroup -o checkmember -m "$OWNER_USER" "$SLEEP_GROUP" >/dev/null 2>&1; then
        warn "$OWNER_USER is not a member of '$SLEEP_GROUP'. Add: sudo dseditgroup -o edit -a $OWNER_USER -t user $SLEEP_GROUP"
    fi
    gid=$(dscl . -read "/Groups/$SLEEP_GROUP" PrimaryGroupID 2>/dev/null | sed -n 's/^PrimaryGroupID:[[:space:]]*//p')
    case "$gid" in
        ''|*[!0-9]*) warn "could not read the GID of group '$SLEEP_GROUP'" ;;
        *) if [ "$gid" -lt 500 ]; then
               warn "group '$SLEEP_GROUP' has GID $gid (below 500), a standard macOS group; a dedicated group is recommended for this rule"
           fi ;;
    esac
    return 0
}

cleanup() { if [ -n "$STAGE" ]; then rm -rf "$STAGE"; fi; }

# ---------------------------------------------------------------- main
main() {
    local f d files

    parse_args "$@"

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

    SBIN=$DESTDIR$HELPER_DIR
    DAEMONS=$DESTDIR/Library/LaunchDaemons
    SUDOERS_D=$DESTDIR/etc/sudoers.d
    AGENT_DIR=$DESTDIR$OWNER_HOME/Library/LaunchAgents
    OWNER_BIN=$DESTDIR$OWNER_HOME/.local/bin

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

    # lidosd.sudoers is a template; substitute the validated group name into the STAGED copy
    grep -Fq '@@SLEEP_GROUP@@' "$STAGE/lidosd.sudoers" \
        || die "lidosd.sudoers has no @@SLEEP_GROUP@@ placeholder (is the template intact?)"
    sed "s/@@SLEEP_GROUP@@/$SLEEP_GROUP/g" "$STAGE/lidosd.sudoers" > "$STAGE/lidosd.sudoers.new" \
        || die "could not substitute the group name into lidosd.sudoers"
    mv -f "$STAGE/lidosd.sudoers.new" "$STAGE/lidosd.sudoers"
    if grep -Fq '@@SLEEP_GROUP@@' "$STAGE/lidosd.sudoers"; then
        die "placeholder still present in the staged lidosd.sudoers after substitution"
    fi
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

    # the sudoers file must grant nothing to %admin (checked first for a clearer message)
    if grep -Eq '^[^#]*%admin' "$STAGE/lidosd.sudoers"; then
        die "lidosd.sudoers grants NOPASSWD to %admin; the decided rule is %$SLEEP_GROUP only"
    fi
    # The staged sudoers must contain exactly the expected active lines, ignoring
    # comments, blank lines, indentation, spacing around , : = and the line
    # continuation backslashes. Content is exact: a changed, missing, extra or
    # duplicated entry fails. (Moving entries to different lines is NOT tolerated.)
    # Keep in sync with tests/sudoers-check-test.sh (it compares this block).
    sudoers_active=$(grep -Ev '^[[:space:]]*(#|$)' "$STAGE/lidosd.sudoers" \
        | sed -e 's/[[:space:]][[:space:]]*/ /g' -e 's/^ //' \
              -e 's/ *\\$//' -e 's/ *, *$//' \
              -e 's/ *= */ = /' -e 's/ *: */: /' -e 's/ $//' \
        | LC_ALL=C sort)
    sudoers_expect=$(printf '%s\n' \
        "Cmnd_Alias LIDOSD_CMDS =" \
        "%$SLEEP_GROUP ALL = (root) NOPASSWD: LIDOSD_CMDS" \
        "$HELPER_DIR/lidosd \"\"" \
        "$HELPER_DIR/lidosd disarm" \
        "$HELPER_DIR/lidosd -l [0-9]" \
        "$HELPER_DIR/lidosd -l [1-9][0-9]" \
        "$HELPER_DIR/lidosd -l [1-9][0-9][0-9]" \
        "$HELPER_DIR/lidosd -l 1[0-3][0-9][0-9]" \
        "$HELPER_DIR/lidosd -l 14[0-3][0-9]" \
        "$HELPER_DIR/lidosd -l 1440" | LC_ALL=C sort)
    if [ "$sudoers_active" != "$sudoers_expect" ]; then
        echo "install.sh: lidosd.sudoers active lines differ from the expected set (< expected, > found):" >&2
        diff <(printf '%s\n' "$sudoers_expect") <(printf '%s\n' "$sudoers_active") >&2 || true
        die "lidosd.sudoers does not match the expected rule for group '$SLEEP_GROUP'"
    fi
    # the top pattern (1440) must agree with MAX_LIMIT in lidosd
    max=$(sed -n 's/^MAX_LIMIT=\([0-9][0-9]*\)[[:space:]]*\(#.*\)\{0,1\}$/\1/p' "$STAGE/lidosd")
    [ "$max" = 1440 ] \
        || die "lidosd MAX_LIMIT is '${max:-not found}' but the sudoers patterns stop at 1440; change both together"

    # the user name and paths are hard-wired in several files; refuse if they disagree
    grep -q "^OWNER_USER=$OWNER_USER\$" "$STAGE/lidosd" \
        || die "lidosd does not set OWNER_USER=$OWNER_USER"
    grep -Fq "$OWNER_HOME/.local/bin/anythingllm-caffeinate.sh" "$STAGE/$AGENT_LABEL.plist" \
        || die "agent plist does not reference $OWNER_HOME/.local/bin/anythingllm-caffeinate.sh"

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

    group_warnings

    cat <<EOF

Done. Verify:
  tail /var/log/lidosd.log
  sudo -u $OWNER_USER $HELPER_DIR/lidosd status
  pmset -g assertions        # while the anythingllm container is running
To remove everything:  sudo bash '$SRC/uninstall.sh'
EOF
}

main "$@"
exit $?
