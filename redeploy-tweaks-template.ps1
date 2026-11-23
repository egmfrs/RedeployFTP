<#
.SYNOPSIS
    Quick incremental redeploy of the LAST batch listed in redeploy-list.txt, plus several
    read-only/bookkeeping modes for managing that log without hand-editing it.

.DESCRIPTION
    Passwords come from .redeploy-secrets.ps1 (gitignored) which you fill in yourself. The list of
    files to send is redeploy-list.txt (kept outside the repo, in %LOCALAPPDATA%\{this repo's
    folder name} - created automatically on first run if missing, derived from this script's own
    location so the same file works unmodified when copied into any project's .ftpScripts folder);
    the default -Deploy flow always deploys the LAST data line in it. Uses the same WinSCP FTP +
    explicit TLS transport as Get-FtpUpload.ps1, mapping repo-root paths 1:1 to /site/wwwroot/.

    There is no direct "edit the last entry" switch. To change an already-added, still-pending
    entry's Files or Details from the command line, either:
      - Run -AddEntry again - this MERGES (appends any new files not already listed, appends new
        -Details text after the existing text) rather than replacing what's there, or
      - Run -DeleteLastEntryIfPending (only works while it's still pending - not yet deployed to
        Test or Live) followed by a fresh -AddEntry, to fully replace it.
    RedeployLogViewer's own "Edit Entry" feature does a true in-place field rewrite (finds the
    exact matching line anywhere in the file, replaces just its Files/Details columns, leaves
    Prep/Test/Live untouched) for any entry, not only the last one - there is no CLI equivalent of
    that today.

.PARAMETER Target
    Which FTP target to use, matched by name against .ftptargets.ps1. Defaults to 'Test'. A target
    name matching /prod|live/i (case-insensitive) triggers the Production safety gate (the "type
    DEPLOY TO LIVE" prompt, or -LiveConfirmed for an automated caller).

.PARAMETER Deploy
    Required to reach the default flow (deploy the log's last entry) - see -AutomationToken for
    the one case where it isn't needed. Running the script with no recognised action switch at
    all (a typo, an empty invocation, -?, ...) now just prints usage and exits, instead of
    silently deploying.

.PARAMETER WhatIf
    Dry run - resolves and prints the file list and plan but sends nothing.

.PARAMETER AddEntry
    Adds a batch (see -Files/-Details) without hand-editing redeploy-list.txt. If the current last
    entry hasn't been deployed to either target yet, this merges the files and details into it
    instead of stranding a second pending entry.

.PARAMETER Files
    One or more relative paths for -AddEntry. A leading DELETE: prefix on any entry marks it for
    removal instead of upload.

.PARAMETER Details
    Free-text description for -AddEntry. Any literal '|' is swapped for '/' automatically, since
    '|' is the column separator.

.PARAMETER ReadLast
    Prints the last N entries (files, details, deployed-to-Test/Live stamps) without touching
    anything - read this before writing a new -Details, so it doesn't repeat what a still-pending
    or already-deployed entry already says. Especially: if you're acting on feedback about
    behaviour that was actually observed live, the entry that shipped it has already been
    deployed even if this script never saw that happen (deployed by hand, or from a different
    session) - -ReadLast shows the DeployedTest/DeployedLive stamps either way, so check them
    rather than assuming "still pending".

.PARAMETER DeleteLastEntryIfPending
    Removes the last data line, but only if it hasn't been deployed to Test or Live yet - refuses
    (and changes nothing) otherwise, so you can't accidentally erase a deployed batch's history
    this way.

.PARAMETER AutomationToken
    Only RedeployLogViewer (the HTA) knows this value. When present and valid (checked against a
    fixed value - see $script:autoModeToken - not merely "some string was supplied"), it also
    satisfies the -Deploy requirement above for the default flow, on the reasoning that only that
    caller ever supplies it and it always means "yes, actually deploy" - a human at this console
    typing the script's name with no arguments, or a mistyped switch, will never have this exact
    value, so the safety -Deploy is meant to add isn't weakened by trusting it here. Also skips
    this script's own interactive "type DEPLOY TO LIVE" prompt when paired with -LiveConfirmed,
    because an unattended/hidden invocation has no console to type into.

.PARAMETER BackupManifest
    Path to a manifest file (one relative path per line, a leading DELETE: is ignored since the
    file's identity is the same either way). Downloads the CURRENT remote copy of every listed
    path into -BackupDir, without touching anything on the server or in redeploy-list.txt. A file
    that doesn't exist remotely yet is reported and skipped, not treated as a failure.

.PARAMETER BackupDir
    Destination folder for -BackupManifest. Defaults to a timestamped folder under
    %LOCALAPPDATA%\{repo}\ftp-backups\ if omitted - the actual path used is always printed as a
    final "BACKUPDIR: ..." line.

.PARAMETER LiveConfirmed
    Only meaningful together with a valid -AutomationToken (same trust gate described there) -
    skips this script's own interactive "type DEPLOY TO LIVE" prompt. The caller
    (RedeployLogViewer) is expected to have already collected that exact confirmation itself
    before passing this.

.PARAMETER DeployManifest
    Path to a manifest file (same format as -BackupManifest). Deploys that arbitrary file list
    instead of "the last entry in redeploy-list.txt". Used by RedeployLogViewer's Prepare a Live
    Deployment flow, which can deploy any existing entr(y/ies) regardless of their position in the
    log - unlike the default flow, this never reads or stamps redeploy-list.txt at all; the caller
    is responsible for marking the right entries Live afterward. Same transfer logic, wording, and
    exclusion checks as the default flow, so progress parses the same way; same live safety gate.

.PARAMETER SuppliedPasswordFile
    Only honoured alongside a valid -AutomationToken (same trust gate as -LiveConfirmed) - reads
    the FTP password from this file instead of looking it up in .redeploy-secrets.ps1, for the one
    -Target this run is against. The file is deleted immediately after being read, whether or not
    the password inside turns out to be correct, so a plaintext copy exists on disk only for the
    brief window between the caller writing it and this script consuming it. Used by
    RedeployLogViewer's "Supply password" checkbox on the Prepare-a-Live-Deployment backup panel,
    for cases where .redeploy-secrets.ps1 has no entry for Production and the user would rather
    paste a password once than add one to that file.

.PARAMETER AlsoFtpBackup
    With -BackupManifest: also uploads each just-downloaded local copy to
    /site/backups/<timestamp>/ on the same FTP target, mirroring how Get-FtpUpload.ps1's own
    backup step works.

.PARAMETER FtpBackupBase
    Remote base path for -AlsoFtpBackup. Defaults to '/site/backups/'.

.PARAMETER DeployListStamp
    With -DeployManifest: a yyyyMMddHHmm timestamp used both for the .deploy-lists\*.txt filename
    this run writes and (by the caller, afterward) as the DeployedLive stamp applied back onto the
    log - letting RedeployLogViewer's own "edit live date" lookup match this run's deploy-list
    file by exact timestamp.

.PARAMETER DeployListDescription
    With -DeployManifest: optional free text included in the .deploy-lists\*.txt filename/header,
    normally the associated log entr(y/ies)' own summary text.

.PARAMETER CommitHashes
    With -DeployManifest: comma-joined full commit hashes involved in this deploy, written into
    the deploy-log-{site}.txt audit row.

.PARAMETER DeployedUpTo
    With -DeployManifest: the single head commit hash this deploy is "up to", written into the
    deploy-log-{site}.txt audit row.

.PARAMETER BackedUpToFtp
    With -DeployManifest: whether the earlier backup step's "also back up to FTP" checkbox was
    ticked, recorded purely for the deploy-log-{site}.txt audit row's own FtpBackup column.

.PARAMETER LocalBackupDir
    With -DeployManifest: the local folder this deploy's pre-overwrite backup copies live in (if
    the backup step ran) - written as a "# LocalBackup: <path>" line in the .deploy-lists\*.txt
    file, letting RedeployLogViewer's Mark-As-Live "View Backup" button find it later.

.PARAMETER DeployListNotesFile
    With -DeployManifest: path to a local text file whose full content (typically the accumulated
    commit messages from RedeployLogViewer's Prepare-a-Live-Deployment screen) is written into the
    .deploy-lists\*.txt file itself as a "# --- Details ---" / ... / "# --- End Details ---" block,
    one comment line per line of the file. Optional - skipped entirely if not supplied, or if the
    file is missing/empty.

.PARAMETER BackupSyncCheck
    Path to a local folder (typically an earlier Live backup) to check against the FTP target:
    for each file inside it, reports ON-FTP or MISSING. Add -DoSync to also upload every MISSING
    file. The remote base is always /site/backups/<leaf name of this folder>/, matching
    -AlsoFtpBackup's own convention, so a folder backed up either way lands in the same remote
    location.

.PARAMETER DoSync
    With -BackupSyncCheck: uploads every file reported MISSING instead of only reporting it.

.PARAMETER CherryPickOverride
    "relpath|localOverridePath" - used by the default flow only (see -DeployManifest's own inline
    manifest-line override syntax for the -DeployManifest equivalent). Substitutes the given local
    file for that one path and bypasses the standard-exclusions check for that line only, since a
    cherry-picked override already went through a mandatory backup+verify+cherry-pick action.

.PARAMETER RetrospectiveManifest
    Path to a plain file-list manifest (same format as -BackupManifest/-DeployManifest). Writes the
    SAME .deploy-lists\*.txt + deploy-log-{site}.txt audit trail -DeployManifest does (using
    -Target/-DeployListStamp/-DeployListDescription/-CommitHashes/-DeployedUpTo the same way), but
    never opens an FTP session or sends anything - used by RedeployLogViewer's "Mark as Already
    Live" -> "Link Commit(s)" feature, for an entry that's already known to be live and just needs
    its commit(s) recorded in the audit trail after the fact. The deploy-list file's own header and
    the deploy-log row's Status column are both marked RETROSPECTIVE so this can never be mistaken
    for a real completed deploy when read back later, by a human or by Get-FtpUpload.ps1's own
    "commits since last deployed" scan.

.EXAMPLE
    .\.ftpScripts\redeploy-tweaks.ps1 -Deploy
    Deploys the last entry to Test (the default target).

.EXAMPLE
    .\.ftpScripts\redeploy-tweaks.ps1 -Deploy -Target Production
    Deploys the last entry to Production, with the interactive "type DEPLOY TO LIVE" safety prompt.

.EXAMPLE
    .\.ftpScripts\redeploy-tweaks.ps1 -Deploy -WhatIf
    Dry run - resolves and prints the plan, sends nothing.

.EXAMPLE
    .\.ftpScripts\redeploy-tweaks.ps1 -AddEntry -Files "a.aspx","b.js" -Details "fixed X"
    Adds (or merges into the still-pending last entry) a new batch.

.EXAMPLE
    .\.ftpScripts\redeploy-tweaks.ps1 -ReadLast 5
    Prints the last 5 entries, read-only.

.EXAMPLE
    .\.ftpScripts\redeploy-tweaks.ps1 -DeleteLastEntryIfPending
    Removes the last entry, only if it's still pending.

.EXAMPLE
    .\.ftpScripts\redeploy-tweaks.ps1 -BackupManifest "list.txt" -Target Production -BackupDir "C:\backup"
    Downloads the current remote copy of every path in list.txt into C:\backup, touching nothing else.

.NOTES
    Uses the same WinSCP FTP + explicit TLS transport as Get-FtpUpload.ps1, mapping repo-root
    paths 1:1 to /site/wwwroot/. Adding [CmdletBinding()] (see just below) is what makes -? work
    as a real PowerShell common parameter and actually show this help text, instead of either
    silently falling through to the old default-deploy behaviour or being treated as an
    unrecognised argument.
#>
[CmdletBinding()]
param(
    [string]$Target = 'Test',
    [switch]$WhatIf,
    [switch]$Deploy,
    [switch]$AddEntry,
    [string[]]$Files,
    [string]$Details,
    [int]$ReadLast,
    [switch]$DeleteLastEntryIfPending,
    [string]$AutomationToken,
    [string]$BackupManifest,
    [string]$BackupDir,
    [switch]$LiveConfirmed,
    [string]$DeployManifest,
    [string]$SuppliedPasswordFile,
    [switch]$AlsoFtpBackup,
    [string]$FtpBackupBase = '/site/backups/',
    [string]$DeployListStamp,
    [string]$DeployListDescription,
    [string]$CommitHashes,
    [string]$DeployedUpTo,
    [switch]$BackedUpToFtp,
    [string]$LocalBackupDir,
    [string]$DeployListNotesFile,
    [string]$BackupSyncCheck,
    [switch]$DoSync,
    [string]$CherryPickOverride,
    [string]$RetrospectiveManifest
)

$ErrorActionPreference = 'Stop'

# Only RedeployLogViewer (the HTA) knows this value - lets it drive a -Target run fully
# unattended (auto-confirms the Y/N prompt, skips the final "press a key" loop) without
# exposing an easily-guessable switch like -Auto that someone could stumble into by hand
# and accidentally skip the confirmation prompt for a real transfer.
$script:autoModeToken = 'RLV-AUTO-9f2c7d41a6b3'
$script:isAutoMode = [bool]$AutomationToken -and ($AutomationToken -eq $script:autoModeToken)

# Same classification Get-FtpUpload.ps1 uses for "this failure means the connection dropped,
# not that the operation itself is wrong" - only these are worth an automatic reconnect+retry
# (see Invoke-FtpOpWithRetry below). A permissions error or similar won't succeed just by
# retrying, so it's reported immediately instead of wasting a retry on it.
$script:sessionDropRegex = 'unexpectedly closed|already read|Lost connection|Disconnected from server|Connection failed'

# Repo-relative log location: %LOCALAPPDATA%\RedeployFTP\{repo folder name}\redeploy-list.txt -
# derived from this script's own location (...\<repo>\.ftpScripts\redeploy-tweaks.ps1), so the
# same file works unmodified when copied into any project's .ftpScripts folder. Namespaced under
# "RedeployFTP\" (not just the bare repo folder name) so this app's own data can never be mistaken
# for - and potentially wiped by - some unrelated app's own %LOCALAPPDATA% folder that happens to
# share the project's name; matches the same namespacing RedeployLogViewer.hta itself now uses
# (see its own projectAppDataDir()/migrateProjectAppDataIfNeeded()).
$repoRootForLog = Split-Path $PSScriptRoot -Parent
$repoNameForLog = Split-Path $repoRootForLog -Leaf
$listFile = Join-Path $env:LOCALAPPDATA "RedeployFTP\$repoNameForLog\redeploy-list.txt"

# Narrow fallback for the one case the HTA's own (much more thorough, whole-folder) migration
# can't reach: this script invoked directly, on a machine where the HTA has never been opened
# with this project active yet, so nothing has migrated $listFile's old location across yet. If
# the new path doesn't exist but a real list file still sits at the OLD bare
# %LOCALAPPDATA%\$repoNameForLog\redeploy-list.txt location, copy just that one file across rather
# than Ensure-ListFile below creating a blank one - the old file is left in place either way,
# never deleted.
if (-not (Test-Path $listFile)) {
    $legacyListFile = Join-Path $env:LOCALAPPDATA "$repoNameForLog\redeploy-list.txt"
    if (Test-Path $legacyListFile) {
        $listFileDir = Split-Path $listFile -Parent
        if (-not (Test-Path $listFileDir)) { New-Item -ItemType Directory -Path $listFileDir -Force | Out-Null }
        Copy-Item -Path $legacyListFile -Destination $listFile
    }
}

$listHeader = @(
    '# redeploy-list.txt  -  incremental deploy batches / change log for redeploy-tweaks.ps1'
    '#'
    '# The script always deploys the LAST data line below. Append a new line after'
    '# each change so this doubles as a running log.'
    '#'
    '# Format (pipe-delimited, 5 columns):'
    '#   yyyy-MM-dd HH:mm | file1,file2,... | details of change | DeployedTest | DeployedLive'
    '#'
    '# Rules:'
    '#   - Column separator is | ; do NOT use a literal | inside a column (use / instead).'
    '#   - File list is comma-separated, paths relative to the repo root, forward or back slashes.'
    '#   - Prefix a path with  DELETE:  to remove it from the server instead of uploading.'
    '#   - In the details column, encode newlines as \n (the script splits them back out for display).'
    '#   - Leave DeployedTest / DeployedLive blank; the script stamps them after a clean deploy.'
    '#     If a set is already stamped for the target you''re pushing to, it warns but still lets you go.'
    '#   - Lines starting with # are comments and are ignored.'
    '#'
)

# Creates the list file (with header only) the first time this runs on a machine.
function Ensure-ListFile {
    param([string]$Path)
    $dir = Split-Path $Path -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    if (-not (Test-Path $Path)) {
        Set-Content -Path $Path -Value $listHeader -Encoding UTF8
        Write-Host "First run on this machine - created $Path" -ForegroundColor Yellow
    }
}

# Shared by the main deploy flow and -BackupManifest, so both connect the same
# way. Resolves -Target against .ftptargets.ps1 (exact name match, then loose
# contains, so -Target Test / Production is enough either way).
function Get-FtpTarget {
    param([string]$ScriptDir, [string]$Name)
    $targetsFile = Join-Path $ScriptDir '.ftptargets.ps1'
    if (-not (Test-Path $targetsFile)) { throw "Missing .ftptargets.ps1 in $ScriptDir." }
    . $targetsFile
    if (-not $ftpTargets) { throw ".ftptargets.ps1 did not define `$ftpTargets." }
    $chosen = $ftpTargets | Where-Object { $_.Name -eq $Name } | Select-Object -First 1
    if (-not $chosen) { $chosen = $ftpTargets | Where-Object { $_.Name -like "*$Name*" } | Select-Object -First 1 }
    if (-not $chosen) { throw "Unknown target '$Name'. Available: $(($ftpTargets | ForEach-Object { $_.Name }) -join ', ')" }
    return $chosen
}

# Derives the short site name (e.g. "ContosoSite") from a target's "SITE\user" Username, the
# same way Get-FtpUpload.ps1 does ($siteName = ($Username -split '\\')[0]) - used so the two
# tools' audit trails (.deploy-lists\, deploy-log-{site}.txt) land in the same place regardless
# of which tool produced them.
function Get-SiteName {
    param([string]$Username)
    return ($Username -split '\\')[0]
}

# Looks up the target's password in .redeploy-secrets.ps1, falling back to an
# in-memory cache, falling back to an interactive prompt (cached for next time)
# - unless $AutoMode is set, in which case there's no console to prompt on, so
# a missing password throws instead. $SuppliedPasswordFile (only honoured when
# $AutoMode is true - same trust gate as -LiveConfirmed, since only
# RedeployLogViewer knows the token that sets $AutoMode) takes priority over
# all of that: read once, delete immediately regardless of outcome so the
# plaintext file never outlives this one lookup, and use it as-is - no
# fallback to .redeploy-secrets.ps1 if it turns out to be wrong, since a
# silent fallback there would mask a mistyped password as a mysterious
# failure further down.
function Get-FtpPassword {
    param([string]$ScriptDir, [string]$TargetName, [hashtable]$Cache, [bool]$AutoMode, [string]$SuppliedPasswordFile)
    if ($AutoMode -and $SuppliedPasswordFile) {
        if (-not (Test-Path $SuppliedPasswordFile)) { throw "SuppliedPasswordFile '$SuppliedPasswordFile' not found." }
        $supplied = (Get-Content -Path $SuppliedPasswordFile -Raw -ErrorAction Stop).Trim()
        Remove-Item -Path $SuppliedPasswordFile -Force -ErrorAction SilentlyContinue
        if (-not $supplied) { throw "SuppliedPasswordFile '$SuppliedPasswordFile' was empty." }
        return $supplied
    }
    $secretsFile = Join-Path $ScriptDir '.redeploy-secrets.ps1'
    if (-not (Test-Path $secretsFile)) { throw "Missing .redeploy-secrets.ps1 - create it and add your FTP passwords." }
    . $secretsFile
    if (-not $ftpPasswords) { throw ".redeploy-secrets.ps1 did not define `$ftpPasswords." }
    $password = [string]$ftpPasswords[$TargetName]
    if (-not $password) { $password = [string]$Cache[$TargetName] }
    if (-not $password) {
        if ($AutoMode) { throw "No stored password for '$TargetName' in .redeploy-secrets.ps1 (automated run - can't prompt for one)." }
        Write-Host "No stored password for '$TargetName' in .redeploy-secrets.ps1." -ForegroundColor Yellow
        $secure = Read-Host "Enter FTP password for $TargetName" -AsSecureString
        $password = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
            [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure))
        if (-not $password) { throw "No password entered - aborted." }
        $Cache[$TargetName] = $password
    }
    return $password
}

# Locates WinSCPnet.dll (same candidates as Get-FtpUpload.ps1), loads it, and
# opens a connected session. Caller is responsible for disposing it.
function New-FtpSession {
    param([string]$HostName, [string]$Username, [string]$Password)
    $dllCandidates = @(
        "$env:LOCALAPPDATA\Programs\WinSCP\WinSCPnet.dll",
        'C:\Program Files (x86)\WinSCP\WinSCPnet.dll',
        'C:\Program Files\WinSCP\WinSCPnet.dll'
    )
    $dll = $dllCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $dll) { throw "WinSCPnet.dll not found. Install WinSCP or edit the path list in this script." }
    Add-Type -Path $dll
    $opts = New-Object WinSCP.SessionOptions -Property @{
        Protocol  = [WinSCP.Protocol]::Ftp
        FtpSecure = [WinSCP.FtpSecure]::Explicit
        HostName  = $HostName
        UserName  = $Username
        Password  = $Password
        GiveUpSecurityAndAcceptAnyTlsHostCertificate = $true
    }
    $session = New-Object WinSCP.Session
    $session.Open($opts)
    return $session
}

# Create each missing parent folder on the server before a put. Moved up here (next to the other
# shared connection helpers) rather than left where it originally lived further down the script -
# PowerShell executes top-level statements in file order and does NOT hoist function definitions
# the way it might first appear to (confirmed by testing a minimal forward-reference script before
# making this change), so -BackupManifest's new -AlsoFtpBackup upload (which needs this function,
# and runs from a top-level `if` block earlier in the file than where this used to be defined)
# would otherwise fail with "the term 'Ensure-RemoteDir' is not recognized".
function Ensure-RemoteDir {
    param($Sess, [string]$RemoteDir)
    $parts = $RemoteDir.TrimStart('/') -split '/'
    $current = ''
    foreach ($part in $parts) {
        if (-not $part) { continue }
        $current += "/$part"
        if (-not $Sess.FileExists($current)) {
            try { $Sess.CreateDirectory($current) } catch { <# already exists / race #> }
        }
    }
}

# Runs $Operation (a scriptblock taking the WinSCP session as its one argument) once. On a
# connection-drop-shaped failure ($script:sessionDropRegex - same classification
# Get-FtpUpload.ps1 uses), disposes the dead session, opens a fresh one, and tries $Operation
# exactly once more against the new session. Any other failure shape (permissions, a genuinely
# missing remote path, etc.) is returned immediately without retrying, since those won't
# succeed just by trying again. Returns @{ Ok; Session; Error; Result } - callers MUST reassign
# their own $session = $result.Session afterward, since a reconnect replaces the object they had.
# Result carries back whatever $Operation itself returned (e.g. a FileExists() boolean) - most
# callers only care about Ok/Error, but a check-only operation needs its actual answer too, not
# just whether the check completed without throwing.
function Invoke-FtpOpWithRetry {
    param($Session, [string]$HostName, [string]$Username, [string]$Password, [scriptblock]$Operation)
    try {
        $opResult = & $Operation $Session
        return @{ Ok = $true; Session = $Session; Error = $null; Result = $opResult }
    } catch {
        if ($_.Exception.Message -notmatch $script:sessionDropRegex) {
            return @{ Ok = $false; Session = $Session; Error = $_.Exception.Message; Result = $null }
        }
        Write-Host "  Session dropped - reconnecting..." -ForegroundColor Yellow
        try { $Session.Dispose() } catch { <# already dead #> }
        try {
            $newSession = New-FtpSession -HostName $HostName -Username $Username -Password $Password
        } catch {
            return @{ Ok = $false; Session = $Session; Error = "Reconnect failed: $($_.Exception.Message)"; Result = $null }
        }
        try {
            $opResult = & $Operation $newSession
            Write-Host "  Reconnected - recovered." -ForegroundColor Yellow
            return @{ Ok = $true; Session = $newSession; Error = $null; Result = $opResult }
        } catch {
            return @{ Ok = $false; Session = $newSession; Error = $_.Exception.Message; Result = $null }
        }
    }
}

# Parses one data line into its 5 columns and validates the shape of the last
# two (DeployedTest / DeployedLive): each must be blank or a yyyy-MM-dd HH:mm
# stamp. A stray '|' typed into the details column shifts everything after it
# along by one, which otherwise silently gets misread as an already-deployed
# stamp - this catches that instead of guessing.
function Parse-DeployLine {
    param([string]$Line)
    $cols = $Line -split '\|'
    if ($cols.Count -lt 3 -or $cols.Count -gt 5) {
        throw "Parsing inconsistency in redeploy-list.txt: line has $($cols.Count) columns (expected 3-5). This is usually a stray '|' in the details column - use '/' instead. Line: $Line"
    }
    $stamp   = $cols[0].Trim()
    $fileCsv = $cols[1].Trim()
    if ($cols.Count -eq 5) {
        $deployedLive = $cols[4].Trim(); $deployedTest = $cols[3].Trim(); $detailsRaw = $cols[2].Trim()
    } elseif ($cols.Count -eq 4) {
        $deployedLive = '';              $deployedTest = $cols[3].Trim(); $detailsRaw = $cols[2].Trim()
    } else {
        $deployedLive = '';              $deployedTest = '';              $detailsRaw = $cols[2].Trim()
    }
    $stampPattern = '^\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}$'
    foreach ($pair in @(@('DeployedTest', $deployedTest), @('DeployedLive', $deployedLive))) {
        if ($pair[1] -and $pair[1] -notmatch $stampPattern) {
            throw "Parsing inconsistency in redeploy-list.txt: $($pair[0]) column reads '$($pair[1])' - not blank and not a yyyy-MM-dd HH:mm stamp. This is usually a stray '|' in the details column - use '/' instead. Line: $Line"
        }
    }
    [pscustomobject]@{ Stamp = $stamp; FileCsv = $fileCsv; DetailsRaw = $detailsRaw; DeployedTest = $deployedTest; DeployedLive = $deployedLive }
}

Ensure-ListFile -Path $listFile

if ($BackupManifest) {
    try {
        if (-not (Test-Path $BackupManifest)) { throw "Backup manifest not found: $BackupManifest" }
        $manifestLines = @(Get-Content $BackupManifest) | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -notmatch '^#' }
        if (-not $manifestLines) { throw "Backup manifest is empty: $BackupManifest" }

        $scriptDirForBackup = $PSScriptRoot
        $remoteBaseForBackup = '/site/wwwroot/'
        $chosen   = Get-FtpTarget -ScriptDir $scriptDirForBackup -Name $Target
        $password = Get-FtpPassword -ScriptDir $scriptDirForBackup -TargetName $chosen.Name -Cache @{} -AutoMode $script:isAutoMode -SuppliedPasswordFile $SuppliedPasswordFile

        if (-not $BackupDir) {
            $repoRootForBackup = Split-Path $scriptDirForBackup -Parent
            $repoNameForBackup = Split-Path $repoRootForBackup -Leaf
            $stampDir = Get-Date -Format 'yyyy-MM-dd_HHmmss'
            $BackupDir = Join-Path $env:LOCALAPPDATA "$repoNameForBackup\ftp-backups\$stampDir"
        }
        if (-not (Test-Path $BackupDir)) { New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null }

        # Same remote base and per-run subfolder name as Get-FtpUpload.ps1's own optional FTP
        # backup ($FtpBackupBase + timestamp + '/') - reusing $BackupDir's own leaf folder name
        # (already a timestamp, e.g. "live-2026-08-18_144022") rather than minting a second one,
        # so the local and server copies of this same snapshot are identifiably the same run.
        $ftpBackupDest = if ($AlsoFtpBackup) { $FtpBackupBase.TrimEnd('/') + '/' + (Split-Path $BackupDir -Leaf) + '/' } else { $null }

        Write-Host ''
        Write-Host "BACKUP FROM : $($chosen.Name)" -ForegroundColor Cyan
        Write-Host "              $($chosen.Username) @ $($chosen.Host)" -ForegroundColor DarkGray
        Write-Host "BACKUP TO   : $BackupDir" -ForegroundColor Cyan
        if ($AlsoFtpBackup) { Write-Host "FTP BACKUP  : $ftpBackupDest" -ForegroundColor Cyan }
        Write-Host ''

        $session = New-FtpSession -HostName $chosen.Host -Username $chosen.Username -Password $password
        $ok = 0; $skip = 0; $fail = 0; $ftpOk = 0; $ftpFail = 0
        $failedBackups = [System.Collections.Generic.List[object]]::new()
        $failedFtpBackups = [System.Collections.Generic.List[object]]::new()
        try {
            foreach ($line in $manifestLines) {
                $rel = $line -replace '^(?i)DELETE:\s*', ''
                $relClean = ($rel -replace '\\', '/').Trim()
                if (-not $relClean) { continue }
                $remote = $remoteBaseForBackup + $relClean
                $local  = Join-Path $BackupDir ($relClean -replace '/', '\')
                # Was a raw, un-retried $session.FileExists() call - a dropped session here threw
                # straight out to the outer catch and aborted the ENTIRE manifest immediately (no
                # per-file "FAILED" line, nothing else in the list even attempted), unlike every
                # other FTP operation in this loop, which already retries through a drop. Routed
                # through the same helper now, so a drop here recovers (or counts as one failed
                # file, eligible for the end-of-run retry sweep below) instead of killing the run.
                $existsResult = Invoke-FtpOpWithRetry -Session $session -HostName $chosen.Host -Username $chosen.Username -Password $password -Operation {
                    param($s)
                    $s.FileExists($remote)
                }
                $session = $existsResult.Session
                if (-not $existsResult.Ok) {
                    $fail++
                    $failedBackups.Add([pscustomobject]@{ Rel = $relClean; Remote = $remote; Local = $local })
                    Write-Host ("  FAILED  " + $relClean + "  ->  " + $existsResult.Error) -ForegroundColor Red
                    continue
                }
                if (-not $existsResult.Result) {
                    Write-Host ("  not on server  " + $relClean + "  (nothing to back up)") -ForegroundColor DarkGray
                    $skip++
                    continue
                }
                $localDir = Split-Path $local -Parent
                if (-not (Test-Path $localDir)) { New-Item -ItemType Directory -Path $localDir -Force | Out-Null }
                $getResult = Invoke-FtpOpWithRetry -Session $session -HostName $chosen.Host -Username $chosen.Username -Password $password -Operation {
                    param($s)
                    $r = $s.GetFiles($remote, $local); $r.Check()
                }
                $session = $getResult.Session
                if (-not $getResult.Ok) {
                    $fail++
                    $failedBackups.Add([pscustomobject]@{ Rel = $relClean; Remote = $remote; Local = $local })
                    Write-Host ("  FAILED  " + $relClean + "  ->  " + $getResult.Error) -ForegroundColor Red
                    continue
                }
                $bkSizeNote = ""
                try { $bkSizeNote = "  (" + (Get-Item $local).Length + " bytes)" } catch { }
                Write-Host ("  backed up  " + $relClean + $bkSizeNote) -ForegroundColor Green
                $ok++

                # Also push the copy just downloaded up to the FTP-side backup folder, on the
                # same session - mirrors Get-FtpUpload.ps1's own PutFiles($entry.BackupFile,
                # $remoteDest) pattern. A failure here doesn't count against $fail / doesn't
                # abort the run - the safety-critical part (the local copy) already succeeded.
                if ($AlsoFtpBackup) {
                    $ftpDest = $ftpBackupDest + $relClean
                    $putResult = Invoke-FtpOpWithRetry -Session $session -HostName $chosen.Host -Username $chosen.Username -Password $password -Operation {
                        param($s)
                        Ensure-RemoteDir -Sess $s -RemoteDir ($ftpDest -replace '/[^/]+$', '')
                        $r = $s.PutFiles($local, $ftpDest); $r.Check()
                    }
                    $session = $putResult.Session
                    if ($putResult.Ok) {
                        $ftpOk++
                    } else {
                        $ftpFail++
                        $failedFtpBackups.Add([pscustomobject]@{ Rel = $relClean; Local = $local; Dest = $ftpDest })
                        Write-Host ("  FTP BACKUP FAILED  " + $relClean + "  ->  " + $putResult.Error) -ForegroundColor Yellow
                    }
                }
            }

            # One automatic sweep over whatever's still failed, after a fresh reconnect -
            # catches an outage that outlasted the inline per-file retry above but has since
            # cleared. No interactive "retry?" prompt (unlike Get-FtpUpload.ps1) - this always
            # runs hidden/unattended, so there's no console to ask on.
            if ($failedBackups.Count -gt 0 -or $failedFtpBackups.Count -gt 0) {
                Write-Host ''
                Write-Host "Reconnecting for a final retry pass..." -ForegroundColor Yellow
                try { $session.Dispose() } catch { <# already dead #> }
                $session = New-FtpSession -HostName $chosen.Host -Username $chosen.Username -Password $password

                $stillFailedBackups = [System.Collections.Generic.List[object]]::new()
                foreach ($item in $failedBackups) {
                    $retryResult = Invoke-FtpOpWithRetry -Session $session -HostName $chosen.Host -Username $chosen.Username -Password $password -Operation {
                        param($s)
                        $r = $s.GetFiles($item.Remote, $item.Local); $r.Check()
                    }
                    $session = $retryResult.Session
                    if ($retryResult.Ok) {
                        $ok++; $fail--
                        Write-Host ("  backed up (retry)  " + $item.Rel) -ForegroundColor Green
                    } else {
                        $stillFailedBackups.Add($item)
                        Write-Host ("  STILL FAILED  " + $item.Rel + "  ->  " + $retryResult.Error) -ForegroundColor Red
                    }
                }
                $failedBackups = $stillFailedBackups

                foreach ($item in $failedFtpBackups) {
                    $retryResult = Invoke-FtpOpWithRetry -Session $session -HostName $chosen.Host -Username $chosen.Username -Password $password -Operation {
                        param($s)
                        Ensure-RemoteDir -Sess $s -RemoteDir ($item.Dest -replace '/[^/]+$', '')
                        $r = $s.PutFiles($item.Local, $item.Dest); $r.Check()
                    }
                    $session = $retryResult.Session
                    if ($retryResult.Ok) {
                        $ftpOk++; $ftpFail--
                        Write-Host ("  FTP backup (retry)  " + $item.Rel) -ForegroundColor Green
                    } else {
                        Write-Host ("  FTP BACKUP STILL FAILED  " + $item.Rel + "  ->  " + $retryResult.Error) -ForegroundColor Yellow
                    }
                }
            }
        } finally {
            if ($session) { $session.Dispose() }
        }
        Write-Host ''
        if ($AlsoFtpBackup) { Write-Host "FTP backup: $ftpOk uploaded, $ftpFail failed." -ForegroundColor $(if ($ftpFail -gt 0) { 'Yellow' } else { 'Green' }) }
        $backupColour = if ($fail -gt 0) { 'Yellow' } else { 'Green' }
        Write-Host "Backup complete: $ok backed up, $skip not on server, $fail failed." -ForegroundColor $backupColour
        Write-Host "BACKUPDIR: $BackupDir" -ForegroundColor Cyan
    } catch {
        Write-Host ''
        Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    }
    return
}

if ($ReadLast -gt 0) {
    $allLines = @(Get-Content $listFile)
    $dataLines = @($allLines | Where-Object { $_.Trim() -and $_.TrimStart() -notmatch '^#' })
    if (-not $dataLines) { Write-Host "redeploy-list.txt has no entries yet." -ForegroundColor Yellow; return }
    $take = [Math]::Min($ReadLast, $dataLines.Count)
    $startIdx = $dataLines.Count - $take
    Write-Host ""
    Write-Host "Last $take of $($dataLines.Count) entr$(if ($dataLines.Count -eq 1) {'y'} else {'ies'}) in redeploy-list.txt:" -ForegroundColor Cyan
    for ($i = $startIdx; $i -lt $dataLines.Count; $i++) {
        $p = Parse-DeployLine -Line $dataLines[$i]
        Write-Host ""
        Write-Host ("[" + ($i + 1) + "/" + $dataLines.Count + "]  " + $p.Stamp) -ForegroundColor White
        Write-Host ("  Files: " + $p.FileCsv) -ForegroundColor Green
        if ($p.DetailsRaw) {
            foreach ($d in ($p.DetailsRaw -split '\\n')) { Write-Host ("  - " + $d.Trim()) -ForegroundColor Gray }
        }
        $depTest = if ($p.DeployedTest) { $p.DeployedTest } else { 'NOT deployed' }
        $depLive = if ($p.DeployedLive) { $p.DeployedLive } else { 'NOT deployed' }
        Write-Host ("  Test: $depTest   |   Live: $depLive") -ForegroundColor DarkGray
    }
    Write-Host ""
    return
}

if ($AddEntry) {
    try {
        if (-not $Files -or $Files.Count -eq 0) { throw "-AddEntry requires -Files (one or more)." }
        if (-not $Details) { throw "-AddEntry requires -Details." }

        # Canonical form throughout the viewer app is forward-slash (matches what git itself always
        # outputs, and what the FTP remote target expects) - -AddEntry is a second, independent way
        # to add a file (invoked directly from the command line, bypassing the HTA's own Add Entry
        # modal entirely), so it needs the same backslash->forward-slash normalization the HTA's own
        # manual-entry points already apply, or a path typed/pasted here in Windows style slips
        # through unnormalized and silently mismatches every other path this app produces.
        $cleanFiles   = $Files | ForEach-Object { ($_ -replace '\|', '/') -replace '\\', '/' }
        $cleanDetails = $Details -replace '\|', '/'
        if ((($Files -join ',') -ne ($cleanFiles -join ',')) -or ($Details -ne $cleanDetails)) {
            Write-Host "Note: replaced '|' with '/' (and any '\' with '/') in your input - '|' is the column separator, '/' is this app's canonical path separator." -ForegroundColor Yellow
        }
        $newFiles = $cleanFiles | ForEach-Object { $_.Trim() } | Where-Object { $_ }
        if (-not $newFiles) { throw "-Files resolved to no entries." }
        # Includes a real time-of-day (not just the date) so same-day "was this file edited after
        # the entry was written" comparisons in the viewer app have something precise to compare
        # against, instead of having to fall back to an end-of-day floor. The reader already
        # parses an optional HH:MM on this field - this is the write side catching up to it.
        $now = Get-Date -Format 'yyyy-MM-dd HH:mm'

        $allLines = @(Get-Content $listFile)
        $lastIdx = -1
        for ($i = $allLines.Count - 1; $i -ge 0; $i--) {
            if ($allLines[$i].Trim() -and $allLines[$i].TrimStart() -notmatch '^#') { $lastIdx = $i; break }
        }

        if ($lastIdx -lt 0) {
            $allLines += "$now | $($newFiles -join ',') | $cleanDetails | | "
            Set-Content -Path $listFile -Value $allLines -Encoding UTF8
            Write-Host "Added first entry to redeploy-list.txt." -ForegroundColor Green
        } else {
            $parsed = Parse-DeployLine -Line $allLines[$lastIdx]
            if (-not $parsed.DeployedTest -and -not $parsed.DeployedLive) {
                $mergedFiles = @($parsed.FileCsv -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
                foreach ($f in $newFiles) { if ($mergedFiles -notcontains $f) { $mergedFiles += $f } }
                $mergedDetails = if ($parsed.DetailsRaw) { $parsed.DetailsRaw + '\n' + $cleanDetails } else { $cleanDetails }
                $allLines[$lastIdx] = "$now | $($mergedFiles -join ',') | $mergedDetails | | "
                Set-Content -Path $listFile -Value $allLines -Encoding UTF8
                Write-Host "Last entry was still pending (not deployed to Test or Live) - merged into it." -ForegroundColor Green
            } else {
                $allLines += "$now | $($newFiles -join ',') | $cleanDetails | | "
                Set-Content -Path $listFile -Value $allLines -Encoding UTF8
                Write-Host "Last entry was already deployed - appended a new entry." -ForegroundColor Green
            }
        }
    } catch {
        Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    }
    return
}

if ($DeleteLastEntryIfPending) {
    try {
        $allLines = @(Get-Content $listFile)
        $lastIdx = -1
        for ($i = $allLines.Count - 1; $i -ge 0; $i--) {
            if ($allLines[$i].Trim() -and $allLines[$i].TrimStart() -notmatch '^#') { $lastIdx = $i; break }
        }
        if ($lastIdx -lt 0) { throw "redeploy-list.txt has no entries." }

        $parsed = Parse-DeployLine -Line $allLines[$lastIdx]
        if ($parsed.DeployedTest -or $parsed.DeployedLive) {
            $depTest = if ($parsed.DeployedTest) { $parsed.DeployedTest } else { 'no' }
            $depLive = if ($parsed.DeployedLive) { $parsed.DeployedLive } else { 'no' }
            throw "Last entry has already been deployed (Test: $depTest, Live: $depLive) - refusing to delete a deployed entry."
        }

        $removedLine = $allLines[$lastIdx]
        # Built by index-filtering rather than array-slicing, since PowerShell's ..
        # range operator misbehaves when $lastIdx is the first or last element.
        $newLines = New-Object System.Collections.ArrayList
        for ($i = 0; $i -lt $allLines.Count; $i++) {
            if ($i -ne $lastIdx) { [void]$newLines.Add($allLines[$i]) }
        }
        Set-Content -Path $listFile -Value $newLines -Encoding UTF8
        Write-Host "Deleted last entry (was pending, not yet deployed):" -ForegroundColor Green
        Write-Host "  $removedLine" -ForegroundColor DarkGray
    } catch {
        Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    }
    return
}

# Defense in depth: RedeployLogViewer's own UI already refuses to add these to a batch, but
# redeploy-list.txt is explicitly documented as hand-editable, so a mistyped or manually-added
# entry could still reach this script directly. Only the rules RedeployLogViewer.hta treats as
# universal (STANDARD_EXCLUSIONS) live here - ported from Get-FtpUpload.ps1's own $deployable
# filter, including its quirk that dot-prefix is only checked at the start of the full path or
# the filename itself (a dot-folder in the middle of a path slips through in the original too).
# Get-FtpUpload.ps1 also excludes z_*/zz*-prefixed filenames, but that's a team naming
# convention, not a universal rule, so it's deliberately not enforced here either - add it as a
# project's own .ftpignore pattern if that project wants it back.
function Test-StandardExclusion {
    param([string]$RelPath)
    $rel = $RelPath -replace '\\', '/'
    $name = ($rel -split '/')[-1]
    if ($rel.StartsWith('.') -or $name.StartsWith('.')) { return $true }
    if ($rel -match '\.(ps1|md|sql|sln|old|publishproj)$') { return $true }
    if ($rel -match '(^|/)web\.config$') { return $true }
    if ($rel -match '(^|/)web\.[^/]+\.config$') { return $true }
    if ($rel -match '(^|/)bin/[^/]+\.(pdb|xml|refresh)$') { return $true }
    if ($rel -match '(^|/)packages/') { return $true }
    if ($rel -match '(^|/)app_data/publishprofiles(/|$)') { return $true }
    return $false
}

# Full-screen multicolour "are you sure" flash for live deploys.
function Show-ProductionSplash {
    $colours = @([ConsoleColor]::Red, [ConsoleColor]::Yellow, [ConsoleColor]::Green,
                 [ConsoleColor]::Cyan, [ConsoleColor]::Magenta, [ConsoleColor]::Blue,
                 [ConsoleColor]::White, [ConsoleColor]::DarkRed, [ConsoleColor]::DarkYellow)
    try { $w = $Host.UI.RawUI.WindowSize.Width - 1; $h = $Host.UI.RawUI.WindowSize.Height - 1 }
    catch { $w = 80; $h = 25 }
    if ($w -lt 20) { $w = 80 }
    if ($h -lt 12) { $h = 25 }
    $lines = @('', '*** THIS IS PRODUCTION ***', '', 'L I V E', '', 'ARE YOU CRAZY?', '')
    $midStart = [int](($h - $lines.Count) / 2)
    $rnd = New-Object System.Random
    for ($frame = 0; $frame -lt 8; $frame++) {
        Clear-Host
        for ($row = 0; $row -lt $h; $row++) {
            $bg = $colours[$rnd.Next($colours.Count)]
            $msgIx = $row - $midStart
            if ($msgIx -ge 0 -and $msgIx -lt $lines.Count -and $lines[$msgIx]) {
                $txt = $lines[$msgIx]
                $pad = [int](($w - $txt.Length) / 2)
                if ($pad -lt 0) { $pad = 0 }
                $full = (' ' * $pad) + $txt + (' ' * [Math]::Max(0, $w - $pad - $txt.Length))
                Write-Host $full -BackgroundColor $bg -ForegroundColor Black
            } else {
                Write-Host (' ' * $w) -BackgroundColor $bg
            }
        }
        Start-Sleep -Milliseconds 140
    }
}

if ($DeployManifest) {
    try {
        if (-not (Test-Path $DeployManifest)) { throw "Deploy manifest not found: $DeployManifest" }
        $manifestLines = @(Get-Content $DeployManifest) | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -notmatch '^#' }
        if (-not $manifestLines) { throw "Deploy manifest is empty: $DeployManifest" }

        $scriptDirForDeploy  = $PSScriptRoot
        $repoRootForDeploy   = Split-Path $scriptDirForDeploy -Parent
        $remoteBaseForDeploy = '/site/wwwroot/'

        $chosen   = Get-FtpTarget -ScriptDir $scriptDirForDeploy -Name $Target
        $password = Get-FtpPassword -ScriptDir $scriptDirForDeploy -TargetName $chosen.Name -Cache @{} -AutoMode $script:isAutoMode -SuppliedPasswordFile $SuppliedPasswordFile

        # --- live safety gate (identical to the default flow's) ---
        $isProduction = $chosen.Name -match '(?i)prod|live'
        if ($isProduction) {
            if ($script:isAutoMode -and $LiveConfirmed) {
                Write-Host 'Production deploy - confirmation phrase already verified by caller (automated).' -ForegroundColor DarkGray
            } else {
                Show-ProductionSplash
                Write-Host ''
                $phrase = Read-Host 'To proceed type exactly:  DEPLOY TO LIVE'
                if ($phrase -cne 'DEPLOY TO LIVE') { throw 'Production deploy NOT confirmed - aborted.' }
            }
        }

        # --- resolve / validate files (same defense-in-depth exclusion check as the default flow) ---
        # A standard-excluded file (web.config etc.) no longer aborts the whole run - RedeployLogViewer
        # now lets one be selected into a batch purely so the audit trail shows it was part of the
        # changeset, even though it still can't be sent verbatim. It's skipped and reported instead,
        # UNLESS the line carries a cherry-pick override (see below), which is a deliberate, already
        # mandatory-backup-and-verified per-file opt-in to send a hand-merged substitute instead of
        # the raw file - re-blocking that here would just be redundant friction on something already
        # consciously chosen through that separate workflow.
        $plan = @()
        $excludedFiles = [System.Collections.Generic.List[string]]::new()
        foreach ($line in $manifestLines) {
            $isDelete = $false; $rel = $line
            if ($line -match '^(?i)DELETE:\s*(.+)$') { $isDelete = $true; $rel = $Matches[1].Trim() }
            # Cherry-pick override: "relpath|overrideLocalPath" - only ever appended by
            # RedeployLogViewer itself (runLiveDeploy()), never present in a hand-written manifest.
            $overrideLocal = $null
            if ($rel -match '^(.+?)\|(.+)$') { $rel = $Matches[1]; $overrideLocal = $Matches[2] }
            $relClean = $rel -replace '\\', '/'
            if (-not $overrideLocal -and (Test-StandardExclusion -RelPath $relClean)) {
                $excludedFiles.Add($relClean)
                continue
            }
            $localPath = if ($overrideLocal) { $overrideLocal } else { Join-Path $repoRootForDeploy ($relClean -replace '/', '\') }
            if (-not $isDelete -and -not (Test-Path $localPath)) { throw "File not found locally: $relClean" }
            $plan += [pscustomobject]@{ Rel = $relClean; Local = $localPath; Remote = ($remoteBaseForDeploy + $relClean); Delete = $isDelete }
        }

        # --- write the .deploy-lists audit file (same location/format as Get-FtpUpload.ps1's own,
        # so RedeployLogViewer's pencil-icon "edit live date" lookup can find and describe a
        # Prepare-a-Live-Deployment run exactly like it already can for a Get-FtpUpload one).
        # Written now, before the transfer - mirrors Get-FtpUpload's own ordering, where the list
        # describes what was INTENDED, so it still exists even on a partial/failed run. ---
        $deployListName = $null
        if ($DeployListStamp) {
            $deployListsDir = Join-Path $scriptDirForDeploy '.deploy-lists'
            if (-not (Test-Path $deployListsDir)) { New-Item -ItemType Directory -Path $deployListsDir -Force | Out-Null }
            $safeDesc = ($DeployListDescription -replace '[\\/:*?"<>|]', '_').Trim()
            $deployListName = if ($safeDesc) { "$DeployListStamp $safeDesc.txt" } else { "$DeployListStamp.txt" }
            $rangeSummary = if ($CommitHashes) {
                $hashList = @($CommitHashes -split ',' | Where-Object { $_ })
                "RedeployLogViewer Prepare-a-Live-Deployment - $($hashList.Count) commit(s): " +
                    (($hashList | ForEach-Object { $_.Substring(0, [Math]::Min(7, $_.Length)) }) -join ',')
            } else {
                'RedeployLogViewer Prepare-a-Live-Deployment'
            }
            $dlLines = [System.Collections.Generic.List[string]]::new()
            $dlLines.Add("# Auto-generated deploy list - $rangeSummary")
            $dlLines.Add("# Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm')")
            if ($LocalBackupDir) { $dlLines.Add("# LocalBackup: $LocalBackupDir") }
            # Full accumulated Details text (typically every ticked commit's own message, oldest
            # first) from RedeployLogViewer's Prepare-a-Live-Deployment screen - one comment line
            # per line of the notes file, delimited so it's unambiguous where this block starts/
            # ends among the other single-line header fields above it. Skipped entirely if not
            # supplied, or the file turns out to be missing/empty.
            if ($DeployListNotesFile -and (Test-Path $DeployListNotesFile)) {
                $notesLines = @(Get-Content $DeployListNotesFile)
                if ($notesLines) {
                    $dlLines.Add("# --- Details ---")
                    foreach ($nLine in $notesLines) { $dlLines.Add("# $nLine") }
                    $dlLines.Add("# --- End Details ---")
                }
            }
            $dlLines.Add("")
            foreach ($p in $plan) {
                if ($p.Delete) { $dlLines.Add("DELETE: $($p.Rel)") } else { $dlLines.Add($p.Rel) }
            }
            try {
                $dlLines | Set-Content -Path (Join-Path $deployListsDir $deployListName) -Encoding UTF8
                Write-Host "DEPLOYLIST: $(Join-Path $deployListsDir $deployListName)" -ForegroundColor Cyan
            } catch {
                Write-Host "Could not write .deploy-lists audit file: $($_.Exception.Message)" -ForegroundColor Yellow
                $deployListName = $null
            }
        }

        # --- show the plan and confirm ---
        Write-Host ''
        Write-Host "TARGET : $($chosen.Name)" -ForegroundColor Cyan
        Write-Host "         $($chosen.Username) @ $($chosen.Host)" -ForegroundColor DarkGray
        if ($WhatIf) { Write-Host "MODE   : DRY RUN (nothing will be sent)" -ForegroundColor Yellow }
        Write-Host ''
        Write-Host 'Files to deploy:' -ForegroundColor White
        foreach ($p in $plan) {
            if ($p.Delete) { Write-Host ("  [DELETE] " + $p.Rel) -ForegroundColor Red }
            else           { Write-Host ("  " + $p.Rel) -ForegroundColor Green }
        }
        if ($excludedFiles.Count -gt 0) {
            Write-Host ''
            # Same "verb  path  (reason)" shape as the sent/deleted/skipped lines below (not just a
            # human-readable summary block) - RedeployLogViewer's poll parser looks for this exact
            # pattern so each excluded file's status updates from "pending" instead of getting stuck
            # there for the rest of the run (the same class of bug already found and fixed once this
            # session for the delete-target-already-gone "skipped" line).
            foreach ($ex in $excludedFiles) { Write-Host ("  excluded  " + $ex + "  (standard exclusion - not sent)") -ForegroundColor DarkYellow }
        }
        Write-Host ''
        if ($script:isAutoMode) {
            Write-Host 'Confirm? [Y/N] : Y (auto)' -ForegroundColor DarkGray
        } else {
            $c = Read-Host 'Confirm? [Y/N]'
            if ($c -notmatch '^(?i)y') { throw 'Aborted by user.' }
        }

        if ($WhatIf) { Write-Host 'Dry run complete - nothing sent.' -ForegroundColor Yellow; return }

        $session = New-FtpSession -HostName $chosen.Host -Username $chosen.Username -Password $password
        $ok = 0; $fail = 0; $skip = 0
        $failedDeploys = [System.Collections.Generic.List[object]]::new()
        try {
            Write-Host ''
            Write-Host 'Connected. Transferring...' -ForegroundColor Cyan
            foreach ($p in $plan) {
                if ($p.Delete) {
                    $delResult = Invoke-FtpOpWithRetry -Session $session -HostName $chosen.Host -Username $chosen.Username -Password $password -Operation {
                        param($s)
                        $r = $s.RemoveFiles($p.Remote); $r.Check()
                    }
                    $session = $delResult.Session
                    if ($delResult.Ok) {
                        Write-Host ("  deleted  " + $p.Rel) -ForegroundColor Red
                        $ok++
                    } elseif ($delResult.Error -match 'Could not retrieve file information') {
                        # Same "already gone = functionally a success" reasoning as the default flow.
                        Write-Host ("  skipped  " + $p.Rel + "  (already not on server)") -ForegroundColor DarkGray
                        $skip++
                    } else {
                        $fail++
                        $failedDeploys.Add($p)
                        Write-Host ("  FAILED   " + $p.Rel + "  ->  " + $delResult.Error) -ForegroundColor Red
                    }
                } else {
                    $putResult = Invoke-FtpOpWithRetry -Session $session -HostName $chosen.Host -Username $chosen.Username -Password $password -Operation {
                        param($s)
                        $remoteDir = $p.Remote -replace '/[^/]+$', ''
                        Ensure-RemoteDir -Sess $s -RemoteDir $remoteDir
                        $r = $s.PutFiles($p.Local, $p.Remote); $r.Check()
                    }
                    $session = $putResult.Session
                    if ($putResult.Ok) {
                        Write-Host ("  sent     " + $p.Rel) -ForegroundColor Green
                        $ok++
                    } else {
                        $fail++
                        $failedDeploys.Add($p)
                        Write-Host ("  FAILED   " + $p.Rel + "  ->  " + $putResult.Error) -ForegroundColor Red
                    }
                }
            }

            # One automatic sweep over whatever's still failed, after a fresh reconnect - see
            # -BackupManifest's matching block for the full reasoning (no interactive prompt,
            # since this always runs hidden/unattended).
            if ($failedDeploys.Count -gt 0) {
                Write-Host ''
                Write-Host "Reconnecting for a final retry pass..." -ForegroundColor Yellow
                try { $session.Dispose() } catch { <# already dead #> }
                $session = New-FtpSession -HostName $chosen.Host -Username $chosen.Username -Password $password
                foreach ($p in $failedDeploys) {
                    if ($p.Delete) {
                        $retryResult = Invoke-FtpOpWithRetry -Session $session -HostName $chosen.Host -Username $chosen.Username -Password $password -Operation {
                            param($s)
                            $r = $s.RemoveFiles($p.Remote); $r.Check()
                        }
                        $session = $retryResult.Session
                        if ($retryResult.Ok) {
                            $ok++; $fail--
                            Write-Host ("  deleted (retry)  " + $p.Rel) -ForegroundColor Red
                        } elseif ($retryResult.Error -match 'Could not retrieve file information') {
                            $skip++; $fail--
                            Write-Host ("  skipped (retry)  " + $p.Rel + "  (already not on server)") -ForegroundColor DarkGray
                        } else {
                            Write-Host ("  STILL FAILED  " + $p.Rel + "  ->  " + $retryResult.Error) -ForegroundColor Red
                        }
                    } else {
                        $retryResult = Invoke-FtpOpWithRetry -Session $session -HostName $chosen.Host -Username $chosen.Username -Password $password -Operation {
                            param($s)
                            $remoteDir = $p.Remote -replace '/[^/]+$', ''
                            Ensure-RemoteDir -Sess $s -RemoteDir $remoteDir
                            $r = $s.PutFiles($p.Local, $p.Remote); $r.Check()
                        }
                        $session = $retryResult.Session
                        if ($retryResult.Ok) {
                            $ok++; $fail--
                            Write-Host ("  sent (retry)  " + $p.Rel) -ForegroundColor Green
                        } else {
                            Write-Host ("  STILL FAILED  " + $p.Rel + "  ->  " + $retryResult.Error) -ForegroundColor Red
                        }
                    }
                }
            }
        } finally {
            if ($session) { $session.Dispose() }
        }

        Write-Host ''
        $skipNote = if ($skip -gt 0) { ", $skip already up to date" } else { '' }
        $excludedNote = if ($excludedFiles.Count -gt 0) { ", $($excludedFiles.Count) excluded (not sent)" } else { '' }
        if ($fail -eq 0) {
            Write-Host "Done. $ok file(s) redeployed$skipNote$excludedNote to $($chosen.Name)." -ForegroundColor Green
        } else {
            Write-Host "Completed with errors: $ok sent$skipNote$excludedNote, $fail failed." -ForegroundColor Yellow
        }

        # --- deploy-log-{site}.txt audit row - same format Get-FtpUpload.ps1 writes (same
        # site-name derivation via Get-SiteName, same pipe-delimited columns), so both tools'
        # history reads as one continuous trail no matter which one did a given deploy. Gated on
        # $ok -gt 0, identical to Get-FtpUpload.ps1's own $uploadedPaths.Count -gt 0 gate. ---
        if ($DeployListStamp -and $ok -gt 0) {
            try {
                $siteName = Get-SiteName -Username $chosen.Username
                $deployLogFile = Join-Path $scriptDirForDeploy "deploy-log-$($siteName.ToLower()).txt"
                $safeNote = ($DeployListDescription -replace '\|', '-')
                $logStatus = if ($fail -gt 0) { 'PARTIAL' } else { 'OK' }
                $row = "$(Get-Date -Format 'yyyy-MM-dd HH:mm')|$siteName|$DeployedUpTo|$CommitHashes|$deployListName|Y|$(if ($BackedUpToFtp) { 'Y' } else { 'N' })|$ok|$fail|$logStatus|$safeNote"
                if (-not (Test-Path $deployLogFile)) {
                    "# DateTime|Site|DeployedUpTo|Commits|DeployList|Compare|FtpBackup|Uploaded|Failed|Status|Notes" |
                        Set-Content -Path $deployLogFile -Encoding UTF8
                }
                Add-Content -Path $deployLogFile -Value $row -Encoding UTF8
                Write-Host "Deploy log updated: $deployLogFile" -ForegroundColor Cyan
            } catch {
                Write-Host "Could not write deploy log: $($_.Exception.Message)" -ForegroundColor Yellow
            }
        }
    } catch {
        Write-Host ''
        Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
        if ($_.ScriptStackTrace) { Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray }
    }
    return
}

# Retrospective Live-link (RedeployLogViewer's "Mark as Already Live" -> "Link Commit(s)"): writes
# the SAME .deploy-lists\*.txt + deploy-log-{site}.txt audit trail -DeployManifest does, for an
# entry that's already known to be live and just needs its commit(s) recorded after the fact - no
# FTP session is ever opened here, nothing is sent. Both the deploy-list file's own header comment
# and the deploy-log row's Status column are marked RETROSPECTIVE, so this is never mistaken for a
# real completed deploy when read back later (by a human, or by Get-FtpUpload.ps1's own "commits
# since last deployed" scan).
if ($RetrospectiveManifest) {
    try {
        if (-not (Test-Path $RetrospectiveManifest)) { throw "Files manifest not found: $RetrospectiveManifest" }
        $manifestLines = @(Get-Content $RetrospectiveManifest) | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -notmatch '^#' }
        if (-not $manifestLines) { throw "Files manifest is empty: $RetrospectiveManifest" }
        if (-not $DeployListStamp) { throw "-DeployListStamp is required." }

        $scriptDirForRetro = $PSScriptRoot
        $chosen = Get-FtpTarget -ScriptDir $scriptDirForRetro -Name $Target
        $siteName = Get-SiteName -Username $chosen.Username

        $deployListsDir = Join-Path $scriptDirForRetro '.deploy-lists'
        if (-not (Test-Path $deployListsDir)) { New-Item -ItemType Directory -Path $deployListsDir -Force | Out-Null }
        $safeDesc = ($DeployListDescription -replace '[\\/:*?"<>|]', '_').Trim()
        $deployListName = if ($safeDesc) { "$DeployListStamp $safeDesc.txt" } else { "$DeployListStamp.txt" }
        $hashList = @($CommitHashes -split ',' | Where-Object { $_ })
        $rangeSummary = if ($hashList.Count -gt 0) {
            "RedeployLogViewer retrospective Live link - $($hashList.Count) commit(s): " +
                (($hashList | ForEach-Object { $_.Substring(0, [Math]::Min(7, $_.Length)) }) -join ',')
        } else {
            'RedeployLogViewer retrospective Live link'
        }
        $dlLines = [System.Collections.Generic.List[string]]::new()
        $dlLines.Add("# Auto-generated deploy list - $rangeSummary")
        $dlLines.Add("# Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm')")
        $dlLines.Add("# RETROSPECTIVE - created when linking an already-live entry's commit(s) in RedeployLogViewer; no real file transfer occurred for this deploy list.")
        $dlLines.Add("")
        foreach ($line in $manifestLines) { $dlLines.Add($line) }
        $dlLines | Set-Content -Path (Join-Path $deployListsDir $deployListName) -Encoding UTF8
        Write-Host "DEPLOYLIST: $(Join-Path $deployListsDir $deployListName)" -ForegroundColor Cyan

        $deployLogFile = Join-Path $scriptDirForRetro "deploy-log-$($siteName.ToLower()).txt"
        $safeNote = ($DeployListDescription -replace '\|', '-')
        $noteText = if ($safeNote) { "Retrospective link (no real deploy) - $safeNote" } else { 'Retrospective link (no real deploy)' }
        $row = "$(Get-Date -Format 'yyyy-MM-dd HH:mm')|$siteName|$DeployedUpTo|$CommitHashes|$deployListName|N|N|0|0|RETROSPECTIVE|$noteText"
        if (-not (Test-Path $deployLogFile)) {
            "# DateTime|Site|DeployedUpTo|Commits|DeployList|Compare|FtpBackup|Uploaded|Failed|Status|Notes" |
                Set-Content -Path $deployLogFile -Encoding UTF8
        }
        Add-Content -Path $deployLogFile -Value $row -Encoding UTF8
        Write-Host "RETROSPECTIVE_OK: $deployListName" -ForegroundColor Green
    } catch {
        Write-Host ''
        Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
        if ($_.ScriptStackTrace) { Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray }
    }
    return
}

# Checks (and, with -DoSync, uploads) a local backup folder against its FTP-side counterpart at
# /site/backups/<same leaf folder name>/ - the same remote-location convention -AlsoFtpBackup
# already uses above, so a folder backed up with that checkbox and one synced later through this
# mode land in the identical remote location either way. Used by RedeployLogViewer's "View
# Backup" panel (opened from the Mark-As-Live modal's pencil icon) to let you finish an
# FTP-side backup you skipped earlier, without re-running the whole Prepare-a-Live-Deployment
# flow. Read-only without -DoSync; with it, uploads whatever's currently MISSING (backup
# snapshots are immutable once written, so "missing vs. present" is a stable per-file state -
# nothing already on FTP is ever re-uploaded).
if ($BackupSyncCheck) {
    try {
        if (-not (Test-Path $BackupSyncCheck)) { throw "Local backup folder not found: $BackupSyncCheck" }
        $localFiles = @(Get-ChildItem -Path $BackupSyncCheck -Recurse -File)
        if (-not $localFiles) { throw "Local backup folder is empty: $BackupSyncCheck" }

        $scriptDirForSync = $PSScriptRoot
        $chosen   = Get-FtpTarget -ScriptDir $scriptDirForSync -Name $Target
        $password = Get-FtpPassword -ScriptDir $scriptDirForSync -TargetName $chosen.Name -Cache @{} -AutoMode $script:isAutoMode -SuppliedPasswordFile $SuppliedPasswordFile

        $ftpBase = $FtpBackupBase.TrimEnd('/') + '/' + (Split-Path $BackupSyncCheck -Leaf) + '/'
        $baseFull = (Resolve-Path $BackupSyncCheck).Path.TrimEnd('\')
        $items = foreach ($f in $localFiles) {
            $rel = $f.FullName.Substring($baseFull.Length + 1) -replace '\\', '/'
            [pscustomobject]@{ Rel = $rel; Local = $f.FullName; Remote = $ftpBase + $rel }
        }

        Write-Host ''
        Write-Host "LOCAL FOLDER : $BackupSyncCheck" -ForegroundColor Cyan
        Write-Host "FTP TARGET   : $($chosen.Name)" -ForegroundColor Cyan
        Write-Host "FTP LOCATION : $ftpBase" -ForegroundColor Cyan
        Write-Host ''

        $session = New-FtpSession -HostName $chosen.Host -Username $chosen.Username -Password $password
        $onFtp = 0; $missing = 0; $synced = 0; $syncFailed = 0
        $missingItems = [System.Collections.Generic.List[object]]::new()
        try {
            foreach ($item in $items) {
                # FileExists() itself throws on a real connection problem (retried below like any
                # other op); a clean "false" (file genuinely never uploaded) is turned into this
                # throw purely so Invoke-FtpOpWithRetry's Ok/Error shape can carry it back too -
                # "MISSING_MARKER" never matches $script:sessionDropRegex, so it's never retried.
                $checkResult = Invoke-FtpOpWithRetry -Session $session -HostName $chosen.Host -Username $chosen.Username -Password $password -Operation {
                    param($s)
                    if (-not $s.FileExists($item.Remote)) { throw "MISSING_MARKER" }
                }
                $session = $checkResult.Session
                if ($checkResult.Ok) {
                    Write-Host ("  ON-FTP   " + $item.Rel) -ForegroundColor Green
                    $onFtp++
                } else {
                    Write-Host ("  MISSING  " + $item.Rel) -ForegroundColor Yellow
                    $missing++
                    $missingItems.Add($item)
                }
            }

            if ($DoSync -and $missingItems.Count -gt 0) {
                Write-Host ''
                Write-Host 'Syncing missing files to FTP...' -ForegroundColor Cyan
                $stillMissing = [System.Collections.Generic.List[object]]::new()
                foreach ($item in $missingItems) {
                    $putResult = Invoke-FtpOpWithRetry -Session $session -HostName $chosen.Host -Username $chosen.Username -Password $password -Operation {
                        param($s)
                        Ensure-RemoteDir -Sess $s -RemoteDir ($item.Remote -replace '/[^/]+$', '')
                        $r = $s.PutFiles($item.Local, $item.Remote); $r.Check()
                    }
                    $session = $putResult.Session
                    if ($putResult.Ok) {
                        Write-Host ("  SYNCED   " + $item.Rel) -ForegroundColor Green
                        $synced++
                    } else {
                        $stillMissing.Add($item)
                        Write-Host ("  SYNC-FAILED  " + $item.Rel + "  ->  " + $putResult.Error) -ForegroundColor Red
                    }
                }

                # One automatic sweep, same reasoning as every other transfer loop in this script.
                if ($stillMissing.Count -gt 0) {
                    Write-Host ''
                    Write-Host "Reconnecting for a final retry pass..." -ForegroundColor Yellow
                    try { $session.Dispose() } catch { <# already dead #> }
                    $session = New-FtpSession -HostName $chosen.Host -Username $chosen.Username -Password $password
                    foreach ($item in $stillMissing) {
                        $retryResult = Invoke-FtpOpWithRetry -Session $session -HostName $chosen.Host -Username $chosen.Username -Password $password -Operation {
                            param($s)
                            Ensure-RemoteDir -Sess $s -RemoteDir ($item.Remote -replace '/[^/]+$', '')
                            $r = $s.PutFiles($item.Local, $item.Remote); $r.Check()
                        }
                        $session = $retryResult.Session
                        if ($retryResult.Ok) {
                            $synced++
                            Write-Host ("  SYNCED (retry)  " + $item.Rel) -ForegroundColor Green
                        } else {
                            $syncFailed++
                            Write-Host ("  SYNC-STILL-FAILED  " + $item.Rel + "  ->  " + $retryResult.Error) -ForegroundColor Red
                        }
                    }
                }
            }
        } finally {
            if ($session) { $session.Dispose() }
        }

        Write-Host ''
        if ($DoSync) {
            Write-Host "Sync check complete: $onFtp on FTP, $missing missing, $synced synced, $syncFailed sync-failed." -ForegroundColor $(if ($syncFailed -gt 0) { 'Yellow' } else { 'Green' })
        } else {
            Write-Host "Sync check complete: $onFtp on FTP, $missing missing." -ForegroundColor $(if ($missing -gt 0) { 'Yellow' } else { 'Green' })
        }
    } catch {
        Write-Host ''
        Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    }
    return
}

# Nothing above matched, so reaching here means the default flow - deploy the log's last entry -
# is about to run. Requires an explicit -Deploy, or a valid -AutomationToken (see its own doc
# comment above for why that alone is trusted) - protects against any malformed, empty, or
# mistyped invocation silently reaching a real deploy just because nothing else matched, not only
# the specific case of running with no arguments or -?.
if (-not ($Deploy -or $script:isAutoMode)) {
    Write-Host ''
    Write-Host 'No action specified - nothing was deployed.' -ForegroundColor Yellow
    Write-Host 'To deploy the last entry in redeploy-list.txt, pass -Deploy explicitly:'
    Write-Host '    .\.ftpScripts\redeploy-tweaks.ps1 -Deploy'
    Write-Host '    .\.ftpScripts\redeploy-tweaks.ps1 -Deploy -Target Production'
    Write-Host ''
    Write-Host "See this script's own header comment for every other mode (-AddEntry, -ReadLast, -BackupManifest, -DeployManifest, ...)."
    exit
}

# Keep the window alive between runs: after each pass you can hit Space to re-run
# (picks up the latest redeploy-list.txt) or Enter to close. Typed passwords are
# cached across restarts so you only enter them once.
$pwCache = @{}
$restart = $true
while ($restart) {
$restart = $false
try {
    $runStart   = Get-Date
    $scriptDir  = $PSScriptRoot
    $repoRoot   = Split-Path $scriptDir -Parent
    $remoteBase = '/site/wwwroot/'

    # --- target / password (shared helpers, also used by -BackupManifest) ---
    $chosen   = Get-FtpTarget -ScriptDir $scriptDir -Name $Target
    $password = Get-FtpPassword -ScriptDir $scriptDir -TargetName $chosen.Name -Cache $pwCache -AutoMode $script:isAutoMode

    # --- live safety gate ---
    $isProduction = $chosen.Name -match '(?i)prod|live'
    if ($isProduction) {
        if ($script:isAutoMode -and $LiveConfirmed) {
            # No console on a hidden/automated run to type the phrase into - the caller
            # (RedeployLogViewer) is trusted to have already collected the same exact
            # confirmation itself before passing -LiveConfirmed alongside a valid token.
            Write-Host 'Production deploy - confirmation phrase already verified by caller (automated).' -ForegroundColor DarkGray
        } else {
            Show-ProductionSplash
            Write-Host ''
            $phrase = Read-Host 'To proceed type exactly:  DEPLOY TO LIVE'
            if ($phrase -cne 'DEPLOY TO LIVE') { throw 'Production deploy NOT confirmed - aborted.' }
        }
    }

    # --- last batch from redeploy-list.txt ---
    # Columns: timestamp | files | details | DeployedTest | DeployedLive
    if (-not (Test-Path $listFile)) { throw "Missing redeploy-list.txt." }
    $allLines = @(Get-Content $listFile)
    $lastIdx = -1
    for ($i = $allLines.Count - 1; $i -ge 0; $i--) {
        if ($allLines[$i].Trim() -and $allLines[$i].TrimStart() -notmatch '^#') { $lastIdx = $i; break }
    }
    if ($lastIdx -lt 0) { throw "redeploy-list.txt has no deploy entries." }
    $parsed = Parse-DeployLine -Line $allLines[$lastIdx]
    $stamp = $parsed.Stamp; $fileCsv = $parsed.FileCsv; $detailsRaw = $parsed.DetailsRaw
    $deployedTest = $parsed.DeployedTest; $deployedLive = $parsed.DeployedLive
    $detailParts = if ($detailsRaw) { $detailsRaw -split '\\n' } else { @() }
    $entries = $fileCsv -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    if (-not $entries) { throw "No files listed in the last redeploy-list.txt entry." }

    # --- resolve / validate files ---
    # Standard-excluded files are skipped and reported, not a hard abort - see the matching
    # comment in the -DeployManifest block above for why.
    #
    # -CherryPickOverride "relpath|localOverridePath" is the default flow's equivalent of
    # -DeployManifest's own inline "relpath|overrideLocalPath" manifest-line syntax - a single
    # pair rather than per-line, since the default flow's file list comes from a plain CSV column
    # (redeploy-list.txt) that can't carry an embedded "|" without corrupting the log's own column
    # structure. Only ever supplied by RedeployLogViewer itself (Cherry Pick on the Test Deploy
    # backup panel), never typed by hand. Matches that a file is skipped by
    # Test-StandardExclusion, applies only when this one entry's relpath matches, and - like the
    # -DeployManifest case - deliberately bypasses the exclusion check for that one match: the
    # override existing at all already means the file went through a mandatory backup+verify gate
    # and a deliberate cherry-pick+edit+verify action, so re-blocking it here would just be
    # redundant friction on something already consciously chosen.
    $cherryOverrideRel = $null; $cherryOverrideLocal = $null
    if ($CherryPickOverride -and $CherryPickOverride -match '^(.+?)\|(.+)$') {
        $cherryOverrideRel = ($Matches[1] -replace '\\', '/'); $cherryOverrideLocal = $Matches[2]
    }
    $plan = @()
    $excludedFiles = [System.Collections.Generic.List[string]]::new()
    foreach ($e in $entries) {
        $isDelete = $false; $rel = $e
        if ($e -match '^(?i)DELETE:\s*(.+)$') { $isDelete = $true; $rel = $Matches[1].Trim() }
        $relClean  = $rel -replace '\\', '/'
        $overrideLocal = if ($cherryOverrideRel -and $cherryOverrideRel -eq $relClean) { $cherryOverrideLocal } else { $null }
        if (-not $overrideLocal -and (Test-StandardExclusion -RelPath $relClean)) {
            $excludedFiles.Add($relClean)
            continue
        }
        $localPath = if ($overrideLocal) { $overrideLocal } else { Join-Path $repoRoot ($relClean -replace '/', '\') }
        if (-not $isDelete -and -not (Test-Path $localPath)) { throw "File not found locally: $relClean" }
        $cherryPicked = [bool]$overrideLocal
        $sizeBytes = $null
        if (-not $isDelete) { try { $sizeBytes = (Get-Item $localPath).Length } catch { $sizeBytes = $null } }
        $noteParts = @()
        if ($sizeBytes -ne $null) { $noteParts += "$sizeBytes bytes" }
        if ($cherryPicked) { $noteParts += 'CHERRY-PICKED' }
        $note = if ($noteParts.Count -gt 0) { '  (' + ($noteParts -join ', ') + ')' } else { '' }
        $plan += [pscustomobject]@{
            Rel          = $relClean
            Local        = $localPath
            Remote       = ($remoteBase + $relClean)
            Delete       = $isDelete
            CherryPicked = $cherryPicked
            Note         = $note
        }
    }

    # --- show the plan and confirm ---
    Write-Host ''
    Write-Host "TARGET : $($chosen.Name)" -ForegroundColor Cyan
    Write-Host "         $($chosen.Username) @ $($chosen.Host)" -ForegroundColor DarkGray
    if ($WhatIf) { Write-Host "MODE   : DRY RUN (nothing will be sent)" -ForegroundColor Yellow }
    Write-Host "BATCH  : $stamp" -ForegroundColor Cyan
    Write-Host ''
    Write-Host 'Files to redeploy:' -ForegroundColor White
    foreach ($p in $plan) {
        if ($p.Delete) { Write-Host ("  [DELETE] " + $p.Rel) -ForegroundColor Red }
        else           { Write-Host ("  " + $p.Rel + $p.Note) -ForegroundColor Green }
    }
    if ($excludedFiles.Count -gt 0) {
        Write-Host ''
        # Same "verb  path  (reason)" shape the HTA's poll parser looks for - see the matching
        # comment in the -DeployManifest block above.
        foreach ($ex in $excludedFiles) { Write-Host ("  excluded  " + $ex + "  (standard exclusion - not sent)") -ForegroundColor DarkYellow }
    }
    if ($detailParts.Count) {
        Write-Host ''
        Write-Host 'Details of change:' -ForegroundColor White
        foreach ($d in $detailParts) { Write-Host ("  " + $d.Trim()) -ForegroundColor Gray }
    }
    $alreadyStamp = if ($isProduction) { $deployedLive } else { $deployedTest }
    if ($alreadyStamp) {
        Write-Host ''
        Write-Host "You've already transferred this set to $($chosen.Name) on $alreadyStamp - you know?" -ForegroundColor Yellow
    }
    Write-Host ''
    if ($script:isAutoMode) {
        Write-Host 'Confirm? [Y/N] : Y (auto)' -ForegroundColor DarkGray
    } else {
        $c = Read-Host 'Confirm? [Y/N]'
        if ($c -notmatch '^(?i)y') { throw 'Aborted by user.' }
    }

    if ($WhatIf) { Write-Host 'Dry run complete - nothing sent.' -ForegroundColor Yellow; return }

    $session = New-FtpSession -HostName $chosen.Host -Username $chosen.Username -Password $password
    $ok = 0; $fail = 0; $skip = 0
    $failedDeploys = [System.Collections.Generic.List[object]]::new()
    try {
        Write-Host ''
        Write-Host 'Connected. Transferring...' -ForegroundColor Cyan
        foreach ($p in $plan) {
            if ($p.Delete) {
                $delResult = Invoke-FtpOpWithRetry -Session $session -HostName $chosen.Host -Username $chosen.Username -Password $password -Operation {
                    param($s)
                    $r = $s.RemoveFiles($p.Remote); $r.Check()
                }
                $session = $delResult.Session
                if ($delResult.Ok) {
                    Write-Host ("  deleted  " + $p.Rel) -ForegroundColor Red
                    $ok++
                } elseif ($delResult.Error -match 'Could not retrieve file information') {
                    # WinSCP can't even find the file to delete it - the functional
                    # equivalent of uploading a file that's already identical on the
                    # server: the end state you wanted is already true, so it's noise,
                    # not a real failure.
                    Write-Host ("  skipped  " + $p.Rel + "  (already not on server)") -ForegroundColor DarkGray
                    $skip++
                } else {
                    $fail++
                    $failedDeploys.Add($p)
                    Write-Host ("  FAILED   " + $p.Rel + "  ->  " + $delResult.Error) -ForegroundColor Red
                }
            } else {
                $putResult = Invoke-FtpOpWithRetry -Session $session -HostName $chosen.Host -Username $chosen.Username -Password $password -Operation {
                    param($s)
                    $remoteDir = $p.Remote -replace '/[^/]+$', ''
                    Ensure-RemoteDir -Sess $s -RemoteDir $remoteDir
                    $r = $s.PutFiles($p.Local, $p.Remote); $r.Check()
                }
                $session = $putResult.Session
                if ($putResult.Ok) {
                    Write-Host ("  sent     " + $p.Rel + $p.Note) -ForegroundColor Green
                    $ok++
                } else {
                    $fail++
                    $failedDeploys.Add($p)
                    Write-Host ("  FAILED   " + $p.Rel + "  ->  " + $putResult.Error) -ForegroundColor Red
                }
            }
        }

        # One automatic sweep over whatever's still failed, after a fresh reconnect - see
        # -BackupManifest's matching block for the full reasoning.
        if ($failedDeploys.Count -gt 0) {
            Write-Host ''
            Write-Host "Reconnecting for a final retry pass..." -ForegroundColor Yellow
            try { $session.Dispose() } catch { <# already dead #> }
            $session = New-FtpSession -HostName $chosen.Host -Username $chosen.Username -Password $password
            foreach ($p in $failedDeploys) {
                if ($p.Delete) {
                    $retryResult = Invoke-FtpOpWithRetry -Session $session -HostName $chosen.Host -Username $chosen.Username -Password $password -Operation {
                        param($s)
                        $r = $s.RemoveFiles($p.Remote); $r.Check()
                    }
                    $session = $retryResult.Session
                    if ($retryResult.Ok) {
                        $ok++; $fail--
                        Write-Host ("  deleted (retry)  " + $p.Rel) -ForegroundColor Red
                    } elseif ($retryResult.Error -match 'Could not retrieve file information') {
                        $skip++; $fail--
                        Write-Host ("  skipped (retry)  " + $p.Rel + "  (already not on server)") -ForegroundColor DarkGray
                    } else {
                        Write-Host ("  STILL FAILED  " + $p.Rel + "  ->  " + $retryResult.Error) -ForegroundColor Red
                    }
                } else {
                    $retryResult = Invoke-FtpOpWithRetry -Session $session -HostName $chosen.Host -Username $chosen.Username -Password $password -Operation {
                        param($s)
                        $remoteDir = $p.Remote -replace '/[^/]+$', ''
                        Ensure-RemoteDir -Sess $s -RemoteDir $remoteDir
                        $r = $s.PutFiles($p.Local, $p.Remote); $r.Check()
                    }
                    $session = $retryResult.Session
                    if ($retryResult.Ok) {
                        $ok++; $fail--
                        Write-Host ("  sent (retry)  " + $p.Rel + $p.Note) -ForegroundColor Green
                    } else {
                        Write-Host ("  STILL FAILED  " + $p.Rel + "  ->  " + $retryResult.Error) -ForegroundColor Red
                    }
                }
            }
        }
    } finally {
        if ($session) { $session.Dispose() }
    }

    # Stamps the deploy time back into the correct column of the last line - factored out since
    # it's now reachable two ways: the clean-success path below, and the "stamp anyway" prompt
    # for a batch that still has real failures in it.
    function Stamp-DeployTime {
        $nowStamp = Get-Date -Format 'yyyy-MM-dd HH:mm'
        $detailsClean = $detailsRaw -replace '\|', '/'   # keep details pipe-free so columns stay clean
        $writeCols = @($stamp, $fileCsv, $detailsClean, $deployedTest, $deployedLive)
        if ($isProduction) { $writeCols[4] = $nowStamp } else { $writeCols[3] = $nowStamp }
        $allLines[$lastIdx] = ($writeCols -join ' | ')
        Set-Content -Path $listFile -Value $allLines -Encoding UTF8
        Write-Host "Logged $($chosen.Name) deploy time ($nowStamp) in redeploy-list.txt." -ForegroundColor DarkGray
    }

    Write-Host ''
    Write-Host ("STARTED: " + $runStart.ToString('yyyy-MM-dd HH:mm:ss')) -ForegroundColor DarkGray
    Write-Host ("DURATION: " + [Math]::Round(((Get-Date) - $runStart).TotalSeconds, 1) + "s") -ForegroundColor DarkGray
    $skipNote = if ($skip -gt 0) { ", $skip already up to date" } else { '' }
    $excludedNote = if ($excludedFiles.Count -gt 0) { ", $($excludedFiles.Count) excluded (not sent)" } else { '' }
    if ($fail -eq 0) {
        Write-Host "Done. $ok file(s) redeployed$skipNote$excludedNote to $($chosen.Name)." -ForegroundColor Green
        Stamp-DeployTime
    }
    else {
        Write-Host "Completed with errors: $ok sent$skipNote$excludedNote, $fail failed." -ForegroundColor Yellow
        if ($script:isAutoMode) {
            # No console to ask on an unattended run - keep the safe default of not stamping,
            # same as before this change.
            Write-Host "Not stamping redeploy-list.txt (automated run, real failures present)." -ForegroundColor Yellow
        } else {
            $stampAnyway = Read-Host "Mark this batch as deployed to $($chosen.Name) anyway? [Y/N]"
            if ($stampAnyway -match '^(?i)y') { Stamp-DeployTime }
            else { Write-Host "Not stamping redeploy-list.txt." -ForegroundColor Yellow }
        }
    }
}
catch {
    Write-Host ''
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    if ($_.ScriptStackTrace) { Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray }
    if ($runStart) {
        Write-Host ("STARTED: " + $runStart.ToString('yyyy-MM-dd HH:mm:ss')) -ForegroundColor DarkGray
        Write-Host ("DURATION: " + [Math]::Round(((Get-Date) - $runStart).TotalSeconds, 1) + "s") -ForegroundColor DarkGray
    }
}
finally {
    if ($script:isAutoMode) {
        # Automated run - the caller doesn't have a console to press anything on, and there's
        # nothing sensible "re-run" would mean here, so just let the script end.
        Write-Host ''
    } else {
        Write-Host ''
        Write-Host 'Press [Space] to re-run (picks up the latest changes), or [Enter] to close...' -ForegroundColor Cyan
        try {
            # Only Space or Enter act; everything else (Alt, Tab, etc.) is ignored so Alt+Tabbing
            # away to check the browser does not close the window.
            while ($true) {
                $key = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
                if ($key.VirtualKeyCode -eq 32) { $restart = $true; Clear-Host; break }  # Space
                if ($key.VirtualKeyCode -eq 13) { break }                               # Enter
            }
        } catch {
            # Host without ReadKey support - fall back to a plain Enter-to-close.
            Read-Host
        }
    }
}
}
