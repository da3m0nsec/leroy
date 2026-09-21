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

function base(id, name, subdomain) {
  return {
    metadata: { id, name, prefix: id },
    tenant: { name, subdomain },
    features: emptyFeatures(true),
    personas: [
      persona(`admin`, `${name} Admin`, `${id}-admin`, 'tenant-admin', {
        verify: { allow: '/api/whoami', deny: '' },
      }),
      persona(`operator`, `${name} Operator`, `${id}-operator`, 'platform-operator', {
        permissions: OPERATOR_PERMISSIONS.map((rule) => ({ ...rule })),
        verify: { allow: '/api/tasks?max=1', deny: '' },
        runsWorkflow: true,
      }),
      persona(`consumer`, `${name} Consumer`, `${id}-consumer`, 'service-consumer', {
        permissions: CONSUMER_PERMISSIONS.map((rule) => ({ ...rule })),
        verify: { allow: '/api/catalog-item-types?max=1', deny: '/api/tasks?max=1' },
      }),
    ],
    environments: [],
    groups: [],
    policies: [],
    automation: {
      inputs: [{ name: 'Mensaje de la demo', fieldName: `${camel(id)}Message`, fieldLabel: 'Mensaje', defaultValue: 'Hola desde Leroy' }],
      tasks: [{ name: 'Saludo de la demo', code: `${id}-hello`, content: `return [success:true, message:(customOptions?.${camel(id)}Message ?: "Hola"), source:"${id}"]` }],
      workflows: [{ name: 'Bienvenida', code: `${id}-welcome`, task: `${id}-hello`, input: `${camel(id)}Message` }],
      catalogItems: [{ name: 'Bienvenida', code: `${id}-catalog`, category: name, workflow: `${id}-welcome`, input: `${camel(id)}Message`, enabled: true, featured: true, visibility: 'private' }],
    },
  };
}

function camel(id) {
  return id.replace(/-([a-z0-9])/g, (_, chr) => chr.toUpperCase());
}

function environments(id, entries) {
  return entries.map(([name, suffix]) => ({ name, code: `${id}-${suffix}`, visibility: 'private' }));
}

function groups(id, entries) {
  return entries.map(([name, suffix, location]) => ({ name, code: `${id}-${suffix}`, location: location || name }));
}

export const SCENARIOS = [
  {
    id: 'plataforma',
    label: 'Plataforma estándar',
    summary: 'La demostración completa de Leroy: tres personas, tres entornos y dos grupos.',
    build() {
      const id = 'leroy-demo';
      const state = base(id, 'Leroy Demo Organization', 'leroy-demo');
      state.environments = environments(id, [['Desarrollo', 'dev'], ['Preproducción', 'stg'], ['Producción', 'prod']]);
      state.groups = groups(id, [['Desarrollo', 'development'], ['Producción', 'production']]);
      state.policies = [
        { name: 'Mensaje de la demo', code: `${id}-motd`, type: 'motd', scope: 'tenant', config: { message: 'Bienvenido al entorno de demostración de Leroy.' } },
        { name: 'Nomenclatura', code: `${id}-instance-name`, type: 'instance-name', scope: 'groups', config: { namingPattern: `${id}-\${userInitials}-\${sequence}` } },
        { name: 'Caducidad', code: `${id}-expiration`, type: 'expiration', scope: 'groups', config: { expirationDays: 30 } },
        { name: 'Acceso a Cypher', code: `${id}-cypher`, type: 'cypher', scope: 'tenant', config: { keyPattern: `password/24/${id}/*` } },
      ];
      return state;
    },
  },
  {
    id: 'banca',
    label: 'Banca regulada',
    summary: 'Cuatro personas con auditor de solo lectura, caducidad corta y aviso de cumplimiento.',
    build() {
      const id = 'banca-demo';
      const state = base(id, 'Banca Demo', 'banca-demo');
      state.personas.push(persona('auditor', 'Banca Demo Auditor', `${id}-auditor`, 'auditor', {
        permissions: AUDITOR_PERMISSIONS.map((rule) => ({ ...rule })),
        verify: { allow: '/api/whoami', deny: '/api/tasks?max=1' },
        catalogAccess: false,
      }));
      state.environments = environments(id, [['Desarrollo', 'dev'], ['Integración', 'int'], ['Preproducción', 'pre'], ['Producción', 'pro']]);
      state.groups = groups(id, [['Core bancario', 'core', 'CPD principal'], ['Canales digitales', 'canales', 'CPD secundario']]);
      state.policies = [
        { name: 'Aviso de cumplimiento', code: `${id}-motd`, type: 'motd', scope: 'tenant', config: { message: 'Entorno sujeto a registro de actividad y normativa interna.' } },
        { name: 'Nomenclatura regulada', code: `${id}-instance-name`, type: 'instance-name', scope: 'groups', config: { namingPattern: 'bnk-${userInitials}-${sequence}' } },
        { name: 'Caducidad corta', code: `${id}-expiration`, type: 'expiration', scope: 'groups', config: { expirationDays: 7 } },
        { name: 'Acceso a Cypher', code: `${id}-cypher`, type: 'cypher', scope: 'tenant', config: { keyPattern: `password/24/${id}/*` } },
      ];
      return state;
    },
  },
  {
    id: 'retail',
    label: 'Retail multimarca',
    summary: 'Grupos por marca y catálogo de autoservicio destacado para tiendas.',
    build() {
      const id = 'retail-demo';
      const state = base(id, 'Retail Demo', 'retail-demo');
      state.environments = environments(id, [['Tienda', 'tienda'], ['Comercio electrónico', 'ecom'], ['Producción', 'pro']]);
      state.groups = groups(id, [['Marca norte', 'norte', 'Región norte'], ['Marca sur', 'sur', 'Región sur'], ['Plataforma común', 'comun', 'Central']]);
      state.policies = [
        { name: 'Aviso de campaña', code: `${id}-motd`, type: 'motd', scope: 'tenant', config: { message: 'Entorno de demostración para campañas de retail.' } },
        { name: 'Nomenclatura por marca', code: `${id}-instance-name`, type: 'instance-name', scope: 'groups', config: { namingPattern: 'rtl-${userInitials}-${sequence}' } },
        { name: 'Caducidad de campaña', code: `${id}-expiration`, type: 'expiration', scope: 'groups', config: { expirationDays: 14 } },
      ];
      state.automation.catalogItems[0].category = 'Servicios de tienda';
      return state;
    },
  },
  {
    id: 'telco',
    label: 'Telco y borde',
    summary: 'Entornos por región, sin multitenancy: todo se crea en el Master Tenant.',
    build() {
      const id = 'telco-demo';
      const state = base(id, 'Telco Demo', 'telco-demo');
      state.features = { ...emptyFeatures(true), multitenancy: false, roles: false };
      state.environments = environments(id, [['Núcleo', 'core'], ['Borde norte', 'edge-n'], ['Borde sur', 'edge-s'], ['Laboratorio', 'lab']]);
      state.groups = groups(id, [['Núcleo de red', 'core', 'CPD central'], ['Emplazamientos de borde', 'edge', 'Distribuido']]);
      state.policies = [
        { name: 'Aviso de red', code: `${id}-motd`, type: 'motd', scope: 'tenant', config: { message: 'Entorno de demostración de red y borde.' } },
        { name: 'Nomenclatura de nodo', code: `${id}-instance-name`, type: 'instance-name', scope: 'groups', config: { namingPattern: 'tlc-${userInitials}-${sequence}' } },
      ];
      return state;
    },
  },
  {
    id: 'publico',
    label: 'Sector público',
    summary: 'Solo gobierno y entornos: sin automatización ni catálogo, para una demostración corta.',
    build() {
      const id = 'sector-publico';
      const state = base(id, 'Sector Público Demo', 'sector-publico');
      state.features = { ...emptyFeatures(true), automation: false, catalog: false };
      state.environments = environments(id, [['Desarrollo', 'dev'], ['Producción', 'pro']]);
      state.groups = groups(id, [['Servicios ciudadanos', 'ciudadanos', 'CPD público'], ['Back office', 'backoffice', 'CPD público']]);
      state.policies = [
        { name: 'Aviso legal', code: `${id}-motd`, type: 'motd', scope: 'tenant', config: { message: 'Uso restringido a personal autorizado.' } },
        { name: 'Caducidad', code: `${id}-expiration`, type: 'expiration', scope: 'groups', config: { expirationDays: 30 } },
      ];
      return state;
    },
  },
];

export function scenarioById(id) {
  return SCENARIOS.find((scenario) => scenario.id === id) || SCENARIOS[0];
}
