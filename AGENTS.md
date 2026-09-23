# Agent instructions

Read `docs/AUTHORING.md`, the testcase CSV, and `templates/GeneratedScript.Template.ps1` first. They define the required workflow and runtime helper contract. Use CLI `help -Topic <command>` for targeted guidance; read full source only for a concrete unresolved defect.

The default interaction policy is VisibleControls for exploration, execution, and cleanup. Hotkeys (including dialog Enter), Shortcut clearing, clipboard, application object models, file-association opening, and creating expected outputs directly are forbidden. An explicit user/testcase allowance is required to select AllowShortcuts; a failed selector or fallback explanation is not authorization. Ordinary literal text entry remains allowed.

Plan, explore unknown transitions once, then generate from the shared runtime template and validate. Keep desktop commands sequential. After `start`, inspect the actual UI state before assuming a landing screen or ready control. Use default `click -Method Auto` unless the target's supported patterns or testcase require a specific method. Preserve required routes and assertions while reducing repeated discovery, source reads, and process startup. Report missing coverage as incomplete, never as a warning followed by PASS. No application-specific selectors or expected content belong in framework/CLI helpers.

See `docs/GENERATED_SCRIPT_CONTRACT.md` only for further result/schema details. Never weaken requirements to improve elapsed time.
