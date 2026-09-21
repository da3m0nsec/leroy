#!/usr/bin/env node
// Prints the manifest a builder scenario produces, using the same modules the
// page loads. The test suite feeds the output to validate_manifest, so the
// builder cannot drift away from what leroy.sh accepts without CI noticing.
//
//   node web/tools/emit-manifests.mjs            # every scenario id
//   node web/tools/emit-manifests.mjs banca      # one manifest as JSON
//   node web/tools/emit-manifests.mjs banca count

import { buildManifest, resourceCount } from '../assets/schema.js';
import { SCENARIOS, scenarioById } from '../assets/scenarios.js';

const [, , id, mode] = process.argv;

if (!id) {
  for (const scenario of SCENARIOS) process.stdout.write(`${scenario.id}\n`);
  process.exit(0);
}

const scenario = SCENARIOS.find((item) => item.id === id);
if (!scenario) {
  process.stderr.write(`unknown scenario: ${id}\n`);
  process.exit(2);
}

const state = scenarioById(id).build();
if (mode === 'count') {
  process.stdout.write(`${resourceCount(state)}\n`);
} else {
  process.stdout.write(`${JSON.stringify(buildManifest(state), null, 2)}\n`);
}
