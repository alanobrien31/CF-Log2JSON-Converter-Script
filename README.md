# ColdFusion Log to JSON Converter (PowerShell)

## Overview

This PowerShell script converts Adobe ColdFusion `.log` files into structured JSON (NDJSON) format for easier ingestion into logging platforms such as Splunk, Datadog, ELK, or similar tools.

It is designed to:

* Incrementally process log files (no reprocessing)
* Track state between runs
* Output JSON equivalents of active log files
* Maintain a lightweight operational run log
* Work with both **Windows PowerShell 5.1** and **PowerShell 7+**

---

## Features

* ✅ Converts ColdFusion logs to newline-delimited JSON (NDJSON)
* ✅ Processes **only new log entries** after initial run
* ✅ Excludes rotated logs (e.g. `application.1.log`)
* ✅ Automatically detects log truncation/rotation
* ✅ Maintains a persistent state file
* ✅ Generates a run log **only when changes occur**
* ✅ Compatible with PowerShell 5.1 and 7+

---

## Default Paths

```powershell
$LogDir   = "D:\CFusion\cfusion\logs"
$JsonDir  = "D:\CFusion\cfusion\logs\JSON"
$StateFile = "D:\CFusion\cfusion\logs\JSON\log_json_state.json"
$RunLog    = "D:\CFusion\cfusion\logs\JSON\log2json_run.log"
```

---

## How It Works

1. Reads all `.log` files in the ColdFusion logs directory
2. Excludes rotated logs (e.g. `*.1.log`, `*.2.log`)
3. Tracks last processed position using a state file
4. Converts new lines into structured JSON
5. Appends JSON output to matching `.json` files
6. Logs only files that had updates

---

## Output Format

### JSON (NDJSON)

Each log line becomes a JSON object:

```json
{"src":"application.log","ts":"Mar 24 2026 15:03:04","lvl":"Information","thr":"main","cat":"scheduler","msg":"Task completed"}
```

If parsing fails:

```json
{"src":"coldfusion-out.log","raw":"some raw log line"}
```

---

### Run Log Example

Only updated files are logged:

```text
2026-03-24 17:00:01 [INFO] application.log appended 12 lines (Mar 24 2026 15:03:04 -> Mar 24 2026 15:15:22)
2026-03-24 17:00:02 [INFO] scheduler.log appended 3 lines (Mar 24 2026 07:25:00 -> Mar 24 2026 07:30:00)
2026-03-24 17:00:03 [INFO] Summary: processed 19 files, updated 2 files, appended 15 lines
```

If no logs changed → **no run log entries are written**

---

## First Run Behavior

* Converts all existing log contents into JSON
* Creates the state file
* Subsequent runs only process new log entries

---

## Usage

### Run manually

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\Scripts\log2json.ps1"
```

### Schedule (recommended)

Create a Windows Scheduled Task:

* Trigger: every hour
* Action:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\Scripts\log2json.ps1"
```

---

## File Mapping

| Source Log      | JSON Output      |
| --------------- | ---------------- |
| application.log | application.json |
| server.log      | server.json      |
| scheduler.log   | scheduler.json   |

Rotated logs like `application.1.log` are **ignored**.

---

## State File

The script maintains:

```text
log_json_state.json
```

This tracks:

* last processed line
* last file size

⚠️ If deleted, the script will reprocess logs from the beginning.

---

## Error Handling

* File read failures are logged to the run log
* State file corruption is handled gracefully
* Script continues processing remaining files

---

## Performance Notes

* Designed for **hourly scheduled execution**
* Efficient for typical ColdFusion log sizes
* Reads full file per run (acceptable for moderate sizes)

For very large logs (GB scale), consider:

* streaming approach
* or a dedicated log shipper (Fluent Bit, NXLog, etc.)

---

## Limitations

* Multiline logs (e.g. stack traces) are treated as separate entries
* Not all log formats will parse into structured fields
* Some logs (e.g. `coldfusion-out.log`) may remain mostly unparsed

---

## Optional Enhancements

Possible future improvements:

* Log rotation for `log2json_run.log`
* Byte-offset tracking instead of line-based
* Multiline log handling
* Streaming (real-time) processing mode
* ISO8601 timestamp normalization

---

## Summary

This script provides a lightweight, reliable way to:

* modernize ColdFusion logging
* enable structured log ingestion
* maintain operational visibility
* avoid modifying ColdFusion itself

---

## License

Internal / Custom Use (adjust as needed)

---
