# Leroy demo builder

Published at **https://da3m0nsec.github.io/leroy/**

A graphical manifest builder for HPE Morpheus demonstrations. It produces a
schema 2 JSON manifest that Leroy applies without conversion:

```bash
./leroy.sh demo plan  --file my-demo.json
./leroy.sh demo apply --file my-demo.json
```

The page has two views. The landing explains the tool, how it works, what it
deploys and how to install the CLI, with copyable `curl` and `wget` commands.
The "Manifest builder" button opens the canvas, which is also reachable
directly at `#builder`.

## How to use it

Download a manifest into the repository's `manifests/` directory and the TUI
lists it for selection, no path typing needed.

1. Pick a starting scenario (platform, banking, retail, telco, public sector).
2. Adjust identity, personas, environments, groups, policies and automation.
3. Switch blocks on and off with the toggle on each box of the canvas.
4. Download the manifest or copy the JSON, and apply it with Leroy.

Boxes drag, select for editing, and move with the arrow keys when focused. The
lines draw the dependencies Leroy actually applies: the tenant role before the
tenant, the users inside it, the policies over the groups, and the input and
the task inside the workflow the catalog exposes.

Work in progress is saved in the browser. No data leaves the page: there is no
server, no analytics and no calls to Morpheus. A manifest never contains
passwords; Leroy generates them with Cypher at apply time.

## Development

```bash
make web            # serves the builder at http://localhost:8765/
make web-manifests  # prints each scenario's manifest
make check          # includes the cross-checks between the builder and leroy.sh
```

No build step and no dependencies: HTML, CSS and ES modules served as they are,
the same way the rest of the project sticks to bash, curl and jq.

| File | Responsibility |
| --- | --- |
| `index.html` | Landing and builder, one page with two views. |
| `assets/schema.js` | Manifest model, dependency rules and validation. |
| `assets/scenarios.js` | Demonstration scenarios. |
| `assets/graph.js` | Canvas: boxes, edges, dragging and zoom. |
| `assets/app.js` | Views, inspector, validation, preview, import and export. |
| `tools/emit-manifests.mjs` | Runs the builder logic outside the browser, for the tests. |

## Why the validation is duplicated

`assets/schema.js` restates the rules of `validate_manifest` in `leroy.sh`. The
duplication is deliberate: the builder is static and cannot run bash. If you
change the rules in `leroy.sh`, change them here too. `make check` runs every
scenario through `validate_manifest` and compares the resource counts of both
implementations, so a divergence breaks CI.

## Publishing

`.github/workflows/pages.yml` publishes this directory to GitHub Pages on every
push to `main` that touches `web/`. It requires Pages to be configured in the
repository with "GitHub Actions" as the source.

The landing offers the CLI from
`https://raw.githubusercontent.com/da3m0nsec/leroy/main/leroy.sh`, that is, the
default branch. Once the project publishes tagged releases, that URL should
point at a tag so the install command is reproducible.
