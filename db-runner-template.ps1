<#
.SYNOPSIS
    Non-interactive DB script runner for .dbScripts\dbUpdates\ batches - the automated counterpart
    to Seeder.ps1, driven by RedeployLogViewer (the "DB Scripts..." panel) rather than run by hand.

.DESCRIPTION
    Reuses the same .dbtargets.ps1 target list and connection approach Seeder.template.ps1 already
    uses, but with no interactive prompts - every input comes from parameters, and progress is
    printed as plain lines for a caller to poll, matching how redeploy-tweaks.ps1 itself is driven.

    This is a template: RedeployLogViewer copies it (without ".template" in the name) into a
    project's own .dbScripts\ the first time the DB Scripts panel is used there. Like Seeder.ps1's
    own copies, the per-project copy is a disposable, gitignored local file - only this template is
    tracked in this repo.

    Only ever runs when -AutomationToken matches the fixed value RedeployLogViewer itself supplies -
    there's no interactive mode here at all (unlike redeploy-tweaks.ps1's own default flow), so a
    manual invocation without the token does nothing rather than risk running against a database
    unattended.

.PARAMETER Target
    Which database to use, matched by name against .dbtargets.ps1 (the same file Seeder.ps1 itself
    reads, found by walking up from this script's own folder).

.PARAMETER GetObjectDefinition
    Mode switch. Looks up -ObjectName's current definition on -Target (via OBJECT_DEFINITION) and
    writes it to -OutputFile, read-only - no transaction, nothing is changed. A trailing lowercase
    "go" line is appended to match the convention every local dbUpdates object file already ends
    with (see the shared conventions doc), so a diff against the local file doesn't show a spurious
    one-line difference at the bottom that isn't a real change. If the object doesn't exist yet on
    this database, writes a plain placeholder comment instead of failing.

.PARAMETER ObjectName
    The SP/view/function name to look up. Required with -GetObjectDefinition.

.PARAMETER OutputFile
    Where -GetObjectDefinition writes the looked-up definition text.

.PARAMETER RunFiles
    Mode switch. Runs every file listed in -Files, in order, inside ONE transaction spanning the
    whole run (matching Seeder.template.ps1's own "a later script can depend on an earlier one in
    the same run" model) - commits once at the end if every file succeeded, rolls back immediately
    and stops on the first failure. A file whose content carries a "-- STATE QUERY:" / "-- END
    STATE QUERY" block (see the shared conventions doc) has that query run once before the file's
    real statement and once after, each result written to its own temp file, reported via a
    STATEDIFF line - a before/after snapshot for the caller to diff, since the "after" state only
    exists once the real statement has actually run.

.PARAMETER Files
    Path to a plain text file, one absolute .sql path per line, in the order to run. Required with
    -RunFiles.

.PARAMETER TrialRun
    Only meaningful with -RunFiles. Every file still runs for real, in the same single transaction,
    with the same per-file RAN/FAILED/STATEDIFF reporting (so a STATEDIFF snapshot from a trial run
    is the real thing, not a guess) - but the whole transaction is rolled back at the end instead of
    committed, exactly mirroring Seeder.template.ps1's own Trial Run semantics. Prints "Trial run
    complete." instead of "Done." on a clean finish, so a caller can tell a trial apart from a real
    commit and avoid treating it as one.

.PARAMETER BackupEnv
    Only meaningful with -RunFiles. "Test" or "Live" - before applying any file that's an object
    definition (a CREATE [OR ALTER] or DROP PROCEDURE/VIEW/FUNCTION/TRIGGER), looks up that object's
    CURRENT definition on -Target and writes it to <the file's own folder>\<test or live,
    lowercase>\<ObjectName>.sql - a durable backup living next to the .sql files themselves, not a
    scratch temp file. Reports each one via a "BACKED UP" line.

    For a data/structure file (no single object of its own), the SAME durable location instead gets
    the affected rows' original values, as <...>\<test or live>\<script file's own base name>.before.txt
    - either from an explicit "-- STATE QUERY:" block's own Before query, or, when the file has none,
    auto-derived from a plain single-statement UPDATE/DELETE's own table + WHERE clause (see
    Get-AutoDataBeforeQuery) - a read-only companion SELECT, never a change to the real statement
    actually run. A file this can't confidently parse (anything beyond one plain UPDATE/DELETE) is
    simply not backed up this way, rather than guessed at.

    Still written during a -TrialRun (the backup is a snapshot of state BEFORE the file's own
    statement runs - trial or not, that moment is identical, since a trial still executes for real
    and only rolls back at the very end) - this keeps an as-yet-unrun file's backup self-refreshing
    on every trial run, not just on a Compare click, right up until a real run against that same
    environment actually commits for that file. The caller is expected to stop calling with
    -BackupEnv for a file once that happens (see RedeployLogViewer's own hasDbScriptRunOn check),
    but this script doesn't strictly rely on that: it refuses on its own to overwrite an EXISTING
    backup with a worthless result - "the object doesn't exist" / "no rows matched" - since that
    combination (nothing found now, but a real backup already sitting there) is the signature of a
    re-run after the real drop/delete already happened (e.g. via Run Now, which has no "already
    ran this" gate of its own), and overwriting in that specific case would only ever destroy the
    one copy that mattered. Reported via a "SKIPPED BACKUP" line rather than silently doing nothing.
    A genuinely fresh result (a real definition, real rows) still always overwrites, same as before.

.PARAMETER SuppliedPasswordFile
    Path to a temp file holding a one-off password for -Target, read once and deleted immediately
    after - never put on the command line itself. Falls back to -Target's own optional Password
    field in .dbtargets.ps1 if this isn't given.

.PARAMETER AutomationToken
    Must match this script's own fixed token (shared with RedeployLogViewer.hta) or nothing runs.

.EXAMPLE
    .\redeploy-db-runner.ps1 -GetObjectDefinition -Target AssentDCC_TestCleanse -ObjectName UPDATE_PlanCheck_Submit -OutputFile C:\temp\live.sql -AutomationToken "RLV-AUTO-9f2c7d41a6b3"

.PARAMETER PreviewTableChange
    Mode switch. Read-only, like -GetObjectDefinition, but for a table rather than an object - there
    is no OBJECT_DEFINITION-equivalent stored source text for a table, so this previews what an
    ALTER TABLE/CREATE TABLE file in -SqlFile would actually do by: querying the real table's CURRENT
    column structure (-OutputBeforeFile); for ALTER, cloning the table's structure under a
    timestamped throwaway name, applying the SAME statement to that clone (never the real table),
    querying the clone's resulting columns, then dropping the clone; for CREATE, running the
    statement directly under the throwaway name instead of the real one. Either way -OutputAfterFile
    gets the real result reported by SQL Server, never guessed at by re-parsing ALTER TABLE semantics
    ourselves. A plain DROP TABLE file writes an empty -OutputAfterFile instead (nothing survives to
    preview an "after" state for) - see Get-AlteredTableName's own IsDrop case. Column-level only
    (via INFORMATION_SCHEMA.COLUMNS) - constraints, indexes and keys aren't reflected either side.

.PARAMETER SqlFile
    The dbUpdates .sql file to preview. Required with -PreviewTableChange.

.PARAMETER OutputBeforeFile
    Where -PreviewTableChange writes the table's current column structure. Required with
    -PreviewTableChange.

.PARAMETER OutputAfterFile
    Where -PreviewTableChange writes the column structure after the file's statement would apply
    (empty for a DROP TABLE file). Required with -PreviewTableChange.

.EXAMPLE
    .\redeploy-db-runner.ps1 -RunFiles -Target AssentDCC_TestCleanse -Files C:\temp\files.txt -BackupEnv Test -AutomationToken "RLV-AUTO-9f2c7d41a6b3"

.EXAMPLE
    .\redeploy-db-runner.ps1 -PreviewTableChange -Target AssentDCC_TestCleanse -SqlFile C:\repo\.dbScripts\dbUpdates\x\01_(alter)_tblFoo.sql -OutputBeforeFile C:\temp\before.txt -OutputAfterFile C:\temp\after.txt -AutomationToken "RLV-AUTO-9f2c7d41a6b3"

.PARAMETER PreviewDataChange
    Mode switch. Read-only in effect, like -PreviewTableChange, but for a plain data file (an
    insertrow/updaterow/etc. .sql carrying its own "-- STATE QUERY:" / "-- END STATE QUERY" block -
    see the shared conventions doc) rather than a table structure. Runs the file's Before query
    (-OutputBeforeFile), then the file's real statement, then its After query (-OutputAfterFile) -
    all inside ONE transaction that is ALWAYS rolled back at the end, success or failure, so nothing
    is ever actually committed. This genuinely executes the real statement for the duration of the
    preview (unlike -GetObjectDefinition/-PreviewTableChange, which never touch the real table/
    object at all) - any effect that lives outside the transaction (a trigger messaging something
    external, for instance) would still happen even though the data change itself is undone. Throws
    if the file has no "-- STATE QUERY:" block at all - there is nothing to preview without one.

.PARAMETER SqlFile
    (Also used by -PreviewDataChange.) The dbUpdates .sql file to preview.

.PARAMETER OutputBeforeFile
    (Also used by -PreviewDataChange.) Where the Before query's result is written.

.PARAMETER OutputAfterFile
    (Also used by -PreviewDataChange.) Where the After query's result is written, captured right
    after the real statement runs but before the transaction is rolled back.

.EXAMPLE
    .\redeploy-db-runner.ps1 -PreviewDataChange -Target AssentDCC_TestCleanse -SqlFile C:\repo\.dbScripts\dbUpdates\x\02_(insertrow)_tblFoo.sql -OutputBeforeFile C:\temp\before.txt -OutputAfterFile C:\temp\after.txt -AutomationToken "RLV-AUTO-9f2c7d41a6b3"
#>

param(
    [string]$Target,
    [switch]$GetObjectDefinition,
    [string]$ObjectName,
    [string]$OutputFile,
    [switch]$RunFiles,
    [string]$Files,
    [switch]$TrialRun,
    [string]$BackupEnv,
    [switch]$PreviewTableChange,
    [switch]$PreviewDataChange,
    [string]$SqlFile,
    [string]$OutputBeforeFile,
    [string]$OutputAfterFile,
    [string]$SuppliedPasswordFile,
    [string]$AutomationToken,
    [string]$RepoRoot
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Data

# Every backup/snapshot this script writes uses this - plain ASCII was lossy for anything outside
# the basic Latin alphabet (confirmed: a currency symbol in a real live definition came back as a
# literal "?"), which for a DROP file's object backup means the ONLY remaining copy would already
# be corrupted the moment it's written. No BOM, so a plain byte-for-byte diff against a local
# dbUpdates file (itself written without one) doesn't show a spurious leading difference.
$script:backupTextEncoding = New-Object System.Text.UTF8Encoding($false)

# -RunFiles reporting only ever needs to name a file relative to the repo - the backup folder a
# given .sql file writes to is always right next to it, so a full absolute path on every line was
# just noise. Falls back to the full path unchanged if -RepoRoot wasn't supplied (an older caller,
# or a direct hand invocation) rather than guessing at a root that might be wrong.
function Get-RelativeDisplayPath {
    param([string]$FullPath)
    if (-not $RepoRoot) { return $FullPath }
    $root = $RepoRoot.TrimEnd('\', '/')
    if ($FullPath.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {
        $rel = $FullPath.Substring($root.Length).TrimStart('\', '/')
        return ($rel -replace '\\', '/')
    }
    return $FullPath
}

# Compares what's already on disk - the backup DIFF showed, and whatever was reviewed/Reviewed-
# ticked/Run-Now-clicked against - with a freshly re-derived value, right before -RunFiles would
# otherwise use it to decide whether this file's backup still needs writing. Returns a human-
# readable reason if they don't match (or there's nothing on disk to check against at all), or
# $null when they agree and it's safe to proceed. Deliberately never writes anything itself, and
# deliberately not wrapped in a try/catch anywhere it's called - a mismatch here is meant to abort
# the run (propagate to the per-file catch below), not be swallowed into a lenient WARN/note the
# way a transient DB/IO failure is elsewhere in this script.
function Test-BackupDrift {
    param([string]$ExistingPath, [string]$FreshText)
    if (-not (Test-Path $ExistingPath)) { return "no existing backup found at $(Get-RelativeDisplayPath $ExistingPath) to verify against - run DIFF first" }
    $existing = [System.IO.File]::ReadAllText($ExistingPath, $script:backupTextEncoding)
    if ($existing -ne $FreshText) { return "live state has changed since it was last reviewed with DIFF - re-run DIFF to review the current version before trying again" }
    return $null
}

# Same fixed token as redeploy-tweaks-template.ps1 - not a real access boundary (anyone who could
# run this script at all could just as easily supply the token), purely to stop a stray/mistyped
# manual invocation from running unattended against a real database.
$script:autoModeToken = 'RLV-AUTO-9f2c7d41a6b3'
$script:isAutoMode = [bool]$AutomationToken -and ($AutomationToken -eq $script:autoModeToken)

if (-not $script:isAutoMode) {
    Write-Host "This script is driven by RedeployLogViewer's DB Scripts panel, not run by hand - use Seeder.ps1 for an interactive run." -ForegroundColor Yellow
    exit
}

# Walks up from this script's own folder looking for .dbtargets.ps1 - same approach
# Seeder.template.ps1 already uses, so the same file works unmodified regardless of exactly where
# under .dbScripts\ this script ends up copied.
function Find-DbTargetsFile {
    $dir = $PSScriptRoot
    while ($dir) {
        $candidate = Join-Path $dir '.dbtargets.ps1'
        if (Test-Path $candidate) { return $candidate }
        $parent = Split-Path $dir -Parent
        if (-not $parent -or $parent -eq $dir) { break }
        $dir = $parent
    }
    return $null
}

function Get-DbTarget {
    param([string]$Name)
    $targetsFile = Find-DbTargetsFile
    if (-not $targetsFile) { throw "Could not find .dbtargets.ps1 above $PSScriptRoot." }
    . $targetsFile
    if (-not $dbTargets) { throw ".dbtargets.ps1 did not define `$dbTargets." }
    $chosen = $dbTargets | Where-Object { $_.Name -eq $Name } | Select-Object -First 1
    if (-not $chosen) { $chosen = $dbTargets | Where-Object { $_.Name -like "*$Name*" } | Select-Object -First 1 }
    if (-not $chosen) { throw "Unknown target '$Name'. Available: $(($dbTargets | ForEach-Object { $_.Name }) -join ', ')" }
    return $chosen
}

# -SuppliedPasswordFile (read once, deleted immediately regardless of outcome) takes priority over
# .dbtargets.ps1's own optional Password field - mirrors Get-FtpPassword's exact contract in
# redeploy-tweaks-template.ps1, including the "no fallback if it turns out to be wrong" reasoning
# (a silent fallback would mask a mistyped password as a mysterious failure further down).
function Get-DbPassword {
    param($Target, [string]$SuppliedPasswordFile)
    if ($SuppliedPasswordFile) {
        if (-not (Test-Path $SuppliedPasswordFile)) { throw "SuppliedPasswordFile '$SuppliedPasswordFile' not found." }
        $supplied = (Get-Content -Path $SuppliedPasswordFile -Raw -ErrorAction Stop).Trim()
        Remove-Item -Path $SuppliedPasswordFile -Force -ErrorAction SilentlyContinue
        if (-not $supplied) { throw "SuppliedPasswordFile '$SuppliedPasswordFile' was empty." }
        return $supplied
    }
    if ($Target.Contains('Password') -and $Target.Password) { return [string]$Target.Password }
    throw "No stored password for '$($Target.Name)' in .dbtargets.ps1 (automated run - can't prompt for one)."
}

# Same connection-building approach as Seeder.template.ps1 (SqlConnectionStringBuilder + plain
# System.Data.SqlClient.SqlConnection, Encrypt on) - no new DB connectivity technique, same proven
# approach reused without the interactive prompts.
function Connect-Db {
    param($Target, [string]$Password)
    $csb = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
    $csb['Data Source'] = [string]$Target.Server
    $csb['Initial Catalog'] = [string]$Target.Name
    $csb['Encrypt'] = $true
    $csb['Connect Timeout'] = 30
    $csb['Application Name'] = 'RedeployDbRunner'
    if ($Target.Contains('Username') -and $Target.Username) {
        $csb['User ID'] = [string]$Target.Username
        $csb['Password'] = [string]$Password
    } else {
        $csb['Integrated Security'] = $true
    }
    $conn = New-Object System.Data.SqlClient.SqlConnection($csb.ConnectionString)
    $conn.Open()
    return $conn
}

# Strips a trailing lone "go" line - cosmetic in dbUpdates files (matches what DataGrip's own diff
# view shows for a live object), not real T-SQL. Copied from Seeder.template.ps1's own identical
# helper - see the shared conventions doc's item 8 for the full reasoning.
function Remove-TrailingGo([string]$sql) {
    $lines = $sql -split "`r?`n"
    $lines = $lines | Where-Object { $_.Trim() -notmatch '^(?i)go$' }
    return ($lines -join "`r`n")
}

# Extracts "<schema>.<name>" from a CREATE [OR ALTER] or DROP PROCEDURE/VIEW/FUNCTION/TRIGGER
# statement - used only to find what to back up before overwriting/destroying it (see -BackupEnv).
# A DROP file is checked too, and matters most of the three - once it's run, OBJECT_DEFINITION has
# nothing left to look up, so this backup becomes the only remaining copy. Returns $null for a
# data/structure file (or a DROP TABLE - OBJECT_DEFINITION has no definition text for a table, so
# it can't be backed up this way at all; that needs a structure snapshot via a STATE QUERY block
# instead), which has no single object of its own to back up here.
#
# The DROP half is deliberately NOT anchored to the start of a line the way CREATE is, and allows
# an optional "IF EXISTS" - a real review of this project's own drop files turned up three shapes
# the original line-anchored, no-IF-EXISTS version silently missed: "DROP ... IF EXISTS", an inline
# "IF OBJECT_ID(...) IS NOT NULL DROP ..." guard-and-drop on one line, and (structurally impossible
# to fix here) DROP TABLE, which still correctly returns $null for the reason above.
#
# Schema/name are each captured as EITHER a bracketed run of anything-but-"]" OR a bare \w+ - not
# "\[?(\w+)\]?" (brackets always optional, content always \w-only), which silently truncated at the
# first non-word character and left the closing "]" unconsumed. Found via a real project file with
# two procedures whose actual names contain spaces (e.g. "[REPORT_EmailLogSentReceived_BACKUP 09 08
# 2015]") - the old pattern captured only "REPORT_EmailLogSentReceived_BACKUP", so OBJECT_DEFINITION
# looked up a name that doesn't exist and wrote the "does not exist" placeholder under the wrong,
# truncated filename, losing the real backup entirely. A bracketed identifier can legally contain
# almost anything except an unescaped "]" (that one edge case - a literal "]]" inside a name - isn't
# handled either, accepted as a rare enough limitation not worth the extra complexity here). FullName
# is built bracket-quoted ("[schema].[name]"), the documented way to pass OBJECT_ID a name containing
# special characters, rather than relying on it tolerating a bare unbracketed string with embedded
# spaces - confirmed against the real two procedures above (OBJECT_ID resolved correctly, not NULL).
function Get-ObjectNameFromSql([string]$sql) {
    $m = [regex]::Match($sql, '(?im)^\s*CREATE\s+(?:OR\s+ALTER\s+)?(?:PROCEDURE|PROC|VIEW|FUNCTION|TRIGGER)\s+(?:\[(?<schema>[^\]]+)\]|(?<schema>\w+))\.(?:\[(?<name>[^\]]+)\]|(?<name>\w+))')
    if (-not $m.Success) {
        $m = [regex]::Match($sql, '(?im)DROP\s+(?:PROCEDURE|PROC|VIEW|FUNCTION|TRIGGER)\s+(?:IF\s+EXISTS\s+)?(?:\[(?<schema>[^\]]+)\]|(?<schema>\w+))\.(?:\[(?<name>[^\]]+)\]|(?<name>\w+))')
    }
    if (-not $m.Success) { return $null }
    $schema = $m.Groups['schema'].Value
    $name = $m.Groups['name'].Value
    return [pscustomobject]@{ Schema = $schema; Name = $name; FullName = "[$schema].[$name]" }
}

# True when $sql's content looks like it drops something - any shape, not just the ones
# Get-ObjectNameFromSql can confidently extract a name from - used only to decide whether to print
# a WARN line when nothing ended up backed up for a file. Deliberately DROP-only, not ALTER TABLE
# too: an ordinary ADD COLUMN alter is common and mostly non-destructive, and would just make this
# warning noisy without the extra nuance (e.g. detecting a destructive DROP COLUMN specifically)
# nobody's asked for yet - so a plain ALTER TABLE file stays silent, matching today's behaviour.
function LooksLikeDrop([string]$sql) {
    return $sql -match '(?im)\bDROP\s+(?:PROCEDURE|PROC|VIEW|FUNCTION|TRIGGER|TABLE)\b'
}

# Extracts "<schema>.<table>" from a plain ALTER TABLE, CREATE TABLE, or DROP TABLE statement - used
# to preview a before/after column structure comparison (see -PreviewTableChange and -BackupEnv's
# own table-structure safety net in -RunFiles) without ever touching the real table for ALTER/CREATE.
# "Literal" is the EXACT matched "[schema].[table]" (or bare) text, as it actually appears in the
# file - used later to safely find-and-replace every occurrence of it with a throwaway preview table
# name via a plain string .Replace(), not a second regex guess at the same thing. $null for IsDrop
# (nothing to rewrite - a drop has no "after" to preview) and for anything this can't confidently
# parse (a multi-table statement, multiple statements in one file, etc.) - skipped rather than
# guessed at, same philosophy as Get-AutoDataBeforeQuery's own guards.
function Get-AlteredTableName([string]$sql) {
    $m = [regex]::Match($sql, '(?im)^\s*ALTER\s+TABLE\s+(?:\[(?<schema>[^\]]+)\]|(?<schema>\w+))\.(?:\[(?<table>[^\]]+)\]|(?<table>\w+))')
    $isCreate = $false
    $isDrop = $false
    if (-not $m.Success) {
        $m = [regex]::Match($sql, '(?im)^\s*CREATE\s+TABLE\s+(?:\[(?<schema>[^\]]+)\]|(?<schema>\w+))\.(?:\[(?<table>[^\]]+)\]|(?<table>\w+))')
        $isCreate = $m.Success
    }
    if (-not $m.Success) {
        $m = [regex]::Match($sql, '(?im)DROP\s+TABLE\s+(?:IF\s+EXISTS\s+)?(?:\[(?<schema>[^\]]+)\]|(?<schema>\w+))\.(?:\[(?<table>[^\]]+)\]|(?<table>\w+))')
        $isDrop = $m.Success
    }
    if (-not $m.Success) { return $null }
    $schema = $m.Groups['schema'].Value
    $table = $m.Groups['table'].Value
    $literal = $null
    if (-not $isDrop) {
        $literal = $m.Value -replace '(?im)^\s*(?:ALTER|CREATE)\s+TABLE\s+', ''
    }
    return [pscustomobject]@{ Schema = $schema; Table = $table; Literal = $literal; IsCreate = $isCreate; IsDrop = $isDrop }
}

# Column-level structure snapshot for one table, parameterized (not string-built) even though the
# schema/table names come from our own regex extraction, not external input - good hygiene costs
# nothing here. Deliberately a separate function from Get-QueryResultText (which takes a raw,
# user-authored SQL string for STATE QUERY) rather than reusing it - this one's query is fixed and
# its inputs are untrusted-by-default parameters, not text to run verbatim.
function Get-TableColumnsText {
    param($Conn, [string]$Schema, [string]$Table)
    $cmd = $Conn.CreateCommand()
    $cmd.CommandText = "SELECT COLUMN_NAME, DATA_TYPE, CHARACTER_MAXIMUM_LENGTH, IS_NULLABLE, COLUMN_DEFAULT FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA = @schema AND TABLE_NAME = @table ORDER BY ORDINAL_POSITION"
    [void]$cmd.Parameters.AddWithValue("@schema", $Schema)
    [void]$cmd.Parameters.AddWithValue("@table", $Table)
    $reader = $cmd.ExecuteReader()
    try {
        $lines = New-Object 'System.Collections.Generic.List[string]'
        $n = $reader.FieldCount
        $cols = New-Object 'System.Collections.Generic.List[string]'
        for ($i = 0; $i -lt $n; $i++) { $cols.Add($reader.GetName($i)) }
        $lines.Add(($cols -join ' | '))
        $rowCount = 0
        while ($reader.Read()) {
            $vals = New-Object object[] $n
            [void]$reader.GetValues($vals)
            $cells = @($vals | ForEach-Object { if ($null -eq $_ -or $_ -is [System.DBNull]) { '' } else { [string]$_ } })
            $lines.Add(($cells -join ' | '))
            $rowCount++
        }
        if ($rowCount -eq 0) { $lines.Add('(no rows)') }
        return ($lines -join "`r`n")
    } finally {
        $reader.Close()
    }
}

# Computes the "after" half of a table-alter/create preview: clones the real table's structure
# under a throwaway name (skipped for a CREATE - there's nothing real to clone from yet), applies
# the already-rewritten statement to that clone ONLY, snapshots its resulting columns, then always
# drops the clone (even on failure) so nothing is ever left behind on a successful path. A clone via
# "SELECT * INTO ... WHERE 1=0" carries over columns but not constraints/indexes/keys - acceptable,
# matching the same column-level scope as the rest of this preview; a constraint-only change won't
# show up here, which is flagged to the caller via the UI rather than silently assumed away.
function Get-TableAfterPreviewText {
    param($Conn, [string]$Schema, [string]$Table, [string]$PreviewSql, [string]$PreviewTable, [bool]$IsCreate)
    if (-not $IsCreate) {
        $cloneCmd = $Conn.CreateCommand()
        $cloneCmd.CommandText = "SELECT * INTO [$Schema].[$PreviewTable] FROM [$Schema].[$Table] WHERE 1=0"
        $cloneCmd.CommandTimeout = 60
        [void]$cloneCmd.ExecuteNonQuery()
    }
    try {
        $alterCmd = $Conn.CreateCommand()
        $alterCmd.CommandText = $PreviewSql
        $alterCmd.CommandTimeout = 60
        [void]$alterCmd.ExecuteNonQuery()
        return Get-TableColumnsText -Conn $Conn -Schema $Schema -Table $PreviewTable
    } finally {
        try {
            $dropCmd = $Conn.CreateCommand()
            $dropCmd.CommandText = "IF OBJECT_ID('$Schema.$PreviewTable') IS NOT NULL DROP TABLE [$Schema].[$PreviewTable]"
            [void]$dropCmd.ExecuteNonQuery()
        } catch {
            Write-Host ("WARN: could not clean up preview table {0}.{1} - it may need manual removal" -f $Schema, $PreviewTable)
        }
    }
}

# Persists a table's before/after column structure durably, next to the .sql file itself - same
# test/live-subfolder convention as every other backup in this script. Unlike the object-definition
# and data-row guards (which separately judge whether THIS write looks like worthless placeholder
# content), a table structure pair is captured and frozen as one atomic unit: if a before/after pair
# already exists for this table, the whole pair is left alone rather than judging each half on its
# own - simpler, and matches exactly what was asked for ("the backup can stop updating after the
# real run has gone through").
function Backup-TableStructureBeforeAfter {
    param([string]$FilePath, [string]$BackupEnv, [string]$BeforeText, [string]$AfterText, [string]$TableName)
    try {
        $backupFolder = Join-Path (Split-Path $FilePath -Parent) $BackupEnv.ToLower()
        if (-not (Test-Path $backupFolder)) { New-Item -ItemType Directory -Path $backupFolder -Force | Out-Null }
    } catch {
        return ("failed: {0}" -f $_.Exception.Message)
    }
    $beforePath = Join-Path $backupFolder "$TableName.before.txt"
    $afterPath = Join-Path $backupFolder "$TableName.after.txt"
    if (Test-Path $beforePath) {
        # Deliberately outside any try/catch here - a real structure drift must abort the run (see
        # Test-BackupDrift's own comment), not be swallowed into a lenient "backup failed" note.
        $drift = Test-BackupDrift -ExistingPath $beforePath -FreshText $BeforeText
        if ($drift) { throw "$TableName`: $drift" }
        return (Get-RelativeDisplayPath $beforePath)
    }
    try {
        [System.IO.File]::WriteAllText($beforePath, $BeforeText, $script:backupTextEncoding)
        [System.IO.File]::WriteAllText($afterPath, $AfterText, $script:backupTextEncoding)
        return (Get-RelativeDisplayPath $beforePath)
    } catch {
        return ("failed: {0}" -f $_.Exception.Message)
    }
}

# Extracts a "-- STATE QUERY:" / "-- END STATE QUERY" block (see the shared conventions doc's item
# 10) - returns $null if the file has none. A second block supplies a distinct After query for the
# rarer case where before/after need different shapes; otherwise the Before query is reused as-is
# for After. Remainder is the file's SQL with the marker block(s) cut out, ready to run normally.
function Parse-StateQuery([string]$sql) {
    $pattern = '(?is)--\s*STATE QUERY:\s*(.*?)--\s*END STATE QUERY'
    $found = [regex]::Matches($sql, $pattern)
    if ($found.Count -eq 0) { return $null }
    $before = $found[0].Groups[1].Value.Trim()
    $after = $before
    if ($found.Count -ge 2) { $after = $found[1].Groups[1].Value.Trim() }
    $remainder = [regex]::Replace($sql, $pattern, '')
    return [pscustomobject]@{ Before = $before; After = $after; Remainder = $remainder }
}

# Extracts a single-table UPDATE/DELETE's own table + WHERE clause, to auto-capture the affected
# rows' original values for a data file with no explicit "-- STATE QUERY:" block of its own - a
# read-only companion SELECT run right before the real statement, never a change to what actually
# executes. Only matches a plain single-statement UPDATE ... SET ... [WHERE ...] or DELETE FROM ...
# [WHERE ...] spanning the WHOLE given text (the trailing $ anchor, with no "m" flag, means a
# second statement tacked on after it fails the whole match) - anything more complex (multiple
# statements, a DELETE's own join-alias form) isn't guessed at, it just returns $null so the caller
# skips the auto-capture for that file rather than risk capturing the wrong rows. An UPDATE using
# the "UPDATE t SET ... FROM t JOIN ..." join form matches the same shape on the surface, but its
# real affected-row-set depends on the join, not just the trailing WHERE - explicitly rejected via
# the FROM check below rather than silently reproducing only part of the real predicate.
function Get-AutoDataBeforeQuery([string]$sql) {
    $trimmed = $sql.Trim()
    # [^;]+? (not .+?) for the body/where captures - a lazy .+? with singleline matching can cross
    # a ";" entirely to reach end-of-string, silently absorbing a SECOND statement into what looks
    # like one enormous WHERE clause instead of failing the match - found via a live test. Excluding
    # ";" from the class makes that impossible: the group simply can't extend past the first one.
    $m = [regex]::Match($trimmed, '(?is)^\s*UPDATE\s+(?<table>\[?\w+\]?(?:\.\[?\w+\]?)?)\s+SET\s+(?<body>[^;]+?)(?:\s+WHERE\s+(?<where>[^;]+?))?\s*;?\s*$')
    if ($m.Success) {
        if ($m.Groups['body'].Value -match '(?i)\bFROM\b') { return $null }
        $table = $m.Groups['table'].Value
        $where = $m.Groups['where'].Value
        if ($where) { return "SELECT * FROM $table WHERE $where" }
        return "SELECT * FROM $table"
    }
    $m = [regex]::Match($trimmed, '(?is)^\s*DELETE\s+FROM\s+(?<table>\[?\w+\]?(?:\.\[?\w+\]?)?)\s*(?:WHERE\s+(?<where>[^;]+?))?\s*;?\s*$')
    if (-not $m.Success) { return $null }
    $table = $m.Groups['table'].Value
    $where = $m.Groups['where'].Value
    if ($where) { return "SELECT * FROM $table WHERE $where" }
    return "SELECT * FROM $table"
}

# Persists a captured "before" row snapshot durably, next to the .sql file itself (a test/live
# subfolder of its own dbUpdates batch folder, matching exactly how Get-ObjectNameFromSql's own
# object-definition backups are stored) - named after the script file itself, since a data file
# has no single object name of its own the way a CREATE/DROP file does. Best-effort: a failure here
# is reported but never fails the run - the real statement has already succeeded by the time this
# runs for the explicit-STATE-QUERY case, and the whole point of the auto-derived case is to be a
# helpful extra, not a new way for a file to fail.
function Backup-DataRowsBeforeChange {
    # -CheckDrift is opt-in: the plain auto-capture and explicit-STATE-QUERY uses of this function
    # were never gated behind a pre-run DIFF/Reviewed step (no Compare button ever shows for those
    # files), so there's nothing to have drifted away from - stays fully best-effort/lenient for
    # them. Only the table-DROP caller (whose "before" snapshot IS what DIFF showed and Reviewed
    # was ticked against, same as the object/table-structure cases) passes this switch.
    param([string]$FilePath, [string]$BackupEnv, [string]$BeforeText, [switch]$CheckDrift)
    try {
        $backupFolder = Join-Path (Split-Path $FilePath -Parent) $BackupEnv.ToLower()
        if (-not (Test-Path $backupFolder)) { New-Item -ItemType Directory -Path $backupFolder -Force | Out-Null }
    } catch {
        return ("failed: {0}" -f $_.Exception.Message)
    }
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($FilePath)
    $backupPath = Join-Path $backupFolder "$baseName.before.txt"
    # Same reasoning as the object-backup path's own guard: a re-run after the real rows are
    # already gone would otherwise capture "(no rows)" and overwrite a genuine prior snapshot
    # that had real data in it. Get-QueryResultText always emits this exact literal line when
    # nothing matched, and nothing else legitimately would.
    $isEmpty = $BeforeText -match '(?m)^\(no rows\)\s*$'
    if ($isEmpty -and (Test-Path $backupPath)) {
        return (Get-RelativeDisplayPath $backupPath)
    }
    if ($CheckDrift -and (Test-Path $backupPath)) {
        # Deliberately outside any try/catch here - see Test-BackupDrift's own comment.
        $drift = Test-BackupDrift -ExistingPath $backupPath -FreshText $BeforeText
        if ($drift) { throw "$baseName`: $drift" }
    }
    try {
        [System.IO.File]::WriteAllText($backupPath, $BeforeText, $script:backupTextEncoding)
        return (Get-RelativeDisplayPath $backupPath)
    } catch {
        return ("failed: {0}" -f $_.Exception.Message)
    }
}

# Companion to Backup-DataRowsBeforeChange, written right after the real statement runs (see
# -RunFiles's own STATE QUERY handling) so a file that gets Run before it was ever previewed via
# -PreviewDataChange still ends up with a complete before/after pair in the same durable location -
# matching the table-structure backup's own "always written as one atomic pair" guarantee (see
# Backup-TableStructureBeforeAfter). No "don't overwrite with an empty result" guard here, unlike
# the Before half - an After snapshot can always be safely re-queried later, there's no irreplaceable
# state to protect. Best-effort, same as every other backup helper in this file.
function Backup-DataRowsAfterChange {
    param([string]$FilePath, [string]$BackupEnv, [string]$AfterText)
    try {
        $backupFolder = Join-Path (Split-Path $FilePath -Parent) $BackupEnv.ToLower()
        if (-not (Test-Path $backupFolder)) { New-Item -ItemType Directory -Path $backupFolder -Force | Out-Null }
    } catch {
        return
    }
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($FilePath)
    $afterPath = Join-Path $backupFolder "$baseName.after.txt"
    try {
        [System.IO.File]::WriteAllText($afterPath, $AfterText, $script:backupTextEncoding)
    } catch {
        # best effort - a failed after-snapshot shouldn't fail a run that already succeeded
    }
}

# Runs a query and returns its result as plain pipe-delimited text (header row, then one row per
# line, "(no rows)" if empty) - simple and diffable by any plain text tool, not tied to any one
# SQL client's own grid format.
function Get-QueryResultText {
    param($Conn, $Tx, [string]$Sql)
    $cmd = $Conn.CreateCommand()
    $cmd.Transaction = $Tx
    $cmd.CommandText = $Sql
    $cmd.CommandTimeout = 120
    $reader = $cmd.ExecuteReader()
    try {
        $lines = New-Object 'System.Collections.Generic.List[string]'
        $n = $reader.FieldCount
        $cols = New-Object 'System.Collections.Generic.List[string]'
        for ($i = 0; $i -lt $n; $i++) { $cols.Add($reader.GetName($i)) }
        $lines.Add(($cols -join ' | '))
        $rowCount = 0
        while ($reader.Read()) {
            $vals = New-Object object[] $n
            [void]$reader.GetValues($vals)
            $cells = @($vals | ForEach-Object { if ($null -eq $_ -or $_ -is [System.DBNull]) { '' } else { [string]$_ } })
            $lines.Add(($cells -join ' | '))
            $rowCount++
        }
        if ($rowCount -eq 0) { $lines.Add('(no rows)') }
        return ($lines -join "`r`n")
    } finally {
        $reader.Close()
    }
}

try {
    if ($GetObjectDefinition) {
        if (-not $Target) { throw "-Target is required." }
        if (-not $ObjectName) { throw "-ObjectName is required." }
        if (-not $OutputFile) { throw "-OutputFile is required." }

        $chosen = Get-DbTarget -Name $Target
        $password = Get-DbPassword -Target $chosen -SuppliedPasswordFile $SuppliedPasswordFile
        $conn = Connect-Db -Target $chosen -Password $password
        try {
            $cmd = $conn.CreateCommand()
            $cmd.CommandText = "SELECT OBJECT_DEFINITION(OBJECT_ID(@name)) AS Def"
            [void]$cmd.Parameters.AddWithValue("@name", $ObjectName)
            $def = $cmd.ExecuteScalar()
            if ($null -eq $def -or $def -is [System.DBNull]) {
                $defText = "-- object does not exist yet on this database --"
            } else {
                # Trailing "go" added to match the convention every local dbUpdates object file
                # already ends with - without this, every compare would show a spurious one-line
                # difference at the bottom that isn't a real change.
                $defText = ([string]$def).Trim() + "`r`ngo`r`n"
            }
            [System.IO.File]::WriteAllText($OutputFile, $defText, $script:backupTextEncoding)
            Write-Host "Done."
        } finally {
            $conn.Close()
        }
        exit
    }

    if ($PreviewTableChange) {
        if (-not $Target) { throw "-Target is required." }
        if (-not $SqlFile) { throw "-SqlFile is required." }
        if (-not (Test-Path $SqlFile)) { throw "SqlFile '$SqlFile' not found." }
        if (-not $OutputBeforeFile) { throw "-OutputBeforeFile is required." }
        if (-not $OutputAfterFile) { throw "-OutputAfterFile is required." }

        $rawSql = Get-Content -LiteralPath $SqlFile -Raw -Encoding UTF8
        $stateQuery = Parse-StateQuery $rawSql
        if ($stateQuery) { $body = $stateQuery.Remainder } else { $body = $rawSql }
        $sqlToRun = Remove-TrailingGo $body

        $tableInfo = Get-AlteredTableName $sqlToRun
        if (-not $tableInfo) { throw "Could not find a plain ALTER TABLE/CREATE TABLE/DROP TABLE statement to preview in this file." }

        $chosen = Get-DbTarget -Name $Target
        $password = Get-DbPassword -Target $chosen -SuppliedPasswordFile $SuppliedPasswordFile
        $conn = Connect-Db -Target $chosen -Password $password
        try {
            $beforeText = Get-TableColumnsText -Conn $conn -Schema $tableInfo.Schema -Table $tableInfo.Table
            [System.IO.File]::WriteAllText($OutputBeforeFile, $beforeText, $script:backupTextEncoding)

            if ($tableInfo.IsDrop) {
                # Nothing survives to preview an "after" state for - mirrors the proc/view/function
                # drop case's own "current vs empty" treatment, just at the table-structure level.
                [System.IO.File]::WriteAllText($OutputAfterFile, "", $script:backupTextEncoding)
            } else {
                $stamp = Get-Date -Format "yyyyMMddHHmmss"
                $previewTable = "$($tableInfo.Table)__preview_$stamp"
                $previewLiteral = "[$($tableInfo.Schema)].[$previewTable]"
                $previewSql = $sqlToRun.Replace($tableInfo.Literal, $previewLiteral)
                $afterText = Get-TableAfterPreviewText -Conn $conn -Schema $tableInfo.Schema -Table $tableInfo.Table -PreviewSql $previewSql -PreviewTable $previewTable -IsCreate $tableInfo.IsCreate
                [System.IO.File]::WriteAllText($OutputAfterFile, $afterText, $script:backupTextEncoding)
            }
            Write-Host "Done."
        } finally {
            $conn.Close()
        }
        exit
    }

    if ($PreviewDataChange) {
        if (-not $Target) { throw "-Target is required." }
        if (-not $SqlFile) { throw "-SqlFile is required." }
        if (-not (Test-Path $SqlFile)) { throw "SqlFile '$SqlFile' not found." }
        if (-not $OutputBeforeFile) { throw "-OutputBeforeFile is required." }
        if (-not $OutputAfterFile) { throw "-OutputAfterFile is required." }

        $rawSql = Get-Content -LiteralPath $SqlFile -Raw -Encoding UTF8
        $stateQuery = Parse-StateQuery $rawSql
        if (-not $stateQuery) { throw "No -- STATE QUERY: block found in this file - there is nothing to preview." }
        $sqlToRun = Remove-TrailingGo $stateQuery.Remainder

        $chosen = Get-DbTarget -Name $Target
        $password = Get-DbPassword -Target $chosen -SuppliedPasswordFile $SuppliedPasswordFile
        $conn = Connect-Db -Target $chosen -Password $password
        $tx = $conn.BeginTransaction()
        try {
            $beforeText = Get-QueryResultText -Conn $conn -Tx $tx -Sql $stateQuery.Before
            [System.IO.File]::WriteAllText($OutputBeforeFile, $beforeText, $script:backupTextEncoding)

            $cmd = $conn.CreateCommand()
            $cmd.Transaction = $tx
            $cmd.CommandText = $sqlToRun
            $cmd.CommandTimeout = 300
            [void]$cmd.ExecuteNonQuery()

            $afterText = Get-QueryResultText -Conn $conn -Tx $tx -Sql $stateQuery.After
            [System.IO.File]::WriteAllText($OutputAfterFile, $afterText, $script:backupTextEncoding)

            Write-Host "Done."
        } finally {
            # Always rolled back, success or failure - this is a preview, nothing it does is ever
            # meant to be kept. See the .PARAMETER PreviewDataChange doc comment for the one caveat
            # (a non-transactional side effect, e.g. a trigger messaging something external, would
            # still happen even though the data change itself is undone).
            try { $tx.Rollback() } catch {}
            $conn.Close()
        }
        exit
    }

    if ($RunFiles) {
        $runStart = Get-Date
        Write-Host ("STARTED: {0}" -f $runStart.ToString("yyyy-MM-dd HH:mm:ss"))
        if (-not $Target) { throw "-Target is required." }
        if (-not $Files) { throw "-Files is required." }
        if (-not (Test-Path $Files)) { throw "Files manifest '$Files' not found." }
        $filePaths = @(Get-Content -Path $Files | Where-Object { $_.Trim() })
        if ($filePaths.Count -eq 0) { throw "No files listed in '$Files'." }

        $chosen = Get-DbTarget -Name $Target
        $password = Get-DbPassword -Target $chosen -SuppliedPasswordFile $SuppliedPasswordFile
        $conn = Connect-Db -Target $chosen -Password $password

        # One transaction for the whole run, matching Seeder.template.ps1's own model exactly - a
        # later file that depends on an earlier one in this same run (e.g. a proc referencing a
        # column an earlier file just added) sees it exactly as it will when these run for real.
        $tx = $conn.BeginTransaction()
        $txOpen = $true
        $ok = 0
        $fail = 0
        try {
            foreach ($filePath in $filePaths) {
                $relFilePath = Get-RelativeDisplayPath $filePath
                if (-not (Test-Path $filePath)) {
                    Write-Host ("FAILED {0} -> file not found" -f $relFilePath)
                    $fail++
                    $tx.Rollback()
                    $txOpen = $false
                    break
                }
                $rawSql = Get-Content -LiteralPath $filePath -Raw -Encoding UTF8
                $stateQuery = Parse-StateQuery $rawSql
                if ($stateQuery) { $sqlBeforeGoStrip = $stateQuery.Remainder } else { $sqlBeforeGoStrip = $rawSql }
                $sqlToRun = Remove-TrailingGo $sqlBeforeGoStrip
                # Collected instead of printed immediately, so every backup this file triggers (object
                # definition, auto data-rows, table structure, or an explicit STATE QUERY's own capture)
                # lands on the one identity line below instead of a separate BACKED UP line each.
                $backupNotes = @()

                try {
                    if ($BackupEnv) {
                        $objInfo = Get-ObjectNameFromSql $rawSql
                        if ($objInfo) {
                            $liveDef = $null
                            $fetchOk = $false
                            try {
                                $cmdDef = $conn.CreateCommand()
                                $cmdDef.Transaction = $tx
                                $cmdDef.CommandText = "SELECT OBJECT_DEFINITION(OBJECT_ID(@name)) AS Def"
                                [void]$cmdDef.Parameters.AddWithValue("@name", $objInfo.FullName)
                                $liveDef = $cmdDef.ExecuteScalar()
                                $fetchOk = $true
                            } catch {
                                $backupNotes += ("failed: {0}" -f $_.Exception.Message)
                            }
                            if ($fetchOk) {
                                $objectGone = ($null -eq $liveDef -or $liveDef -is [System.DBNull])
                                $backupFolder = Join-Path (Split-Path $filePath -Parent) $BackupEnv.ToLower()
                                if (-not (Test-Path $backupFolder)) { New-Item -ItemType Directory -Path $backupFolder -Force | Out-Null }
                                $backupPath = Join-Path $backupFolder "$($objInfo.Name).sql"
                                if ($objectGone -and (Test-Path $backupPath)) {
                                    # Most likely a re-run (e.g. Run Now again) after this object's drop
                                    # already committed for real - OBJECT_DEFINITION correctly finds
                                    # nothing left, but a real backup from the FIRST run is already sitting
                                    # here. Writing the placeholder over it would destroy the only
                                    # remaining copy for no reason - leave it alone instead.
                                    $backupNotes += (Get-RelativeDisplayPath $backupPath)
                                } else {
                                    if ($objectGone) {
                                        $backupText = "-- object does not exist yet on this database --"
                                    } else {
                                        $backupText = ([string]$liveDef).Trim() + "`r`ngo`r`n"
                                    }
                                    # Deliberately outside any try/catch here - abort the whole run
                                    # (propagate to the per-file catch below) rather than silently
                                    # overwriting the backup DIFF showed with a drifted live value and
                                    # running anyway. See Test-BackupDrift's own comment for why.
                                    $drift = Test-BackupDrift -ExistingPath $backupPath -FreshText $backupText
                                    if ($drift) { throw "$($objInfo.FullName): $drift" }
                                    [System.IO.File]::WriteAllText($backupPath, $backupText, $script:backupTextEncoding)
                                    $backupNotes += (Get-RelativeDisplayPath $backupPath)
                                }
                            }
                        } elseif (-not $stateQuery) {
                            # No explicit "-- STATE QUERY:" block and this isn't an object file - if it's
                            # a plain single-statement UPDATE/DELETE, auto-capture the affected rows'
                            # original values the same durable way, with no change to $sqlToRun itself.
                            $autoSelect = Get-AutoDataBeforeQuery $sqlToRun
                            if ($autoSelect) {
                                try {
                                    $autoBeforeText = Get-QueryResultText -Conn $conn -Tx $tx -Sql $autoSelect
                                    $backupNotes += (Backup-DataRowsBeforeChange -FilePath $filePath -BackupEnv $BackupEnv -BeforeText $autoBeforeText)
                                } catch {
                                    $backupNotes += ("failed (auto-capture): {0}" -f $_.Exception.Message)
                                }
                            } else {
                                # Safety net for a table alter/create/drop that was never previewed via
                                # -PreviewTableChange (e.g. Reviewed was ticked by hand, or Run Now was
                                # clicked without ever opening Compare) - captures the same before/after
                                # (or before-only, for a drop) this file would have gotten from Compare.
                                $tableInfo = Get-AlteredTableName $sqlToRun
                                if ($tableInfo -and -not $tableInfo.IsDrop) {
                                    $tBeforeText = $null
                                    $tAfterText = $null
                                    $computeOk = $false
                                    try {
                                        $tBeforeText = Get-TableColumnsText -Conn $conn -Schema $tableInfo.Schema -Table $tableInfo.Table
                                        $tStamp = Get-Date -Format "yyyyMMddHHmmss"
                                        $tPreviewTable = "$($tableInfo.Table)__preview_$tStamp"
                                        $tPreviewLiteral = "[$($tableInfo.Schema)].[$tPreviewTable]"
                                        $tPreviewSql = $sqlToRun.Replace($tableInfo.Literal, $tPreviewLiteral)
                                        $tAfterText = Get-TableAfterPreviewText -Conn $conn -Schema $tableInfo.Schema -Table $tableInfo.Table -PreviewSql $tPreviewSql -PreviewTable $tPreviewTable -IsCreate $tableInfo.IsCreate
                                        $computeOk = $true
                                    } catch {
                                        $backupNotes += ("failed (table structure): {0}" -f $_.Exception.Message)
                                    }
                                    if ($computeOk) {
                                        # Outside the try above on purpose - Backup-TableStructureBeforeAfter
                                        # itself throws (uncaught) on a real drift, which must abort the run.
                                        $backupNotes += (Backup-TableStructureBeforeAfter -FilePath $filePath -BackupEnv $BackupEnv -BeforeText $tBeforeText -AfterText $tAfterText -TableName $tableInfo.Table)
                                    }
                                } elseif ($tableInfo -and $tableInfo.IsDrop) {
                                    $tBeforeText2 = $null
                                    $computeOk2 = $false
                                    try {
                                        $tBeforeText2 = Get-TableColumnsText -Conn $conn -Schema $tableInfo.Schema -Table $tableInfo.Table
                                        $computeOk2 = $true
                                    } catch {
                                        $backupNotes += ("failed (table structure): {0}" -f $_.Exception.Message)
                                    }
                                    if ($computeOk2) {
                                        # -CheckDrift: this IS the before/after structure DIFF showed for a
                                        # table-drop file, unlike the plain auto-capture/STATE-QUERY uses of
                                        # the same function elsewhere, which stay lenient.
                                        $backupNotes += (Backup-DataRowsBeforeChange -FilePath $filePath -BackupEnv $BackupEnv -BeforeText $tBeforeText2 -CheckDrift)
                                    }
                                } elseif (LooksLikeDrop $rawSql) {
                                    # Nothing above backed this up - a DROP shape still too unusual to
                                    # parse. Surfaced here rather than silently skipped, found via a real
                                    # review of this project's own drop files turning up exactly this gap.
                                    $backupNotes += "n/a - looks like a DROP, review manually"
                                }
                            }
                        }
                    }

                    $beforeFile = $null
                    $afterFile = $null
                    if ($stateQuery) {
                        $beforeFile = [System.IO.Path]::GetTempFileName()
                        $beforeText = Get-QueryResultText -Conn $conn -Tx $tx -Sql $stateQuery.Before
                        [System.IO.File]::WriteAllText($beforeFile, $beforeText, $script:backupTextEncoding)
                        if ($BackupEnv) { $backupNotes += (Backup-DataRowsBeforeChange -FilePath $filePath -BackupEnv $BackupEnv -BeforeText $beforeText) }
                    }

                    # One BCK line per backup this file triggered - printed right before it actually
                    # runs. Only the backup's own path/reason, never a repeat of the file's own path
                    # (that's what the RAN/FAILED line right after it is for).
                    foreach ($note in ($backupNotes | Where-Object { $_ })) {
                        Write-Host ("BCK " + $note)
                    }

                    $cmd = $conn.CreateCommand()
                    $cmd.Transaction = $tx
                    $cmd.CommandText = $sqlToRun
                    $cmd.CommandTimeout = 300
                    $rowsAffected = $cmd.ExecuteNonQuery()

                    if ($stateQuery) {
                        $afterFile = [System.IO.Path]::GetTempFileName()
                        $afterText = Get-QueryResultText -Conn $conn -Tx $tx -Sql $stateQuery.After
                        [System.IO.File]::WriteAllText($afterFile, $afterText, $script:backupTextEncoding)
                        if ($BackupEnv) { Backup-DataRowsAfterChange -FilePath $filePath -BackupEnv $BackupEnv -AfterText $afterText }
                    }

                    # DDL (CREATE/ALTER/DROP) always reports -1 here - not a real "no rows" answer,
                    # just SQL Server's own convention for a statement with no row count to give, so
                    # the suffix is only shown for a genuine DML row count (an UPDATE/DELETE/INSERT).
                    $ranSuffix = ""
                    if ($rowsAffected -ge 0) {
                        $ranSuffix = " ({0} row{1} affected)" -f $rowsAffected, $(if ($rowsAffected -ne 1) { "s" } else { "" })
                    }
                    Write-Host ("RAN {0}{1}" -f $relFilePath, $ranSuffix)
                    if ($beforeFile -and $afterFile) {
                        Write-Host ("STATEDIFF {0}|{1}|{2}" -f $relFilePath, $beforeFile, $afterFile)
                    }
                    $ok++
                } catch {
                    Write-Host ("FAILED {0} -> {1}" -f $relFilePath, $_.Exception.Message)
                    $fail++
                    $tx.Rollback()
                    $txOpen = $false
                    break
                }
            }

            if ($txOpen) {
                if ($TrialRun) {
                    $tx.Rollback()
                } else {
                    $tx.Commit()
                }
                $txOpen = $false
            }
        } finally {
            if ($txOpen) { try { $tx.Rollback() } catch {} }
            $conn.Close()
        }

        Write-Host ("DURATION: {0}s" -f [Math]::Round(((Get-Date) - $runStart).TotalSeconds, 1))
        if ($fail -eq 0) {
            if ($TrialRun) {
                Write-Host "Trial run complete."
            } else {
                Write-Host "Done."
            }
        } else {
            Write-Host "Completed with errors."
        }
        exit
    }

    throw "No action specified - use -GetObjectDefinition, -PreviewTableChange, -PreviewDataChange, or -RunFiles."
} catch {
    # $runStart is only ever set once -RunFiles mode starts (see above) - still $null/unset here
    # for every other mode, or if -RunFiles failed before reaching that line at all.
    if ($runStart) {
        Write-Host ("DURATION: {0}s" -f [Math]::Round(((Get-Date) - $runStart).TotalSeconds, 1))
    }
    Write-Host ("ERROR: {0}" -f $_.Exception.Message)
}
