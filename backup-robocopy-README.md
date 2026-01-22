```markdown
# Robocopy Backup PowerShell Wrapper

This document explains how to use the included PowerShell script `backup-robocopy.ps1`, what each variable/attribute and robocopy switch does, and how to schedule the script.

## Quick start

1. Save `backup-robocopy.ps1` somewhere, e.g. `C:\Scripts\backup-robocopy.ps1`.
2. Open an elevated PowerShell (Run as Administrator) if you need to preserve ACLs/owners/auditing or use backup mode.
3. Test with a dry run:
   ```
   powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Scripts\backup-robocopy.ps1" -Source "D:\Data\MyFolder" -Destination "E:\Backups\MyFolder" -WhatIf
   ```
   This runs robocopy with `/L` and writes what would be done to the log without copying.
4. Run the real job (no -WhatIf):
   ```
   powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Scripts\backup-robocopy.ps1" -Source "D:\Data\MyFolder" -Destination "E:\Backups\MyFolder"
   ```

## Scheduling examples

Using schtasks to create a daily task at 02:00 AM run as SYSTEM (no interactive login required):
```
schtasks /Create /SC DAILY /TN "Robocopy Backup - MyFolder" /ST 02:00 /RL HIGHEST /RU "SYSTEM" /F /TR "powershell.exe -NoProfile -ExecutionPolicy Bypass -File \"C:\Scripts\backup-robocopy.ps1\" -Source \"D:\Data\MyFolder\" -Destination \"E:\Backups\MyFolder\""
```

Or schedule to run as a specific user (replace DOMAIN\User and omit /RU SYSTEM):
```
schtasks /Create /SC DAILY /TN "Robocopy Backup - MyFolder" /ST 02:00 /RL HIGHEST /RU "DOMAIN\User" /RP "UserPassword" /F /TR "powershell.exe -NoProfile -ExecutionPolicy Bypass -File \"C:\Scripts\backup-robocopy.ps1\" -Source \"D:\Data\MyFolder\" -Destination \"E:\Backups\MyFolder\""
```

Alternatively, use Task Scheduler GUI:
- Create Basic Task -> Trigger (Daily) -> Action: Start a program -> Program/script: powershell.exe
- Add arguments: -NoProfile -ExecutionPolicy Bypass -File "C:\Scripts\backup-robocopy.ps1" -Source "D:\Data\MyFolder" -Destination "E:\Backups\MyFolder"
- Configure to run whether user is logged on or not and run with highest privileges.

## Log location and naming
Default log folder: `%ProgramData%\RobocopyBackup\Logs`
Log file per run: `robocopy_backup_YYYY-MM-DD_HH-mm-ss.log` (timestamped).

## Important options exposed by the script

- Source: Source folder to back up. If not present, the script prompts you.
- Destination: Destination folder to receive files. If missing, the script prompts and will create it.
- LogFolder: Where logs are kept. Default: `%ProgramData%\RobocopyBackup\Logs`.
- Mirror: Switch that performs `/MIR` (mirror). WARNING: `robocopy /MIR` will delete files from the destination that no longer exist in the source. Use with caution.
- UseBackupMode: Switch that uses `/B` (backup mode). This attempts to copy files even when ACLs would block normal copies but requires Backup privilege (Administrator or SeBackupPrivilege).
- WhatIf: Dry-run. Adds `/L` to the robocopy options so no files are copied; useful for testing.
- Retry: Number of retries for individual file copy failures (default 3) -> `/R:n`.
- Wait: Seconds to wait between retries (default 5) -> `/W:n`.
- Threads: Number for multithreaded copy `/MT:n`. Default 8. Set to 1 to avoid using `/MT`.
- ExcludeJunctions: Adds `/XJ` to exclude junction points (junction reparse points) and avoid recursion loops.

## Robocopy switches used (what they mean)

- /E : Copy subdirectories, including empty ones.
- /COPY:DATSOU : Copy Data, Attributes, Timestamps, Security (NTFS ACLs), Owner, and Auditing info. Equivalent to /COPYALL (but explicit).
  - This preserves file contents (so EXIF stored inside files is preserved), timestamps, attributes and NTFS security metadata.
  - Note: copying owner/auditing may require admin rights.
- /B : Backup mode. Attempts to copy files using backup privileges rather than standard access checks.
- /MIR : Mirror a directory tree (equivalent to /E plus /PURGE). Danger: may delete files at destination.
- /R:n and /W:n : Retry count and wait time between retries.
- /MT:n : Enable multithreaded copying with n threads (default used in the script: 8). Speeds up copying many small files; some robocopy switches incompatible with /MT.
- /XJ : Exclude junction points (recommended to avoid copying reparse points that cause loops).
- /V : Produce verbose output (shows skipped files).
- /TEE : Write output to console window, and to the log file.
- /NP : No progress - suppresses the percentage progress to reduce log noise.
- /ETA : Show estimated time of arrival for each file.
- /LOG:file or /LOG+:file : Write (overwrite) or append robocopy output to file. Script uses /LOG+ to append; the script pre-writes a header, then appends robocopy output.
- /L : List-only (do not perform copy). Useful for dry-runs.

## Robocopy exit codes (how script interprets them)
Robocopy uses a bitmask exit code. Common values:
- 0 : No files were copied. No failure.
- 1 : Some files copied successfully.
- 2 : Extra files or directories were present (no failure).
- 4 : Mismatched files or directories detected.
- 8 : Some files or directories could not be copied (failure).
- 16: Serious error (invalid parameters, out of memory, etc.)

Interpretation: Codes less than 8 are usually treated as success or success-with-warnings. Codes >= 8 indicate failure or serious error. The script returns robocopy's exit code as its own exit code.

## Preservation of EXIF and metadata
- EXIF and embedded metadata are part of the file's binary contents. Robocopy copies files byte-for-byte; therefore EXIF is preserved.
- File system metadata:
  - Timestamps and attributes: preserved with `/COPY` options and robocopy default behavior.
  - NTFS ACLs, owner, and auditing: preserved with `/COPY:DATSOU` (may require Administrator privileges).
  - Alternate Data Streams (ADS) and reparse points: ADS are preserved by robocopy when copying NTFS; use caution with junctions.

## Tips and safety
- Test with `-WhatIf` first to confirm behavior.
- Test on a small folder before running full backup.
- If you require exact mirroring but want safety, consider enabling logging and running the script without `-Mirror` first to verify source contents.
- If you plan to copy from network shares, ensure the scheduled user has network access and permission.
- When copying system files or using `/B`, run the task with elevated privileges.

## Example usage
Dry-run listing only:
```
powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Scripts\backup-robocopy.ps1" -Source "D:\Photos" -Destination "E:\Backups\Photos" -WhatIf -LogFolder "C:\Logs\Backup"
```

Real run with mirror (be careful, will delete destination extras):
```
powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Scripts\backup-robocopy.ps1" -Source "D:\Photos" -Destination "E:\Backups\Photos" -Mirror -Threads 12 -Retry 2 -Wait 3
```

## Questions / customization
If you want:
- Email or Windows Event Log alerts on failure,
- Rotation of old logs (automatic deletion after N days),
- Backups per user/profile or incremental VSS snapshots,
I can update the script to add those features.
```