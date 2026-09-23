# Session Agent Prompt

You are generating a repeatable PowerShell GUI test script from a CSV testcase.

Read:

- `AGENTS.md`
- `README.md`
- `docs\GENERATED_SCRIPT_CONTRACT.md`
- the testcase CSV supplied by the user

Use `..\potato_cli\potato.ps1` for all GUI exploration and actions. Do not use old PoTATo testcases or legacy automation libraries.

Begin with the generated-script template and CLI `help -Topic <command>`. Read implementation modules/application examples only for a specific unresolved question. Map each row to its required interaction route and expected-result assertion. User/testcase prohibitions override all fallback guidance below. Do not substitute shortcuts, clipboard, object models, process/file-association opening, or directly created output for required GUI actions. Keep desktop commands sequential and preserve failed-run evidence.

Workflow:

1. Planning: parse the CSV rows, create a run folder, and write down the likely GUI operations, unknown selectors/dialogs, required evidence, and expected validation checks.
2. Exploration: use PoTATo CLI commands to navigate the real UI and perform the required operations manually. Learn selectors, window titles, timing, modal behavior, and reliable verification points.
3. Development/Iteration: generate a PowerShell script under the run folder's `generated` directory, run it once, fix concrete script or CLI usage bugs only, optimize it for speed and robustness, and return paths to the generated script, result JSON, screenshots, cleanup actions, optimization notes, and any failed command JSON.

Generated scripts must dot-source `Framework\GeneratedScriptRuntime.ps1` and call `Initialize-AGTAGeneratedTest`. Use the shared runtime helpers for PoTATo invocation, compact command summaries, evidence, cleanup, step results, and final JSON writing. Do not copy those universal helper functions into each generated script; only write testcase-specific actions, selectors, assertions, and small app-specific helpers.

Prefer selector-based GUI actions over hotkeys. Use `hotkey` only when the visible GUI route is unreliable, unavailable through UI Automation, or needed to recover from a known state.

Initialize new scripts with `-RequireAssertions`. Assert expected state with `Assert-ExpectedResult`, `Assert-PotatoFound`, or `Assert-FileWait`; command success/screenshots alone cannot prove a step. Parse scripts and validate inputs before GUI execution. Use unique output paths and nonempty/stable file waits followed by content checks. Observe an ambiguous action's result before retrying it.

Generated scripts must clean up after themselves at the end even when the testcase does not ask for cleanup. Close applications/windows opened by the script and delete fixed-path or external files/state that could affect a later run. Preserve screenshots, transcripts, result JSON, and intentional evidence under the run folder.

After the script is functionally correct, perform an optimization pass. Prefer explicit `wait-element` or `wait-file` conditions over arbitrary sleeps, tighten selectors, remove unused exploratory commands, keep evidence capture intentional, and make known dialog handling deterministic.

The generated script must write exactly one compact JSON result object to stdout and save the same object to `results\result.json`. Full PoTATo responses must go to an execution-specific command log, not into step `commands`.

Use a full GUI rerun after automation behavior changes. If a successful run only needs cosmetic reporting cleanup, prefer parse/static checks or targeted validation instead of another full rerun.
