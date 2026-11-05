# Keep-awake + lid-close One-Shot Disable (macOS Monterey 12.7)

## Layout
Keep all of these together in one folder / git repo, e.g. `/Users/Shared/<reponame>/`:

- `install.sh` / `uninstall.sh` : deploy / remove everything (below)
- `anythingllm-caffeinate.sh` : holds idle + system sleep assertions while llmserver's AnythingLLM Docker container runs (it wraps `docker wait`)
- `com.llmserver.anythingllm-caffeinate.plist` : LaunchAgent that keeps that script running
- `lidosd` : OSD command and root watcher daemon (one script, subcommands)
- `com.llmserver.lidosd.plist` : LaunchDaemon that runs `lidosd daemon` as root
- `lidosd.sudoers` : template for the sudoers rule; `install.sh --group NAME` fills in the group whose members may run `lidosd` / `lidosd disarm` without a password

Process identity: `lidosd` (arm check and daemon) still matches the exact name `AnythingLLM`
AND owner `llmserver` (`pgrep -x -u llmserver AnythingLLM`); other users' AnythingLLM
processes are ignored. That is the Desktop app, and the check is to be replaced by a
Docker-aware one. `anythingllm-caffeinate.sh` checks no process: it holds the assertions
while the container named by `CONTAINER` (default `anythingllm`) runs in llmserver's Docker.

If the account differs, change it everywhere: the `OWNER_USER` constant in `lidosd`, the home path in the agent plist, and the `OWNER_USER=llmserver` constant near the top of `install.sh` and `uninstall.sh`. (The sudoers rule names a group, not the account, so it needs no change; add the new account to that group.) `install.sh` checks that `lidosd`'s `OWNER_USER` and the agent plist's script path agree with it, and refuses to install if not. If the container name or the Docker CLI path differs, change `CONTAINER` or `DOCKER` in `anythingllm-caffeinate.sh`; `install.sh` does not check those.

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
   sudoers, and that the user name, group and paths agree) and installs only from
   that copy,
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
- `lidosd` (arm) and `lidosd disarm`: members of the group given to `install.sh --group`
  (for example `sleepers`), without a password (lidosd.sudoers). Anyone else is refused.
- `lidosd daemon`: not a user command; launchd runs it as root.

Use the full path, `/Library/PrivilegedHelperTools/lidosd` (macOS does not put that directory on PATH), or define an alias for it; no `sudo` is needed, because the script elevates itself via `sudo -n`.

Arming needs llmserver's AnythingLLM running, whoever types the command. State is
machine-wide: anyone's arm/disarm affects everyone.

Unexpected password prompt? `sudo -l` lists matching rules; the LAST match wins, and
drop-in files are read alphabetically after /etc/sudoers.

## Use (as a member of the `--group` group)
    lidosd            # arm (refused if llmserver's AnythingLLM isn't running)
    lidosd disarm     # disarm now
    lidosd status
    tail -f /var/log/lidosd.log

The OSD reverts to `idle` (and `pmset disablesleep 0`) on the FIRST of:
lid closed then reopened, `lidosd disarm`, or llmserver's AnythingLLM exiting.
The daemon polls every 5s, so reverts take up to ~5s.

## Before first use
As llmserver: `pgrep -lx -u llmserver AnythingLLM` must print exactly one PID.

## Test plan
1. `lidosd status` -> state idle, SleepDisabled 0.
2. `lidosd` -> state armed, SleepDisabled 1.
3. Close the lid for >10s (AC power; screen goes dark, Mac stays up; e.g. ping it from another machine). Status shows `closed`.
4. Reopen -> state idle, SleepDisabled 0 within ~5s.
5. Close the lid again -> Mac now sleeps normally.
6. Arm, then `lidosd disarm` -> state idle immediately.
7. Arm, then quit llmserver's AnythingLLM -> state idle within ~5s; `pmset -g assertions` no longer lists caffeinate.
8. With another user running AnythingLLM and llmserver's NOT running: `pmset -g assertions` shows no caffeinate, and `lidosd` refuses to arm.
9. As a member of the `--group` group who isn't llmserver, `lidosd` arms with no password prompt.
10. As a user who is not in the `--group` group (admin or not), `lidosd` is refused, but `lidosd status` works.
11. `sudo -l -U llmserver` lists the rule, and `lidosd arm` / `lidosd daemon` are not allowed via sudo.

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
only, accepts at most one argument (`disarm`, `status`; bare = arm), refuses to use a state
directory that isn't a real root-owned, non-group/other-writable directory, and fails safe
(sleep re-enabled) if its state file is missing, unreadable or unrecognized.

## Notes
- 2026-11-01: `lidosd` moved from `/usr/local/sbin` to `/Library/PrivilegedHelperTools`, and
  the sudoers rule changed from `%admin` plus `llmserver` to a single group (`sleepers` on
  this Mac). The live setup was changed first; the repo was updated to match afterwards.
  See `impl/lidosd-relocation-runbook.md` in the llmserver-mbp docs.
- 2026-11-05: The keep-awake script and agent plist were synced to the live Docker versions
  (installed under `~/.local/bin`; the trigger is the container `anythingllm` running).
  `lidosd`'s arm check, "Before first use" and test items 5 to 8 still describe the Desktop
  process until the Docker-aware check lands.
