# Appliance validation checklist

Leroy's automated suite runs without network access: `curl` is mocked, the API
transport is exercised against fixtures, and no Morpheus appliance is involved.
That proves argument handling, manifest expansion, state bookkeeping, payload
construction, and terminal rendering. It cannot prove that HPE Morpheus accepts
those payloads, that the endpoints exist on the target build, or that the
resulting demonstration behaves as intended.

This file lists every behavior that is **unverified until it runs against a
Morpheus 9 appliance**, so a session with appliance access can check all of them
in one pass. Each item has a stable ID. Record results in
[`FEEDBACK.md`](FEEDBACK.md) using the same ID.

Do not paste appliance URLs, tokens, generated passwords, or raw API responses
containing secrets into either file.

## How to read the status column

| Status | Meaning |
| --- | --- |
| Unverified | Implemented and unit-tested against fixtures; never executed against Morpheus. |
| Partly verified | Confirmed once on an appliance; a later change has not been re-checked. |

## Transport and authentication

| ID | Behavior | Why local tests cannot settle it | Expected on an appliance |
| --- | --- | --- | --- |
| AV-001 | Bearer authentication through a `curl` header file | The header file is only inspected, never sent | `leroy status` reports the service account identity; no token appears in `ps` output or logs |
| AV-002 | TLS verification disabled by default, `MORPHEUS_VERIFY_TLS=true` honored | No appliance certificate is available | Default run warns and succeeds; with `true` against an untrusted certificate it fails with exit code 5 |
| AV-003 | Connect and request timeout handling | No slow endpoint to exercise | A short `MORPHEUS_CONNECT_TIMEOUT` against an unreachable host exits 5 within the timeout |
| AV-004 | HTTP status mapping to exit codes 4, 5, 6, 7 | Statuses are synthesized locally | A revoked token exits 4; an unknown ID exits 6 |
| AV-005 | `POST /oauth/token` password grant with `subdomain\username` | No identity provider available | Persona login succeeds and returns an access token |
| AV-006 | Temporary token discovery and revocation through `/api/tokens` | Response shape is assumed | Tokens created during deep verification are gone afterwards |

## Collection pagination

| ID | Behavior | Why local tests cannot settle it | Expected on an appliance |
| --- | --- | --- | --- |
| AV-010 | `api_collection` follows `max`/`offset` until a short page | Page shapes are synthetic | `leroy --output json environments list` returns every environment on an appliance with more than 100 |
| AV-011 | Collection key handling per endpoint | Real key names are assumed (`environments`, `roles`, `policyTypes`); the helper falls back to the first array in the response and republishes it under the name the caller expects, which is itself untested against a real body | Roles, policy types, and name lookups all return records rather than an empty set |
| AV-012 | Base role discovery no longer capped at one page | The appliance may expose more than 100 roles | Preflight finds the built-in Tenant Admin and user admin roles on a role-heavy appliance |

## Preflight and capability discovery

| ID | Behavior | Why local tests cannot settle it | Expected on an appliance |
| --- | --- | --- | --- |
| AV-020 | Master-tenant assertion from `/api/whoami` | Response is synthetic | A subtenant token exits 4 with a clear message |
| AV-021 | Morpheus 9 version gate and the field it reads | The real `whoami` field name and format are assumed | A Morpheus 9 appliance passes; the recorded build appears in `demo state` |
| AV-022 | Per-component capability probes | Endpoint availability varies by build and license | Every selected component's probe succeeds; a missing one exits 9 naming the capability |
| AV-023 | Dashboard identity and build extraction | Same response assumptions as AV-021 | The Connection row shows the real username and build, not `unknown` |

## Resource payloads

Every payload below is built locally and has never been accepted or rejected by
Morpheus. A rejection surfaces as exit code 5 with the API message.

| ID | Resource | Specific risk |
| --- | --- | --- |
| AV-030 | Tenant (`/api/accounts`) | Nesting of `account` plus the tenant role reference |
| AV-031 | Account role and user roles (`/api/roles`) | `roleType`, `authority`, and `baseRoleId` acceptance |
| AV-032 | Role feature permissions (`/api/roles/{id}/update-permission`) | Access levels are copied from the base role; a permission that accepts neither is still possible (see LRY-004) |
| AV-033 | Users (`/api/accounts/{id}/users`) | Password from Cypher, role binding, and required name fields |
| AV-034 | Environments (`/api/environments`) | `visibility` and `code` acceptance |
| AV-035 | Groups (`/api/groups`) | `location` and `code` acceptance |
| AV-036 | Policies (`/api/policies`) | Policy type resolution by name, `sites` scoping, and per-type `config` keys |
| AV-037 | Option type (`/api/library/option-types`) | `fieldContext: customOptions` reaching the workflow |
| AV-038 | Groovy task (`/api/tasks`) | `taskType.code`, `executeTarget`, and inline file content |
| AV-039 | Workflow (`/api/task-sets`) | `optionTypes` and `tasks[].taskPhase` for an operational workflow |
| AV-040 | Catalog item (`/api/catalog-item-types`) | `type: workflow`, `context: none`, and workflow binding |
| AV-041 | Catalog access (`/api/roles/{id}/update-catalog-item-type`) | Grant shape and effect on the consumer persona |
| AV-042 | ID extraction from create responses | Each response wrapper key is assumed; a mismatch exits 7 |

## Cypher

| ID | Behavior | Expected on an appliance |
| --- | --- | --- |
| AV-050 | `GET /api/cypher/password/24/<demo>/<user>` generates a password on read | A password is returned and never written to state, manifests, or logs |
| AV-051 | `GET /api/cypher?list=true&key=<exact>` does not generate a key | Planning a fresh demo shows `create`, never a false `conflict` (LRY-003) |
| AV-052 | Adoption of an existing Leroy-owned key | A second plan shows `adopt` or `unchanged` |
| AV-054 | Adoption of non-Cypher resources after state is lost | Delete the state file and replan: resources carrying the marker show `adopt`, and apply records their existing IDs rather than creating duplicates |
| AV-055 | The marker is visible in list responses | If `/api/roles?name=` omits `description`, adoption falls back to fetching the object; confirm that path is exercised at most once per resource |
| AV-053 | Cypher deletion during destroy | The key is gone; unrelated keys are untouched |

## RBAC and deep verification

| ID | Behavior | Expected on an appliance |
| --- | --- | --- |
| AV-060 | Tenant admin persona reaches `/api/whoami` | `persona` check passes for the admin |
| AV-061 | Platform operator reaches `/api/tasks` | `persona` check passes for the operator |
| AV-062 | Service consumer reaches `/api/catalog-item-types` | `persona` check passes for the consumer |
| AV-063 | Service consumer is denied `/api/tasks` | The negative check fails the run if the consumer has task administration |
| AV-064 | Workflow execution as the operator persona | The `workflow` check passes and the task returns the demo message |
| AV-065 | Every temporary persona token is revoked | No leftover tokens for the persona users afterwards |

## Lifecycle

| ID | Behavior | Expected on an appliance |
| --- | --- | --- |
| AV-070 | First apply creates all resources in dependency order | `demo apply` exits 0 and ends with a verification report showing no failures |
| AV-071 | Second apply is idempotent | Every plan row is `unchanged`; nothing is recreated |
| AV-072 | Interrupted apply resumes | Interrupt mid-apply, rerun, and the run completes without duplicating resources (exit 10 on the interrupted run) |
| AV-073 | Ownership verification before deletion | A resource whose marker was edited by hand refuses deletion with exit 8 unless `--force` |
| AV-078 | Force deletion after an ownership mismatch | With `--force`, a resource still carrying a Leroy identity is deleted; a resource with none is still refused with exit 8 |
| AV-074 | Reverse-order destroy | `demo destroy` removes everything it created and leaves the appliance otherwise unchanged |
| AV-075 | Recreate after a component change | Changing the selection with saved state exits 8; recreate applies the new selection |
| AV-076 | Master Tenant deployment without multitenancy | Selected content is created in the Master Tenant and payloads carry no tenant account (LRY-005) |
| AV-077 | `demo state` shows real Morpheus IDs | Each recorded ID resolves in the Morpheus UI |

## TUI flows that need an appliance

The dashboard, the component selector, the manifest-source screen, the pager,
key handling, and layout are covered by the local suite and by a pseudo-terminal
harness. What remains unverified is everything downstream of a real API call.

| ID | Flow | Expected on an appliance |
| --- | --- | --- |
| AV-080 | Startup connection probe | The dashboard shows `Connected as <user> (Morpheus <build>)` within the connect timeout |
| AV-081 | Probe against an unreachable appliance | The dashboard shows `Not reachable` and stays usable |
| AV-082 | `s` connection status screen | Identity, build, master-admin flag, and tenant are correct |
| AV-083 | `p` plan and `a` build | Live progress is visible while the build runs |
| AV-084 | `i` inventory after a build | Every created resource is listed with its Morpheus ID |
| AV-085 | `v` and `d` verification | The per-check report matches the appliance state |
| AV-086 | `x` destroy and `r` recreate | The typed organization name matches the saved deployment and the action completes |
| AV-089 | `m` selecting a saved deployment | The dashboard switches to that demo's ID, components, and state, and a deployment from another appliance is labelled |
| AV-090 | `a` build preview | The plan counts match the resources the build then creates, and cancelling sends nothing |
| AV-091 | TUI force retry after a mismatch | The offer appears only for an ownership mismatch, and typing `force` completes the deletion |
| AV-087 | `w` wizard, then plan and apply from the generated manifest | The generated demo ID, tenant subdomain, and Cypher namespace are used throughout |
| AV-088 | Long output paging during a real build | Scrolling reaches the end of the output without truncation |

## Schema 2 and the graphical builder

Schema 2 manifests exercise code paths that fixtures cannot settle, because
what a persona may do is decided by Morpheus, not by Leroy.

| ID | Behavior | Why local tests cannot settle it | Expected on an appliance |
| --- | --- | --- | --- |
| AV-100 | A schema 2 manifest applies end to end | Only payload construction is tested locally | `demo apply --file` on a builder manifest completes and verifies |
| AV-101 | Per-persona permission rules from the manifest | Pattern matching runs against the permissions the real base role advertises | Each rule matches at least one feature permission and every grant is accepted; a rule that matches none fails with exit code 9 listing what the appliance offers. Confirm the preset's `catalog|service catalog` rule matches a real feature permission, since only instance and persona entries matched it before (LRY-018) |
| AV-102 | Access levels other than `source` | Morpheus decides which levels a permission accepts (see LRY-004) | `read`, `full` and `user` are accepted, or the run fails with the API message |
| AV-103 | A persona with a profile Morpheus does not know | Schema 2 allows any profile string; only `tenant-admin` is special to Leroy | The role is created with the base user role and the manifest's permissions |
| AV-104 | More than three personas | Resource expansion is tested; creation is not | Every persona yields a role, a Cypher key and a user |
| AV-105 | `catalogAccess: false` | Only the outbound calls are asserted locally | That persona's role has no catalog grant in the Morpheus UI |
| AV-106 | `runsWorkflow` on a persona other than the operator | Execution is mocked locally | Deep verification executes the workflow as that persona |
| AV-107 | Per-persona `verify.allow` and `verify.deny` | Real permissions decide the outcome | The allow path succeeds and the deny path is refused; a wrong expectation fails with exit code 9 |
| AV-108 | A renamed tenant administrator persona | The tenant token depends on that persona's login | `ensure_tenant_token` logs in as it and tenant-scoped resources are created |

The builder itself needs no appliance: it is static and makes no Morpheus
calls. What an appliance run must confirm is that the manifests it produces
apply cleanly, which is `AV-100` to `AV-108` above.

## Suggested run sheet

Run in this order on an appliance that can be rebuilt. Steps 1 to 4 need no
credentials.

```bash
make check                                  # local suite, no appliance
leroy demo list                             # AV-077 (empty on a fresh machine)
leroy demo preset > /tmp/leroy-demo.json    # manifest generation
leroy --output json demo state --demo-id leroy-demo   # expect exit 6

leroy status                                # AV-001, AV-004, AV-020, AV-023
leroy --output json environments list       # AV-010, AV-011
leroy demo plan                             # AV-022, AV-051
leroy demo apply                            # AV-030..AV-042, AV-050, AV-070
leroy demo plan                             # AV-071, expect every row unchanged
leroy demo state                            # AV-077
leroy demo verify                           # structural report
leroy demo verify --deep                    # AV-060..AV-065
leroy demo destroy --demo-id leroy-demo --yes  # AV-053, AV-074

# then a schema 2 manifest from the builder, with a fourth persona
leroy demo plan   --file banking-demo.json     # AV-100
leroy demo apply  --file banking-demo.json     # AV-101..AV-105, AV-108
leroy demo verify --file banking-demo.json --deep   # AV-106, AV-107
# then rename one resource in the Morpheus UI, rebuild, and retry destroy for AV-073 and AV-078
```

Then repeat the interactive pass in the TUI for AV-080 to AV-091, including one
run with multitenancy deselected for AV-076 and one recreate for AV-075.
