# Answer key — giftcard-transfer (conventions from saleor/AGENTS.md + graphql/AGENTS.md)
T1 own error class + code enum per mutation (transfer, bulk) — graphql/AGENTS
T2 `ADDED_IN_324` on all new types/fields/inputs — graphql/AGENTS
T3 `Meta.permissions = (GiftcardPermissions.MANAGE_GIFT_CARD,)`, no manual checks — graphql/AGENTS
T4 return the mutated objects — graphql/AGENTS
T5 bulk input list ≤100, documented — graphql/AGENTS
T6 concurrency: `traced_atomic_transaction` + `select_for_update` via a NEW `giftcard/lock_objects.py` (`gift_card_qs_select_for_update`, `order_by("pk")` — consistent lock order for deadlock-freedom) — saleor/AGENTS; balance updates with `F()` (existing pattern `giftcard/gateway.py:419`); no check-then-act
T7 webhook: new `GIFT_CARD_BALANCE_TRANSFERRED` (event_types + EVENT_MAP permission + subscription type + enums) dispatched via `call_event` (on commit) — saleor/AGENTS
T8 history: GiftCardEvent new event type(s) for both cards (giftcard/events.py)
T9 tests: given/when/then, flat functions, error code via enum `.name`, assert errors list length, fixtures over mocks, no redundant name prefixes; concurrency test
T10 schema regen (`get_graphql_schema` / poe build-schema), CHANGELOG
T11 dashboard: webhook event picker is generated from the enum → only regenerate; optional UI; pinned schema 3.23
