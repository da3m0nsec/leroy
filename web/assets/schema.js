// Manifest model for the Leroy demo builder.
//
// Every rule here mirrors validate_manifest in leroy.sh. When that function
// changes, change this file with it: a manifest the builder calls valid must be
// one Leroy accepts, or the operator finds out only at plan time.

export const FEATURE_KEYS = [
  'multitenancy', 'roles', 'environments', 'groups', 'policies', 'automation', 'catalog',
];

export const PROFILES = [
  { value: 'tenant-admin', label: 'Administrador del tenant' },
  { value: 'platform-operator', label: 'Operador de plataforma' },
  { value: 'service-consumer', label: 'Consumidor de servicio' },
  { value: 'auditor', label: 'Auditor' },
  { value: 'custom', label: 'Personalizado' },
];

export const ACCESS_LEVELS = [
  { value: 'source', label: 'source (el que anuncie Morpheus)' },
  { value: 'full', label: 'full' },
  { value: 'read', label: 'read' },
  { value: 'user', label: 'user' },
  { value: 'none', label: 'none' },
];

export const POLICY_TYPES = [
  { value: 'motd', label: 'Mensaje del día', config: { message: 'Bienvenido al entorno de demostración.' } },
  { value: 'instance-name', label: 'Nomenclatura de instancias', config: { namingPattern: '${userInitials}-${sequence}' } },
  { value: 'expiration', label: 'Caducidad', config: { expirationDays: 30 } },
  { value: 'cypher', label: 'Acceso a Cypher', config: { keyPattern: 'password/24/demo/*' } },
];

const ID_PATTERN = /^[a-z][a-z0-9-]{2,40}$/;
const SUBDOMAIN_PATTERN = /^[a-z][a-z0-9-]+$/;
const PERSONA_KEY_PATTERN = /^[a-z][a-z0-9-]{0,30}$/;
const SECRET_KEYS = new Set(['password', 'token', 'access_token']);

export function emptyFeatures(value = true) {
  return Object.fromEntries(FEATURE_KEYS.map((key) => [key, value]));
}

// Dependency rules, identical to tui_toggle_component in leroy.sh. The
// direction matters: switching a dependent on pulls its dependency in, and
// switching a dependency off pushes its dependents out. Applying both
// directions blindly would undo the change the operator just made.
export function applyFeatureDependencies(features, changed) {
  const next = { ...features };
  const value = next[changed];
  switch (changed) {
    case 'multitenancy':
    case 'roles':
      next.multitenancy = value;
      next.roles = value;
      break;
    case 'groups':
      if (!value) next.policies = false;
      break;
    case 'policies':
      if (value) next.groups = true;
      break;
    case 'automation':
      if (!value) next.catalog = false;
      break;
    case 'catalog':
      if (value) next.automation = true;
      break;
    default:
      break;
  }
  return next;
}

export function marker(id) {
  return `Managed by Leroy demo:${id}`;
}

// The resources a manifest expands to, mirroring RESOURCE_STREAM_JQ. The
// builder shows this count so it matches what Leroy will report.
export function resourceCount(state) {
  const f = state.features;
  let total = 0;
  if (f.multitenancy) total += 2;
  if (f.roles) total += state.personas.length * 3;
  if (f.environments) total += state.environments.length;
  if (f.groups) total += state.groups.length;
  if (f.policies) total += state.policies.length;
  if (f.automation) {
    total += state.automation.inputs.length + state.automation.tasks.length + state.automation.workflows.length;
  }
  if (f.catalog) total += state.automation.catalogItems.length;
  return total;
}

export function buildManifest(state) {
  const id = state.metadata.id;
  const description = marker(id);
  const manifest = {
    schemaVersion: 2,
    features: Object.fromEntries(FEATURE_KEYS.map((key) => [key, Boolean(state.features[key])])),
    metadata: {
      id,
      name: state.metadata.name,
      prefix: state.metadata.prefix || id,
      language: 'en',
    },
    tenant: {
      name: state.tenant.name,
      subdomain: state.tenant.subdomain,
      description,
    },
    personas: state.personas.map((persona) => {
      const entry = {
        key: persona.key,
        role: persona.role,
        username: persona.username,
        email: persona.email,
        profile: persona.profile,
      };
      if (persona.permissions.length > 0) {
        entry.permissions = persona.permissions.map((rule) => ({ pattern: rule.pattern, access: rule.access }));
      }
      if (persona.verify && persona.verify.allow) {
        entry.verify = persona.verify.deny
          ? { allow: persona.verify.allow, deny: persona.verify.deny }
          : { allow: persona.verify.allow };
      }
      entry.catalogAccess = persona.catalogAccess !== false;
      if (persona.runsWorkflow) entry.runsWorkflow = true;
      return entry;
    }),
    environments: state.environments.map((item) => ({
      name: item.name, code: item.code, description, visibility: item.visibility || 'private',
    })),
    groups: state.groups.map((item) => ({
      name: item.name, code: item.code, location: item.location || item.name, description,
    })),
    policies: state.policies.map((item) => ({
      name: item.name, code: item.code, type: item.type, scope: item.scope, config: item.config,
    })),
    automation: {
      inputs: state.automation.inputs.map((item) => ({
        name: item.name, fieldName: item.fieldName, fieldLabel: item.fieldLabel,
        type: 'text', defaultValue: item.defaultValue, required: true,
      })),
      tasks: state.automation.tasks.map((item) => ({
        name: item.name, code: item.code, type: 'groovy', resultType: 'json', content: item.content,
      })),
      workflows: state.automation.workflows.map((item) => ({
        name: item.name, code: item.code, type: 'operation', task: item.task, input: item.input,
      })),
      catalogItems: state.automation.catalogItems.map((item) => ({
        name: item.name, code: item.code, category: item.category, workflow: item.workflow,
        input: item.input, context: 'none', enabled: item.enabled !== false,
        featured: item.featured !== false, visibility: item.visibility || 'private',
      })),
    },
  };
  return manifest;
}

function hasSecretKey(value) {
  if (Array.isArray(value)) return value.some(hasSecretKey);
  if (value && typeof value === 'object') {
    return Object.entries(value).some(([key, inner]) => SECRET_KEYS.has(key) || hasSecretKey(inner));
  }
  return false;
}

// Returns the reasons Leroy would reject this manifest. An empty list means
// demo plan --file will get past validation.
export function validate(state) {
  const problems = [];
  const add = (node, message) => problems.push({ node, message });
  const f = state.features;

  if (!ID_PATTERN.test(state.metadata.id || '')) {
    add('meta', 'El ID de la demo debe empezar por letra minúscula y tener entre 3 y 41 caracteres (a-z, 0-9, guion).');
  }
  if (!(state.metadata.name || '').trim()) add('meta', 'La organización necesita un nombre.');
  if (!(state.tenant.name || '').trim()) add('tenant', 'El tenant necesita un nombre.');
  if (!SUBDOMAIN_PATTERN.test(state.tenant.subdomain || '')) {
    add('tenant', 'El subdominio del tenant debe empezar por letra minúscula y usar solo a-z, 0-9 y guion.');
  }

  if (state.personas.length === 0) add('personas', 'Hace falta al menos una persona.');
  const keys = new Set();
  const usernames = new Set();
  for (const persona of state.personas) {
    const node = `persona:${persona.key}`;
    if (!PERSONA_KEY_PATTERN.test(persona.key || '')) {
      add(node, `Clave de persona inválida: ${persona.key || '(vacía)'}`);
    }
    if (keys.has(persona.key)) add(node, `Clave de persona duplicada: ${persona.key}`);
    keys.add(persona.key);
    if (!(persona.username || '').trim()) add(node, `La persona ${persona.key} necesita un usuario.`);
    if (usernames.has(persona.username)) add(node, `Usuario duplicado: ${persona.username}`);
    usernames.add(persona.username);
    if (!(persona.email || '').trim()) add(node, `La persona ${persona.key} necesita un correo.`);
    if (!(persona.role || '').trim()) add(node, `La persona ${persona.key} necesita un nombre de rol.`);
    if (!(persona.profile || '').trim()) add(node, `La persona ${persona.key} necesita un perfil.`);
    for (const rule of persona.permissions) {
      if (!(rule.pattern || '').trim()) add(node, `Un permiso de ${persona.key} no tiene patrón.`);
      if (!(rule.access || '').trim()) add(node, `Un permiso de ${persona.key} no tiene nivel de acceso.`);
    }
    if (persona.verify && persona.verify.allow && !persona.verify.allow.startsWith('/api/')) {
      add(node, `La ruta permitida de ${persona.key} debe empezar por /api/.`);
    }
    if (persona.verify && persona.verify.deny && !persona.verify.deny.startsWith('/api/')) {
      add(node, `La ruta denegada de ${persona.key} debe empezar por /api/.`);
    }
  }
  if (f.roles) {
    const admins = state.personas.filter((persona) => persona.profile === 'tenant-admin');
    if (admins.length !== 1) {
      add('personas', `Con roles activos hace falta exactamente un perfil tenant-admin; hay ${admins.length}. Leroy inicia sesión como esa persona para obtener el token del tenant.`);
    }
  }
  if (state.personas.filter((persona) => persona.runsWorkflow).length > 1) {
    add('personas', 'Solo una persona puede ejecutar el flujo de trabajo.');
  }

  if (f.roles !== f.multitenancy) add('tenant', 'Multitenancy y roles de persona se despliegan juntos.');
  if (f.policies && !f.groups) add('policies', 'Las políticas necesitan grupos.');
  if (f.catalog && !f.automation) add('catalog', 'El catálogo necesita automatización.');

  if (f.automation) {
    const taskCodes = new Set(state.automation.tasks.map((item) => item.code));
    const inputNames = new Set(state.automation.inputs.map((item) => item.fieldName));
    for (const workflow of state.automation.workflows) {
      if (!taskCodes.has(workflow.task)) add('task', `El flujo ${workflow.name} referencia una tarea inexistente: ${workflow.task}`);
      if (!inputNames.has(workflow.input)) add('input', `El flujo ${workflow.name} referencia una entrada inexistente: ${workflow.input}`);
    }
  }
  if (f.catalog) {
    const workflowCodes = new Set(state.automation.workflows.map((item) => item.code));
    for (const item of state.automation.catalogItems) {
      if (!workflowCodes.has(item.workflow)) add('catalog', `El elemento de catálogo ${item.name} referencia un flujo inexistente: ${item.workflow}`);
    }
  }

  for (const [label, list] of [['entorno', state.environments], ['grupo', state.groups], ['política', state.policies]]) {
    const codes = new Set();
    for (const item of list) {
      if (!(item.code || '').trim()) add('meta', `Un ${label} no tiene código.`);
      if (codes.has(item.code)) add('meta', `Código de ${label} duplicado: ${item.code}`);
      codes.add(item.code);
    }
  }

  if (hasSecretKey(buildManifest(state))) {
    add('meta', 'El manifiesto no puede contener claves password, token ni access_token.');
  }
  return problems;
}

// Reads a manifest of either schema version back into builder state, so an
// existing demo can be opened, edited and exported again.
export function parseManifest(manifest) {
  const version = manifest.schemaVersion;
  if (version !== 1 && version !== 2) {
    throw new Error(`Versión de esquema no soportada: ${version}`);
  }
  const automation = manifest.automation || {};
  return {
    metadata: {
      id: manifest.metadata?.id || 'leroy-demo',
      name: manifest.metadata?.name || 'Leroy Demo',
      prefix: manifest.metadata?.prefix || manifest.metadata?.id || 'leroy-demo',
    },
    tenant: {
      name: manifest.tenant?.name || manifest.metadata?.name || 'Leroy Demo',
      subdomain: manifest.tenant?.subdomain || 'leroy-demo',
    },
    features: { ...emptyFeatures(true), ...(manifest.features || {}) },
    personas: (manifest.personas || []).map((persona) => ({
      key: persona.key,
      role: persona.role,
      username: persona.username,
      email: persona.email,
      profile: persona.profile,
      permissions: (persona.permissions || []).map((rule) => ({ pattern: rule.pattern, access: rule.access })),
      verify: persona.verify ? { allow: persona.verify.allow || '', deny: persona.verify.deny || '' } : { allow: '', deny: '' },
      catalogAccess: persona.catalogAccess !== false,
      runsWorkflow: persona.runsWorkflow === true,
    })),
    environments: (manifest.environments || []).map((item) => ({
      name: item.name, code: item.code, visibility: item.visibility || 'private',
    })),
    groups: (manifest.groups || []).map((item) => ({
      name: item.name, code: item.code, location: item.location || item.name,
    })),
    policies: (manifest.policies || []).map((item) => ({
      name: item.name, code: item.code, type: item.type, scope: item.scope || 'tenant', config: item.config || {},
    })),
    automation: {
      inputs: (automation.inputs || []).map((item) => ({
        name: item.name, fieldName: item.fieldName, fieldLabel: item.fieldLabel, defaultValue: item.defaultValue,
      })),
      tasks: (automation.tasks || []).map((item) => ({ name: item.name, code: item.code, content: item.content })),
      workflows: (automation.workflows || []).map((item) => ({
        name: item.name, code: item.code, task: item.task, input: item.input,
      })),
      catalogItems: (automation.catalogItems || []).map((item) => ({
        name: item.name, code: item.code, category: item.category, workflow: item.workflow,
        input: item.input, enabled: item.enabled !== false, featured: item.featured !== false,
        visibility: item.visibility || 'private',
      })),
    },
  };
}
