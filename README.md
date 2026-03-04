# Ralph Loop

An autonomous AI agent loop for building applications from a PRD.
Inspired by [snarktank/ralph](https://github.com/snarktank/ralph).

## How it works

Ralph runs your AI coding tool (Claude Code, Amp, or OpenCode) in a loop — each
iteration gets a fresh context and picks up where the previous one left off by
reading shared state files. It keeps iterating until every user story in the PRD
passes its acceptance criteria.

```
┌─────────────────────────────────────┐
│            ralph.ps1                │
│                                     │
│  1. Read prd.json (find pending)    │
│  2. Run claude/amp with CLAUDE.md   │◄──┐
│  3. Agent works, commits, signals   │   │
│  4. Check <promise>COMPLETE</promise>│  │ loop
│  5. Re-read prd.json                │   │
│  6. All passing? → exit             │   │
│  7. Otherwise → iterate             │───┘
└─────────────────────────────────────┘
```

## Requirements

- **PowerShell Core (`pwsh`)** — runs on Windows, macOS, and Linux
  - Windows: included with Windows 10/11, or [download here](https://aka.ms/powershell)
  - macOS: `brew install --cask powershell`
  - Linux: [Microsoft install guide](https://learn.microsoft.com/en-us/powershell/scripting/install/installing-powershell-on-linux)
- At least one AI coding tool: `claude`, `amp`, or `opencode`

## Quick Start

### 1. Drop `ralph/` into your project

```bash
# Copy the folder into any project root
cp -r path/to/ralph ./ralph
```

### 2. Set up your PRD

```bash
cp ralph/prd.json.example ralph/prd.json
```

Edit `ralph/prd.json` to describe your feature as user stories.

### 3. Customise the prompt

Edit `ralph/CLAUDE.md` to add your project's:
- Tech stack
- Build / test / lint commands
- Known conventions

### 4. Run Ralph

**macOS / Linux:**
```bash
chmod +x ralph/ralph.sh
./ralph/ralph.sh

# OpenCode + specific model
./ralph/ralph.sh -Tool opencode -Model openai/gpt-4o
./ralph/ralph.sh -Tool opencode -Model ollama/qwen2.5-coder   # local via Ollama

# Automatic model fallback chain — switches when a rate-limit is hit
./ralph/ralph.sh -Tool opencode -Models anthropic/claude-sonnet-4-5,openai/gpt-4o,ollama/llama3.3

# Use Amp
./ralph/ralph.sh -Tool amp -Max 15

# Help
./ralph/ralph.sh -Help
```

**Windows (PowerShell):**
```powershell
.\ralph\ralph.ps1

# OpenCode + specific model
.\ralph\ralph.ps1 -Tool opencode -Model openai/gpt-4o
.\ralph\ralph.ps1 -Tool opencode -Model ollama/qwen2.5-coder   # local via Ollama

# Automatic model fallback chain — switches when a rate-limit is hit
.\ralph\ralph.ps1 -Tool opencode -Models anthropic/claude-sonnet-4-5,openai/gpt-4o,ollama/llama3.3

# Use Amp
.\ralph\ralph.ps1 -Tool amp -Max 15

# Help
.\ralph\ralph.ps1 -Help
```

## File Structure

Everything lives inside `ralph/` — copy the whole folder into any project.

```
ralph/
  ralph.ps1         ← Main loop script        (all platforms via pwsh)
  ralph.sh          ← Shell wrapper            (macOS / Linux entry point)
  prd.json          ← Your task list           (copy from prd.json.example)
  prd.json.example  ← Template
  CLAUDE.md         ← Prompt for Claude Code / OpenCode
  prompt.md         ← Prompt for Amp
  AGENTS.md         ← Codebase patterns        (auto-updated by agent)
  progress.txt      ← Append-only iteration log (auto-created)
  archive/          ← Previous runs            (auto-created)
```

## prd.json format

```json
{
  "project": "MyApp",
  "branchName": "ralph/my-feature",
  "description": "What this Ralph run builds",
  "userStories": [
    {
      "id": "US-001",
      "title": "Short title",
      "description": "As a user, I need X so that Y.",
      "acceptanceCriteria": [
        "Specific, testable criterion",
        "All tests pass"
      ],
      "priority": 1,
      "passes": false,
      "notes": ""
    }
  ]
}
```

- `priority`: Lower numbers run first.
- `passes`: Set to `true` by the agent when the story is complete.
- Each story should fit within one LLM context window — split large features.

## Supported tools & models

| `-Tool`    | CLI required | Model selection |
|------------|-------------|-----------------|
| `claude`   | `claude`    | Configured in Claude Code settings |
| `amp`      | `amp`       | Configured in Amp settings |
| `opencode` | `opencode`  | `-Model provider/model-id` or `opencode.json` default |

### OpenCode model examples (`-Model`)

| Provider | Example value |
|----------|--------------|
| Anthropic | `anthropic/claude-sonnet-4-5` |
| OpenAI | `openai/gpt-4o` |
| Google | `google/gemini-2.0-flash` |
| Ollama (local) | `ollama/qwen2.5-coder` |
| Ollama (local) | `ollama/llama3.3` |

OpenCode supports 75+ providers. See [opencode.ai/docs/models](https://opencode.ai/docs/models/) for the full list.

## Completion signal

The agent signals the loop by outputting one of:

| Signal | Meaning |
|--------|---------|
| `<promise>COMPLETE</promise>` | All stories pass — Ralph exits successfully |
| `<promise>CONTINUE</promise>` | More work to do — Ralph iterates again |

## Tips

- **Right-size stories**: Each story should be completable in one iteration.
  "Build the entire dashboard" is too big; "Add priority column to DB" is right.
- **Quality gates matter**: If tests are broken, each iteration inherits the
  mess. Keep typecheck/tests green at every commit.
- **Read `progress.txt`**: After a run, this file shows what happened in each
  iteration and is a useful debugging tool.
- **Increase `-Max`** for complex features; decrease it for quick tasks.
