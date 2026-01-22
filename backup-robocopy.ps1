<#
.SYNOPSIS
  Robocopy backup wrapper with detailed logging, scheduling-friendly options and automatic log pruning.

.DESCRIPTION
  This script wraps robocopy to perform robust backups on Windows.
  It preserves file data (so EXIF embedded in files is preserved), file timestamps,
  attributes, NTFS ACLs, owner and auditing info (when run with sufficient privileges).
  Produces timestamped logs and interprets robocopy exit codes.
  Adds automatic log pruning: deletes old logs matching robocopy_backup_*.log older than RetainLogsDays.

.NOTES
  - Run elevated (as Administrator) if you need to copy security/owner/auditing or use backup mode.
  - For large jobs, consider running during off-hours and use /MT to parallelize.
#>

param(
    [Parameter(Position=0, HelpMessage="Source folder to back up. If omitted, you'll be prompted.")]
    [string]$Source,

    [Parameter(Position=1, HelpMessage="Destination folder (folder that will receive the files). If omitted, you'll be prompted.")]
    [string]$Destination,

    [Parameter(HelpMessage="Folder where logs are stored. Default: %ProgramData%\\RobocopyBackup\\Logs")]
    [string]$LogFolder = "$env:ProgramData\RobocopyBackup\Logs",

    [Parameter(HelpMessage="If set, performs a mirror (equivalent to robocopy /MIR). WARNING: mirror deletes extra files in destination.")]
    [switch]$Mirror,

    [Parameter(HelpMessage="If set, uses backup mode (/B) to attempt to copy files even if ACLs would block normal access. Requires appropriate privileges.")]
    [switch]$UseBackupMode,

    [Parameter(HelpMessage="Dry run: Adds robocopy /L (list only) so nothing is actually copied.")]
    [switch]$WhatIf,

    [Parameter(HelpMessage="Number of retry attempts on failed copies. Default 3.")]
    [int]$Retry = 3,

    [Parameter(HelpMessage="Wait time (seconds) between retries. Default 5.")]
    [int]$Wait = 5,

    [Parameter(HelpMessage="Number of threads for robocopy /MT. Default 8. Set 1 to disable /MT.")]
    [int]$Threads = 8,

    [Parameter(HelpMessage="If set, exclude copying junction points (/XJ).")]
    [switch]$ExcludeJunctions,

    [Parameter(HelpMessage="Number of days to keep logs. Logs older than this will be deleted. Set 0 or negative to disable pruning. Default 30.")]
    [int]$RetainLogsDays = 30
)

function Ensure-AbsolutePath([string]$p) {
    if (-not $p) { return $p }
    return (Resolve-Path -Path $p -ErrorAction Stop).ProviderPath
}

function Prune-OldLogs {
    param(
        [string]$LogFolderPath,
        [int]$DaysToKeep,
        [string]$MainLogFile
    )
    if ($DaysToKeep -le 0) {
        Add-Content -Path $MainLogFile -Value ("Log pruning disabled (RetainLogsDays={0})." -f $DaysToKeep)
        return
    }

    try {
        $cutoff = (Get-Date).AddDays(-$DaysToKeep)
        Add-Content -Path $MainLogFile -Value ("Pruning logs older than {0} (cutoff: {1})." -f $DaysToKeep, $cutoff.ToString("yyyy-MM-dd HH:mm:ss"))

        $files = Get-ChildItem -Path $LogFolderPath -Filter "robocopy_backup_*.log" -File -ErrorAction SilentlyContinue
        if (-not $files) {
            Add-Content -Path $MainLogFile -Value "No log files found to consider for pruning."
            return
        }

        $oldFiles = $files | Where-Object { $_.LastWriteTime -lt $cutoff }
        $count = 0
        foreach ($f in $oldFiles) {
            try {
                Add-Content -Path $MainLogFile -Value ("Pruning: Deleting {0} (LastWriteTime: {1})" -f $f.FullName, $f.LastWriteTime.ToString("yyyy-MM-dd HH:mm:ss"))
                Remove-Item -Path $f.FullName -Force -ErrorAction Stop
                $count++
            } catch {
                Add-Content -Path $MainLogFile -Value ("Pruning: FAILED to delete {0} : {1}" -f $f.FullName, $_.Exception.Message)
            }
        }
        Add-Content -Path $MainLogFile -Value ("Pruning complete. Deleted {0} file(s)." -f $count)
    } catch {
        Add-Content -Path $MainLogFile -Value ("Pruning encountered an error: {0}" -f $_.Exception.Message)
    }
}

# Prompt for source/destination if not provided
if (-not $Source) {
    $Source = Read-Host "Enter source folder to back up (e.g. D:\Data\MyFiles)"
}
if (-not $Destination) {
    $Destination = Read-Host "Enter destination folder (e.g. E:\Backups\MyFiles)"
}

try {
    $Source = Ensure-AbsolutePath $Source
} catch {
    Write-Error "Source path '$Source' does not exist or cannot be resolved."
    exit 99
}
# Destination may not yet exist; resolve/create
try {
    $parent = Split-Path -Path $Destination -Parent
    if ($parent -and -not (Test-Path -Path $parent)) {
        New-Item -Path $parent -ItemType Directory -Force | Out-Null
    }
    if (-not (Test-Path -Path $Destination)) {
        New-Item -Path $Destination -ItemType Directory -Force | Out-Null
    }
    $Destination = Ensure-AbsolutePath $Destination
} catch {
    Write-Error "Destination '$Destination' cannot be created or resolved: $_"
    exit 98
}

# Prepare log folder and log file
if (-not (Test-Path -Path $LogFolder)) {
    New-Item -Path $LogFolder -ItemType Directory -Force | Out-Null
}
$timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
$logFile = Join-Path $LogFolder ("robocopy_backup_{0}.log" -f $timestamp)

# Pre-write header to log so pruning actions can be recorded
$header = @(
    "================ Robocopy Backup ================",
    "Timestamp  : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')",
    "Source     : $Source",
    "Destination: $Destination",
    "ScriptPath : $MyInvocation.MyCommand.Definition",
    "RetainLogsDays: $RetainLogsDays",
    "-------------------------------------------------",
    ""
) -join "`r`n"

Add-Content -Path $logFile -Value $header

# Perform pruning of old logs (if enabled)
Prune-OldLogs -LogFolderPath $LogFolder -DaysToKeep $RetainLogsDays -MainLogFile $logFile

# Robocopy arguments
$rcArgs = @()

# Source and Destination
$rcArgs += ('"{0}"' -f $Source)
$rcArgs += ('"{0}"' -f $Destination)

# Copy everything under source (including empty directories)
$rcArgs += "/E"

# Preserve data, attributes, timestamps, security (ACLs), owner, auditing, and alternate data streams:
$rcArgs += "/COPY:DATSOU"

if ($UseBackupMode) {
    $rcArgs += "/B"
}

if ($Mirror) {
    $rcArgs += "/MIR"
}

$rcArgs += ("/R:{0}" -f $Retry)
$rcArgs += ("/W:{0}" -f $Wait)

if ($Threads -gt 1) {
    $rcArgs += ("/MT:{0}" -f $Threads)
}

if ($ExcludeJunctions) {
    $rcArgs += "/XJ"
}

# Logging and verbosity options
$rcArgs += "/V"    # verbose - lists skipped files
$rcArgs += "/TEE"  # write to console and to log
$rcArgs += "/NP"   # no progress - removes progress output percent
$rcArgs += "/ETA"  # show estimated time of arrival
# If you want the full file list in logs, remove /NFL below. By default we keep it concise.
$rcArgs += "/NFL"  # no file list (reduce log noise)

# Use /LOG+ to append to our log (we pre-wrote header)
$rcArgs += ("/LOG+:\"{0}\"" -f $logFile)

if ($WhatIf) {
    $rcArgs += "/L"
    Write-Host "Running in DRY-RUN mode (robocopy /L) - no files will be copied."
}

# Compose command string for display/log
$rcCommand = "robocopy " + ($rcArgs -join " ")

Add-Content -Path $logFile -Value ("Command   : {0}" -f $rcCommand)
Add-Content -Path $logFile -Value ("Parameters: Mirror={0} UseBackupMode={1} WhatIf={2} Retry={3} Wait={4} Threads={5} ExcludeJunctions={6}" -f $Mirror, $UseBackupMode, $WhatIf, $Retry, $Wait, $Threads, $ExcludeJunctions)
Add-Content -Path $logFile -Value ("-------------------------------------------------" + "`r`n")

# Execute robocopy
Write-Host "Starting robocopy. Log: $logFile"
$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = "robocopy"
$psi.Arguments = $rcArgs -join " "
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$psi.UseShellExecute = $false
$psi.CreateNoWindow = $true

$proc = New-Object System.Diagnostics.Process
$proc.StartInfo = $psi
$proc.Start() | Out-Null

$stdOut = $proc.StandardOutput
$stdErr = $proc.StandardError

while (-not $proc.HasExited) {
    while (-not $stdOut.EndOfStream) {
        $line = $stdOut.ReadLine()
        Add-Content -Path $logFile -Value $line
    }
    while (-not $stdErr.EndOfStream) {
        $line = $stdErr.ReadLine()
        Add-Content -Path $logFile -Value $line
    }
    Start-Sleep -Milliseconds 200
}
while (-not $stdOut.EndOfStream) {
    Add-Content -Path $logFile -Value ($stdOut.ReadLine())
}
while (-not $stdErr.EndOfStream) {
    Add-Content -Path $logFile -Value ($stdErr.ReadLine())
}

$proc.WaitForExit()
$exitCode = $proc.ExitCode

# Interpret robocopy exit code
$summary = "`r`n================ Summary ================" +
           "`r`nEndTime   : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" +
           "`r`nExitCode  : $exitCode"

if ($exitCode -eq 0) {
    $summary += "`r`nResult    : No files copied. No failure."
} elseif ($exitCode -eq 1) {
    $summary += "`r`nResult    : Some files copied successfully. No failures."
} elseif ($exitCode -lt 8) {
    $summary += "`r`nResult    : Success with minor issues (exit code indicates extra/mismatched files or similar)."
} else {
    $summary += "`r`nResult    : FAILURE (some files could not be copied or serious error)."
}

Add-Content -Path $logFile -Value $summary
Write-Host $summary

exit $exitCode