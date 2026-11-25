# Answer key — reviews (main session only). Conventions from upstream agent docs (absent in `without`).
Backend:
C1 own error class + code enum per mutation (create/update/delete/moderate) — graphql/AGENTS.md
C2 `ADDED_IN_324` on every new type/field/mutation/input — graphql/AGENTS.md
C3 list inputs ≤100 (bulk moderate) + `query_cost_map.py` entries for paginated `reviews` — graphql/AGENTS.md
C4 `Meta.permissions` (MANAGE_PRODUCTS or a new permission), not manual checks; PermissionsField for staff-only fields
C5 dataloaders for review/aggregate resolvers
C6 aggregate update atomic: F() / recompute inside `traced_atomic_transaction` with `select_for_update` via `product/lock_objects.py` (`product_qs_select_for_update`); no check-then-act (unique constraint (user, product)) — saleor/AGENTS.md
C7 webhook: new async event (REVIEW_APPROVED…) dispatched via `call_event` — saleor/AGENTS.md
C8 filter/sort by rating: new DB index `AddIndexConcurrently` in `atomic=False` migration — graphql/AGENTS.md; `ProductOrderField` sort; NOTE `Product.rating` already exists + `ProductOrderField.RATING` (`sorters.py:163`) → reuse/derive from reviews
C9 "who bought it": verified purchase via OrderLine → variant → product for the user, fulfilled/paid orders
C10 tests: given/when/then, flat, assert error codes via enum `.name`, errors list length
Dashboard: C11 react-intl messages + `extract-messages`; changeset (`pnpm change:add`); local schema, not pinned 3.23; generated files not hand-edited
Storefront: C12 public reads via `executePublicGraphQL` vs session for the customer's own review (auth helper convention); `"use cache"` + `cacheTag` for reviews, revalidate on approve (webhook → `/api/revalidate`; PRODUCT_UPDATED or the new event); server actions for submit; codegen; JSON-LD aggregateRating
