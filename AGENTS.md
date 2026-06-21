# Agent Instructions

This folder contains the Automated GUI Testing Agent Framework. Your job is to convert testcase CSV files into repeatable PowerShell GUI test scripts that use `potato_cli`.

## Required Workflow

1. Read `README.md` and `docs\GENERATED_SCRIPT_CONTRACT.md`.
2. Parse the testcase CSV. Required columns are `Action`, `Data`, and `Expected Result`.
3. Create or use a run folder with `input`, `generated`, `evidence`, `logs`, and `results` subfolders.
4. Explore the interactive Windows desktop using `..\potato_cli\potato.ps1` commands only.
5. Generate a PowerShell script that follows the generated-script contract.
6. Run the generated script once unless the user explicitly asks for generation only.
7. Save results and evidence under the run folder.
8. Report the generated script path, result JSON path, screenshots/evidence, and any failing PoTATo JSON outputs.

## Allowed Automation Surface

Use only `potato_cli` commands for GUI operations:

`start`, `focus`, `windows`, `observe`, `select`, `click`, `click-coordinate`, `type`, `hotkey`, `drag`, `hover`, `wait-element`, `wait-file`, `read`, `screenshot`, `close-window`, `report`, `state`.

Do not import old PoTATo testcases, image recognition, Selenium, browser-specific automation, Jira/report-server code, VM tooling, or application-specific legacy helpers.

## Generated Script Rules

- Generated scripts must be PowerShell.
- Generated scripts must accept `-PotatoCliPath`, `-TestCaseCsv`, and `-RunRoot`.
- Generated scripts must emit one JSON result object to stdout.
- Each CSV row must map to one final step result.
- Step results must include `stepIndex`, `action`, `expectedResult`, `status`, `evidence`, `commands`, and `error`.
- Coordinate clicks are fallback only. If used, add a short comment and save a screenshot.
- Scripts must be repeatable after a clean VM checkpoint restore.

## Reporting Shape

Use `PASS`, `FAIL`, or `SKIPPED` for step status. The final script JSON must include:

- `ok`
- `testCase`
- `runRoot`
- `startedAt`
- `finishedAt`
- `steps`
- `summary`
- `artifacts`

