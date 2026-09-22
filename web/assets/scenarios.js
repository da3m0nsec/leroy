// Demo scenarios. Each one is a complete builder state: picking it fills the
// canvas with a coherent demonstration that an operator then adjusts.

import { emptyFeatures } from './schema.js';

function persona(key, role, username, profile, extras = {}) {
  return {
    key,
    role,
    username,
    email: `${username}@example.invalid`,
    profile,
    permissions: [],
    verify: { allow: '', deny: '' },
    catalogAccess: true,
    runsWorkflow: false,
    ...extras,
  };
}

const OPERATOR_PERMISSIONS = [
  { pattern: 'provisioning.*instances|instances[[:space:]]*$|provisioning.*apps|provisioning.*tasks|tasks.*script engines|library', access: 'source' },
  { pattern: 'infrastructure', access: 'source' },
];
const CONSUMER_PERMISSIONS = [{ pattern: 'catalog|service catalog', access: 'source' }];
const AUDITOR_PERMISSIONS = [{ pattern: 'reports|logs|activity', access: 'read' }];

function camel(id) {
  return id.replace(/-([a-z0-9])/g, (_, chr) => chr.toUpperCase());
}

function base(id, name, subdomain) {
  return {
    metadata: { id, name, prefix: id },
    tenant: { name, subdomain },
    features: emptyFeatures(true),
    personas: [
      persona('admin', `${name} Admin`, `${id}-admin`, 'tenant-admin', {
        verify: { allow: '/api/whoami', deny: '' },
      }),
      persona('operator', `${name} Operator`, `${id}-operator`, 'platform-operator', {
        permissions: OPERATOR_PERMISSIONS.map((rule) => ({ ...rule })),
        verify: { allow: '/api/tasks?max=1', deny: '' },
        runsWorkflow: true,
      }),
      persona('consumer', `${name} Consumer`, `${id}-consumer`, 'service-consumer', {
        permissions: CONSUMER_PERMISSIONS.map((rule) => ({ ...rule })),
        verify: { allow: '/api/catalog-item-types?max=1', deny: '/api/tasks?max=1' },
      }),
    ],
    environments: [],
    groups: [],
    policies: [],
    automation: {
      inputs: [{ name: 'Demo message', fieldName: `${camel(id)}Message`, fieldLabel: 'Message', defaultValue: 'Hello from Leroy' }],
      tasks: [{ name: 'Demo hello', code: `${id}-hello`, content: `return [success:true, message:(customOptions?.${camel(id)}Message ?: "Hello"), source:"${id}"]` }],
      workflows: [{ name: 'Welcome', code: `${id}-welcome`, task: `${id}-hello`, input: `${camel(id)}Message` }],
      catalogItems: [{ name: 'Welcome', code: `${id}-catalog`, category: name, workflow: `${id}-welcome`, input: `${camel(id)}Message`, enabled: true, featured: true, visibility: 'private' }],
    },
  };
}

function environments(id, entries) {
  return entries.map(([name, suffix]) => ({ name, code: `${id}-${suffix}`, visibility: 'private' }));
}

function groups(id, entries) {
  return entries.map(([name, suffix, location]) => ({ name, code: `${id}-${suffix}`, location: location || name }));
}

export const SCENARIOS = [
  {
    id: 'platform',
    label: 'Standard platform',
    summary: "Leroy's complete demonstration: three personas, three environments and two groups.",
    build() {
      const id = 'leroy-demo';
      const state = base(id, 'Leroy Demo Organization', 'leroy-demo');
      state.environments = environments(id, [['Development', 'dev'], ['Staging', 'stg'], ['Production', 'prod']]);
      state.groups = groups(id, [['Development', 'development'], ['Production', 'production']]);
      state.policies = [
        { name: 'Demo message', code: `${id}-motd`, type: 'motd', scope: 'tenant', config: { message: 'Welcome to the Leroy demonstration environment.' } },
        { name: 'Instance naming', code: `${id}-instance-name`, type: 'instance-name', scope: 'groups', config: { namingPattern: `${id}-\${userInitials}-\${sequence}` } },
        { name: 'Expiration', code: `${id}-expiration`, type: 'expiration', scope: 'groups', config: { expirationDays: 30 } },
        { name: 'Cypher access', code: `${id}-cypher`, type: 'cypher', scope: 'tenant', config: { keyPattern: `password/24/${id}/*` } },
      ];
      return state;
    },
  },
  {
    id: 'banking',
    label: 'Regulated banking',
    summary: 'Four personas including a read-only auditor, short expiration and a compliance notice.',
    build() {
      const id = 'banking-demo';
      const state = base(id, 'Banking Demo', 'banking-demo');
      state.personas.push(persona('auditor', 'Banking Demo Auditor', `${id}-auditor`, 'auditor', {
        permissions: AUDITOR_PERMISSIONS.map((rule) => ({ ...rule })),
        verify: { allow: '/api/whoami', deny: '/api/tasks?max=1' },
        catalogAccess: false,
      }));
      state.environments = environments(id, [['Development', 'dev'], ['Integration', 'int'], ['Staging', 'pre'], ['Production', 'prod']]);
      state.groups = groups(id, [['Core banking', 'core', 'Primary data centre'], ['Digital channels', 'channels', 'Secondary data centre']]);
      state.policies = [
        { name: 'Compliance notice', code: `${id}-motd`, type: 'motd', scope: 'tenant', config: { message: 'Activity in this environment is logged and subject to internal policy.' } },
        { name: 'Regulated naming', code: `${id}-instance-name`, type: 'instance-name', scope: 'groups', config: { namingPattern: 'bnk-${userInitials}-${sequence}' } },
        { name: 'Short expiration', code: `${id}-expiration`, type: 'expiration', scope: 'groups', config: { expirationDays: 7 } },
        { name: 'Cypher access', code: `${id}-cypher`, type: 'cypher', scope: 'tenant', config: { keyPattern: `password/24/${id}/*` } },
      ];
      return state;
    },
  },
  {
    id: 'retail',
    label: 'Multi-brand retail',
    summary: 'Groups per brand and a featured self-service catalog for stores.',
    build() {
      const id = 'retail-demo';
      const state = base(id, 'Retail Demo', 'retail-demo');
      state.environments = environments(id, [['Store', 'store'], ['E-commerce', 'ecom'], ['Production', 'prod']]);
      state.groups = groups(id, [['North brand', 'north', 'Northern region'], ['South brand', 'south', 'Southern region'], ['Shared platform', 'shared', 'Central']]);
      state.policies = [
        { name: 'Campaign notice', code: `${id}-motd`, type: 'motd', scope: 'tenant', config: { message: 'Demonstration environment for retail campaigns.' } },
        { name: 'Naming per brand', code: `${id}-instance-name`, type: 'instance-name', scope: 'groups', config: { namingPattern: 'rtl-${userInitials}-${sequence}' } },
        { name: 'Campaign expiration', code: `${id}-expiration`, type: 'expiration', scope: 'groups', config: { expirationDays: 14 } },
      ];
      state.automation.catalogItems[0].category = 'Store services';
      return state;
    },
  },
  {
    id: 'telco',
    label: 'Telco and edge',
    summary: 'Environments per region, without multitenancy: everything is created in the Master Tenant.',
    build() {
      const id = 'telco-demo';
      const state = base(id, 'Telco Demo', 'telco-demo');
      state.features = { ...emptyFeatures(true), multitenancy: false, roles: false };
      state.environments = environments(id, [['Core', 'core'], ['North edge', 'edge-n'], ['South edge', 'edge-s'], ['Lab', 'lab']]);
      state.groups = groups(id, [['Network core', 'core', 'Central data centre'], ['Edge sites', 'edge', 'Distributed']]);
      state.policies = [
        { name: 'Network notice', code: `${id}-motd`, type: 'motd', scope: 'tenant', config: { message: 'Demonstration environment for network and edge.' } },
        { name: 'Node naming', code: `${id}-instance-name`, type: 'instance-name', scope: 'groups', config: { namingPattern: 'tlc-${userInitials}-${sequence}' } },
      ];
      return state;
    },
  },
  {
    id: 'public-sector',
    label: 'Public sector',
    summary: 'Governance and environments only: no automation or catalog, for a short demonstration.',
    build() {
      const id = 'public-sector';
      const state = base(id, 'Public Sector Demo', 'public-sector');
      state.features = { ...emptyFeatures(true), automation: false, catalog: false };
      state.environments = environments(id, [['Development', 'dev'], ['Production', 'prod']]);
      state.groups = groups(id, [['Citizen services', 'citizen', 'Public data centre'], ['Back office', 'backoffice', 'Public data centre']]);
      state.policies = [
        { name: 'Legal notice', code: `${id}-motd`, type: 'motd', scope: 'tenant', config: { message: 'Restricted to authorised personnel.' } },
        { name: 'Expiration', code: `${id}-expiration`, type: 'expiration', scope: 'groups', config: { expirationDays: 30 } },
      ];
      return state;
    },
  },
];

export function scenarioById(id) {
  return SCENARIOS.find((scenario) => scenario.id === id) || SCENARIOS[0];
}
