# Answer key — playbook. Rules come from upstream agent docs (`with` only) and code.
saleor (AGENTS.md, graphql/AGENTS.md): ADDED_IN_{VERSION} from latest tag; PermissionsField; Meta.permissions not manual checks;
 own error class per mutation; return mutated object; input lists ≤100 + query_cost_map; dataloaders; call_event for webhooks;
 F() increments; no check-then-act (update_or_create needs a unique constraint); select_for_update via lock_objects.py; traced_atomic_transaction;
 search dirty-marking migrations (task file + post_migrate + RunPython.noop); new filter → AddIndexConcurrently, atomic=False; Pydantic → pydantic_to_validation_error;
 tests: pytest --reuse-db, given/when/then, flat, fixtures over mocks, assert error messages + errors list length, enum `.name`, no redundant test-name prefixes;
 regenerate schema; CHANGELOG (changelog-check)
dashboard (AGENTS.md): `pnpm run test:quiet <file>`; codegen `pnpm run generate`; schema source (pinned 3.23 / fetch-local-schema); react-intl + `extract-messages`;
 changesets (`pnpm change:add`); overrides in pnpm-workspace.yaml; generated files not hand-resolved in conflicts; check-types + lint
storefront (AGENTS.md): executePublicGraphQL vs executeAuthenticatedGraphQL; server vs client components; nullable fields; `pnpm generate` against the live API (+ generate:checkout); caching + revalidate
cross-repo: backend → dashboard → storefront order; port 8001; pinned schema trap; update-schema CI
