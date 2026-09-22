# Manifests

Leroy looks for manifests here, beside the script, and in a `manifests/`
directory under wherever you run it from. Anything in either shows up in the
TUI's manifest source screen, so a demo downloaded from the builder can be
dropped in and picked without typing a path. `LEROY_MANIFEST_DIR` overrides
both.

The files below are the builder's starting scenarios, generated from
`web/assets/scenarios.js`. Regenerate them with `make manifests` after changing
a scenario; `make check` fails if they drift.

| File | Demo | Resources |
| --- | --- | --- |
| `platform.json` | Standard platform | 24 |
| `banking.json` | Regulated banking, with a read-only auditor | 28 |
| `retail.json` | Multi-brand retail | 24 |
| `telco.json` | Telco and edge, no multitenancy | 12 |
| `public-sector.json` | Governance only, no automation or catalog | 17 |

Use one directly:

```bash
./leroy.sh demo plan --file manifests/banking.json
```

Your own manifests are welcome here too. They are not tracked by git except for
the generated ones listed above, so a manifest you drop in stays yours.
