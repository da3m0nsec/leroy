# Leroy

Build a complete HPE Morpheus 9 demonstration from an empty appliance — tenant,
personas, environments, groups, policies, automation and a self-service catalog
— then take it down again cleanly. No cloud integration required.

### [→ Open the manifest builder](https://da3m0nsec.github.io/leroy/)

Design the demonstration in the browser, download the manifest, apply it with
one command. The whole tool is a single Bash script.

```bash
curl -fsSL https://raw.githubusercontent.com/da3m0nsec/leroy/main/leroy.sh -O && chmod +x leroy.sh
export MORPHEUS_URL="https://morpheus.example.com"
export MORPHEUS_API_TOKEN="a-master-tenant-admin-token"
./leroy.sh demo apply --file my-demo.json
```

Needs Bash 4.4+, `curl`, `jq`, and a Master Tenant administrator token on
Morpheus 9. Tokens are read from the environment, never from arguments.
`make install` puts the same script on your `PATH` as `leroy`, if you prefer
that to running it from the checkout.

## Three ways in, one behavior

| | How | For |
| --- | --- | --- |
| **Builder** | [the page above](https://da3m0nsec.github.io/leroy/), or `make web` locally | Designing a demo without writing JSON |
| **TUI** | `./leroy.sh` | Guided operation with confirmations |
| **CLI** | `./leroy.sh demo …` | Scripts, CI and automation |

The TUI and CLI call the same functions, so they cannot drift apart.

## Demo lifecycle

```bash
./leroy.sh demo preset > my-demo.json        # built-in manifest to start from
./leroy.sh demo plan    --file my-demo.json  # preview; changes nothing
./leroy.sh demo apply   --file my-demo.json  # build; resumable if interrupted
./leroy.sh demo verify  --file my-demo.json --deep
./leroy.sh demo destroy --demo-id my-demo --yes
```

`verify` checks that every recorded resource still exists and is Leroy's.
`--deep` also logs in as each persona to confirm what it may and may not do,
runs the workflow, and revokes its temporary tokens. It reports one row per
check and exits `9` if any fails.

Also available: `demo list` and `demo state` (read local state, no credentials
needed), `demo wizard`, `demo recreate`, and `demo preset --schema 2`.

Destructive commands need explicit confirmation and only touch resources whose
recorded ID **and** remote ownership marker both match.

Read-only commands: `./leroy.sh status` checks authentication and connectivity,
`./leroy.sh environments list` and `environments get ID` read environment labels.
Add `--output json` to any of them to pipe into `jq`.

## What it builds

Seven blocks you switch on and off independently:

| Block | Creates |
| --- | --- |
| Multitenancy | The demo organization and its account role |
| Roles and users | One role, Cypher password and user per persona |
| Environments | Environment labels for provisioning |
| Groups | Infrastructure groups to govern |
| Policies | MOTD, instance naming, expiration, Cypher access |
| Automation | An input, a local Groovy task and an operational workflow |
| Catalog | A self-service item backed by that workflow |

Dependencies hold themselves: policies need groups, the catalog needs
automation, and persona roles travel with the tenant. Without multitenancy,
the selected content is created in the Master Tenant instead.

## Manifests

A manifest is a secret-free JSON document describing the demonstration.

- **Schema 1** fixes three personas with known keys, and keeps their permission
  rules inside `leroy.sh`.
- **Schema 2** lets the manifest define any number of personas, each with its
  own permission rules, the access it must and must not have, whether it gets
  catalog access, and which one runs the workflow. The builder produces this.

Leroy reads both. `demo preset --schema 2` emits the built-in demo in the newer
form.

## TUI

Run `./leroy.sh` with no arguments. The dashboard reports the appliance, the
authenticated identity, the active manifest and its demo, the component
selection, and the state of that deployment.

| Key | Action |
| --- | --- |
| `s` `i` | Connection status · deployment inventory |
| `p` `a` | Preview plan · build (previews and confirms first) |
| `v` `d` | Verify structure · deep verification |
| `r` `x` | Recreate · destroy (both confirm with the organization name) |
| `c` `m` `w` | Components · manifest source · manifest wizard |
| `q` | Quit |

Boxes, arrow keys and `j`/`k` all work. Output longer than the screen can be
scrolled. Set `NO_COLOR=1` to drop the color styling.

## Security

- Manifests carry no credentials: Morpheus Cypher generates persona passwords
  at apply time, and validation rejects `password`, `token` or `access_token`
  keys outright.
- Tokens come from `MORPHEUS_API_TOKEN` or a `0600` config file, never from
  command-line arguments, which other users can read.
- Everything Leroy creates carries an ownership marker. `destroy` verifies it
  before deleting and stops if anything does not match.
- TLS verification defaults to **off** for appliances with internal
  certificates. Set `MORPHEUS_VERIFY_TLS=true` when the certificate is trusted.
- Use a dedicated least-privilege service account on a demonstration appliance.

State lives under `${XDG_STATE_HOME:-$HOME/.local/state}/leroy` with user-only
permissions and holds resource IDs, never passwords.

## Configuration

Values resolve from built-in defaults, then
`${XDG_CONFIG_HOME:-$HOME/.config}/leroy/config`, then `--config FILE`, then
exported `MORPHEUS_*` variables. See
[`config/leroy.conf.example`](config/leroy.conf.example). Missing values are
requested interactively when a terminal is available; automation still fails
without prompting.

Global options: `--config FILE`, `--output table|json`, `-h`, `-V`.
Exit codes are documented in [`ARCHITECTURE.md`](ARCHITECTURE.md).

## Development

```bash
make check   # syntax, ShellCheck and the test suite
make web     # serve the builder at http://localhost:8765/
```

No test contacts a Morpheus appliance, so a passing suite does not prove that
Morpheus accepts a request. Everything that only an appliance can settle is
listed in [`docs/APPLIANCE_VALIDATION.md`](docs/APPLIANCE_VALIDATION.md).

| Document | |
| --- | --- |
| [`ARCHITECTURE.md`](ARCHITECTURE.md) | Design, schema versions, exit codes |
| [`API_REFERENCE.md`](API_REFERENCE.md) | Morpheus endpoint coverage |
| [`CONTRIBUTING.md`](CONTRIBUTING.md) | Workflow and conventions |
| [`web/README.md`](web/README.md) | The builder |
| [`docs/FEEDBACK.md`](docs/FEEDBACK.md) | Field findings |

## Status

Version `0.2.0`. The public interface is not stable yet: commands,
configuration keys and output schemas may change before `1.0.0`. Changes are
recorded in [`CHANGELOG.md`](CHANGELOG.md). Available under the
[MIT License](LICENSE).
