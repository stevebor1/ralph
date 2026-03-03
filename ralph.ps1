#!/usr/bin/env pwsh
# Ralph Wiggum - Autonomous AI agent loop for building applications from PRDs
# Inspired by: https://github.com/snarktank/ralph
#
# Self-contained: copy the entire ralph/ folder into any project, then run:
#   .\ralph\ralph.ps1
#   .\ralph\ralph.ps1 -Tool claude -Max 20
#   .\ralph\ralph.ps1 -Tool opencode -Model openai/gpt-4o
#   .\ralph\ralph.ps1 -Tool opencode -Model ollama/qwen2.5-coder   # local model
#
# Automatic model fallback (switches on rate-limit / quota errors):
#   .\ralph\ralph.ps1 -Tool opencode -Models anthropic/claude-sonnet-4-5,openai/gpt-4o,ollama/qwen2.5-coder

param(
    [ValidateSet("claude", "amp", "opencode")]
    [string]$Tool = "claude",

    # Single model shorthand (opencode only). Equivalent to -Models with one entry.
    # Examples: anthropic/claude-sonnet-4-5  |  openai/gpt-4o  |  ollama/qwen2.5-coder
    [string]$Model = "",

    # Ordered fallback chain of models (opencode only).
    # Ralph automatically steps to the next model when a rate-limit or quota error
    # is detected. Once all models are exhausted it pauses then cycles from the top.
    # Pass as comma-separated string or repeated flags:
    #   -Models anthropic/claude-sonnet-4-5,openai/gpt-4o,ollama/llama3.3
    [string[]]$Models = @(),

    # Maximum loop iterations before giving up.
    [int]$Max = 10,

    # Seconds to wait before retrying after all models are rate-limited.
    [int]$RateLimitCooldown = 60,

    # Show full agent output instead of just the last 20 lines
    [switch]$Verbose,

    # Interactive mode: press any key during execution to toggle verbose output
    [switch]$Interactive,

    # Re-verify all completed stories (skip build loop)
    [switch]$VerifyAll,

    # Run an alternate PRD/prompt pair.  Built-in presets:
    #   qa  — uses ralph/qa-prd.json + ralph/QA.md (API calls, UI, Playwright)
    # Or pass any base name: -Prd fix uses ralph/fix-prd.json + ralph/FIX.md
    [string]$Prd = "",

    [switch]$Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Force UTF-8 throughout so agent output (em dashes, arrows, etc.) renders correctly
chcp 65001 | Out-Null
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::InputEncoding  = [System.Text.Encoding]::UTF8
$OutputEncoding            = [System.Text.Encoding]::UTF8

# ── Dev server cleanup ────────────────────────────────────────────────────────
# Kills any process holding a given port. Called after each iteration and on exit.
function Stop-DevServer([int[]]$Ports = @(3000)) {
    foreach ($port in $Ports) {
        $pids = netstat -ano 2>$null |
                Select-String ":$port\s" |
                ForEach-Object { ($_ -split '\s+')[-1] } |
                Where-Object { $_ -match '^\d+$' } |
                Sort-Object -Unique
        foreach ($p in $pids) {
            try {
                Stop-Process -Id ([int]$p) -Force -ErrorAction SilentlyContinue
                Write-Step "Killed process $p on port $port"
            } catch { }
        }
    }
}

# Guarantee cleanup on script exit (Ctrl+C, error, or normal finish)
$null = Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action { Stop-DevServer }

# ── Paths ─────────────────────────────────────────────────────────────────────
# ralph.ps1 lives INSIDE the ralph/ folder, so $ScriptDir IS the ralph dir.
# Copy the entire ralph/ folder to any project and run .\ralph\ralph.ps1.

$RalphDir      = Split-Path -Parent $MyInvocation.MyCommand.Path

# Resolve PRD and prompt files — overridden by -Prd if supplied
if ($Prd -ne "") {
    $prdBase      = $Prd.ToLower()
    $PrdFile      = Join-Path $RalphDir "$prdBase-prd.json"
    $PromptFile   = Join-Path $RalphDir "$($Prd.ToUpper()).md"   # e.g. QA.md
    $ProgressFile = Join-Path $RalphDir "$prdBase-progress.txt"
    $VerifyFile   = Join-Path $RalphDir "VERIFY.md"
    $AmpPrompt    = Join-Path $RalphDir "$prdBase-prompt.md"
} else {
    $PrdFile      = Join-Path $RalphDir "prd.json"
    $PromptFile   = Join-Path $RalphDir "CLAUDE.md"
    $ProgressFile = Join-Path $RalphDir "progress.txt"
    $VerifyFile   = Join-Path $RalphDir "VERIFY.md"
    $AmpPrompt    = Join-Path $RalphDir "prompt.md"
}

$ArchiveDir    = Join-Path $RalphDir  "archive"
$LastBranch    = Join-Path $RalphDir  ".last-branch"

# ── Help ──────────────────────────────────────────────────────────────────────

if ($Help) {
    Write-Host @"
Ralph - Autonomous AI agent loop
=================================
Runs an AI coding tool in a loop until all PRD tasks pass.
Automatically switches models when rate limits are hit.

Usage:
  .\ralph.ps1 [-Tool <claude|amp|opencode>] [-Model <m>] [-Models <m1,m2,...>]
              [-Max <n>] [-RateLimitCooldown <seconds>] [-Help]

Options:
  -Tool      AI tool to use (default: claude)
               claude    - Claude Code  (requires: claude CLI)
               amp       - Amp          (requires: amp CLI)
               opencode  - OpenCode     (requires: opencode CLI, 75+ providers)

  -Model     Single model for opencode (shorthand for -Models with one entry)
              Run 'opencode models' to see all available. Examples:
                opencode/minimax-m2.5-free    (default, free)
                opencode/gpt-5-nano           (free tier)
                anthropic/claude-sonnet-4-5
                anthropic/claude-opus-4-5
                anthropic/claude-haiku-4-5

  -Models    Ordered fallback chain for opencode. Ralph steps to the next model
             automatically whenever a rate-limit or quota error is detected.
             Comma-separated or repeated -Models flags:
               -Models opencode/minimax-m2.5-free,anthropic/claude-sonnet-4-5

  -Max       Maximum loop iterations (default: 10)

  -RateLimitCooldown
              Seconds to wait after all models are exhausted before cycling back
              to the first model (default: 60)

  -Verbose, -V
              Show full agent output instead of just last 20 lines

  -Interactive, -I
              Interactive mode: press any key during execution to toggle
              verbose output (useful for monitoring progress)

  -VerifyAll   Re-verify all completed stories (skip build loop). Use this
                to double-check that all completed tasks still pass.

  -Help      Show this message

Required files:
  ralph/prd.json    Task list with user stories
  ralph/CLAUDE.md   Prompt for Claude Code / OpenCode
  ralph/prompt.md   Prompt for Amp

Output:
  ralph/progress.txt  Append-only iteration log
  ralph/AGENTS.md     Codebase patterns (updated by agent)

Examples:
  # Single model (uses OpenCode's free minimax model by default)
  .\ralph.ps1 -Tool opencode

  # With specific model
  .\ralph.ps1 -Tool opencode -Model anthropic/claude-sonnet-4-5

  # Auto-fallback chain: free model first, then paid
  .\ralph.ps1 -Tool opencode -Models opencode/minimax-m2.5-free,anthropic/claude-sonnet-4-5

  # Claude Code (no model selection needed)
  .\ralph.ps1 -Tool claude -Max 20
"@
    exit 0
}

# ── Resolve model list ────────────────────────────────────────────────────────
# Normalise -Model / -Models into a single ordered array $ModelChain.
# Empty chain = no --model flag passed to opencode (uses its configured default).

if ($Models.Count -gt 0) {
    # -Models may arrive as one comma-joined string from the shell; split it.
    $ModelChain = $Models | ForEach-Object { $_ -split "," } |
                            ForEach-Object { $_.Trim() } |
                            Where-Object   { $_ -ne "" }
} elseif ($Model -ne "") {
    $ModelChain = @($Model)
} else {
    $ModelChain = @()   # use opencode default / not applicable for claude/amp
}

# Current position in the fallback chain (script-scoped so helpers can mutate it)
$script:ModelIndex = 0

# Verbose output state (can be toggled in interactive mode)
$script:Verbose = $Verbose

function Get-VerboseState {
    return $script:Verbose
}

function Toggle-Verbose {
    $script:Verbose = -not $script:Verbose
    if ($script:Verbose) {
        Write-Host "  ~~ Verbose mode: ON (showing full output)" -ForegroundColor Cyan
    } else {
        Write-Host "  ~~ Verbose mode: OFF (showing last 20 lines)" -ForegroundColor DarkGray
    }
}

function Get-ActiveModel {
    if ($ModelChain.Count -eq 0) { return "" }
    return $ModelChain[$script:ModelIndex % $ModelChain.Count]
}

function Get-ModelLabel {
    $m = Get-ActiveModel
    if ($m -eq "") { return "" }
    if ($ModelChain.Count -gt 1) {
        return " | Model [$($script:ModelIndex % $ModelChain.Count + 1)/$($ModelChain.Count)]: $m"
    }
    return " | Model: $m"
}

# ── Usage exhaustion detection ────────────────────────────────────────────────
# Claude Pro/Max shows this when the user has burned their monthly/daily quota.
# Unlike rate limits (which recover in minutes), these reset at a fixed time.
# Detect and exit immediately rather than spinning and making empty commits.

$UsageExhaustedPatterns = @(
    "out of extra usage",
    "you.re out of",
    "usage.*resets",
    "out of usage"
)

function Test-UsageExhausted([string]$Output) {
    foreach ($pat in $UsageExhaustedPatterns) {
        if ($Output -imatch $pat) { return $true }
    }
    return $false
}

# ── Rate-limit detection ──────────────────────────────────────────────────────
# Returns $true when the tool output indicates a rate-limit / quota error.

$RateLimitPatterns = @(
    "rate.?limit",          # rate limit / rate_limit / ratelimit
    "429",                  # HTTP Too Many Requests
    "too many requests",
    "quota.?exceeded",
    "quota_exceeded",
    "resource_exhausted",   # Google / gRPC
    "model_overloaded",
    "overloaded",           # Anthropic
    "capacity exceeded",
    "tokens per minute",
    "requests per minute",
    "rpm limit",
    "tpm limit",
    "retry after",
    "please slow down",
    "context_length_exceeded"  # model context too small — try a bigger one
)

function Test-RateLimit([string]$Output) {
    foreach ($pat in $RateLimitPatterns) {
        if ($Output -imatch $pat) { return $true }
    }
    return $false
}

# Step to the next model. Returns $true if we wrapped around (all models hit).
function Step-NextModel([int]$Iteration, [string]$Reason) {
    $from = Get-ActiveModel
    $script:ModelIndex++
    $wrapped = ($script:ModelIndex % $ModelChain.Count) -eq 0

    $to = Get-ActiveModel
    Write-Host ""
    Write-Host "  ~~ Rate limit / quota hit on: $from" -ForegroundColor DarkYellow
    if ($wrapped) {
        Write-Host "  ~~ All models exhausted. Cooling down ${RateLimitCooldown}s then cycling back." -ForegroundColor DarkYellow
        Write-Progress-Log "Iteration ${Iteration}: ALL MODELS HIT ($Reason) - cooling down ${RateLimitCooldown}s"
        Start-Sleep -Seconds $RateLimitCooldown
    } else {
        Write-Host "  ~~ Switching to: $to" -ForegroundColor Cyan
        Write-Progress-Log "Iteration ${Iteration}: RATE LIMIT on $from ($Reason) - switching to $to"
    }
    return $wrapped
}

# ── Display helpers ───────────────────────────────────────────────────────────

function Write-Banner([string]$Text, [ConsoleColor]$Color = "Cyan") {
    $line = "=" * 65
    Write-Host ""
    Write-Host $line -ForegroundColor $Color
    Write-Host "  $Text" -ForegroundColor $Color
    Write-Host $line -ForegroundColor $Color
}

function Write-Step([string]$Msg) { Write-Host "  >> $Msg" -ForegroundColor Yellow }
function Write-Ok([string]$Msg)   { Write-Host "  OK $Msg" -ForegroundColor Green  }
function Write-Err([string]$Msg)  { Write-Host "  !! $Msg" -ForegroundColor Red    }

# ── PRD helpers ───────────────────────────────────────────────────────────────

function Get-PrdBranch {
    if (-not (Test-Path $PrdFile)) { return "" }
    try   { return [string](Get-Content $PrdFile -Raw | ConvertFrom-Json).branchName }
    catch { return "" }
}

function Get-IncompleteTasks {
    if (-not (Test-Path $PrdFile)) { return @() }
    $prd = Get-Content $PrdFile -Raw | ConvertFrom-Json
    return @($prd.userStories | Where-Object { $_.passes -eq $false })
}

function Write-Progress-Log([string]$Entry) {
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -Path $ProgressFile -Value "[$ts] $Entry"
}

function Get-CompletedStoryIds {
    if (-not (Test-Path $PrdFile)) { return @() }
    $prd = Get-Content $PrdFile -Raw | ConvertFrom-Json
    return @($prd.userStories | Where-Object { $_.passes -eq $true } |
             ForEach-Object { $_.id })
}

function Build-VerifyPrompt([string[]]$StoryIds) {
    # Inject story details into VERIFY.md where the placeholder sits
    $prd = Get-Content $PrdFile -Raw | ConvertFrom-Json
    $details = ($StoryIds | ForEach-Object {
        $id    = $_
        $story = $prd.userStories | Where-Object { $_.id -eq $id }
        if (-not $story) { return }   # skip unknown IDs
        $criteria = ($story.acceptanceCriteria | ForEach-Object { "- $_" }) -join "`n"
        "### $($story.id): $($story.title)`n$($story.description)`n`nAcceptance Criteria:`n$criteria"
    } | Where-Object { $_ }) -join "`n`n"  # filter nulls before joining

    $template = Get-Content $VerifyFile -Raw
    return $template -replace "<!-- STORIES_TO_VERIFY -->", $details
}

function Invoke-VerifyIteration([string[]]$StoryIds) {
    if (-not (Test-Path $VerifyFile)) {
        Write-Step "ralph/VERIFY.md not found — skipping verification pass"
        return ""
    }
    $prompt = Build-VerifyPrompt $StoryIds

    [string[]]$out = @()
    if ($Tool -eq "claude") {
        $out = @($prompt | claude --dangerously-skip-permissions --print 2>&1)
    } elseif ($Tool -eq "opencode") {
        $out = @(Invoke-OpencodeRun $prompt)
    } else {
        $out = @($prompt | amp --dangerously-allow-all 2>&1)
    }
    return $out -join "`n"
}

function Ensure-RalphDir {
    if (-not (Test-Path $RalphDir)) {
        New-Item -ItemType Directory -Path $RalphDir | Out-Null
        Write-Ok "Created ralph/ directory"
    }
}

function Ensure-ProgressFile {
    if (-not (Test-Path $ProgressFile)) {
        @("# Ralph Progress Log", "Started: $(Get-Date)", "---") |
            Set-Content -Path $ProgressFile
    }
}

function Archive-PreviousRun([string]$BranchName) {
    $dest = Join-Path $ArchiveDir "$(Get-Date -Format 'yyyy-MM-dd')-$($BranchName -replace '^ralph/','')"
    Write-Step "Archiving previous run: $BranchName"
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
    foreach ($f in @($PrdFile, $ProgressFile)) {
        if (Test-Path $f) { Copy-Item $f $dest }
    }
    @("# Ralph Progress Log", "Started: $(Get-Date)", "---") |
        Set-Content -Path $ProgressFile
    Write-Ok "Archived to $dest"
}

# ── Tool invocation ───────────────────────────────────────────────────────────

function Invoke-ClaudeIteration {
    if (-not (Test-Path $PromptFile)) {
        Write-Err "Missing ralph/CLAUDE.md"; exit 1
    }
    $output = (Get-Content $PromptFile -Raw) |
              claude --dangerously-skip-permissions --print 2>&1
    return $output -join "`n"
}

function Invoke-AmpIteration {
    if (-not (Test-Path $AmpPrompt)) {
        Write-Err "Missing ralph/prompt.md"; exit 1
    }
    $output = (Get-Content $AmpPrompt -Raw) |
              amp --dangerously-allow-all 2>&1
    return $output -join "`n"
}

function Invoke-OpencodeIteration {
    if (-not (Test-Path $PromptFile)) {
        Write-Err "Missing ralph/CLAUDE.md"; exit 1
    }
    $promptContent = Get-Content $PromptFile -Raw
    return Invoke-OpencodeRun $promptContent
}

function Invoke-OpencodeRun([string]$Prompt) {
    $ocArgs = @("run", $Prompt)
    $active = Get-ActiveModel
    if ($active -ne "") { $ocArgs += "-m", $active }
    $ocArgs += "--format", "json"

    $jsonOutput = & opencode @ocArgs 2>&1 | Out-String
    return Parse-OpencodeJsonOutput $jsonOutput
}

function Parse-OpencodeJsonOutput([string]$JsonOutput) {
    $textParts = @()
    $lines = $JsonOutput -split "`n" | Where-Object { $_ -match "^\s*\{.*\}\s*$" }
    foreach ($line in $lines) {
        try {
            $obj = $line | ConvertFrom-Json
            if ($obj.type -eq "text" -and $obj.part.text) {
                $textParts += $obj.part.text
            }
        } catch { }
    }
    return $textParts -join "`n"
}

# ── Pre-flight ────────────────────────────────────────────────────────────────

Write-Banner "Ralph  |  Tool: $Tool$(Get-ModelLabel)  |  Max: $Max iterations"

if ($ModelChain.Count -gt 1) {
    Write-Host "  Fallback chain ($($ModelChain.Count) models):" -ForegroundColor Cyan
    for ($m = 0; $m -lt $ModelChain.Count; $m++) {
        Write-Host "    [$($m+1)] $($ModelChain[$m])" -ForegroundColor White
    }
}

Ensure-RalphDir

if (-not (Test-Path $PrdFile)) {
    Write-Err "ralph/prd.json not found."
    Write-Host "  Copy-Item ralph\prd.json.example ralph\prd.json"
    exit 1
}

# Archive if branch changed
$currentBranch = Get-PrdBranch
if ((Test-Path $LastBranch) -and ($currentBranch -ne "")) {
    $lastVal = (Get-Content $LastBranch -Raw).Trim()
    if ($lastVal -ne $currentBranch.Trim()) { Archive-PreviousRun $lastVal }
}
if ($currentBranch -ne "") { Set-Content -Path $LastBranch -Value $currentBranch }

Ensure-ProgressFile

# ── VerifyAll mode ────────────────────────────────────────────────────────────────
if ($VerifyAll) {
    $allStoryIds = Get-CompletedStoryIds
    if ($allStoryIds.Count -eq 0) {
        Write-Ok "No completed stories to verify."
        exit 0
    }
    Write-Banner "Re-verifying ALL completed stories: $($allStoryIds -join ', ')" "Magenta"
    Write-Progress-Log "VERIFY ALL: Starting verification of $($allStoryIds.Count) stories"

    $verifyOutput = Invoke-VerifyIteration $allStoryIds

    # Show full output
    Write-Host ""
    Write-Host "  --- Verify output ---" -ForegroundColor Cyan
    $verifyOutput -split "`n" | ForEach-Object { Write-Host "  $_" -ForegroundColor Gray }
    Write-Host "  --------------------" -ForegroundColor Cyan

    if ($verifyOutput -match "<verify>FAIL</verify>") {
        Write-Err "Verification FAILED — some stories were reverted"
        exit 1
    } else {
        Write-Ok "All $($allStoryIds.Count) stories verified successfully!"
        exit 0
    }
}

$incomplete = Get-IncompleteTasks
if ($incomplete.Count -eq 0) {
    Write-Ok "All PRD tasks already pass! Nothing for Ralph to do."
    exit 0
}

Write-Host ""
Write-Host "  Pending tasks ($($incomplete.Count)):" -ForegroundColor Magenta
foreach ($story in $incomplete) {
    Write-Host "    [ ] $($story.id) - $($story.title)" -ForegroundColor White
}

# ── Main loop ─────────────────────────────────────────────────────────────────

for ($i = 1; $i -le $Max; $i++) {
    Write-Banner "Iteration $i / $Max  |  Tool: $Tool$(Get-ModelLabel)" "DarkCyan"

    $remaining = Get-IncompleteTasks
    if ($remaining.Count -eq 0) {
        Write-Ok "All tasks marked passing. Ralph is done!"
        Write-Progress-Log "Iteration ${i}: All tasks complete"
        exit 0
    }

    $activeModel    = Get-ActiveModel
    $modelInfo      = if ($activeModel -ne "") { " [$activeModel]" } else { "" }
    Write-Step "Running $Tool$modelInfo ($($remaining.Count) tasks remaining)..."
    Write-Progress-Log "Iteration ${i}: Starting$modelInfo - $($remaining.Count) tasks pending"

    # Snapshot which stories are already passing before this iteration runs
    $passedBefore = Get-CompletedStoryIds

    # ── Invoke tool ───────────────────────────────────────────────────────────
    $output  = ""
    $toolErr = ""
    try {
        if ($Tool -eq "claude") {
            $output = Invoke-ClaudeIteration
        } elseif ($Tool -eq "opencode") {
            $output = Invoke-OpencodeIteration
        } else {
            $output = Invoke-AmpIteration
        }
    } catch {
        $toolErr = $_.Exception.Message
        $output  = $toolErr
    }

    # ── Usage exhaustion (Claude quota burned) ────────────────────────────────
    # Exit cleanly — no point committing or retrying until quota resets.
    if (Test-UsageExhausted $output) {
        Write-Host ""
        Write-Err "Claude usage quota exhausted (resets at midnight America/Los_Angeles)."
        Write-Host "  Ralph stopped at iteration $i with $($remaining.Count) tasks still pending." -ForegroundColor Yellow
        Write-Progress-Log "Iteration ${i}: STOPPED — quota exhausted, $($remaining.Count) tasks pending"
        exit 1
    }

    # ── Rate-limit detection & automatic model rotation ───────────────────────
    if ((Test-RateLimit $output) -and $Tool -eq "opencode" -and $ModelChain.Count -gt 0) {
        $reason = ($RateLimitPatterns | Where-Object { $output -imatch $_ } | Select-Object -First 1)
        Step-NextModel -Iteration $i -Reason $reason
        # Don't count this as a productive iteration — retry same iteration number
        $i--
        continue
    }

    # ── Ordinary tool error (not rate-limit) ──────────────────────────────────
    if ($toolErr -ne "") {
        Write-Err "Tool error: $toolErr"
        Write-Progress-Log "Iteration ${i}: ERROR - $toolErr"
        Write-Host "  Pausing 5 seconds before retry..." -ForegroundColor DarkYellow
        Start-Sleep -Seconds 5
        continue
    }

    # ── Show output (verbose or tail) ─────────────────────────────────────────────
    Write-Host ""
    if (Get-VerboseState) {
        Write-Host "  --- Agent output (full) ---" -ForegroundColor Cyan
        $outputLines = $output -split "`n"
        $outputLines | ForEach-Object { Write-Host "  $_" -ForegroundColor Gray }
        Write-Host "  --------------------------" -ForegroundColor Cyan
    } else {
        $tail = ($output -split "`n") | Select-Object -Last 20
        Write-Host "  --- Agent output (last 20 lines) ---" -ForegroundColor DarkGray
        $tail | ForEach-Object { Write-Host "  $_" -ForegroundColor Gray }
        Write-Host "  -------------------------------------" -ForegroundColor DarkGray
    }

    # Interactive mode: allow toggling verbose during pause
    if ($Interactive) {
        Write-Host ""
        Write-Host "  [Press any key to toggle verbose output, or q to quit]..." -ForegroundColor Yellow -NoNewline
        $key = $Host.UI.RawUI.ReadKey("NoEcho, IncludeKeyDown").Character
        Write-Host ""
        if ($key -eq "q" -or $key -eq "Q") {
            Write-Host "  Exiting Ralph..." -ForegroundColor Yellow
            exit 0
        } else {
            Toggle-Verbose
        }
    }

    # ── Completion signal ─────────────────────────────────────────────────────
    if ($output -match "<promise>COMPLETE</promise>") {
        Write-Ok "Completion signal received!"
        Write-Progress-Log "Iteration ${i}: COMPLETE signal received"
        exit 0
    }

    # ── Verification pass for newly completed stories ─────────────────────────
    $passedAfter  = Get-CompletedStoryIds
    $newlyPassed  = @($passedAfter | Where-Object { $passedBefore -notcontains $_ })

    if ($newlyPassed.Count -gt 0) {
        Write-Banner "Verifying $($newlyPassed.Count) newly completed story/stories: $($newlyPassed -join ', ')" "Magenta"
        Write-Progress-Log "Iteration ${i}: VERIFY START — $($newlyPassed -join ', ')"

        $verifyOutput = Invoke-VerifyIteration $newlyPassed

        # Show last 15 lines of verify output
        $verifyTail = ($verifyOutput -split "`n") |
                      Where-Object { $_ -notmatch '^\s*\{"level":' } |
                      Select-Object -Last 15
        Write-Host ""
        Write-Host "  --- Verify output (last 15 lines) ---" -ForegroundColor DarkGray
        $verifyTail | ForEach-Object { Write-Host "  $_" -ForegroundColor Gray }
        Write-Host "  -------------------------------------" -ForegroundColor DarkGray

        if ($verifyOutput -match "<verify>FAIL</verify>") {
            Write-Err "Verification FAILED — one or more stories reverted to passes: false"
            Write-Progress-Log "Iteration ${i}: VERIFY FAIL — reverted: $($newlyPassed -join ', ')"
            # Loop continues; reverted stories will be picked up next iteration
        } else {
            Write-Ok "Verification PASSED — $($newlyPassed -join ', ') confirmed"
            Write-Progress-Log "Iteration ${i}: VERIFY PASS — confirmed: $($newlyPassed -join ', ')"
        }
    }

    # ── Port cleanup ──────────────────────────────────────────────────────────
    # Kill any dev server the agent started but forgot to stop.
    Stop-DevServer

    Write-Progress-Log "Iteration ${i}: Done$modelInfo"
    Write-Step "Pausing 2 seconds..."
    Start-Sleep -Seconds 2
}

# ── Max iterations reached ────────────────────────────────────────────────────

Write-Host ""
Write-Err "Ralph reached max iterations ($Max) without completing all tasks."
Write-Host "  Review: $ProgressFile" -ForegroundColor Yellow

$stillPending = Get-IncompleteTasks
if ($stillPending.Count -gt 0) {
    Write-Host ""
    Write-Host "  Still pending:" -ForegroundColor Magenta
    foreach ($story in $stillPending) {
        Write-Host "    [ ] $($story.id) - $($story.title)" -ForegroundColor White
    }
}

exit 1
