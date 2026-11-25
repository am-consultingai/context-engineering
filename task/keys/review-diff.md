# Answer key — review-diff (violations planted; sources)
V1 manual permission check in perform_mutation → use `Meta.permissions = (GiftcardPermissions.MANAGE_GIFT_CARD,)` (graphql/AGENTS) [also raising ValidationError instead of PermissionDenied]
V2 reuses `GiftCardError` → own error class + code enum per mutation (graphql/AGENTS; CONTRIBUTING:448)
V3 no `ADDED_IN_324` on mutation/input/fields (graphql/AGENTS)
V4 unbounded `transfers` list → cap at 100 and document (graphql/AGENTS)
V5 read-modify-write `-=`/`+=` + save → lost updates; use `F()` and/or `select_for_update` (saleor/AGENTS "Never use instance.count += 1")
V6 check-then-act on balance without a lock; no transaction → `traced_atomic_transaction` + `select_for_update` via lock_objects module, pk-ordered to avoid deadlocks (saleor/AGENTS)
V7 direct `manager.gift_card_updated(...)` → `call_event` (saleor/AGENTS); also fires before commit
V8 wrong history event (`balance_reset_event` misrepresents a transfer) → new event type
V9 migration: plain `AddIndex` → `AddIndexConcurrently`, `atomic = False` (graphql/AGENTS + .semgrep concurrent-index rule); index on balance likely unneeded anyway
V10 tests wrapped in a class → flat functions (saleor/AGENTS)
V11 redundant name prefix `test_gift_card_balance_transfer_*` in `test_gift_card_balance_transfer.py` (saleor/AGENTS)
V12 `assert ... is not None` → assert actual values vs fixtures (saleor/AGENTS)
V13 error code compared to the string "INVALID" → `GiftCardErrorCode.X.name` (saleor/AGENTS); no assertion on errors list length (saleor/AGENTS); no error message assertion
V14 literal values repeated; no given/when/then (saleor/AGENTS)
V15 `graphene_id` undefined (NameError) — use `graphene.Node.to_global_id`; same-card/currency/active/expired validation missing; returns duplicates; no CHANGELOG; schema.graphql not regenerated; import of GiftCardBalanceTransfer missing in schema.py
V16 `graphene.InputObjectType` → `BaseInputObjectType` with doc_category (repo pattern)
