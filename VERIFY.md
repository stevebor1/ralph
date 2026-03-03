# Ralph Verification Pass — Claude Code

You are the **verification agent** in the Ralph loop. The build agent just
marked one or more stories as complete. Your sole job is to independently
confirm each one actually meets its acceptance criteria.

You did NOT write this code. Approach it with fresh eyes and healthy scepticism.

---

## Stories to verify

<!-- STORIES_TO_VERIFY -->

---

## Verification steps (run for every story listed above)

### 1. Re-run all quality gates

```bash
npx tsc --noEmit      # must show 0 errors
npm run build         # must complete without error
```

If either command fails, every story in this batch is unverified regardless
of what the build agent claimed.

### 2. Check each acceptance criterion

For each criterion in each story:

- **File exists / was created** — read it and confirm
- **TypeScript types are correct** — rely on tsc output above
- **UI component renders** — confirm the component file exists and imports are valid
- **API endpoint exists** — check the route file exists and exports a handler
- **Database schema** — check the Prisma schema file matches the criterion
- **Migration ran** — check the migrations directory for the expected migration file
- **Tests pass** — run tests if a test file exists for this story

### 3. Verdict per story

For each story, choose one:

**PASS** — every criterion is confirmed, both quality gates clean
**FAIL** — one or more criteria not met, OR a quality gate failed

### 4. Update prd.json for any failures

For any story that does NOT pass verification, set:

```json
"passes": false,
"notes": "VERIFY FAIL: <specific criterion that failed and why>"
```

Leave `passes: true` unchanged for stories that do pass.

### 5. Append to progress.txt

```
[VERIFY] US-XXX: PASS — tsc clean, build clean, all criteria confirmed
[VERIFY] US-XXX: FAIL — criterion "<text>" not met: <reason>. Reverted to passes: false.
```

### 6. Signal

Output exactly one of these on the final line:

- `<verify>PASS</verify>` — all stories in this batch are confirmed
- `<verify>FAIL</verify>` — one or more stories were reverted to `passes: false`

---

## Project context

**Quality gates:**
```bash
npx tsc --noEmit
npm run build
```

**Key gotchas:**
- Tailwind v4: `@import "tailwindcss"` in globals.css — no tailwind.config.js
- Zod v4: `z.record()` requires TWO args
- Prisma 7: import from `@/generated/prisma/client`
- Next.js 16: middleware = `src/proxy.ts` exporting `proxy`
- proxy.ts is Edge runtime — no Prisma/Node imports
- `@/*` alias for all imports from `src/`

See `ralph/AGENTS.md` for the full list.
