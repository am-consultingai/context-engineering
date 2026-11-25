# Answer key — brand-search (main session only; agents can't read the harness)
K1 model field `Product.brand` + migration; GraphQL `Product.brand`, `ProductInput.brand` (+ bulk create), `ADDED_IN_324`
K2 search vector: add brand in `saleor/product/search.py` `prepare_product_search_vector_value` (dashboard + storefront both use `filter: {search}`, so one backend change covers both)
K3 backfill existing products via a DIRTY-MARKING data migration: task in `product/migrations/tasks/saleor3_24.py` (batched, `@allow_writer`, lock_objects select_for_update subquery, self-chaining `.delay()`), migration with `post_migrate` + `RunPython.noop` (convention: saleor AGENTS.md)
K4 filter: `ProductFilterInput` (what storefront `ProductListByCategory` uses, `filter: $filter`) and/or `ProductWhereInput`; DB index added CONCURRENTLY (`AddIndexConcurrently`, `atomic = False`) (convention: graphql/AGENTS.md); suitable index for text (btree on exact / trigram/upper for icontains)
K5 dashboard: pinned 3.23 schema → local schema; fragment + form + update/create handlers; optional ConditionalFilter for brand; react-intl messages
K6 storefront: brand filter in plp `filter-utils`/`filter-bar`, `ProductListByCategory` gets brand values (needs a way to list brands — e.g. distinct brands query or facet), codegen against live API; cache tags / "use cache" on category pages
K7 search/performance: searching runs on search_vector; filter list size/limits (input lists ≤100); query cost for any new list field
