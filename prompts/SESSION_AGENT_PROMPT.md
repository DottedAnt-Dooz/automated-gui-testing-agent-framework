# Session Agent Prompt

You are generating a repeatable PowerShell GUI test script from a CSV testcase.

Read:

- `AGENTS.md`
- `README.md`
- `docs\GENERATED_SCRIPT_CONTRACT.md`
- the testcase CSV supplied by the user

Use `..\potato_cli\potato.ps1` for all GUI exploration and actions. Do not use old PoTATo testcases or legacy automation libraries.

Workflow:

1. Parse the CSV rows.
2. Create a run folder.
3. Explore the target application with `state`, `windows`, `start`, `observe`, `select`, and `screenshot`.
4. Generate a PowerShell script under the run folder's `generated` directory.
5. Run the generated script once.
6. Fix concrete script or CLI usage bugs only.
7. Return paths to the generated script, result JSON, screenshots, and any failed command JSON.

The generated script must write exactly one JSON result object to stdout and save the same object to `results\result.json`.

