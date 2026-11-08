# Keep-awake + lid-close One-Shot Disable (macOS Monterey 12.7)

## Layout
Keep all of these together in one folder / git repo, e.g. `/Users/Shared/<reponame>/`:

- `install.sh` / `uninstall.sh` : deploy / remove everything (below)
- `anythingllm-caffeinate.sh` : holds idle + system sleep assertions while llmserver's AnythingLLM Docker container runs (it wraps `docker wait`)
- `com.llmserver.anythingllm-caffeinate.plist` : LaunchAgent that keeps that script running
- `lidosd` : OSD command and root watcher daemon (one script, subcommands)
- `com.llmserver.lidosd.plist` : LaunchDaemon that runs `lidosd daemon` as root
- `lidosd.sudoers` : template for the sudoers rule; `install.sh --group NAME` fills in the group whose members may run `lidosd`, `lidosd disarm` and `lidosd -l MINUTES` without a password

Arm trigger: `lidosd` (arm check and daemon) and `anythingllm-caffeinate.sh` use the same
check: the container named by `CONTAINER` (default `anythingllm`) must be running in
llmserver's Docker, as answered by `docker inspect` run as `OWNER_USER` (only the exact text
`true` counts). `lidosd` refuses to arm if the first check fails, and the daemon disarms
after 3 failed checks in a row (about 15 s). The caffeinate script holds the assertions
while the container runs (it wraps `docker wait`).

If the account differs, change it everywhere: the `OWNER_USER` constant in `lidosd`, the home path in the agent plist, and the `OWNER_USER=llmserver` constant near the top of `install.sh` and `uninstall.sh`. (The sudoers rule names a group, not the account, so it needs no change; add the new account to that group.) `install.sh` checks that `lidosd`'s `OWNER_USER` and the agent plist's script path agree with it, and refuses to install if not. If the container name or the Docker CLI path differs, change `CONTAINER` or `DOCKER` in both `lidosd` and `anythingllm-caffeinate.sh`; `install.sh` does not check those.

The three root-run scripts (`install.sh`, `uninstall.sh`, `lidosd`) fix their own `PATH`
and `umask` and ignore environment variables: only the constants in the files count.
(Each has a test-only switch, `INSTALL_TEST` / `UNINSTALL_TEST` / `LIDOSD_TEST`; `lidosd`'s
is additionally ignored whenever sudo started it.)

## Quick install (as an admin user)
    sudo bash /Users/Shared/<reponame>/install.sh --group NAME

`--group NAME` is required: the existing macOS group whose members may run `lidosd`
without a password (for example `sleepers`; letters a-z, digits, `_` and `-`, up to 32
characters). The installer substitutes it into the sudoers rule. It does not create the
group or add members; it only warns if the group is missing, llmserver is not in it, or
its GID is below 500.

The scripts find the folder from their own path, so the repo name doesn't matter.

Put the folder under an admin-owned location (e.g. `/Users/Shared/<reponame>`, created
by the admin, `chmod -R go-w`). `install.sh` is run as root and installs root-run code
from it, so it refuses to proceed if a source file is a symlink, is group/other-writable,
is owned or writable by llmserver, or sits under a directory llmserver or other users
control (other than sticky ones like `/Users/Shared`).

`install.sh`:
1. fixes `PATH` and `umask`, then copies the sources to a private root-owned temp dir,
   fills the `--group` name into the sudoers template there, validates (syntax, plist,
   and that the user name, group and paths agree; the sudoers file must hold exactly the
   expected rule for the group: spacing and comments may differ, but a widened pattern,
   an extra rule or a `%admin` grant is refused; and `MAX_LIMIT` in `lidosd` must match
   the top `-l` pattern, 1440) and installs only from that copy,
2. BEFORE changing anything, checks that llmserver cannot write to the root-run files
   or any directory above them (`/Library/PrivilegedHelperTools`, `/Library/LaunchDaemons`,
   `/etc/sudoers.d` and their parents). If it can, nothing is changed and the offending
   path is printed; fix its ownership/permissions and re-run,
3. stops any running copy, then installs with explicit owners/modes via `install`
   (existing shared directories are never chown'd/chmod'd; missing ones are created
   `root:wheel 755`),
4. re-checks after installing; on failure it removes lidosd, its plist and its sudoers
   rule and starts nothing,
5. installs the sudoers rule, validates the full config with `visudo -c`, and restores
   the previous rule (or removes the new one) if that fails,
6. writes llmserver's files (`~/.local/bin`, `~/Library/LaunchAgents`) AS llmserver, so a symlink
   planted there cannot redirect a root write,
7. loads the lid daemon (system) and the keep-awake agent (llmserver's GUI session;
   if llmserver isn't logged in, the agent starts at its next login),
8. prints warnings, never errors, for the group: it does not exist, llmserver is not a
   member, or its GID is below 500 (a standard macOS group).

Re-run it after editing any file in the folder. It restarts the daemon, which disarms an armed OSD.

## Setup (the group)
`install.sh --group NAME` needs the group to exist, with `llmserver` and every other
account that should run `lidosd` as members. The installer only warns; an admin creates
the group and adds the members, before or after the install:

    sudo dseditgroup -o create sleepers
    sudo dseditgroup -o edit -a USER -t user sleepers    # once per account, llmserver included

(`sleepers` is an example; use the name you pass to `--group`.)

Trust note: `lidosd` runs as root and is passwordless for the group, so no file that
another member's shell sources (a shared alias file, for example) may be writable by
llmserver, or llmserver could run code as that member.

## Who can run it
- `lidosd status`: anyone (no sudo needed).
- `lidosd` (arm), `lidosd -l MINUTES` and `lidosd disarm`: members of the group given to `install.sh --group`
  (for example `sleepers`), without a password (lidosd.sudoers). Anyone else is refused.
- `lidosd daemon`: not a user command; launchd runs it as root.

Use the full path, `/Library/PrivilegedHelperTools/lidosd` (macOS does not put that directory on PATH), or define an alias for it; no `sudo` is needed, because the script elevates itself via `sudo -n`.

Arming needs the `anythingllm` container running in llmserver's Docker, whoever types the command. State is
machine-wide: anyone's arm/disarm affects everyone.

Unexpected password prompt? `sudo -l` lists matching rules; the LAST match wins, and
drop-in files are read alphabetically after /etc/sudoers.

## Use (as a member of the `--group` group)
    lidosd            # arm, no time limit (refused if the container isn't running)
    lidosd -l 90      # arm, and disarm after 90 minutes (0 to 1440; --limit=90 also works)
    lidosd disarm     # disarm now
    lidosd status
    tail -f /var/log/lidosd.log

The OSD reverts to `idle` (and `pmset disablesleep 0`) on the FIRST of: lid closed then
reopened, `lidosd disarm`, the container stopping (3 failed checks in a row, about 15 s),
or the limit running out. The daemon polls every 5 s.

The limit is optional. The clock starts at arm; a plain `lidosd` clears an earlier limit and
`lidosd -l N` replaces it (`-l 0` means no limit). If the limit ends while the lid is
closed, the Mac then goes to sleep and the service drops until someone opens the lid.
`lidosd status` shows the time left; it does not run the container check (the daemon does).

`lidosd` checks every `pmset ... disablesleep` call (its exit status) and then reads the
flag back with `pmset -g`. In `/var/log/lidosd.log` a verified change is logged: the arm and
disarm lines end in `[SleepDisabled 1 confirmed]` and `[SleepDisabled 0 confirmed]`, and the
daemon logs `daemon start: SleepDisabled N confirmed` when it re-applies the flag at start.
A success of the exit status alone is not logged. A failure is logged with a timestamp, the
exit status and `pmset`'s own message (`arm failed: ...`, `disarm failed: ...`, `daemon start: ...`),
and so is a flag that does not read back as asked. What happens next:
- `lidosd` (arm): if sleep cannot be disabled it undoes the arm (state idle, limit removed)
  and exits 1.
- `lidosd disarm`: if sleep cannot be re-enabled it exits 1 and leaves the state as it was.
- The daemon: a failed disarm is retried on each poll (5 s), up to 12 times (about a
  minute), with no further log lines until it works (`disarmed after N failed attempts`) or
  gives up (`disarm FAILED after 12 retries; giving up, sleep may STILL BE DISABLED`), after
  which the state is `idle`. `lidosd status` always shows the real `SleepDisabled` value.
- Daemon start: if the flag cannot be re-applied for an `armed` or `closed` state, the daemon
  disarms (it never stays armed without the flag).

## Before first use
As llmserver: `/usr/local/bin/docker inspect --format '{{.State.Running}}' anythingllm` must print `true`.

## Test plan
Scripted tests that need no live install (logic tests, the sudoers check, `install.sh` in
test mode) are described in `TESTING.md`. The items below are the checks on the live install.

1. `lidosd status` -> state idle, SleepDisabled 0.
2. `lidosd` -> state armed, SleepDisabled 1.
3. Close the lid for >10s (AC power; screen goes dark, Mac stays up; e.g. ping it from another machine). Status shows `closed`.
4. Reopen -> state idle, SleepDisabled 0 within ~5s.
5. Close the lid again -> Mac now sleeps normally.
6. Arm, then `lidosd disarm` -> state idle immediately.
7. Arm, then as llmserver `docker stop anythingllm` -> state idle within about 15 s; `pmset -g assertions` no longer lists caffeinate. Then `docker start anythingllm`.
8. With the container stopped, `lidosd` prints `container anythingllm is not running (checked as llmserver); not arming.` and exits 1.
9. As a member of the `--group` group who isn't llmserver, `lidosd` arms with no password prompt.
10. As a user who is not in the `--group` group (admin or not), `lidosd` is refused, but `lidosd status` works.
11. `sudo -l -U llmserver` lists the eight commands (`""`, `disarm`, and `-l` with the number patterns up to 1440); `sudo -n /Library/PrivilegedHelperTools/lidosd daemon`, `... arm`, `... -l 05` and `... -l 1441` are each refused (`a password is required`).
12. `lidosd -l 1` -> state armed, `status` shows `limit: 1 min left`; within about 70 s the state is idle, SleepDisabled is 0, and the log shows `limit reached`.
13. `lidosd -l 5`, then plain `lidosd` -> `status` shows `limit: none`.
14. `lidosd -l 1`, close the lid and keep it closed past the minute -> the Mac sleeps; opening the lid brings the service back.
15. `lidosd -l 1441` and `lidosd -l abc` -> the usage message, exit 2, no sudo call.
16. The `pmset` read-back lines. Right after the reinstall, `tail /var/log/lidosd.log` shows
    `daemon start: SleepDisabled 0 confirmed`. After items 2 and 6, the log shows an `armed: ...
    [SleepDisabled 1 confirmed]` line and a `disarmed: ... [SleepDisabled 0 confirmed]` line,
    and no `failed` or `FAILED` line is new since the reinstall. This is the check that the real
    `pmset -g` shows each change at once; if a confirmed line is missing or a mismatch is
    logged, the read-back may need a short delay. The failure paths (`arm failed`, `disarm failed`,
    the retries) are covered by the logic tests only; they are not provoked on the live system.

## Uninstall (as an admin user)
    sudo bash /Users/Shared/<reponame>/uninstall.sh

Unloads and removes everything `install.sh` put in place and sets `pmset -a disablesleep 0`.
Files inside llmserver's home are removed AS llmserver, so a symlink planted there can't
make root delete something else. It keeps going if a step fails and reports warnings.
It leaves the source folder, `/var/log/lidosd.log`, the group named by `--group` (remove it
yourself if it is unused), and the shared directories `/Library/PrivilegedHelperTools` and
`~llmserver/.local/bin` (other files live there).

## Security
`lidosd` is run as root (daemon and NOPASSWD sudo), so it and its
directories must be root-owned and not writable by llmserver (`install.sh` enforces this).
`lidosd` itself re-runs through `sudo -n /Library/PrivilegedHelperTools/lidosd` with canonical arguments
only, parses its arguments strictly (`arm`, `disarm`, `status`, and `-l MINUTES` only with
arm, 0 to 1440), repeats that check as root, and sends sudo only the canonical forms in
`lidosd.sudoers` (`""`, `disarm`, `-l N` with no leading zeros). It refuses to use a state
directory that isn't a real root-owned, non-group/other-writable directory, and fails safe
(sleep re-enabled) if its state file is missing, unreadable or unrecognized.

The limit is optional, so it does not bound a caller who leaves it out, and the container
check gates stale arms, not a caller who wants to stay armed (llmserver controls its own
Docker config).

## Notes
- 2026-11-01: `lidosd` moved from `/usr/local/sbin` to `/Library/PrivilegedHelperTools`, and
  the sudoers rule changed from `%admin` plus `llmserver` to a single group (`sleepers` on
  this Mac). The live setup was changed first; the repo was updated to match afterwards.
  See `impl/lidosd-relocation-runbook.md` in the llmserver-mbp docs.
- 2026-11-05: The keep-awake script and agent plist were synced to the live Docker versions
  (installed under `~/.local/bin`; the trigger is the container `anythingllm` running).
  `lidosd`'s arm check, "Before first use" and test items 5 to 8 still described the Desktop
  process at that point (superseded 2026-11-06, below).
- 2026-11-06: `lidosd` now arms on the container (not the Desktop process) and takes an
  optional `-l MINUTES` limit (0 to 1440). The sudoers rule is a `Cmnd_Alias` of eight
  patterns; `install.sh` checks the staged rule and `MAX_LIMIT`. Scripted tests: `TESTING.md`.
  The live install still has the 2026-11-01 files until `install.sh` is re-run; real sudo
  matching of the `-l` patterns and the container check from the launchd daemon are not yet
  shown.
- 2026-11-07: every `pmset ... disablesleep` call in `lidosd` is now checked (exit status)
  and read back with `pmset -g`; failures are logged with a timestamp, verified results are
  logged as `SleepDisabled N confirmed`, `arm` undoes itself on failure, and the daemon
  retries a failed disarm up to 12 times (see "Use"). Scripted tests: `TESTING.md`, section
  6A (160 checks in all). The live install still has the 2026-11-01 files; whether the real
  `pmset -g` reflects a change at once is not yet shown (test item 16).
