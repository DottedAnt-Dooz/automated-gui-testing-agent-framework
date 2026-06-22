# Agent Instructions

This folder contains the Automated GUI Testing Agent Framework. Your job is to convert testcase CSV files into repeatable PowerShell GUI test scripts that use `potato-cli`.

## Required Workflow

Split the work into three explicit stages. Do not jump directly from reading the CSV to writing the final script.

### 1. Planning

1. Read `README.md` and `docs\GENERATED_SCRIPT_CONTRACT.md`.
2. Parse the testcase CSV. Required columns are `Action`, `Data`, and `Expected Result`.
3. Create or use a run folder with `input`, `generated`, `evidence`, `logs`, and `results` subfolders.
4. Produce a short working plan: map each CSV row to the likely GUI operations, expected selectors, evidence to capture, and unknowns that must be explored.

### 2. Exploration

1. Explore the interactive Windows desktop using `..\potato-cli\potato.ps1` commands only.
2. Perform the required actions manually through the CLI to learn the real UI shape: windows, dialogs, selectors, control names, timing, and failure modes.
3. Capture screenshots or `observe` output when a selector, modal, or fallback decision matters.
4. Prefer GUI operations such as `click`, `select`, `hover`, `drag`, and `type`. Avoid hotkeys when a visible GUI route is practical, because these tests are intended to evaluate GUI automation. Use `hotkey` only for documented fallbacks, common application commands that are not reliably exposed through UI Automation, or recovery from a known state.

### 3. Development/Iteration

1. Generate a PowerShell script that follows the generated-script contract.
2. Dot-source `Framework\GeneratedScriptRuntime.ps1`; do not rewrite the generic PoTATo/result/cleanup helper layer in the generated script.
3. Run the generated script once unless the user explicitly asks for generation only.
4. Fix concrete script or CLI usage defects found during execution.
5. Optimize the script after it works: replace fixed sleeps with specific waits, remove redundant `observe`/screenshot calls that are not used as evidence, tighten selectors, prefer deterministic checks over broad reads, and reduce coordinate/hotkey fallbacks where reliable GUI selectors exist.
6. Make robustness improvements: handle expected dialogs/modals, preserve useful error context, keep cleanup idempotent, and avoid assumptions that only hold for the first run.
7. Add cleanup that runs at the end even when a step fails: close applications/windows opened by the script and remove fixed-path or external files/state created during the run that could affect the next execution.
8. Save results and evidence under the run folder using compact result JSON and full transcripts in execution-specific log files.
9. Report the generated script path, result JSON path, screenshots/evidence, cleanup actions, optimization notes, and any failing PoTATo JSON outputs.

## Allowed Automation Surface

Use only `potato-cli` commands for GUI operations:

`start`, `focus`, `windows`, `observe`, `select`, `click`, `click-coordinate`, `type`, `hotkey`, `drag`, `hover`, `wait-element`, `wait-file`, `read`, `screenshot`, `close-window`, `report`, `state`.

Do not import old PoTATo testcases, image recognition, Selenium, browser-specific automation, Jira/report-server code, VM tooling, or application-specific legacy helpers.

## Generated Script Rules

- Generated scripts must be PowerShell.
- Generated scripts must accept `-PotatoCliPath`, `-TestCaseCsv`, and `-RunRoot`.
- Generated scripts should also accept optional `-FrameworkRoot` and dot-source `Framework\GeneratedScriptRuntime.ps1`.
- Use runtime helpers such as `Initialize-AGTAGeneratedTest`, `Invoke-RecordedStep`, `Invoke-StepCommand`, `Invoke-EvidenceScreenshot`, `Invoke-TestCleanup`, and `Complete-AGTAGeneratedTest` instead of copying boilerplate helper functions.
- Generated scripts must emit one JSON result object to stdout.
- Each CSV row must map to one final step result.
- Step results must include `stepIndex`, `action`, `expectedResult`, `status`, `evidence`, `commands`, and `error`.
- Coordinate clicks are fallback only. If used, add a short comment and save a screenshot.
- Hotkeys are fallback or state-management tools, not the default interaction style. Prefer selector-based GUI actions whenever possible.
- Generated scripts must clean up after themselves before exiting. Preserve evidence under `RunRoot`, but close opened apps and delete files outside the run folder or fixed-path files that would make a later run non-repeatable.
- Generated scripts should be optimized for repeatable speed and robustness: use explicit waits instead of arbitrary sleeps, keep selectors specific, avoid unnecessary command noise, and retain enough evidence to debug failures.
- Generated scripts must create an `executionId`, write full command transcripts to `logs\potato-commands-<executionId>.jsonl`, and keep step `commands` entries compact. Do not embed full UI trees or full PoTATo responses in `result.json` or stdout.
- Do not rerun the full GUI script just to polish reporting after a successful behavioral run. Use a full rerun after automation behavior changes; use parse/static checks for cosmetic result formatting changes when safe.
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

The final JSON should also include cleanup information, either as a top-level `cleanup` field or under `artifacts.cleanup`, so rerun safety can be reviewed.
