# RedeployFTP

A desktop tool for tracking and running incremental FTP deployments out of a git repo, without
needing a full CI/CD pipeline. You keep a plain-text running log of "batches" (a date, the files
touched, a description, and whether/when each one shipped to Test and Live); this app gives you a
GUI over that log and drives the actual file transfer for you.

It's two pieces:

- **`RedeployLogViewer.hta`** - the GUI. Runs via Windows' built-in `mshta.exe`, no install needed.
  Browse deploy history, add/edit batches (with git integration to pull in uncommitted changes or
  specific commits), run a Test deploy, and prepare/verify a Live deployment with a mandatory
  backup-and-compare step first.
- **`redeploy-tweaks-template.ps1`** - the PowerShell backend that actually talks to your FTP
  server (via [WinSCP](https://winscp.net/)). The HTA shells out to a copy of this script for
  every real action.

## Requirements

- Windows (uses `mshta.exe` and Windows Script Host COM objects throughout - this won't run
  anywhere else)
- PowerShell 5.1 or later (already on any current Windows install)
- [WinSCP](https://winscp.net/eng/download.php) installed (the script loads `WinSCPnet.dll` from
  its standard install locations)
- Git on your `PATH`, if you want the git-integration features (optional - everything else works
  without it)

## Setup

### 1. Get the app itself

Clone or download this repo anywhere - `RedeployLogViewer.hta` and its `.ico` can live together in
any folder; nothing about their location matters (both resolve their own path at runtime). For
easy launching, opening the HTA once will regenerate a `RedeployFTP.lnk` shortcut next to it.

### 2. Wire it up to a project

Each project you want to deploy needs its own copy of the PowerShell script, plus two small files
that hold your FTP details - these three live *inside that project's own repo*, not in this one,
and should be gitignored there (they contain real credentials):

```
<your-project-repo>\
  .ftpScripts\
    redeploy-tweaks.ps1       <- copy of redeploy-tweaks-template.ps1, renamed
    .ftptargets.ps1           <- your FTP target definitions (see below)
    .redeploy-secrets.ps1     <- your FTP passwords (see below)
```

Create `.ftptargets.ps1`:

```powershell
$ftpTargets = @(
    [pscustomobject]@{ Name = 'Test';       Host = 'ftp.example.com'; Username = 'test\myuser' }
    [pscustomobject]@{ Name = 'Production'; Host = 'ftp.example.com'; Username = 'prod\myuser' }
)
```

A target whose `Name` matches `/prod|live/i` is treated as production and gets the extra Live
safety gate (type-to-confirm prompt, mandatory backup-and-compare in the HTA). Everything else is
treated as a normal, low-stakes target.

Create `.redeploy-secrets.ps1`:

```powershell
$ftpPasswords = @{
    'Test'       = 'your-test-password'
    'Production' = 'your-production-password'
}
```

If you'd rather not store a password on disk at all, leave a target out of this file - the script
will prompt for it interactively the first time you deploy to that target by hand (not available
when the HTA drives it automatically, since there's no console to prompt on).

### 3. Add the project in the app

Open `RedeployLogViewer.hta` (or the shortcut), click the **+** (Add Project) button, and point it
at your project's repo root (the folder containing `.ftpScripts\`). The app creates
`redeploy-list.txt` - the actual running log - automatically on first use.

## Basic usage

- **Add Entry** - describe a batch of changes (type file paths, or pull them from git) before or
  after you've made them.
- **Test Deploy** - sends the log's most recent batch to your Test target and stamps it as tested.
- **Prepare a Live Deployment** - select one or more tested batches, back up what's currently live
  for comparison, then deploy to Production once you've reviewed the diff.
- **Mark as Live** - if you deployed by some other means, record it after the fact instead.

The interface has a fair number of other features (grouping related batches together, filtering,
readiness markers, cross-checking a live deploy against the log) - hover anything you're unsure
about, most controls have an explanatory tooltip.

## Where your data lives

Everything this app persists for a project - the log, joined-entry groupings, backups, deploy
audit trails - lives under `%LOCALAPPDATA%\RedeployFTP\<project name>\`, entirely separate from
both this repo and your project's own repo. Nothing here is version-controlled; back that folder
up yourself if you want history beyond what's already in `redeploy-list.txt`.

## Security notes

- Real credentials never touch this repo: `.ftptargets.ps1` and `.redeploy-secrets.ps1` live in
  *your* project's repo, gitignored, and are read fresh from disk on every deploy - never copied
  anywhere else.
- The HTA and script share a fixed `AutomationToken` string so the script can tell "the HTA is
  driving this, unattended" apart from "someone typed this by hand." It's not a real access
  boundary - anyone who could run the script at all could just as easily answer its prompts
  directly - so it's fine that it's the same value in every install; it exists purely to stop a
  stray or mistyped invocation from silently deploying.

## License

[PolyForm Noncommercial 1.0.0](LICENSE) - free to use, modify, and share for any noncommercial
purpose (personal projects, learning, internal use at a non-profit/educational/government org,
etc.); not licensed for commercial use or resale. This is "source-available," not open source in
the strict/OSI sense, since it restricts commercial use.
