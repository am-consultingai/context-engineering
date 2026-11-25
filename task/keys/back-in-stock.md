# Answer key — back-in-stock (main session only)
K1 model `BackInStockSubscription(variant FK, email, channel?, created_at)` with a UNIQUE constraint (variant, email[, channel]) + migration
K2 concurrency: no check-then-act; insert via `get_or_create`/`update_or_create` relying on the unique constraint or handle IntegrityError (convention: saleor AGENTS.md); `traced_atomic_transaction`; clearing via `select_for_update` through `product/lock_objects.py` (or delete-returning) so two restock events can't double-send
K3 counter: count query via dataloader, or an F()-incremented counter (never `x += 1; save()`)
K4 public mutation: own error class + error code enum (graphql/AGENTS.md), `ADDED_IN_324`, return created object, abuse/rate concerns (anonymous, email validation, captcha/limits), Meta.permissions (none/public) not manual checks
K5 webhook: REUSE existing `PRODUCT_VARIANT_BACK_IN_STOCK` (`webhook/event_types.py:146`, plus `_IN_CHANNEL`) — extend its subscription payload with the waiting emails (or a new event), dispatched via `call_event` (convention); payload permission (emails = PII → app needs a permission like MANAGE_USERS/…); clear only after successful dispatch/handled
K6 dashboard: variant page shows count (fragment + generated types from local schema, not pinned 3.23)
K7 storefront: PDP is `"use cache"`/RSC → the form must be a client component / server action that bypasses the cache; mutation codegen against live API; out-of-stock detection per selected variant
K8 dataloader for the count field (N+1), PermissionsField for the count (staff only)
