# AGENTS.md — Codebase Patterns & Gotchas

This file is maintained automatically by Ralph iterations.
Each iteration should **append** discoveries here; never delete existing entries.

Always look up one folder for the project's src code and *.md files.

---

## Known Gotchas

### US-001 (Stack Initialization)

- **tsconfig.json must exclude fons-prosearch-template**: Add `"fons-prosearch-template"` to the `"exclude"` array, otherwise TypeScript picks up the template's files and reports hundreds of errors about missing Shadcn/ui components and Prisma models that don't match BrewQuest's schema.

- **Prisma 7 datasource block — no `url` field**: In `prisma/schema.prisma`, the `datasource db` block must NOT include `url = env("DATABASE_URL")`. That goes in `prisma.config.ts` under `datasource.url`. Omitting this from schema is required; including it causes a P1012 validation error.

- **Prisma 7 `previewFeatures = ["driverAdapters"]` is deprecated**: Remove it from the `generator client` block; the functionality works without it and keeping it emits a warning.

- **mapbox-gl v3 ships its own types** — do NOT install `@types/mapbox-gl`. However, `@mapbox/mapbox-gl-geocoder` (and its peer chain) pulls in `@types/mapbox__point-geometry` as a dependency, which is a deprecated stub with no `index.d.ts`. TypeScript sees it in `node_modules/@types/` and tries to load it as an implicit type library, causing a TS2688 error. Fix: create `node_modules/@types/mapbox__point-geometry/index.d.ts` with stub re-exports: `export * from "@mapbox/point-geometry"; export { default } from "@mapbox/point-geometry";`.

- **npm install requires `--legacy-peer-deps`**: `@langchain/community` has a conflicting peer dependency chain via `@browserbasehq/stagehand` (requires zod@3 while project uses zod@4). Always run `npm install ... --legacy-peer-deps` in this project.

- **Project is now in static export mode (US-002 done)**: `next.config.ts` sets `output: "export"` and `images: { unoptimized: true }`. The `out/` directory is the static output. `npm run build` and `npm run export` both trigger `next build`.

- **The project root IS the BrewQuest app**: All source files (`src/`, `prisma/`, `package.json`, etc.) live at `/questsocial/` (root), NOT inside `fons-prosearch-template/`. The template is read-only reference code.

- **Reusable from template**: auth.config.ts/auth.ts pattern (NextAuth v5 split-config), proxy.ts middleware structure, lib/db.ts (Prisma singleton), lib/utils.ts (cn helper), app/globals.css (Tailwind v4 CSS variables), next.config.ts (security headers — extend CSP for Mapbox), prisma.config.ts, components.json.

- **NOT reused from template**: Multi-tenant resolution, super-admin flows, document/project RAG pipeline, BullMQ job queue, ChromaDB vector store wiring, audit logging, Twilio SMS. These are FONS-specific and not needed in BrewQuest v1.

- **`npx shadcn add` internally runs `npm install` even when packages already exist** — this fails silently with exit code 1 in this project due to `@langchain/community` peer dep conflicts with zod v4. Workaround: set `npm_config_legacy_peer_deps=true` before calling shadcn: `npm_config_legacy_peer_deps=true npx shadcn add <component> --yes`.

- **Shadcn/ui v3 imports from `radix-ui` (unified package)** — Generated components use `import { Slot } from "radix-ui"` NOT `@radix-ui/react-slot`. The unified `radix-ui@^1.4.3` package is already in dependencies and provides this.

### US-002 (Static Export + PWA)

- **`output: 'export'` is incompatible with Route Handlers and Middleware** — Any `app/api/**/route.ts` file will fail a static export build. Middleware (even if in `proxy.ts` not `middleware.ts`) still shows in the build output as `ƒ Proxy (Middleware)` but does NOT run in the static output — this is a warning, not an error. Delete API Route Handlers before enabling static export.

- **`.next/` cache holds stale Route Handler type references** — After deleting `src/app/api/auth/[...nextauth]/route.ts`, running `npx tsc --noEmit` will still fail with TS2307 if `.next/types/validator.ts` was generated before deletion. Always `rm -rf .next` before running tsc after removing routes.

- **`headers()` in `next.config.ts` is silently ignored with `output: 'export'`** — Not a build error. Headers must be set at the CDN/server level for static deployments. The config was removed for clarity (security headers should be applied by the host in production).

- **`images: { unoptimized: true }` is required with `output: 'export'`** — Next.js Image Optimization requires a server; set `unoptimized: true` to bypass it and output raw `<img>` tags.

- **Manual service worker preferred over `next-pwa`** — `next-pwa` and its maintained fork `@ducanh2912/next-pwa` have known compatibility issues with Next.js 16 static export. Use a hand-crafted `public/sw.js` (cache-first for assets, network-first for HTML, offline fallback). Register it from a `"use client"` component in layout.tsx.

- **PNG icons can be generated without extra dependencies** — Use `scripts/generate-icons.mjs` with Node.js built-in `zlib.deflateSync` + raw PNG binary construction. No `canvas`, `sharp`, or external tools needed. Run with `node scripts/generate-icons.mjs`.

- **Lighthouse score ≥ 90 requires a live HTTPS deployment** — Cannot be verified in the build agent. All required configuration is in place (manifest.json, SW, 192+512px icons, theme_color, display:standalone, apple-web-app meta). Verify post-deployment with Lighthouse CI or PageSpeed Insights.

- **`npm run export` is an alias for `npm run build`** — With `output: 'export'`, `next build` IS the export step (outputs to `out/`). The separate `next export` command was removed in Next.js 14. `"export": "next build"` in package.json satisfies the AC.

### US-003 (Authentication + Age Gate)

- **Next.js 16 uses `proxy.ts` as its middleware file — DO NOT create `middleware.ts`**: Next.js 16 introduced a "proxy" file concept where `src/proxy.ts` with `export const proxy = auth(...)` and `export const config = { matcher: [...] }` IS the middleware. Creating a separate `middleware.ts` alongside it triggers a fatal build error: "Both middleware file and proxy file detected." Delete any `middleware.ts` you create. The `proxy.ts` approach is already correct.

- **Google/Apple OAuth require live credentials at runtime, not at build time**: Configuring `Google({ clientId: process.env.GOOGLE_CLIENT_ID ?? "" })` compiles and builds fine. OAuth will simply fail at runtime if the env vars are empty. Set them in `.env.local` (Google Cloud Console → OAuth 2.0 client) and in production environment secrets before enabling social login.

- **Apple Sign-In `clientSecret` is a generated JWT, not a plain string**: In production, `APPLE_SECRET` must be a RS256 JWT signed with an Apple-provided private key, valid for up to 6 months. The env var stores the pre-generated token. See Apple Developer documentation for the exact format.

- **Credentials register flow requires a server-side route handler** (`/api/register`): With `output: 'export'`, this route handler cannot exist in the Next.js static build. The register form currently POSTs to `/api/register` which will 404 in static mode. This endpoint must be added when the deployment model includes a Next.js server (Vercel, etc.).

- **Age gate logic must be consistent in two places**: (1) client-side Zod refine in register/page.tsx (blocks form submission for under-21); (2) server-side `isAtLeast21()` check in auth.ts `authorize()` (blocks credential sign-in for existing under-21 accounts). Both must agree.

- **Social login skips DOB gate at sign-in time**: Google/Apple users are provisioned without a dateOfBirth. A future story should add a "complete your profile" redirect for social users who have no DOB on record. The `signIn` callback in auth.ts already skips the age check for social providers.

- **`next-auth/react` `signIn` with `redirect: false` returns `SignInResponse`**: The overloaded type `signIn(provider, { redirect: false })` returns `Promise<SignInResponse>` where `SignInResponse = { error, code, status, ok, url }`. Check `result.error` or `result.ok` for success/failure in client components.

### US-004 (Seed Breweries)

- **Open Brewery DB API**: `GET https://api.openbrewerydb.org/v1/breweries?per_page=200&page=N&by_state=california`. Paginates until response length < 200. Response includes: `id`, `name`, `brewery_type`, `address_1`, `street`, `city`, `state_province`, `state`, `postal_code`, `country`, `latitude` (string), `longitude` (string), `phone`, `website_url`.

- **BreweryType enum import**: Use `$Enums.BreweryType` from `"../src/generated/prisma/client"` (not the named `BreweryType` re-export). `Object.values($Enums.BreweryType)` gives all valid values. OBDB types (micro, nano, regional, brewpub, large, planning, bar, contract, proprietor, taproom, closed) all map 1:1 to the schema enum.

- **Venue.externalId is the idempotency key**: `externalId String? @unique` stores the OBDB `id` (a slug like `10-barrel-brewing-co-bend-1`). Use `db.venue.upsert({ where: { externalId: b.id }, ... })` to skip duplicates.

- **OBDB id is a valid slug**: OBDB ids are already lowercase, dash-separated slug strings (e.g., `sierra-nevada-brewing-co-chico-1`). Use them directly as `Venue.slug` on create (guaranteed unique since externalId is unique).

- **latitude/longitude come as strings from OBDB**: Parse with `parseFloat()`. Can be `null` when location is unknown — handle gracefully.

- **`npm run db:seed-breweries` is the admin command**: Runs `npx tsx scripts/seed-breweries.ts`. Use `SEED_STATE` env var to target a state (default: california) or `SEED_ALL=true` for all US.

### US-005 (Brewery Claiming)

- **`npx prisma db push` does NOT regenerate the client automatically** — always follow with `npx prisma generate` separately after schema changes to update `src/generated/prisma/client/`.

- **VenueClaim model added** — tracks claim requests (pending | approved | rejected) with `contactEmail`, `businessProofUrl?`, `notes?`. Approval workflow is server-side: admin PATCH endpoint sets `Venue.claimStatus='claimed'` and `Venue.ownerId` on approval, and updates `User.role='venue_owner'`.

- **API endpoints for claiming are server-side only** — `/api/venues/search`, `/api/claims`, `/api/owner/venues`, `/api/venues/[id]` (PATCH), `/api/admin/claims`, `/api/admin/claims/[id]` are referenced in client pages but must be implemented as Route Handlers in a non-static deployment (same pattern as `/api/register`).

- **Role check in client pages uses session?.user.role** — Cast via `(session?.user as { role?: string } | undefined)?.role` since the Session type needs TypeScript augmentation for custom fields beyond the base next-auth types. Check `next-auth.d.ts` for the augmented `Session.user` interface.

### US-007 (Check-in QR)

- **`react-qr-code` is the QR library of choice** — Pure SVG output, no canvas API needed, ships its own TypeScript types. Import: `import QRCode from "react-qr-code"`. Usage: `<QRCode value={url} size={200} />`. Installed with `--legacy-peer-deps`.

- **`useSearchParams()` requires a Suspense boundary in static export** — In Next.js App Router with `output: 'export'`, any component that calls `useSearchParams()` must be inside a `<Suspense>` boundary. Pattern: export a `default` page component that wraps the inner content component in `<Suspense fallback={...}>`. Failing to do so causes a build-time warning and may cause hydration issues.

- **Scan URL must be built client-side** — QR codes encode the absolute scan URL (e.g. `https://[host]/checkin?token=XXX`). Since `window.location.origin` is only available in the browser, build the URL after mount using a `useState("")` initialized to `""` and set via the data-loading effect. This avoids hydration mismatches.

- **CheckInQR model already existed in schema** — `token @unique`, `venueId`, `expiresAt`, `scanCount @default(0)` — no migration needed for US-007. Token generation + midnight expiry logic belongs in the future `/api/venues/[id]/checkin-qr` Route Handler.

- **Auto-trigger GPS on page load for UX** — The `/checkin` page calls `requestGPS()` automatically in a `useEffect` when `token` is present, so users don't need to tap a second button after scanning. Use a `useRef` guard (`verifying.current`) to prevent double-invocation under React Strict Mode double-mount.

### US-008 (Per-item Pour QR)

- **`MenuItemQR` model was already in schema** — `token @unique`, `menuItemId`, `expiresAt`, `scanCount @default(0)`. No migration needed. Token generation + midnight expiry logic belongs in the future `/api/menu-items/[id]/pour-qr` Route Handler.

- **Ternary false branch with sibling JSX elements requires a Fragment** — When a ternary alternative needs to render multiple sibling elements (e.g. an item row div + a conditionally shown QR card below it), wrap both in `<>...</>`. Failing to do so causes a TSX parse error since a ternary branch must have a single root expression.

- **"Pour QR" button only shown for on-tap items** — `{item.onTap && <Button>Pour QR</Button>}` keeps the dashboard clean; off-tap items don't get a QR button since they aren't available for scanning.

- **`alreadyVerifiedToday` flag in API response** — The `/api/pour/verify` endpoint should return `{ success: false, alreadyVerifiedToday: true }` when a user has already had a VerifiedPour for the same `menuItemId` on the current calendar day (compare date portion of `verifiedAt`). The client `/pour` page renders a specific "already verified today" message for this case.

### US-011 (RAG Recommendation Pipeline)

- **`MemoryVectorStore` is NOT in `langchain@1.x` or `@langchain/community`** — In LangChain.js v1, `MemoryVectorStore` lives in `@langchain/classic/vectorstores/memory` (transitive dep, not in package.json). Do NOT import from `langchain/vectorstores/memory` (doesn't exist). Solution: implement a custom `VenueVectorStore` class using `cosineSimilarity()` — ~25 lines, no external deps.

- **Anthropic has no embeddings API** — When `LLM_PROVIDER=anthropic`, still use `OpenAIEmbeddings` from `@langchain/openai`. Only LLM generation uses Anthropic; embeddings always use OpenAI or Ollama.

- **RAG pipeline is Node.js-only — implement in `src/lib/recommend/`, not as a Route Handler** — Next.js static export ignores library files not imported by pages. Wire to `src/app/api/recommend/route.ts` only when moving to server mode. This keeps US-002 (static export) and US-011 (RAG pipeline) passing simultaneously.

- **`BaseChatModel` type for dynamic chat model imports** — Annotate return type as `Promise<BaseChatModel>` from `@langchain/core/language_models/chat_models` and cast each with `as BaseChatModel` to avoid union type issues on `.invoke()` and `.stream()`.

- **LLM stream chunk content type** — `chunk.content` is `MessageContent = string | MessageContentComplex[]`. Always use `typeof chunk.content === "string" ? chunk.content : ""` when consuming stream tokens.

- **Vector store TTL singleton pattern** — Module-level `_store: VenueVectorStore | null` + `_storeBuiltAt: number`. Rebuild when `Date.now() - _storeBuiltAt > STORE_TTL_MS`. 10-min TTL works for dev/demo; swap for persistent store in production.

### US-012 (Check-in System & Gamification)

- **`/checkin` page now supports two modes** — `?token=` (QR scan, existing) and `?venueId=` (GPS-only, new). The `?venueId=` mode passes `enableHighAccuracy: true` to `getCurrentPosition` and POSTs to `/api/checkin/gps` with `{ venueId, latitude, longitude }` for server-side ~100 m proximity validation. GPS is required in this mode (no skip-GPS fallback) since the venue cannot be verified otherwise.

- **Badge catalog lives in `src/lib/badges.ts`** — Exports `BADGE_CATALOG: BadgeDef[]`, `UserStats` interface, and `badgeProgress(badge, stats): number` (returns 0–1). Progress is computed client-side from stats returned by `/api/profile`; actual badge awarding is server-side logic (triggered at check-in / verified-pour time).

- **Profile page at `/profile`** — `"use client"` page that fetches `/api/profile` (returns user info + stats + earnedBadgeIds[]) and `/api/leaderboard?type=city|friends`. Badge cards use `badgeProgress()` for the progress bar percentage. Leaderboard tabs switch the API query param.

- **Badge IDs must match Badge.name in DB** — The `BadgeDef.id` field (e.g. `"ipa-conqueror"`) is the slug stored as `Badge.name` in the database. The `earnedBadgeIds` array from `/api/profile` should contain these same slugs for the profile page to highlight earned badges correctly.

