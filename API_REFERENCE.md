# Morpheus API Reference Roadmap

This document tracks the Morpheus REST API surface that Leroy intends to use. It is a project integration guide, not a replacement for the vendor documentation. Endpoint availability, permissions, request bodies, and response fields can vary by HPE Morpheus Enterprise version; implementation work must be verified against the target appliance and current official documentation.

## Official documentation

- [Morpheus API: Getting Started](https://apidocs.morpheusdata.com/docs/getting_started)
- [Morpheus API Reference](https://apidocs.morpheusdata.com/reference)
- [HPE Morpheus Enterprise documentation](https://docs.morpheusdata.com/)
- [Environment administration overview](https://docs.morpheusdata.com/en/latest/administration/settings/settings.html#environments)

The Morpheus API is REST-oriented. Most authenticated requests use an `Authorization: BEARER <access_token>` header, and JSON `POST`/`PUT` requests use `Content-Type: application/json`.

## Base URL and authentication

Leroy constructs API URLs from `MORPHEUS_URL`, for example:

```text
MORPHEUS_URL=https://morpheus.example.com
GET https://morpheus.example.com/api/environments
```

Trailing slashes are normalized. Tokens are read from `MORPHEUS_API_TOKEN` and are never included in command-line arguments or log output.

OAuth token acquisition may eventually use `POST /oauth/token`. The initial bootstrap expects an existing access token and does not store user passwords or implement a login flow.

## Endpoint roadmap

Status values mean **Bootstrap** (represented by the initial framework), **Planned** (intended after schemas and tests are defined), and **Research** (compatibility must be validated first).

### Identity and appliance

| Method | Path | Purpose | Status |
| --- | --- | --- | --- |
| `GET` | `/api/whoami` | Validate the token, permissions, and required Morpheus 9 build. | Implemented |
| `GET` | `/api/setup/check` | Discover appliance setup state where supported. | Research |
| `POST` | `/oauth/token` | Obtain temporary subtenant persona tokens for deep verification. | Implemented |
| `GET`/`DELETE` | `/api/tokens[/{id}]` | Locate and revoke temporary Morpheus 9 tokens. | Implemented |

### Environments

In Morpheus, this endpoint represents environment labels used when provisioning instances and apps. It is distinct from a tenant or an appliance connection profile.

| Method | Path | Purpose | Status |
| --- | --- | --- | --- |
| `GET` | `/api/environments` | List configured environments. | Bootstrap |
| `GET` | `/api/environments/{id}` | Retrieve one environment. | Bootstrap |
| `POST` | `/api/environments` | Create a private demo environment. | Implemented |
| `PUT` | `/api/environments/{id}` | Reconcile a managed environment. | Implemented |
| `DELETE` | `/api/environments/{id}` | Remove a state-tracked, ownership-verified environment. | Implemented |

See the official [List All Environments](https://apidocs.morpheusdata.com/reference/listenvironments) operation and related environment operations in the API reference.

### Groups and clouds

| Method | Path | Purpose | Status |
| --- | --- | --- | --- |
| `GET` | `/api/groups` | List infrastructure groups available to the user. | Planned |
| `GET` | `/api/groups/{id}` | Inspect group details. | Planned |
| `GET` | `/api/zones` | List cloud integrations; Morpheus uses `zones` in this API path. | Planned |
| `GET` | `/api/zones/{id}` | Inspect a cloud integration and status. | Planned |
| `POST`/`PUT` | `/api/zones[/{id}]` | Create or update a supported cloud integration. | Research |

### Demo platform resources

| Method | Path | Purpose | Status |
| --- | --- | --- | --- |
| CRUD | `/api/accounts` | Manage the Leroy demonstration subtenant. | Implemented |
| CRUD | `/api/roles` | Create tenant and persona roles. | Implemented |
| CRUD | `/api/accounts/{id}/users` | Create the three subtenant personas. | Implemented |
| CRUD | `/api/groups` | Manage cloud-agnostic demo groups. | Implemented |
| CRUD | `/api/policies` | Demonstrate governance policies. | Implemented |
| GET/DELETE | `/api/cypher/password/24/...` | Generate and remove demo credentials. | Implemented |
| CRUD | `/api/library/option-types` | Manage the workflow input. | Implemented |
| CRUD | `/api/tasks` | Manage the local Groovy task. | Implemented |
| CRUD | `/api/task-sets` | Manage and execute the operational workflow. | Implemented |
| CRUD | `/api/catalog-item-types` | Manage the workflow-backed catalog item. | Implemented |

Cloud configuration payloads are provider-specific. Leroy will not offer mutations until schemas, secret redaction, and per-provider tests exist.

### Instances and applications

| Method | Path | Purpose | Status |
| --- | --- | --- | --- |
| `GET` | `/api/instances` | List instances with filters and pagination. | Planned |
| `GET` | `/api/instances/{id}` | Inspect an instance. | Planned |
| `POST` | `/api/instances` | Provision an instance from validated input. | Research |
| `PUT` | `/api/instances/{id}` | Update supported instance properties. | Research |
| `DELETE` | `/api/instances/{id}` | Delete an instance with explicit destructive confirmation. | Research |
| `GET` | `/api/apps` | List applications. | Planned |
| `GET` | `/api/apps/{id}` | Inspect an application. | Planned |

See [Get All Instances](https://apidocs.morpheusdata.com/reference/listinstances) and [Create an Instance](https://apidocs.morpheusdata.com/reference/addinstance) for pagination, filters, and provisioning payloads.

### Supporting discovery

| Method | Path | Purpose | Status |
| --- | --- | --- | --- |
| `GET` | `/api/library/instance-types` | Discover provisionable instance types. | Research |
| `GET` | `/api/options/...` | Resolve dependent choices for provisioning forms. | Research |
| `GET` | `/api/plans` | List service plans where supported. | Research |
| `GET` | `/api/networks` | List networks available to the caller. | Research |

Options endpoints can be context-sensitive and version-dependent. Each use must document required query parameters and retain a fixture from a supported appliance version.

## Request behavior

All requests use configurable connect and total timeouts. Collection commands must handle Morpheus pagination rather than assuming one response contains every record. Query parameters must be URL-encoded, and identifiers must be validated before URL construction.

For JSON writes, Leroy will generate a preview and validate required fields locally before submission. It will not automatically retry non-idempotent requests.

## Response and error handling

| HTTP/result | Leroy behavior |
| --- | --- |
| `2xx` with valid JSON | Return normalized or raw output. |
| `400`/`422` | Report validation details without exposing submitted secrets. |
| `401`/`403` | Report authentication or authorization failure. |
| `404` | Report that the requested resource was not found. |
| `429` | Report rate limiting and honor `Retry-After` only for safe requests. |
| `5xx` | Report an appliance failure; retry only under an explicit policy. |
| Transport/TLS failure | Return a network error while preserving TLS verification defaults. |
| Invalid JSON | Treat as an unsupported or invalid API response. |

## Version validation checklist

Before promoting an endpoint from Planned or Research:

1. Confirm it in official documentation for the supported appliance versions.
2. Identify required Morpheus role permissions.
3. Capture sanitized success and error fixtures.
4. Test pagination, empty collections, and unexpected fields.
5. Document request and output schemas.
6. Verify tokens and secret payload fields are redacted from diagnostics.
7. Add TUI and CLI acceptance tests with identical underlying behavior.
