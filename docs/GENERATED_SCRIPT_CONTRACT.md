# Generated Script Contract

Generated testcase scripts must follow this contract so different agents and API providers produce comparable artifacts.

## Parameters

Every generated script must accept:

```powershell
param(
    [string] $PotatoCliPath,
    [string] $TestCaseCsv,
    [string] $RunRoot
)
```

Defaults are allowed, but the parameters must exist.

## Runtime Layout

The script must create these directories under `RunRoot` if they do not exist:

- `evidence`
- `logs`
- `results`

All screenshots, created files, JSON results, and command transcripts belong under `RunRoot`.

## PoTATo Invocation

The script must call `potato_cli\potato.ps1` through a local helper equivalent to:

```powershell
Invoke-PotatoJson -Command "observe" -Arguments @("-Depth", "2")
```

The helper must:

- run `powershell.exe -NoProfile -ExecutionPolicy Bypass -File <potato.ps1>`,
- parse the single JSON result,
- throw a clear error if the output is not JSON,
- save command transcripts under `logs`.

Prefer selector-based GUI interactions in generated scripts. `hotkey` is allowed for documented fallback paths, common commands that are not reliably exposed through UI Automation, or deliberate state recovery, but it should not replace normal visible GUI navigation when `click`, `select`, `wait-element`, `read`, `hover`, `drag`, or `type` can do the job.

## Step Results

Each CSV row maps to one final step result object:

```json
{
  "stepIndex": 1,
  "action": "Open Paint",
  "expectedResult": "Paint opened",
  "status": "PASS",
  "evidence": [],
  "commands": [],
  "error": null
}
```

Allowed statuses:

- `PASS`
- `FAIL`
- `SKIPPED`

## Final JSON

The script must write exactly one JSON object to stdout:

```json
{
  "ok": true,
  "testCase": "Microsoft Paint.csv",
  "runRoot": "C:\\...",
  "startedAt": "2026-06-21T12:00:00.0000000+02:00",
  "finishedAt": "2026-06-21T12:01:00.0000000+02:00",
  "steps": [],
  "summary": {
    "total": 5,
    "passed": 5,
    "failed": 0,
    "skipped": 0
  },
  "artifacts": {
    "resultPath": "C:\\...\\results\\result.json",
    "evidenceRoot": "C:\\...\\evidence"
  }
}
```

The same JSON must also be saved to `results\result.json`.

## Coordinate Fallbacks

Coordinate clicks and drags are allowed only when selector-based automation is not reliable. The script must include a short comment and save a screenshot near the fallback action.
