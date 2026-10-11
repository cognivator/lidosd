# Keep-awake + lid-close One-Shot Disable (macOS Monterey 12.7)

## Layout
Keep all of these together in one folder / git repo, e.g. `/Users/Shared/<reponame>/`:

- `install.sh` / `uninstall.sh` : deploy / remove everything (below)
- `anythingllm-caffeinate.sh` : holds idle + system sleep assertions while llmserver's AnythingLLM runs
- `com.llmserver.anythingllm-caffeinate.plist` : LaunchAgent that keeps that script running
- `lidosd` : OSD command and root watcher daemon (one script, subcommands)
- `com.llmserver.lidosd.plist` : LaunchDaemon that runs `lidosd daemon` as root
- `lidosd.sudoers` : lets llmserver and Admin users run `lidosd` / `lidosd disarm` without a password

Process identity (both scripts): exact name `AnythingLLM` AND owner `llmserver`
(`pgrep -x -u llmserver AnythingLLM`). Other users' AnythingLLM processes are ignored.
If the account or app name differs, change it everywhere: the `OWNER_USER` / `APP_NAME`
constants in BOTH `lidosd` and `anythingllm-caffeinate.sh`, the list of users in
`lidosd.sudoers`, the home path in the agent plist, and the `OWNER_USER=llmserver` constant near the top of `install.sh` and `uninstall.sh`. `install.sh` checks that these agree and refuses to install if not.

The three root-run scripts (`install.sh`, `uninstall.sh`, `lidosd`) fix their own `PATH`
and `umask` and ignore environment variables: only the constants in the files count.
(Each has a test-only switch, `INSTALL_TEST` / `UNINSTALL_TEST` / `LIDOSD_TEST`; `lidosd`'s
is additionally ignored whenever sudo started it.)

## Quick install (as an admin user)
    sudo bash /Users/Shared/<reponame>/install.sh

The scripts find the folder from their own path, so the repo name doesn't matter.

Put the folder under an admin-owned location (e.g. `/Users/Shared/<reponame>`, created
by the admin, `chmod -R go-w`). `install.sh` is run as root and installs root-run code
from it, so it refuses to proceed if a source file is a symlink, is group/other-writable,
is owned or writable by llmserver, or sits under a directory llmserver or other users
control (other than sticky ones like `/Users/Shared`).

`install.sh`:
1. fixes `PATH` and `umask`, then copies the sources to a private root-owned temp dir
   and validates (syntax, plist, sudoers, and that the user name and paths agree)
   and installs only from that copy,
2. BEFORE changing anything, checks that llmserver cannot write to the root-run files
   or any directory above them (`/usr/local/sbin`, `/Library/LaunchDaemons`,
   `/etc/sudoers.d` and their parents). If it can, nothing is changed and the offending
   path is printed; fix its ownership/permissions and re-run,
3. stops any running copy, then installs with explicit owners/modes via `install`
   (existing shared directories are never chown'd/chmod'd; missing ones are created
   `root:wheel 755`),
4. re-checks after installing; on failure it removes lidosd, its plist and its sudoers
   rule and starts nothing,
5. installs the sudoers rule, validates the full config with `visudo -c`, and restores
   the previous rule (or removes the new one) if that fails,
6. writes llmserver's files (`~/bin`, `~/Library/LaunchAgents`) AS llmserver, so a symlink
   planted there cannot redirect a root write,
7. loads the lid daemon (system) and the keep-awake agent (llmserver's GUI session;
   if llmserver isn't logged in, the agent starts at its next login).

Homebrew note (Intel): `/usr/local` is often group-writable by `admin`. If llmserver is
an admin user, step 2 will stop the install. Either make llmserver a standard user, or
tighten the directories it flags.

Re-run it after editing any file in the folder. It restarts the daemon, which disarms an armed OSD.

## Who can run it
- `lidosd status`: anyone (no sudo needed).
- `lidosd` (arm) and `lidosd disarm`: llmserver and members of the `admin` group,
  without a password (lidosd.sudoers). Anyone else is refused.
- `lidosd daemon`: not a user command; launchd runs it as root.

Use the full path, `/usr/local/sbin/lidosd`, unless `/usr/local/sbin` is added to PATH (macOS does not put it on PATH by default).

Arming needs llmserver's AnythingLLM running, whoever types the command. State is
machine-wide: anyone's arm/disarm affects everyone.

Unexpected password prompt? `sudo -l` lists matching rules; the LAST match wins, and
drop-in files are read alphabetically after /etc/sudoers.

## Use (as llmserver or an admin user)
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
9. As an admin who isn't llmserver, /usr/local/sbin/lidosd arms with no password prompt.
10. As a user who is neither, lidosd is refused, but lidosd status works.
11. `sudo -l -U llmserver` lists the rule, and `lidosd arm` / `lidosd daemon` are not allowed via sudo.

## Uninstall (as an admin user)
    sudo bash /Users/Shared/<reponame>/uninstall.sh

Unloads and removes everything `install.sh` put in place and sets `pmset -a disablesleep 0`.
Files inside llmserver's home are removed AS llmserver, so a symlink planted there can't
make root delete something else. It keeps going if a step fails and reports warnings.
It leaves the source folder, `/var/log/lidosd.log`, and the shared directories
`/usr/local/sbin` and `~llmserver/bin` (the latter is removed only if empty).

## Manual equivalent (reference)
From inside the repo folder:

    sudo mkdir -p /usr/local/sbin
    sudo install -o root -g wheel -m 755 lidosd /usr/local/sbin/lidosd
    sudo install -o root -g wheel -m 644 com.llmserver.lidosd.plist /Library/LaunchDaemons/
    sudo launchctl bootstrap system /Library/LaunchDaemons/com.llmserver.lidosd.plist
    sudo visudo -cf lidosd.sudoers && sudo install -o root -g wheel -m 440 lidosd.sudoers /etc/sudoers.d/lidosd
    # as llmserver:
    mkdir -p ~/bin ~/Library/LaunchAgents
    install -m 755 anythingllm-caffeinate.sh ~/bin/
    install -m 644 com.llmserver.anythingllm-caffeinate.plist ~/Library/LaunchAgents/
    launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.llmserver.anythingllm-caffeinate.plist

Security: `lidosd` is run as root (daemon and NOPASSWD sudo), so it and its
directories must be root-owned and not writable by llmserver (`install.sh` enforces this).
`lidosd` itself re-runs through `sudo -n /usr/local/sbin/lidosd` with canonical arguments
only, accepts at most one argument (`disarm`, `status`; bare = arm), refuses to use a state
directory that isn't a real root-owned, non-group/other-writable directory, and fails safe
(sleep re-enabled) if its state file is missing, unreadable or unrecognized.
