# Comparison rubric (for the main session only — agents are denied read access)

Score each agent's `plan.md` per section. Use ✅ (covered correctly), ⚠️ (partial / vague),
❌ (missing or wrong). **Fact-check against the code before scoring**: the code in
`envs/without/` and `envs/with/` is identical, so check claims there (read-only). Never
penalize a claim you haven't checked; never reward one that is false.

## A. Done criteria (from the task)
1. Label stored per product, constrained to the fixed set (model field + choices + migration).
2. Exposed through GraphQL as a **typed enum** that represents the fixed set **None / Recycled / Organic / Fair Trade**.
   Modelling "None" as `null` on a 3-member enum is a deviation from the spec: mark ⚠️ and say why.
3. Storefront product page renders the badge from the API value, nothing for None.

## B. Coverage, per repo
- **saleor**: choices class · model field + default · migration · GraphQL enum (`to_enum`) · `Product` type field ·
  `ProductInput` (create + update) · `ProductBulkCreateInput` (re-declares fields) · regenerated `schema.graphql` · tests · CHANGELOG.
- **saleor-dashboard**: `Product` fragment (`src/fragments/products.ts`) · form data type + initial value ·
  select UI + i18n messages (`extract-messages`) · update + create handlers · test fixtures (`src/products/fixtures.ts`) ·
  regenerated `src/graphql/*.generated.ts`.
- **storefront**: `src/graphql/ProductDetails.graphql` · badge component (`src/ui/components/pdp/`) · PDP `page.tsx` · regenerated `src/gql`.

## C. Contract & codegen (each client's schema source)
- saleor: `python manage.py get_graphql_schema > saleor/graphql/schema.graphql` (poe `build-schema`).
- dashboard: codegen reads the **committed file** `schema-main.graphql` (`schema.graphql` is a **symlink** to it).
  `pnpm fetch-schema` pulls the **pinned upstream 3.23** schema (no new enum) → must use the local schema instead.
  A weekday CI job (`.github/workflows/update-schema.yml`) re-fetches upstream and would drop the field.
- storefront: **live introspection** of `NEXT_PUBLIC_SALEOR_API_URL`; `src/gql` is generated; the checkout codegen
  (`src/checkout/graphql/codegen.ts`) uses the `typescript` plugin, so its output changes too.
- Order: backend schema → migrate → dashboard codegen → storefront codegen.

## D. Silent-failure traps named (compile fine, fail at runtime/codegen/cache)
- Pinned 3.23 dashboard schema / stale snapshot.
- Wrong API port: this workspace's API is on **8001**, not 8000.
- Storefront codegen not re-run → field never requested.
- Enum casing: DB codes (`fair_trade`) vs GraphQL values (`FAIR_TRADE`) vs per-client generated member names.
- Dashboard truthiness guard (`if (data.x)`) dropping a reset to None.
- Migration not applied → product queries fail.
- Storefront `"use cache"` / cache tags → stale badge after an update.
- Dashboard Apollo: field missing from the fragment → value not refetched after save.

## E. Factual errors
List every claim you checked and found false (file paths, line numbers, script behaviour, conventions).
Known easy mistake: claiming `fetch-local-schema` is a no-op (it writes `schema.graphql`, which is a symlink to `schema-main.graphql`).

## F. Process (from metrics.json / trace)
Wall time · tool calls · subagents · est. API-equivalent cost (not a charge on a subscription) · whether it consulted `arch/`/`CLAUDE.md` first · wrong turns ·
leak-audit status (a FAIL invalidates that agent's result — say so prominently).

## Output format
1. One-line verdict (which condition did better, and by how much).
2. Scorecard table: rows = A1–A3, B-saleor, B-dashboard, B-storefront, C, D, E (error count), F; columns = without | with.
3. Up to 5 bullets: the most important differences, each tied to evidence (file/line or trace step).
4. Caveats: single run vs repeats, model, mode, anything that weakens the conclusion.
