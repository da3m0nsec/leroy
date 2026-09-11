# Field feedback

This log records feedback observed against a real Morpheus appliance and the acceptance criteria used to prevent regressions.

## 2026-09-07 — Initial appliance run

### LRY-001 — Interactive bootstrap when configuration is missing

- **Observed:** Leroy exits when `MORPHEUS_URL` or `MORPHEUS_API_TOKEN` is not exported.
- **Expected:** In an interactive terminal, prompt for missing connection values; automation must continue to fail without prompting.
- **Status:** Resolved locally; appliance confirmation pending.

### LRY-002 — TLS verification default

- **Observed:** TLS verification defaults to enabled.
- **Expected:** Default `MORPHEUS_VERIFY_TLS` to `false`, while allowing an explicit secure override.
- **Status:** Resolved locally.

### LRY-003 — Cypher conflicts during plan

- **Observed:** Cypher plan entries report `conflict`, and planning exits with code 8.
- **Expected:** Use an exact, non-creating key lookup. An exact generated-password key inside `password/24/<demo-id>/...` is resumable and appears as `adopt`; unrelated keys remain protected.
- **Status:** Resolved locally; appliance confirmation pending.

### LRY-004 — Invalid feature-permission access type

- **Observed:** Build stops after creating `Leroy Tenant Admin`; Morpheus returns HTTP 400 because `read` is not allowed for one matched permission.
- **Expected:** Never assume that every feature permission accepts `read`; use an access value already advertised for that permission by the built-in administrative role.
- **Status:** Resolved locally; appliance confirmation pending.

### LRY-005 — Selective customer capability deployment

- **Observed:** The TUI always plans the complete demonstration, even when a customer does not want capabilities such as multitenancy.
- **Expected:** Present a checkbox screen with every capability selected by default; allow operators to exclude bundles, enforce dependencies, and deploy non-tenant content in the Master Tenant when multitenancy is disabled.
- **Status:** Resolved locally; appliance confirmation pending.

## Validation requested

On the same appliance build:

1. Start Leroy without exported connection variables and complete the interactive prompts.
2. Run the default plan and confirm Cypher entries are `create`, `adopt`, or `unchanged`, never false `conflict` results.
3. Run build twice: the first invocation completes or resumes, and the second is idempotent.
4. Open the component selector, disable multitenancy, and confirm roles/users are disabled with it.
5. Plan that selection and confirm all remaining resources target the Master Tenant.
6. Re-enable all components, recreate the demo, then run structural and deep verification.

Do not include appliance URLs, tokens, generated passwords, or raw API responses containing secrets in this file.
