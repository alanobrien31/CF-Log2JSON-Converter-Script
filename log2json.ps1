# -----------------------------------------------------------------------------
# CF Log2JSON Converter Script
# Author: Alan O'Brien
#
# Description:
# Converts Adobe ColdFusion .log files into structured JSON (NDJSON) format
# for ingestion into Splunk, Datadog, ELK, or similar tools.
#
# Features:
# - Compatible with Windows PowerShell 5.1 and PowerShell 7+
# - Incremental processing using state tracking
# - Excludes rotated logs like application.1.log
# - Parses double-escaped JSON inside msg where possible
# - Stops/disables Elastic Agent before processing
# - Re-enables/restarts Elastic Agent after processing
# -----------------------------------------------------------------------------
param(
    [string]$LogDir = "D:\CFusion\cfusion\logs",
    [string]$JsonDir = "D:\CFusion\cfusion\logs\JSON",
    [string]$StateFile = "D:\CFusion\cfusion\logs\JSON\log_json_state.json",
    [string]$RunLog = "D:\CFusion\cfusion\logs\JSON\log2json_run.log",
    [string]$ElasticServiceName = "Elastic Agent"
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

function Initialize-Directory {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Add-LineWithRetry {
    param(
        [string]$Path,
        [string]$Value,
        [int]$Retries = 30,
        [int]$DelayMs = 1000
    )

    for ($i = 1; $i -le $Retries; $i++) {
        try {
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($Value + [Environment]::NewLine)

            $stream = [System.IO.File]::Open(
                $Path,
                [System.IO.FileMode]::Append,
                [System.IO.FileAccess]::Write,
                [System.IO.FileShare]::ReadWrite
            )

            try {
                $stream.Write($bytes, 0, $bytes.Length)
            }
            finally {
                $stream.Close()
            }

            return
        }
        catch {
            if ($i -eq $Retries) {
                throw
            }

            Start-Sleep -Milliseconds $DelayMs
        }
    }
}

function Set-FileContentWithRetry {
    param(
        [string]$Path,
        [string]$Value,
        [int]$Retries = 30,
        [int]$DelayMs = 1000
    )

    for ($i = 1; $i -le $Retries; $i++) {
        try {
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($Value)

            $stream = [System.IO.File]::Open(
                $Path,
                [System.IO.FileMode]::Create,
                [System.IO.FileAccess]::Write,
                [System.IO.FileShare]::ReadWrite
            )

            try {
                $stream.Write($bytes, 0, $bytes.Length)
            }
            finally {
                $stream.Close()
            }

            return
        }
        catch {
            if ($i -eq $Retries) {
                throw
            }

            Start-Sleep -Milliseconds $DelayMs
        }
    }
}

function Write-RunLog {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )

    $timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $entry = "$timestamp [$Level] $Message"

    try {
        Add-LineWithRetry -Path $RunLog -Value $entry
    }
    catch {
        Write-Warning "Could not write to run log: $($_.Exception.Message)"
    }
}

function Get-ServiceState {
    param([string]$ServiceName)

    Get-CimInstance Win32_Service -Filter "Name='$ServiceName'" -ErrorAction Stop
}

function Disable-And-Stop-Elastic {
    param([string]$ServiceName)

    Write-Step "Stopping and disabling service: $ServiceName"

    $svc = Get-ServiceState -ServiceName $ServiceName

    Set-Service -Name $ServiceName -StartupType Disabled

    if ($svc.State -ne "Stopped") {
        Stop-Service -Name $ServiceName -Force -ErrorAction Stop
    }

    Start-Sleep -Seconds 30

    $svc = Get-ServiceState -ServiceName $ServiceName

    if ($svc.State -ne "Stopped" -or $svc.StartMode -ne "Disabled") {
        throw "Service check failed. $ServiceName status=$($svc.State), startup=$($svc.StartMode)"
    }

    Write-Ok "Confirmed $ServiceName is stopped and disabled."
}

function Enable-And-Start-Elastic {
    param([string]$ServiceName)

    Write-Step "Enabling and starting service: $ServiceName"

    Set-Service -Name $ServiceName -StartupType Automatic
    Start-Service -Name $ServiceName -ErrorAction Stop

    Start-Sleep -Seconds 30

    $svc = Get-ServiceState -ServiceName $ServiceName

    if ($svc.State -ne "Running" -or $svc.StartMode -ne "Auto") {
        throw "Service check failed. $ServiceName status=$($svc.State), startup=$($svc.StartMode)"
    }

    Write-Ok "Confirmed $ServiceName is running and set to Automatic."
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

    $json = $out | ConvertTo-Json -Depth 10
    Set-FileContentWithRetry -Path $Path -Value $json
}

function Convert-PossibleJsonMessage {
    param([string]$Message)

    $msg = $Message.Trim()

    if ([string]::IsNullOrWhiteSpace($msg)) {
        return $msg
    }

    if ($msg.Length -ge 2 -and $msg.StartsWith('"') -and $msg.EndsWith('"')) {
        $msg = $msg.Substring(1, $msg.Length - 2)
    }

    $candidate = $msg -replace '""', '"'

    if ($candidate -match '^\s*[\{\[]') {
        try {
            return ($candidate | ConvertFrom-Json -ErrorAction Stop)
        }
        catch {
            return $Message.Trim()
        }
    }

    return $Message.Trim()
}

function Convert-LogLineToObject {
    param(
        [string]$Line,
        [string]$SourceFile
    )

    if ($Line -match '^(?<level>"?[^,]+"?),\s*(?<thread>"?[^,]+"?),\s*(?<date>"?[^,]+"?),\s*(?<time>"?[^,]+"?),\s*(?<category>"?[^,]+"?),\s*(?<message>.*)$') {
        $msgValue = Convert-PossibleJsonMessage -Message $matches.message

        return [PSCustomObject]@{
            src = $SourceFile
            ts  = '{0} {1}' -f $matches.date.Trim('" '), $matches.time.Trim('" ')
            lvl = $matches.level.Trim('" ')
            thr = $matches.thread.Trim('" ')
            cat = $matches.category.Trim('" ')
            msg = $msgValue
        }
    }

    return [PSCustomObject]@{
        src = $SourceFile
        raw = $Line
    }
}

function Get-LogTimestamp {
    param([string]$Line)

    if ($Line -match '^(?<level>"?[^,]+"?),\s*(?<thread>"?[^,]+"?),\s*(?<date>"?[^,]+"?),\s*(?<time>"?[^,]+"?),') {
        return ('{0} {1}' -f $matches.date.Trim('" '), $matches.time.Trim('" '))
    }

    return $null
}

Initialize-Directory -Path $JsonDir

try {
    Disable-And-Stop-Elastic -ServiceName $ElasticServiceName

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
            $jsonLine = $record | ConvertTo-Json -Compress -Depth 100

            try {
                Add-LineWithRetry -Path $jsonPath -Value $jsonLine
            }
            catch {
                $msg = "Could not append to $jsonPath : $($_.Exception.Message)"
                Write-WarnText $msg
                Write-RunLog $msg "ERROR"
                continue
            }

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
}
finally {
    Enable-And-Start-Elastic -ServiceName $ElasticServiceName
}

Write-Host ""
Write-Info "Completed. State saved to $StateFile"
