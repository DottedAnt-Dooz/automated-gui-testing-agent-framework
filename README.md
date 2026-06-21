# Automated GUI Testing Agent Framework

PowerShell-only framework for turning CSV testcase descriptions into repeatable GUI automation scripts that use `potato_cli`.

## Workflows

### 1. Agent Session Workflow

Use this when a coding agent such as Codex, Copilot, or Hermes is running in an interactive Windows desktop session.

1. Point the agent at this folder.
2. Provide a testcase CSV, for example `Microsoft Paint.csv`.
3. Ask the agent to generate and validate a PowerShell GUI test script.
4. The agent should follow `AGENTS.md` and `docs\GENERATED_SCRIPT_CONTRACT.md`.

### 2. API Workflow

Use this when a model is called through an API and the framework owns tool execution.

Graphical launcher:

```powershell
cd C:\diplomamunka\automated-gui-testing-agent-framework
.\Invoke-AgentAuthoringGui.ps1
```

The GUI lets a user load a CSV, preview and edit testcase rows, edit the system prompt and optional user prompt override, choose the API vendor, set the model/API key, and launch authoring.

Command-line launcher:

```powershell
cd C:\diplomamunka\automated-gui-testing-agent-framework
.\Invoke-AgentAuthoring.ps1 -TestCaseCsv ".\Microsoft Paint.csv" -Provider OpenAI -Model "gpt-5.5" -Execute
```

For a no-network dry run:

```powershell
.\Invoke-AgentAuthoring.ps1 -TestCaseCsv ".\Microsoft Paint.csv" -Provider Mock
```

The OpenAI provider reads `OPENAI_API_KEY` from the environment and uses the Responses API with function tools. The tool loop is allowlisted: the model can read the testcase, run PoTATo commands, write a generated script, run that script when `-Execute` is set, read run artifacts, and finalize.

OpenAI API references:

- [Responses API](https://developers.openai.com/api/reference/responses/overview/)
- [Function calling](https://developers.openai.com/api/docs/guides/function-calling)
- [Agents SDK](https://developers.openai.com/api/docs/guides/agents)

## Folder Layout

- `Framework\AutomatedGuiTestingAgentFramework.psm1` - runtime module.
- `Invoke-AgentAuthoring.ps1` - API/mock orchestration entrypoint.
- `Invoke-AgentAuthoringGui.ps1` - WinForms launcher for API-driven authoring.
- `docs\GENERATED_SCRIPT_CONTRACT.md` - required generated script format.
- `prompts\SESSION_AGENT_PROMPT.md` - prompt for robust coding agents.
- `examples\MicrosoftPaint.Reference.ps1` - reference output script style.
- `tests\Framework.Tests.ps1` - Pester 3-compatible tests.
- `runs\` - generated runtime artifacts, ignored by git.

## Required CSV Columns

```csv
Action,Data,Expected Result
Open Paint,,Paint opened
```

Optional columns are accepted and preserved when present:

- `StepId`
- `Application`
- `Notes`

## Common Commands

Run tests:

```powershell
Invoke-Pester -Script .\tests -EnableExit:$false
```

Create a run folder:

```powershell
Import-Module .\Framework\AutomatedGuiTestingAgentFramework.psm1 -Force
New-AGTARunDirectory -TestCaseCsv ".\Microsoft Paint.csv"
```

Invoke PoTATo safely:

```powershell
Invoke-AGTAPotatoJson -PotatoCliPath "..\potato_cli\potato.ps1" -Command "state" -RunRoot ".\runs\manual"
```

## Environment Assumptions

v1 assumes the VM is already logged into an interactive desktop. It does not restore checkpoints, call LoginAgent, unlock the desktop, or install applications.
