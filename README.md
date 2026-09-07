# Leroy

Leroy is a Bash-based terminal application for exploring, configuring, and managing HPE Morpheus Enterprise environments. It provides two interfaces over the same command and API layers:

- an interactive TUI for operators who want guided navigation and confirmation prompts; and
- a non-interactive CLI for shell scripts, CI jobs, and infrastructure automation.

The project is in its `0.2.0` phase. The complete application lives in the single `leroy.sh` script, which contains configuration loading, authenticated HTTP transport, CLI commands, and the interactive TUI.

## Capabilities

- Build a complete Morpheus 9 demonstration tenant from an empty appliance.
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

The TUI exposes status, manifest generation, planning, application, structural and deep verification, recreation, and protected destruction.

It runs in the terminal's alternate screen and needs no UI framework. Navigate with the arrow keys or `j`/`k`, press `Enter` to run the selected action, or use the displayed shortcut key (`s`, `p`, `a`, `v`, `d`, `r`, `x`, or `w`). Press `q` or `Esc` to return to the shell. Action results remain visible until a key is pressed, and failures return to the dashboard instead of terminating the session.

The dashboard shows the configured appliance, connection status, local lifecycle state, and the result of the latest action. Destruction and recreation require the exact organization name before Leroy makes changes. Set `NO_COLOR=1` if the terminal should not emit color styling.

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

Use a custom manifest produced by the TUI wizard or edited from the preset:

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

Destructive commands require explicit confirmation and only act on IDs in local state whose remote ownership marker also matches:

```bash
leroy demo destroy --demo-id leroy-demo --yes
leroy demo recreate --file custom-demo.json --yes
```

State is stored with user-only permissions under `${XDG_STATE_HOME:-$HOME/.local/state}/leroy`. An interrupted apply retains its completed resource IDs and can be resumed by running the same command again.

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

Run `leroy --help` for the currently implemented command surface. CLI output written to standard output is intended for consumers; diagnostics are written to standard error.

## Security model

Leroy uses the Morpheus bearer-token authentication model. Tokens are never accepted as command-line flags because process arguments may be visible to other users. TLS verification is enabled by default. Disabling it is intended only for controlled development environments and emits a warning. Demo-user passwords are generated by Morpheus Cypher and are never written to manifests or local state.

Use a dedicated Morpheus service account with the least privilege required for the intended operations. Store configuration files containing tokens with mode `0600`, prevent debug logs from recording authorization headers, and rotate credentials according to your organization’s policy.

## Development

```bash
make check      # syntax checks, ShellCheck, and tests when available
make test       # bats test suite
make format     # format Bash sources with shfmt
```

See [`CONTRIBUTING.md`](CONTRIBUTING.md), [`ARCHITECTURE.md`](ARCHITECTURE.md), and [`API_REFERENCE.md`](API_REFERENCE.md) for contribution workflow, design details, and the endpoint roadmap.

## Project status

The public interface is not yet stable. Commands, configuration keys, and output schemas may change before `1.0.0`. Changes are recorded in [`CHANGELOG.md`](CHANGELOG.md).

## License

Leroy is available under the [MIT License](LICENSE).
