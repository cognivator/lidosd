#!/bin/bash
# sudoers-check-test.sh - tests for the lidosd.sudoers checks in install.sh
#
# Run as an ordinary user (no root needed; nothing live is read or written):
#     /bin/bash tests/sudoers-check-test.sh [REPO-DIR]
# (default: the repo one level above this script).
#
# install.sh validates the staged sudoers file by normalizing its active lines
# (comments and blank lines dropped; indentation, runs of whitespace, spacing
# around , : = and the line-continuation backslashes ignored; order ignored) and
# comparing them with the expected set for the chosen group. It also reads
# MAX_LIMIT from the staged lidosd and requires 1440, the top sudoers pattern.
# This script tests that logic on the committed template and on reformatted and
# tampered copies of it.
#
# The code under test is a reference copy written below (ref-sudoers.sh and
# ref-max.sh). A sync check compares it, ignoring indentation, with the code in
# install.sh and FAILS if they differ; it reports SKIP while install.sh does not
# contain the check yet. Change the reference and install.sh together.
#
# NOT covered: that real sudo or visudo accepts a reformatted variant (install.sh
# runs `visudo -cf` on the staged copy separately), and that real sudo matches the
# patterns (only the real reinstall shows that). Written for macOS /bin/bash (3.2).

REPO=${1:-$(cd "$(dirname "$0")/.." && pwd)}
TEMPLATE=$REPO/lidosd.sudoers
INSTALL=$REPO/install.sh
LIDOSD=$REPO/lidosd
for f in "$TEMPLATE" "$INSTALL" "$LIDOSD"; do
    [ -f "$f" ] || { echo "no such file: $f" >&2; exit 1; }
done

W=$(/usr/bin/mktemp -d /tmp/lidosd-sudoers-test.XXXXXX) || exit 1
trap '/bin/rm -rf "$W"' EXIT
TAB=$(printf '\t')
HELPER_DIR=/Library/PrivilegedHelperTools
pass=0; fail=0; skip=0
ok()  { pass=$((pass + 1)); echo "PASS  $1"; }
bad() { fail=$((fail + 1)); echo "FAIL  $1"; }
skp() { skip=$((skip + 1)); echo "SKIP  $1"; }

# ---- reference code: what install.sh is expected to contain (indentation aside).
# $F is the sudoers file, $M the lidosd file; install.sh has "$STAGE/..." there.
/bin/cat > "$W/ref-sudoers.sh" <<'EOF'
sudoers_active=$(grep -Ev '^[[:space:]]*(#|$)' "$F" \
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
EOF
/bin/cat > "$W/ref-max.sh" <<'EOF'
max=$(sed -n 's/^MAX_LIMIT=\([0-9][0-9]*\)[[:space:]]*\(#.*\)\{0,1\}$/\1/p' "$M")
EOF

sudoers_ok() {   # sudoers_ok FILE GROUP : 0 if the normalized active lines are the expected set
    F=$1; SLEEP_GROUP=$2
    . "$W/ref-sudoers.sh"
    [ "$sudoers_active" = "$sudoers_expect" ]
}
accepts() {      # accepts DESC FILE [GROUP]
    if sudoers_ok "$2" "${3:-sleepers}"; then ok "$1"; else bad "$1 (expected a match)"; fi
}
rejects() {      # rejects DESC FILE [GROUP]
    if sudoers_ok "$2" "${3:-sleepers}"; then bad "$1 (expected a mismatch)"; else ok "$1"; fi
}
max_is() {       # max_is DESC FILE EXPECTED   (EXPECTED empty = no value found)
    M=$2
    . "$W/ref-max.sh"
    if [ "$max" = "$3" ]; then ok "$1"; else bad "$1 (got '$max', expected '$3')"; fi
}

BASE=$W/base
sed 's/@@SLEEP_GROUP@@/sleepers/g' "$TEMPLATE" > "$BASE"
[ -s "$BASE" ] || { echo "empty template: $TEMPLATE" >&2; exit 1; }

# ---------------------------------------------------------------- 1. layout changes to tolerate
echo "== 1. Layout changes the check must tolerate"
accepts "committed template, group substituted" "$BASE"
sed "s/^    /$TAB/" "$BASE" > "$W/v"
accepts "indent is a tab" "$W/v"
sed 's/^[[:space:]]*//' "$BASE" > "$W/v"
accepts "no indentation" "$W/v"
sed -e 's/^    /            /' -e '/\\$/!s/$/   /' "$BASE" > "$W/v"
accepts "deeper indent, trailing spaces on lines without a backslash" "$W/v"
sed -e 's/ = \\$/=\\/' -e 's/, \\$/,\\/' -e 's/NOPASSWD: /NOPASSWD:/' "$BASE" > "$W/v"
accepts "no space before backslashes, around = or after NOPASSWD:" "$W/v"
sed 's/ /   /g' "$BASE" > "$W/v"
accepts "every space tripled" "$W/v"
{ echo; echo '# extra comment'; sed '/^#/d' "$BASE"; echo; echo '# trailing comment'; } > "$W/v"
accepts "other comments and blank lines, header comment removed" "$W/v"
{
    echo "%sleepers ALL=(root) NOPASSWD: LIDOSD_CMDS"
    echo "Cmnd_Alias LIDOSD_CMDS = \\"
    echo "  $HELPER_DIR/lidosd -l 1440, \\"
    echo "  $HELPER_DIR/lidosd -l 14[0-3][0-9], \\"
    echo "  $HELPER_DIR/lidosd -l 1[0-3][0-9][0-9], \\"
    echo "  $HELPER_DIR/lidosd -l [1-9][0-9][0-9], \\"
    echo "  $HELPER_DIR/lidosd -l [1-9][0-9], \\"
    echo "  $HELPER_DIR/lidosd -l [0-9], \\"
    echo "  $HELPER_DIR/lidosd disarm, \\"
    echo "  $HELPER_DIR/lidosd \"\""
} > "$W/v"
accepts "rule line first, entries in reverse order" "$W/v"

# ---------------------------------------------------------------- 2. changes to reject
echo "== 2. Changes the check must reject"
sed 's/-l 14\[0-3\]\[0-9\],/-l 14[0-9][0-9],/' "$BASE" > "$W/v"
rejects "a pattern widened (14[0-3][0-9] to 14[0-9][0-9])" "$W/v"
sed '/lidosd disarm,/d' "$BASE" > "$W/v"
rejects "the disarm entry missing" "$W/v"
awk '{print} /lidosd disarm,/ {print "    /Library/PrivilegedHelperTools/lidosd *, \\"}' "$BASE" > "$W/v"
rejects "an extra entry (lidosd *)" "$W/v"
{ cat "$BASE"; echo "%admin ALL=(root) NOPASSWD: LIDOSD_CMDS"; } > "$W/v"
rejects "an extra rule line for %admin" "$W/v"
awk '{print} /lidosd disarm,/ {print}' "$BASE" > "$W/v"
rejects "a duplicated entry" "$W/v"
rejects "rule names %sleepers but the group given is staff" "$BASE" staff
sed 's/NOPASSWD: LIDOSD_CMDS/NOPASSWD: ALL/' "$BASE" > "$W/v"
rejects "rule grants ALL instead of the alias" "$W/v"
sed 's/LIDOSD_CMDS/CMDS/g' "$BASE" > "$W/v"
rejects "alias renamed" "$W/v"
sed 's/-l 1440/-l 1441/' "$BASE" > "$W/v"
rejects "top entry changed to 1441" "$W/v"
sed 's|PrivilegedHelperTools|usr/local/sbin|g' "$BASE" > "$W/v"
rejects "wrong path" "$W/v"
{
    echo "Cmnd_Alias LIDOSD_CMDS = \\"
    echo "  $HELPER_DIR/lidosd \"\", $HELPER_DIR/lidosd disarm, \\"
    echo "  $HELPER_DIR/lidosd -l [0-9], \\"
    echo "  $HELPER_DIR/lidosd -l [1-9][0-9], \\"
    echo "  $HELPER_DIR/lidosd -l [1-9][0-9][0-9], \\"
    echo "  $HELPER_DIR/lidosd -l 1[0-3][0-9][0-9], \\"
    echo "  $HELPER_DIR/lidosd -l 14[0-3][0-9], \\"
    echo "  $HELPER_DIR/lidosd -l 1440"
    echo "%sleepers ALL=(root) NOPASSWD: LIDOSD_CMDS"
} > "$W/v"
rejects "two entries joined on one line (documented limit)" "$W/v"
sed '/\\$/s/$/ /' "$BASE" > "$W/v"
rejects "a space after a continuation backslash (documented limit)" "$W/v"
: > "$W/v"
rejects "empty file" "$W/v"

# ---------------------------------------------------------------- 3. MAX_LIMIT extraction
echo "== 3. MAX_LIMIT extraction"
max_is "the repo lidosd" "$LIDOSD" 1440
printf 'MAX_LIMIT=1440      # comment\n' > "$W/m"
max_is "value, spaces, comment" "$W/m" 1440
printf 'MAX_LIMIT=1440\n' > "$W/m"
max_is "value alone" "$W/m" 1440
printf 'MAX_LIMIT=1440 # c\n' > "$W/m"
max_is "value, one space, comment" "$W/m" 1440
printf 'MAX_LIMIT=1441  # c\n' > "$W/m"
max_is "a different value is read as is" "$W/m" 1441
printf 'X=1\n' > "$W/m"
max_is "no MAX_LIMIT line" "$W/m" ""
printf '# MAX_LIMIT=1440\n' > "$W/m"
max_is "commented out" "$W/m" ""
printf 'MAX_LIMIT=1440 extra\n' > "$W/m"
max_is "trailing text that is not a comment" "$W/m" ""
printf 'MAX_LIMIT=\n' > "$W/m"
max_is "empty value" "$W/m" ""
printf 'MAX_LIMIT=1440\nMAX_LIMIT=1\n' > "$W/m"
max_is "defined twice (both values come back, so a check for 1440 fails)" "$W/m" "$(printf '1440\n1')"

# ---------------------------------------------------------------- 4. sync with install.sh
echo "== 4. Sync with install.sh"
awk '/sudoers_active=\$\(/ {on = 1} on {print} on && /lidosd -l 1440" \| LC_ALL=C sort\)/ {exit}' "$INSTALL" \
    | sed -e 's/^[[:space:]]*//' -e 's|"\$STAGE/lidosd.sudoers"|"$F"|' > "$W/inst-sudoers.txt"
sed 's/^[[:space:]]*//' "$W/ref-sudoers.sh" > "$W/ref-sudoers.txt"
if [ ! -s "$W/inst-sudoers.txt" ]; then
    skp "install.sh has no sudoers check yet (sudoers block)"
elif cmp -s "$W/ref-sudoers.txt" "$W/inst-sudoers.txt"; then
    ok "install.sh sudoers block equals the reference (indentation aside)"
else
    bad "install.sh sudoers block differs from the reference (< reference, > install.sh):"
    diff "$W/ref-sudoers.txt" "$W/inst-sudoers.txt" | sed 's/^/      /'
fi
grep 'max=\$(sed' "$INSTALL" \
    | sed -e 's/^[[:space:]]*//' -e 's|"\$STAGE/lidosd"|"$M"|' > "$W/inst-max.txt"
sed 's/^[[:space:]]*//' "$W/ref-max.sh" > "$W/ref-max.txt"
if [ ! -s "$W/inst-max.txt" ]; then
    skp "install.sh has no MAX_LIMIT check yet (max line)"
elif cmp -s "$W/ref-max.txt" "$W/inst-max.txt"; then
    ok "install.sh max line equals the reference (indentation aside)"
else
    bad "install.sh max line differs from the reference (< reference, > install.sh):"
    diff "$W/ref-max.txt" "$W/inst-max.txt" | sed 's/^/      /'
fi

echo
echo "$pass passed, $fail failed, $skip skipped"
[ "$fail" -eq 0 ]
