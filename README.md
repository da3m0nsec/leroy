# Leroy

Leroy is a Bash-based terminal application for exploring, configuring, and managing HPE Morpheus Enterprise environments. It provides two interfaces over the same command and API layers:

- an interactive TUI for operators who want guided navigation and confirmation prompts; and
- a non-interactive CLI for shell scripts, CI jobs, and infrastructure automation.

The project is in its `0.2.0` phase. The complete application lives in the single `leroy.sh` script, which contains configuration loading, authenticated HTTP transport, CLI commands, and the interactive TUI.

## Capabilities

- Build a complete Morpheus 9 demonstration tenant from an empty appliance, or select only the platform capabilities relevant to the customer.
- Demonstrate RBAC, environments, groups, policies, Cypher, automation, and self-service catalog capabilities without requiring a cloud.
- Expose equivalent CLI commands with stable output and exit codes.
- Support JSON output for composition with tools such as `jq`.
- Protect credentials by accepting access tokens through environment variables or user-only configuration files.
- Add confirmation gates and dry-run support before mutating Morpheus resources.

## Requirements

- Bash 4.4 or newer
- `curl`
- `jq`
- Optional for development: `shellcheck`, `shfmt`, and `bats-core`

## Installation

Clone the repository and run the setup script:

```bash
git clone <repository-url> leroy
cd leroy
bash ./scripts/setup.sh
```

For a user-local installation:

```bash
make install PREFIX="$HOME/.local"
```

This installs the single executable as `$HOME/.local/bin/leroy`. Ensure `$HOME/.local/bin` is on your `PATH`.

To run directly from a checkout, no installation is required:

```bash
bash ./leroy.sh --help
```

## Configuration

Copy the environment template and set the URL of your Morpheus appliance and an API access token:

```bash
cp .env.example .env
chmod 600 .env
${EDITOR:-vi} .env
```

If the URL or token is missing when Leroy starts in an interactive terminal, it asks for the missing values before opening the TUI or running the requested command. The token input is hidden and the answers apply only to the current process.

Then export the values before starting Leroy:

```bash
set -a
source .env
set +a
```

Do not commit `.env`, access tokens, passwords, or exported API responses containing sensitive data. For installed use, Leroy can also read `${XDG_CONFIG_HOME:-$HOME/.config}/leroy/config`; see [`config/leroy.conf.example`](config/leroy.conf.example).

## TUI usage

Start the interactive interface by running Leroy without a subcommand:

```bash
leroy
```

Or request it explicitly:

```bash
leroy tui
```

It runs in the terminal's alternate screen and needs no UI framework. Navigate with the arrow keys or `j`/`k`, press `Enter` to run the selected action, or use the displayed shortcut key. Press `q` or `Esc` to return to the shell. Keys the dashboard does not use, including function and navigation keys, are ignored rather than treated as `Esc`.

| Key | Action |
| --- | --- |
| `s` | Check connection and show identity, build, and tenant |
| `i` | Deployment inventory: recorded resources and their Morpheus IDs |
| `p` | Preview the plan for the current manifest and selection |
| `a` | Build or resume the selected demo |
| `v` | Verify structure and ownership |
| `d` | Deep verification of personas and the workflow |
| `r` | Recreate: destroy, then build the current selection |
| `x` | Destroy the demo the dashboard is showing |
| `c` | Select deployment components |
| `m` | Choose the manifest source: preset, a saved deployment, or a file |
| `w` | Create a custom manifest with the wizard |
| `q` | Quit |

The dashboard reports the appliance, the connection and authenticated identity, the active manifest with its demo ID, the component selection, the state of that demo, and the result of the latest action. Every row describes the demo the actions will operate on, so switching the manifest source switches all of them together. Leroy checks the connection once when the TUI opens; an unreachable appliance is reported on the dashboard instead of blocking startup.

Choose **Select deployment components** (`c`) to open a checkbox screen. All seven bundles are enabled initially: multitenancy, persona roles and users, environments, groups, policies, automation, and service catalog. Use the arrow keys or `j`/`k`, press `Space` to toggle, `a` to select all, `n` to clear all, `Enter` to save, or `Esc` to cancel. Dependencies are kept valid automatically: multitenancy and persona roles move together, policies require groups, and catalog requires automation. With multitenancy disabled, selected platform content is created in the Master Tenant instead. An asterisk marks a component that differs from the saved deployment, and the dashboard says when the selection needs a recreate.

Choose **Choose manifest source** (`m`) to pick what the TUI operates on: the built-in preset, one of the deployments recorded in the state directory, or a manifest file you name. Every state file embeds the manifest it was built from, so a saved deployment can be selected without still having its manifest; a deployment recorded against a different appliance is labelled as such. A manifest saved by the wizard (`w`) becomes the active source automatically. An unreadable or invalid manifest is refused and the previous source is kept.

**Build selected demo** (`a`) previews first: it runs the plan, lets you scroll it when it is longer than the screen, then reports how many resources it would create, update, and adopt, and asks for confirmation before anything is sent to Morpheus. A plan that reports conflicts fails the preview, so a build never starts over one.

If destruction or recreation stops because a resource no longer matches the ownership marker Leroy recorded, the TUI offers to retry with force and requires you to type `force`. Forcing still refuses any resource that carries no Leroy identity at all. Failures for other reasons, such as state belonging to a different appliance, are not offered a retry, because forcing would not help.

Inventory, verification, destruction, and recreation are only offered when a saved deployment exists for the active demo ID, and destruction and recreation require the exact organization name recorded in that state. Action output is shown while it runs; anything longer than the screen can be scrolled afterwards with `j`/`k`, `Space`, and `q`, because the alternate screen keeps no scrollback. Failures return to the dashboard instead of terminating the session. The dashboard fits an 80x24 terminal and drops its group headings when the terminal is shorter. Set `NO_COLOR=1` if the terminal should not emit color styling.

## Constructor gráfico de manifiestos

`web/` contiene un constructor gráfico que genera manifiestos sin escribir JSON
a mano. Se despliega en GitHub Pages y se ejecuta en local con `make web`.

Su portada explica la herramienta, describe los siete bloques que despliega y
ofrece la orden de instalación de la CLI lista para copiar:

```bash
curl -fsSL https://raw.githubusercontent.com/da3m0nsec/leroy/main/leroy.sh -o leroy && chmod +x leroy
```

El lienzo dibuja la demostración como cajas conectadas por las dependencias que
Leroy aplica realmente. Cada caja se arrastra y se activa o desactiva, lo que
enciende o apaga el bloque correspondiente del manifiesto. Trae escenarios de
partida (plataforma, banca, retail, telco y sector público), edita personas con
sus permisos y comprobaciones de acceso, valida contra las mismas reglas que
`leroy.sh`, y exporta un manifiesto de esquema 2:

```bash
leroy demo plan --file mi-demo.json
```

Consulta [`web/README.md`](web/README.md) para el detalle.

## Demo lifecycle

Print the built-in, secret-free manifest:

```bash
leroy demo preset > leroy-demo.json
```

Preview or apply the default demo:

```bash
leroy demo plan
leroy demo apply
```

Use a custom manifest produced by the TUI wizard or edited from the preset. The wizard prints a summary of what it generated and writes the complete manifest to the file:

```bash
leroy demo wizard
leroy demo plan --file custom-demo.json
leroy demo apply --file custom-demo.json
```

Verify resource ownership and configuration. Deep verification logs in temporarily as all three personas, checks positive and negative permissions, executes the autonomous workflow, and revokes its temporary OAuth tokens:

```bash
leroy demo verify --file custom-demo.json
leroy demo verify --file custom-demo.json --deep
```

Verification reports one row per check so a failing run names what failed:

```text
RESULT  CHECK      TARGET
pass    manifest   leroy-demo
pass    resource   environment:Leroy Development
fail    resource   group:Leroy Production (resource is missing on the appliance)
3 checks, 1 failed
```

Use `--output json` for `{verified, checked, failed, checks[]}` instead.

Inspect what Leroy recorded locally. Both commands read state only and need no appliance credentials:

```bash
leroy demo list
leroy demo state --demo-id leroy-demo
leroy --output json demo state --file custom-demo.json
```

Destructive commands require explicit confirmation and only act on IDs in local state whose remote ownership marker also matches:

```bash
leroy demo destroy --demo-id leroy-demo --yes
leroy demo recreate --file custom-demo.json --yes
```

Manifests come in two schema versions. Version 1 fixes the persona set at three,
with known keys and profiles, and keeps their Morpheus permission rules inside
`leroy.sh`. Version 2 moves that into the manifest: any number of personas, each
with its own permission rules, the access it must and must not have, whether it
receives catalog access, and whether it runs the demonstration workflow. Leroy
reads both, and `demo preset --schema 2` emits the built-in demo in the newer
form. The graphical builder produces version 2.

State is stored with user-only permissions under `${XDG_STATE_HOME:-$HOME/.local/state}/leroy`. An interrupted apply retains its completed resource IDs and can be resumed by running the same command again. If a saved deployment exists, changing its component selection requires **Recreate** so Leroy cannot silently leave deselected resources behind.

CLI users can make the same selection by editing the top-level `features` booleans in a generated manifest. Omitting `features` remains backward compatible and enables every bundle.

## CLI usage

Check authentication and appliance connectivity:

```bash
leroy status
```

List environment labels:

```bash
leroy environments list
```

Retrieve one environment by numeric ID:

```bash
leroy environments get 42
```

Return raw JSON for automation:

```bash
leroy --output json environments list | jq '.environments[] | .name'
```

Use a non-default configuration file:

```bash
leroy --config /secure/path/production.conf status
```

List collections with pagination applied, so a result is not limited to the first page:

```bash
leroy --output json environments list | jq '.environments | length'
```

Run `leroy --help` for the currently implemented command surface. CLI output written to standard output is intended for consumers; diagnostics are written to standard error.

## Security model

Leroy uses the Morpheus bearer-token authentication model. Tokens are never accepted as command-line flags because process arguments may be visible to other users. TLS verification defaults to disabled to support demonstration appliances with internal certificates; set `MORPHEUS_VERIFY_TLS=true` whenever the appliance has a trusted certificate. Demo-user passwords are generated by Morpheus Cypher and are never written to manifests or local state.

Use a dedicated Morpheus service account with the least privilege required for the intended operations. Store configuration files containing tokens with mode `0600`, prevent debug logs from recording authorization headers, and rotate credentials according to your organization’s policy.

## Development

```bash
make check      # syntax checks, ShellCheck, and tests when available
make test       # bats test suite
make format     # format Bash sources with shfmt
```

The automated suite never contacts a Morpheus appliance. [`docs/APPLIANCE_VALIDATION.md`](docs/APPLIANCE_VALIDATION.md) lists every behavior that stays unverified until it runs against one, with the checks to perform and the expected results.

See [`CONTRIBUTING.md`](CONTRIBUTING.md), [`ARCHITECTURE.md`](ARCHITECTURE.md), [`API_REFERENCE.md`](API_REFERENCE.md), [`docs/APPLIANCE_VALIDATION.md`](docs/APPLIANCE_VALIDATION.md), and [`docs/FEEDBACK.md`](docs/FEEDBACK.md) for contribution workflow, design details, endpoint coverage, appliance validation, and field feedback.

## Project status

The public interface is not yet stable. Commands, configuration keys, and output schemas may change before `1.0.0`. Changes are recorded in [`CHANGELOG.md`](CHANGELOG.md).

## License

Leroy is available under the [MIT License](LICENSE).
