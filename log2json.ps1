# -----------------------------------------------------------------------------
# CF Log2JSON Converter Script
# Author: Alan O'Brien
#
# Description:
# This PowerShell script converts Adobe ColdFusion .log files into structured
# JSON (NDJSON) format for easier ingestion into logging platforms such as
# Splunk, Datadog, ELK, or similar tools.
#
# Features:
# - Incrementally processes log files (no reprocessing)
# - Tracks state between runs
# - Outputs JSON equivalents of active log files
# - Maintains a lightweight operational run log
# - Compatible with Windows PowerShell 5.1 and PowerShell 7+
# -----------------------------------------------------------------------------

param(
    [string]$LogDir = "D:\CFusion\cfusion\logs",
    [string]$JsonDir = "D:\CFusion\cfusion\logs\JSON",
    [string]$StateFile = "D:\CFusion\cfusion\logs\JSON\log_json_state.json",
    [string]$RunLog = "D:\CFusion\cfusion\logs\JSON\log2json_run.log"
)

$ErrorActionPreference = "Stop"

function Write-Info {
    param([string]$Message)
    Write-Host $Message -ForegroundColor Cyan
}

function Write-Step {
    param([string]$Message)
    Write-Host $Message -ForegroundColor Yellow
}

function Write-Ok {
    param([string]$Message)
    Write-Host $Message -ForegroundColor Green
}

function Write-WarnText {
    param([string]$Message)
    Write-Warning $Message
}

function Write-RunLog {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )

    $timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $entry = "$timestamp [$Level] $Message"
    Add-Content -LiteralPath $RunLog -Value $entry -Encoding UTF8
}

function Initialize-Directory {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Load-State {
    param([string]$Path)

    $result = @{}

    if (-not (Test-Path -LiteralPath $Path)) {
        return $result
    }

    try {
        $raw = Get-Content -LiteralPath $Path -Raw
        if ([string]::IsNullOrWhiteSpace($raw)) {
            return $result
        }

        $loaded = $raw | ConvertFrom-Json

        if ($null -eq $loaded) {
            return $result
        }

        foreach ($property in $loaded.PSObject.Properties) {
            $result[$property.Name] = @{
                LastLine   = [int]$property.Value.LastLine
                LastLength = [int64]$property.Value.LastLength
            }
        }
    }
    catch {
        Write-WarnText "Could not read state file. Starting with empty state."
        Write-RunLog "Could not read state file at $Path. Starting with empty state. Error: $($_.Exception.Message)" "WARN"
        $result = @{}
    }

    return $result
}

function Save-State {
    param(
        [hashtable]$State,
        [string]$Path
    )

    $out = @{}

    foreach ($key in $State.Keys) {
        $out[$key] = @{
            LastLine   = [int]$State[$key].LastLine
            LastLength = [int64]$State[$key].LastLength
        }
    }

    $out | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Convert-LogLineToObject {
    param(
        [string]$Line,
        [string]$SourceFile
    )

    if ($Line -match '^(?<date>[^,]+),\s*(?<time>[^,]+),\s*(?<severity>[^,]+),\s*(?<thread>[^,]+),\s*(?<category>[^,]+),\s*(?<message>.*)$') {
        return [PSCustomObject]@{
            src = $SourceFile
            ts  = '{0} {1}' -f $matches.date.Trim(), $matches.time.Trim()
            lvl = $matches.severity.Trim()
            thr = $matches.thread.Trim()
            cat = $matches.category.Trim()
            msg = $matches.message.Trim()
        }
    }

    return [PSCustomObject]@{
        src = $SourceFile
        raw = $Line
    }
}

function Get-LogTimestamp {
    param([string]$Line)

    if ($Line -match '^(?<date>[^,]+),\s*(?<time>[^,]+),') {
        return ('{0} {1}' -f $matches.date.Trim(), $matches.time.Trim())
    }

    return $null
}

Initialize-Directory -Path $JsonDir

$state = Load-State -Path $StateFile

$excluded = @(
    "websocket.log"
)

$logFiles = Get-ChildItem -Path $LogDir -Filter "*.log" -File |
    Where-Object {
        ($excluded -notcontains $_.Name) -and
        ($_.Name -notmatch '\.\d+\.log$')
    } |
    Sort-Object Name

Write-Info "Found $($logFiles.Count) log files in $LogDir"

$totalFilesProcessed = 0
$totalFilesUpdated = 0
$totalLinesWritten = 0
$runLogEntries = New-Object System.Collections.Generic.List[string]

foreach ($logFile in $logFiles) {
    $totalFilesProcessed++

    $fullPath = $logFile.FullName
    $name = $logFile.Name
    $jsonPath = Join-Path $JsonDir ([System.IO.Path]::ChangeExtension($name, ".json"))

    Write-Host ""
    Write-Step "Processing $name"
    Write-Host "  Source: $fullPath"
    Write-Host "  Target: $jsonPath"

    if (-not (Test-Path -LiteralPath $jsonPath)) {
        New-Item -ItemType File -Path $jsonPath -Force | Out-Null
        Write-Host "  Created JSON file."
    }

    try {
        $lines = Get-Content -LiteralPath $fullPath
    }
    catch {
        $msg = "Could not read $fullPath : $($_.Exception.Message)"
        Write-WarnText $msg
        Write-RunLog $msg "ERROR"
        continue
    }

    if ($null -eq $lines) {
        $lines = @()
    }
    elseif (-not ($lines -is [System.Array])) {
        $lines = @($lines)
    }

    $lineCount = $lines.Count
    Write-Host "  Current line count: $lineCount"

    $isFirstRunForFile = -not $state.ContainsKey($fullPath)

    if ($isFirstRunForFile) {
        $state[$fullPath] = @{
            LastLine   = 0
            LastLength = [int64]$logFile.Length
        }
        Write-Ok "  First run for this file. Existing log contents will be converted."
    }

    $lastLine = [int]$state[$fullPath].LastLine
    $lastLength = [int64]$state[$fullPath].LastLength

    if (-not $isFirstRunForFile) {
        if (($logFile.Length -lt $lastLength) -or ($lineCount -lt $lastLine)) {
            Write-Host "  File appears rotated or truncated. Resetting read position." -ForegroundColor Magenta
            $lastLine = 0
        }
    }

    if ($lineCount -le $lastLine) {
        Write-Host "  No new lines."
        $state[$fullPath].LastLine = $lineCount
        $state[$fullPath].LastLength = [int64]$logFile.Length
        continue
    }

    $newLineCount = $lineCount - $lastLine
    Write-Ok "  Lines to write: $newLineCount"

    if ($newLineCount -eq 1) {
        $newLines = @($lines[$lastLine])
    }
    else {
        $newLines = $lines[$lastLine..($lineCount - 1)]
    }

    $written = 0
    $firstTs = $null
    $lastTs = $null

    foreach ($line in $newLines) {
        if ($null -eq $line) {
            continue
        }

        $record = Convert-LogLineToObject -Line ([string]$line) -SourceFile $name
        $jsonLine = $record | ConvertTo-Json -Compress -Depth 5
        Add-Content -LiteralPath $jsonPath -Value $jsonLine -Encoding UTF8

        $ts = Get-LogTimestamp -Line ([string]$line)
        if ($ts) {
            if (-not $firstTs) {
                $firstTs = $ts
            }
            $lastTs = $ts
        }

        $written++
    }

    Write-Host "  Appended $written JSON records."

    if ($written -gt 0) {
        $totalFilesUpdated++
        $totalLinesWritten += $written

        if ($firstTs -and $lastTs) {
            $runLogEntries.Add("$name appended $written lines ($firstTs -> $lastTs)")
        }
        else {
            $runLogEntries.Add("$name appended $written lines (no timestamp parsed)")
        }
    }

    $state[$fullPath].LastLine = $lineCount
    $state[$fullPath].LastLength = [int64]$logFile.Length
}

Save-State -State $state -Path $StateFile

if ($runLogEntries.Count -gt 0) {
    foreach ($entry in $runLogEntries) {
        Write-RunLog $entry
    }

    Write-RunLog "Summary: processed $totalFilesProcessed files, updated $totalFilesUpdated files, appended $totalLinesWritten lines"
}

Write-Host ""
Write-Info "Completed. State saved to $StateFile"
