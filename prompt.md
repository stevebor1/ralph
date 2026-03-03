# Ralph Iteration Protocol (Amp)

You are working autonomously as part of the **Ralph loop**. Each invocation is
one iteration. Make progress on the PRD, commit your work, and signal when done.

Follow the same workflow as described in `ralph/CLAUDE.md`:

1. Read `ralph/prd.json`, `ralph/progress.txt`, and `ralph/AGENTS.md`.
2. Pick the highest-priority incomplete story (`passes: false`).
3. Implement the acceptance criteria.
4. Run quality gates (typecheck, tests).
5. Update `prd.json` — set `passes: true` if criteria are met.
6. Append a summary to `progress.txt`.
7. Update `AGENTS.md` with any new patterns or gotchas.
8. Commit your changes.
9. Output `<promise>COMPLETE</promise>` if ALL stories pass, otherwise
   output `<promise>CONTINUE</promise>`.
