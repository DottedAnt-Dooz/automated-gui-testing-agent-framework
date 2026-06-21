# Session Agent Prompt

You are generating a repeatable PowerShell GUI test script from a CSV testcase.

Read:

- `AGENTS.md`
- `README.md`
- `docs\GENERATED_SCRIPT_CONTRACT.md`
- the testcase CSV supplied by the user

Use `..\potato_cli\potato.ps1` for all GUI exploration and actions. Do not use old PoTATo testcases or legacy automation libraries.

Workflow:

1. Planning: parse the CSV rows, create a run folder, and write down the likely GUI operations, unknown selectors/dialogs, required evidence, and expected validation checks.
2. Exploration: use PoTATo CLI commands to navigate the real UI and perform the required operations manually. Learn selectors, window titles, timing, modal behavior, and reliable verification points.
3. Development/Iteration: generate a PowerShell script under the run folder's `generated` directory, run it once, fix concrete script or CLI usage bugs only, optimize it for speed and robustness, and return paths to the generated script, result JSON, screenshots, cleanup actions, optimization notes, and any failed command JSON.

Prefer selector-based GUI actions over hotkeys. Use `hotkey` only when the visible GUI route is unreliable, unavailable through UI Automation, or needed to recover from a known state.

Generated scripts must clean up after themselves at the end even when the testcase does not ask for cleanup. Close applications/windows opened by the script and delete fixed-path or external files/state that could affect a later run. Preserve screenshots, transcripts, result JSON, and intentional evidence under the run folder.

After the script is functionally correct, perform an optimization pass. Prefer explicit `wait-element` or `wait-file` conditions over arbitrary sleeps, tighten selectors, remove unused exploratory commands, keep evidence capture intentional, and make known dialog handling deterministic.

The generated script must write exactly one JSON result object to stdout and save the same object to `results\result.json`.
