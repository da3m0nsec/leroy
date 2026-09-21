# Field feedback

This log records feedback observed against a real Morpheus appliance and the acceptance criteria used to prevent regressions.

Behavior that has never run against an appliance is tracked separately in [`APPLIANCE_VALIDATION.md`](APPLIANCE_VALIDATION.md) under `AV-` identifiers. Record appliance results against those identifiers; record defects against the `LRY-` identifiers here.

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

## 2026-09-21 — Pre-appliance accuracy review

Found by reading the code and driving the TUI in a pseudo-terminal, not on an appliance. All are fixed locally; none has been confirmed against Morpheus.

### LRY-006 — The TUI described a demo it was not acting on

- **Observed:** The dashboard, the component selector, and every lifecycle action assumed the built-in preset and the demo ID `leroy-demo`. A manifest produced by the wizard could not be used at all, and a saved deployment under any other demo ID was reported as `Not created`.
- **Expected:** One selected manifest drives the demo ID, organization name, state file, resource count, and every action. A manifest file can be chosen in the TUI, and the wizard hands its output over.
- **Status:** Resolved locally; appliance confirmation pending (`AV-087`).

### LRY-007 — Resource totals were fixed per component bundle

- **Observed:** The dashboard counted 24 resources for any manifest, because per-bundle totals were hard-coded. A manifest with more environments was described with preset numbers, and `Ready`/`Partial` was decided against the wrong expected count.
- **Expected:** Expand the manifest and count what it actually produces.
- **Status:** Resolved locally; appliance confirmation pending (`AV-077`).

### LRY-008 — Destruction confirmed with the wrong organization name

- **Observed:** Destroy and recreate always asked for `Leroy Demo Organization` and always targeted `leroy-demo`, whatever was deployed. With no saved state they asked for confirmation first and only then failed with exit code 6.
- **Expected:** Confirm with the organization name recorded in the state that will be deleted, and offer the action only when that state exists.
- **Status:** Resolved locally; appliance confirmation pending (`AV-086`).

### LRY-009 — Unmapped terminal keys quit the dashboard

- **Observed:** Any escape sequence other than an arrow key, including `Home`, `End`, and function keys, was read as `Esc` and closed the TUI. Longer sequences also left their trailing characters in the input buffer, where they were read as menu shortcuts.
- **Expected:** Read the complete sequence, map the navigation keys, and ignore anything unrecognized.
- **Status:** Resolved locally.

### LRY-010 — Collection reads stopped at the first page

- **Observed:** Environment lists, base-role discovery, policy-type resolution, and name lookups read at most 100 or 200 records. On an appliance with more roles than that, preflight could fail to find the built-in base roles.
- **Expected:** Follow Morpheus pagination in one shared helper.
- **Status:** Resolved locally; appliance confirmation pending (`AV-010`, `AV-011`, `AV-012`).

### LRY-011 — Verification reported only a failure count

- **Observed:** A failed run printed `N verification check(s) failed` with loose diagnostics, so an appliance run could not show what passed.
- **Expected:** One row per check in table and JSON output, keeping exit code 9.
- **Status:** Resolved locally; appliance confirmation pending (`AV-060` to `AV-065`).

### LRY-012 — The TUI could reach only one saved deployment

- **Observed:** The manifest-source screen took a file path, so a second deployment recorded in the state directory was invisible unless its manifest file was still at hand.
- **Expected:** List saved deployments and use the manifest each state file embeds.
- **Status:** Resolved locally; appliance confirmation pending (`AV-089`).

### LRY-013 — Build mutated Morpheus with no preview

- **Observed:** Pressing `a` went straight to apply, although the architecture describes preview and confirmation for mutating workflows.
- **Expected:** Plan first, report the counts, and require confirmation.
- **Status:** Resolved locally; appliance confirmation pending (`AV-090`).

### LRY-014 — Force was unreachable from the TUI

- **Observed:** A destroy stopped by an ownership mismatch could only be completed by dropping to the CLI with `--force`.
- **Expected:** Offer a gated retry, and only for failures force can resolve.
- **Status:** Resolved locally; appliance confirmation pending (`AV-091`).

### LRY-015 — The Leroy-identity check did not evaluate as written

- **Observed:** `remote_has_leroy_identity` piped its input through `tostring` before testing individual values, so the name-prefix arm could never match, and that prefix was hardcoded rather than read from the manifest.
- **Expected:** Test the values of the resource, using the manifest's prefix.
- **Status:** Resolved locally; appliance confirmation pending (`AV-078`). Resources matching the prefix already satisfied the ownership check, so the correction does not widen what force may delete unless a manifest sets no prefix.

## Validation requested

On the same appliance build:

1. Start Leroy without exported connection variables and complete the interactive prompts.
2. Run the default plan and confirm Cypher entries are `create`, `adopt`, or `unchanged`, never false `conflict` results.
3. Run build twice: the first invocation completes or resumes, and the second is idempotent.
4. Open the component selector, disable multitenancy, and confirm roles/users are disabled with it.
5. Plan that selection and confirm all remaining resources target the Master Tenant.
6. Re-enable all components, recreate the demo, then run structural and deep verification.
7. Work through [`APPLIANCE_VALIDATION.md`](APPLIANCE_VALIDATION.md) and record each `AV-` identifier as passed or failed.

Do not include appliance URLs, tokens, generated passwords, or raw API responses containing secrets in this file.
