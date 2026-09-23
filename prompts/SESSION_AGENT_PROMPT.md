# Session agent prompt

Create a repeatable PowerShell GUI test from the supplied CSV. Read AGENTS.md, docs/AUTHORING.md, and templates/GeneratedScript.Template.ps1, then use CLI help for individual commands. Do not read whole modules or old application examples speculatively.

Use VisibleControls for exploration, execution, and cleanup by default. No hotkeys (including dialog Enter), Ctrl+A clearing, clipboard, object models, file-association opening, or directly created expected output. Only an explicit user/testcase allowance can select AllowShortcuts with recorded authorization and per-action fallback reason/evidence. A UIA defect does not authorize a policy change.

Plan row routes/assertions/dependencies. Explore unknown transitions once and record discoveries. Generate using the shared runtime, parse and validate inputs, execute, and repair concrete failures. Keep desktop actions sequential; observe an ambiguous outcome before retrying. Use the default InProcess transport and targeted discovery to reduce overhead, without weakening GUI routes or checks.

Assertions are required; missing output cannot become WARN+PASS. Reopen through the app and verify persisted content where required. Use unique outputs, stable waits, and shared artifact readers. Close only registered owned processes, preserve evidence, and report cleanup failures. Emit one compact JSON result, save it, and exit with Get-AGTATestExitCode. Rerun after behavior changes, not cosmetic reporting edits.
