# Testing lidosd

There are three layers:

1. **Logic tests** (`tests/lidosd-logic-test.sh`, described below): automated, run against a
   copy of `lidosd` in a scratch tree with fake `pmset`, `ioreg`, `sudo` and `docker`. They
   never change the live system.
2. **Sudoers-check tests** (`tests/sudoers-check-test.sh`, see "Sudoers-check tests" at the
   end): automated, no root needed; they test how `install.sh` validates the staged
   `lidosd.sudoers` and the `MAX_LIMIT` agreement.
3. **Functional tests** (`INSTALL.md`, items 1 to 16): run by hand on the installed system.
   Items 7, 8 and 11 to 15 cover the container check, the sudoers refusals and the `-l`
   limit; item 16 checks the `pmset` read-back lines in the log. Items 7, 8 and 11 to 16 were
   written from the scripts and have not been run yet (they wait for the real reinstall).

The logic tests cover what can be proven without the real system. Real `sudo`/sudoers
matching, launchd, the real `docker` CLI and the real `pmset` are only exercised by the
functional tests after a real install.

## Logic tests

```
sudo /bin/bash tests/lidosd-logic-test.sh [PATH-TO-lidosd]
```

- Run as root: `lidosd` insists on a root-owned state directory. Takes a few minutes (the
  daemon scenarios wait on real polling).
- Without an argument it tests the repo's `lidosd` (the file one level above `tests/`,
  found from the script's own location); pass a path to test another copy.
- Output is one `PASS`/`FAIL` line per check and a final count. Exit status is 0 only if
  every check passed. On failure the scratch tree is kept (its path is printed), and the
  tails of the daemon and fake-`pmset` logs are shown for the failing daemon scenario.
- Written for macOS `/bin/bash` (3.2).

### How it works

The script copies `lidosd` into a root-owned scratch directory under `/private/tmp` and runs
that copy in test mode. Test mode (`LIDOSD_TEST=1`) lets environment variables replace the
tools and paths `lidosd` uses. It is honored only when `SUDO_USER` is unset, so a caller
coming through `sudo` can never turn it on; the test script therefore runs `lidosd` through
`env -u SUDO_USER`.

| Hook | Replaced by |
|---|---|
| `LIDOSD_PMSET` | fake `pmset`: logs its arguments, keeps a `SleepDisabled` flag, and can fail, lie or fail a set number of times (modes below) |
| `LIDOSD_IOREG` | fake `ioreg`: reports the lid open or closed from a file |
| `LIDOSD_SUDO` | fake `sudo`: `exec` mode drops `-n -u USER -H` and runs the command; `log` mode only records its arguments |
| `LIDOSD_DOCKER` | fake `docker`, behavior set from a file (see below) |
| `LIDOSD_CONTAINER`, `LIDOSD_OWNER_USER` | `testbox`, `llmtest` |
| `LIDOSD_STATE_DIR` | the scratch state directory |
| `LIDOSD_POLL`, `LIDOSD_CHECK_TIMEOUT` | 1 s each, so the daemon scenarios run quickly |
| `LIDOSD_DISARM_RETRIES` | 3 (the real value is 12), so the give-up scenario is short |

The fake `docker` modes: `true`, `false`, `fail` (error exit), `junk` (`true x`), `hang`
(sleeps), `hangterm` (hangs and ignores TERM, so only `kill -9` ends it) and `flaky` (two
`false` answers, then `true`).

The fake `pmset` modes (the file `pmset.mode`; they apply to the `disablesleep` sets only,
and `pmset -g` always answers): `ok` (default), `fail` (every set exits 1 with a message),
`lie` (a set exits 0 but the flag does not change, so only the read-back catches it) and
`failn` (the next N sets fail, N from the file `pmset.failsleft`, then they work).

### Safety guards

- **Canary:** before anything else, a read-only `lidosd status` must reach the fake `pmset`.
  If it does not, the hooks are not in effect and the script aborts without running anything
  that changes state.
- **Live system check:** the script records the live `/var/db/lidosd` file stats and the real
  `SleepDisabled` value (one read-only `pmset -g`) at the start and compares them at the end.
  Arming the live daemon while the tests run makes that check fail, legitimately.
- The scratch tree is removed on success and kept on failure.

### What it covers (160 checks)

| Section | Checks | What is checked |
|---|---|---|
| 0. Hooks | 1 | The fake `pmset` is the one called. |
| 1. Command line | 4 | `-l 1441`, `disarm -l 5` and an unknown word are refused with exit 2 and change nothing. |
| 2. Arm refusal | 27 | With the container answering `false`, an error, `true x`, hanging, or hanging while ignoring TERM, `arm` exits 1 with the refusal message, leaves the state idle, never disables sleep and writes no deadline. Both hang cases give up within 5 s (this exercises the `kill -9` path). |
| 3. Arm | 5 | A healthy container arms: state `armed`, sleep disabled, no deadline without `-l`, and `docker` is asked as `-n -u llmtest -H <absolute path> inspect --format {{.State.Running}} testbox`. |
| 4. Limit | 14 | `-l 1`, `-l 05` and `--limit=0010` write a deadline about 60, 300 and 600 s ahead (leading zeros canonicalized) and `status` shows the minutes left. `-l 0` and a plain `lidosd` clear the limit. A refused re-arm leaves the old deadline untouched. `disarm` returns to idle, re-enables sleep and removes the deadline. |
| 5. Status | 5 | No `limit:` line when idle. A garbage, 14-digit or symlink deadline shows `invalid`; a past deadline shows `expired`. |
| 6. Daemon | 32 | See the list below. |
| 6A. `pmset` failures | 49 | See the list below. |
| 7. Sudo arguments | 21 | Run as user `nobody` with the fake `sudo` in `log` mode. Every accepted spelling reaches sudo in a canonical form: nothing, `disarm` or `-l N` (for example `arm -l 05` becomes `-l 5`, `--limit=0010` becomes `-l 10`, `-l5` becomes `-l 5`, `-l 0000` becomes `-l 0`, `-l 1440` stays). Invalid input (`-l 1441`, `-l 00005`, `disarm -l 5`, `-l`, `-l x`) exits 2 with no sudo call. These are the forms the sudoers patterns must match. |
| 8. Live system | 2 | The live state files and `SleepDisabled` are unchanged. |

Daemon scenarios (section 6, poll 1 s):

- 6.1 The container stops while armed: disarm after 3 consecutive failed checks.
- 6.2 Two failed checks in a row do not disarm; the daemon keeps polling.
- 6.3 The limit runs out while armed: `limit reached (or deadline file invalid); disarming`.
- 6.4 A garbage, expired or symlink deadline at startup: idle at once, logged as `at startup`.
- 6.5 The container is down at startup: idle at once.
- 6.6 Healthy at startup stays armed; SIGTERM disarms and re-enables sleep.
- 6.7 The limit runs out while the lid is closed (state `closed`).
- 6.8 A hung container check counts as a failure and leads to a disarm.

`pmset` failure scenarios (section 6A; every `disablesleep` set is checked by exit status and
read back with `pmset -g`; the first five use the command line, the rest the daemon):

- 6A.1 `arm` with `pmset` exiting 1: exit 1, an `arm failed:` line with the exit status and `pmset`'s message, the undo also fails (`arm undo failed:`), state idle, no deadline, no `armed:` line.
- 6A.2 `arm -l 5` with `pmset` exiting 0 but the flag unchanged (`lie`): the read-back mismatch is logged, then `arm undone: SleepDisabled 0 confirmed`; state idle, deadline removed.
- 6A.3 A healthy `arm`: the log line ends in `[SleepDisabled 1 confirmed]` and there is no `failed` text.
- 6A.4 `disarm` with `pmset` failing: exit 1, state left `armed`, `disarm failed:` logged, `(state left unchanged)` on stderr, no `disarmed:` line.
- 6A.5 A healthy `disarm`: `[SleepDisabled 0 confirmed]`, state idle, flag 0.
- 6A.6 The daemon's disarm keeps failing (3 retries in the test): exactly two error lines (the first failure and the final one; the retries are silent), then `giving up, sleep may STILL BE DISABLED`; state idle, flag still 1.
- 6A.7 The daemon's disarm fails twice, then works: `disarmed after 2 failed attempts`, one `disarm failed:` line, no give-up.
- 6A.8 Daemon start in state idle with the first two sets failing: the start failure is logged with the exit status, then the retries succeed.
- 6A.9 Daemon start in state armed with the flag not re-applied: the start failure, the fail-safe disarm (which also fails once), then success after one retry; state idle.
- 6A.10 Daemon start with a healthy `pmset`, in state armed and in state idle: `daemon start: SleepDisabled N confirmed` and no failure line.

### Not covered

- Real `sudo` and sudoers matching (section 7 shows what `lidosd` sends, not that sudo accepts it).
- launchd and the daemon's real start, and the real `docker` CLI under the daemon.
- The real `pmset`: its real exit status and messages on failure, and whether `pmset -g`
  shows a change at once (the read-back after each set). Only the reinstall shows these
  (`INSTALL.md` item 16).
- Behavior under load or across a reboot.

### Last recorded run

2026-11-07, run by the user as `sudo /bin/bash` on the Monterey Mac: **160 passed, 0 failed**
(the 111 earlier checks plus the 49 of section 6A), after the `pmset` exit-status and
read-back work (e). Before that, 2026-11-06: 111 passed, 0 failed, after the container check
(d1) and the `-l|--limit` option (d2) were committed.

### Changing the tests

- `check DESC CMD...` passes when the command succeeds; `nocheck` passes when it fails.
- `begin NAME` resets the scratch state and starts a scenario; `end_` stops the daemon and
  prints the log tails if a check in that scenario failed.
- `startd` starts the daemon in the background; `stop_daemon` sends it SIGTERM.
- Update the counts in this file when checks are added or removed.

## Sudoers-check tests

```
/bin/bash tests/sudoers-check-test.sh [REPO-DIR]
```

- Run as an ordinary user. It reads the repo's `lidosd.sudoers`, `install.sh` and `lidosd`
  (found from the script's own location, or from `REPO-DIR`) and writes only to a scratch
  directory under `/tmp`, removed on exit. It never touches the live system.
- Output is one `PASS`, `FAIL` or `SKIP` line per check and a final count. Exit status is 0
  when nothing failed (`SKIP` is not a failure). Written for macOS `/bin/bash` (3.2).

### What it tests

`install.sh` checks the staged sudoers file by normalizing its active lines and comparing
them with the expected set for the group given by `--group`. Normalizing drops comments and
blank lines; trims indentation; collapses runs of whitespace; makes the spacing around `,`
`:` and `=` uniform; strips the trailing `,` and the continuation `\`; and sorts. The result
must equal the expected 10 lines (the alias header, its 8 entries and the rule line). A
layout change passes, a content change fails. It also reads `MAX_LIMIT` from the staged
`lidosd` and requires 1440, the top number pattern.

| Section | Checks | What is checked |
|---|---|---|
| 1. Layout tolerated | 8 | The committed template with the group substituted; a tab indent; no indent; a deeper indent with trailing spaces; no spaces before backslashes, around `=` or after `NOPASSWD:`; every space tripled; other comments and blank lines; the rule line first with the entries in reverse order. All must match. |
| 2. Changes rejected | 13 | A widened pattern; a missing entry; an extra entry (`lidosd *`); an extra `%admin` rule; a duplicated entry; the wrong group; `NOPASSWD: ALL`; a renamed alias; a top entry of 1441; a wrong path; an empty file. Also two documented limits that fail on purpose: two entries joined on one line, and a space after a continuation backslash. |
| 3. `MAX_LIMIT` | 10 | The repo `lidosd` gives 1440; a trailing comment, none, or one space is accepted; a different value is read as is; no line, a commented line, trailing text that is not a comment, an empty value and a double definition do not read as 1440. |
| 4. Sync | 2 | The sudoers block and the `max=` line in `install.sh` equal the reference copy in the test, ignoring indentation. `SKIP` while `install.sh` does not contain them yet. |

### The reference copy

The code under test is written into the script (`ref-sudoers.sh` and `ref-max.sh`, as
temporary files) and run from there. Section 4 compares it with `install.sh`, with
`"$STAGE/lidosd.sudoers"` read as `"$F"` and `"$STAGE/lidosd"` as `"$M"`, so a change in
one place without the other shows as a `FAIL` with a diff. Change both together.

### Not covered

- That real `sudo` or `visudo` accepts a reformatted variant. `install.sh` runs
  `visudo -cf` on the staged copy as a separate step, and the test does not.
- That real `sudo` matches the patterns (only the real reinstall shows that).
- Reformatting that moves content between lines (see the two documented limits).

### Last recorded run

2026-11-06, run by the user as an ordinary user: first run 31 passed, 0 failed, 2 skipped (before the `install.sh` edit); after it, **33 passed, 0 failed, 0 skipped**.
