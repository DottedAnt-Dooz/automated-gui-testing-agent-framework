# Authoring entry point

Read this page, the supplied CSV, and `templates/GeneratedScript.Template.ps1`. Skip unrelated testcase CSVs and application examples. Use CLI `help -Topic <command>` for a specific command. Do not read whole implementation modules or application examples without an unresolved defect.

## Interaction policy

The default is **VisibleControls**, in exploration, generated execution, and cleanup. Use visible menus, buttons, and writable text fields. No hotkeys (including Enter to submit a dialog), Ctrl+A clearing, clipboard, object models, file-association opening, or direct creation of expected output. `type` sends literal text; it checks focus, application ownership, and writability. Newlines/tabs are allowed only in Document controls. `-PreDelete` selects text through UIA and presses Backspace; unsupported selection must fail rather than silently use Ctrl+A.

Only an explicit user/testcase allowance may select `AllowShortcuts`. Set `-InteractionPolicy AllowShortcuts -PolicyReason '<authorization>'` at runtime initialization/authoring launch. Every shortcut command then requires `-FallbackReason '<observed limitation>' -FallbackEvidence '<screenshot or observation reference>'`. Neither convenience nor a failed selector authorizes changing policy. Clipboard remains unsupported. Never use a per-command policy override in a generated script.

CLI calls from a shell use VisibleControls by default. For an authorized relaxed run, pass `-InteractionPolicy AllowShortcuts` on exploration commands too. Record the same policy in the generated script. Compare elapsed time only between runs with identical interaction constraints and assertions.

## Minimal workflow

1. Map each row to its GUI route, expected assertion, dependencies, and unknowns. Create input/generated/evidence/logs/results folders.
2. Explore only unknown transitions. Query a bounded set by label before guessing its ControlType. Reuse observations while the UI state is unchanged; prefer a targeted read/wait over another whole tree. Record selectors, expected state, and the evidence reference in `logs/discoveries.md`.
3. Generate from the template using the shared runtime. Run `./Get-RuntimeHelp.ps1 -Name <helper>` for complete helper signatures and source paths; it emits JSON without nested PowerShell quoting. The runtime imports helper files, so searching only the main runtime file cannot prove a helper is absent. Run `./Test-GeneratedScript.ps1 -ScriptPath <file> -TestCaseCsv <csv> -PotatoCliPath <cli>` before execution; the template and API authoring tools also preflight automatically. Execute once, fix concrete failures, then rerun after behavior changes. Do not rerun only to polish reporting.

After an action, wait for a specific UI/file postcondition instead of a fixed sleep. Desktop calls remain sequential. The CLI serializes overlapping commands with a bounded desktop mutex; this is not permission to run concurrent workflows. `outcome:unknown` means inspect the postcondition before retrying. Provider calls can outlast selector timeouts; no automatic retry of submissions or typing.

For interactive shell exploration, use `potato-stream.ps1` when the shell supports clean, non-echoing persistent pipes: one JSON request per line, read its response before sending the next. A one-shot pipeline can also run several already-known sequential commands in one process. An echoing terminal may wrap or decorate JSON, so use `potato.ps1` there. Generated scripts already use the in-process transport.

`start` confirms a process and possibly a window, not a ready landing screen. Inspect the visible controls or wait for the next expected control, then choose the route for the observed state. `wait-element -ControlType Window` includes the working window itself; assert `data.exists`. Do not infer one application's initial state from a previous launch.

## Runtime helpers

```powershell
$Context = Initialize-AGTAGeneratedTest -PotatoCliPath $PotatoCliPath -TestCaseCsv $TestCaseCsv -RunRoot $RunRoot
$results += Invoke-RecordedStep -StepIndex 1 -Body {
    param([ref] $Commands, [ref] $Evidence)
    # Invoke-StepCommand; Assert-PotatoOk checks dispatch, not the expected result.
    # Assert-ExpectedResult compares actual UI state/content with the CSV expectation.
}
$cleanup = @(Invoke-TestCleanup) # place in finally
Complete-AGTAGeneratedTest -StepResults $results -Cleanup $cleanup
exit (Get-AGTATestExitCode)
```

- `Invoke-StepCommand -Commands $Commands -Command <name> -Arguments @(...)` records compact summaries and full execution-specific transcripts. `type` with an explicit selector uses `-FocusMethod Auto`: it checks writability, tries UIA focus, then visibly clicks the field only if focus is unconfirmed. It verifies focus before sending text, so a separate click is usually unnecessary. `type -Verify` polls readback for up to 3000 ms by default; use `-VerifyMode NormalizedExact|NormalizedContains` for multiline text. `-VerifyTimeoutMs` controls readback, while `-TimeoutMs` controls selector lookup. A failed readback does not resend input. The default InProcess transport avoids a new PowerShell process for every command; `-Transport Process` remains available for compatibility comparisons.
- `Invoke-StepClick -Commands $Commands -Arguments @(<selector>)` records the click and checks dispatch. It defaults to `-Method Auto`, which uses a supported UIA action or visible mouse click. Supply `-Method Invoke` only after confirming InvokePattern in `select`/`observe`; an unsupported explicit method fails with the available patterns. Assert the resulting application state separately.
- Start in a clean session. Runtime `start` requires a new application process, waits briefly for a closing prior instance, and automatically registers its owned PID and start time for cleanup. Do not add a redundant manual registration or remove ownership tracking to work around a failure; inspect `ownedProcessId` if ownership is unclear. Cleanup never closes by broad process name. Create a fresh document through its visible route, even if some document is already present.
- Scope dialog input with `-PathJson`/`-SelectorJson` and `-ProcessId`. `-ModalOnly` restricts a selector to modal-window descendants. Confirm a text target is editable, and scope optional prompt dismissal to the owned process and dialog. `windows -ProcessId` reports `isModal`; modal windows may be nested beneath their owner in UIA, and cleanup closes them before the parent.
- `Assert-ExpectedResult -Condition <bool> -Message <expectation>` records a required assertion. `Assert-PotatoFound` checks existence; it does not prove document content. Assertions default on; catching a failed assertion cannot turn the step into PASS.
- For asynchronous outputs: use a unique execution path, `wait-file -MinBytes 1 -StableMs 500`, then `Assert-FileWait -Result $wait [-Message <expectation>]`; the assertion reads the path from the wait result, and `-Path` remains available. Use `Read-AGTAArtifactBytes -Path ... -Count ...` or `Assert-ArtifactPrefix -ExpectedBytes ...` for bounded reads with sharing/retries. Generated-script preflight rejects direct `[IO.File]::ReadAllBytes`, which may fail while an application holds the output open. A signature alone is not a content check. Reopen through the app and read the execution marker back when content persistence is required.
- Verify selected output destinations through UIA value/selection state, not merely a button Name or an exploration screenshot of the default setting.
- `Invoke-EvidenceScreenshot` records useful evidence; it is not itself an assertion. `Register-CreatedExternalPath` is for outputs created by this execution; never register pre-existing user files.
- Final success requires all CSV rows exactly once, passing assertions, policy compliance, and successful cleanup. Missing output fails; no WARN+PASS. JSON and process exit status must agree.

Result timing reports command wrapper/backend time, wait-command time, cleanup, and other elapsed time. Cleanup and wait timings overlap command totals; do not add them all together. Optimize repeated discovery and transport first; retain the required GUI routes and checks.
