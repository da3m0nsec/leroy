import {
  ACCESS_LEVELS, FEATURE_KEYS, POLICY_TYPES, PROFILES,
  applyFeatureDependencies, buildManifest, parseManifest, resourceCount, validate,
} from './schema.js';
import { SCENARIOS, scenarioById } from './scenarios.js';
import { Canvas, buildGraph } from './graph.js';

const STORAGE_KEY = 'leroy-builder.state.v1';
const FEATURE_LABELS = {
  multitenancy: 'Multitenancy',
  roles: 'Roles y usuarios',
  environments: 'Entornos',
  groups: 'Grupos',
  policies: 'Políticas',
  automation: 'Automatización',
  catalog: 'Catálogo',
};

let state = scenarioById('plataforma').build();
let selected = 'tenant';
let canvas;

const el = (id) => document.getElementById(id);

// --- persistence -----------------------------------------------------------
// Browser storage can be unavailable or blocked, and the page must still work.
function save() {
  try {
    localStorage.setItem(STORAGE_KEY, JSON.stringify({ state, positions: canvas.exportPositions(), selected }));
  } catch { /* ignore: the builder is fully usable without storage */ }
}

function restore() {
  try {
    const raw = localStorage.getItem(STORAGE_KEY);
    if (!raw) return null;
    return JSON.parse(raw);
  } catch {
    return null;
  }
}

// --- small form helpers ----------------------------------------------------
function control(labelText, node) {
  const wrap = document.createElement('label');
  wrap.className = 'field';
  const span = document.createElement('span');
  span.textContent = labelText;
  wrap.append(span, node);
  return wrap;
}

function textField(labelText, value, onInput, { placeholder = '', mono = false, textarea = false } = {}) {
  const input = document.createElement(textarea ? 'textarea' : 'input');
  if (!textarea) input.type = 'text';
  input.value = value ?? '';
  input.placeholder = placeholder;
  if (mono) input.classList.add('mono');
  if (textarea) input.rows = 4;
  input.addEventListener('input', () => { onInput(input.value); refresh({ inspector: false }); });
  input.addEventListener('change', () => refresh());
  return control(labelText, input);
}

function selectField(labelText, value, options, onChange) {
  const select = document.createElement('select');
  for (const option of options) {
    const node = document.createElement('option');
    node.value = option.value;
    node.textContent = option.label;
    select.append(node);
  }
  select.value = value;
  select.addEventListener('change', () => { onChange(select.value); refresh(); });
  return control(labelText, select);
}

function switchField(labelText, value, onChange, hint = '') {
  const wrap = document.createElement('div');
  wrap.className = 'switch-row';
  const button = document.createElement('button');
  button.type = 'button';
  button.className = 'switch';
  button.setAttribute('role', 'switch');
  button.setAttribute('aria-checked', String(Boolean(value)));
  button.addEventListener('click', () => { onChange(!value); refresh(); });
  const text = document.createElement('div');
  const strong = document.createElement('strong');
  strong.textContent = labelText;
  text.append(strong);
  if (hint) {
    const small = document.createElement('small');
    small.textContent = hint;
    text.append(small);
  }
  wrap.append(button, text);
  return wrap;
}

function sectionTitle(text, action) {
  const header = document.createElement('div');
  header.className = 'section-head';
  const heading = document.createElement('h3');
  heading.textContent = text;
  header.append(heading);
  if (action) header.append(action);
  return header;
}

function iconButton(label, onClick, variant = '') {
  const button = document.createElement('button');
  button.type = 'button';
  button.className = `mini ${variant}`.trim();
  button.textContent = label;
  button.addEventListener('click', onClick);
  return button;
}

// --- inspector -------------------------------------------------------------
function inspectorFor(id) {
  const panel = document.createElement('div');
  panel.className = 'inspector';
  if (id === 'tenant' || id === 'tenant-role') return tenantInspector(panel);
  if (id.startsWith('persona:')) return personaInspector(panel, id.slice('persona:'.length));
  if (id === 'environments') return listInspector(panel, 'Entornos', state.environments, environmentFields, () => ({
    name: 'Nuevo entorno', code: `${state.metadata.id}-nuevo`, visibility: 'private',
  }));
  if (id === 'groups') return listInspector(panel, 'Grupos', state.groups, groupFields, () => ({
    name: 'Nuevo grupo', code: `${state.metadata.id}-nuevo`, location: 'Sin ubicación',
  }));
  if (id === 'policies') return policiesInspector(panel);
  if (id === 'input' || id === 'task' || id === 'workflow') return automationInspector(panel, id);
  if (id === 'catalog') return catalogInspector(panel);
  panel.append(hint('Selecciona una caja del lienzo para editarla.'));
  return panel;
}

function hint(text) {
  const paragraph = document.createElement('p');
  paragraph.className = 'hint';
  paragraph.textContent = text;
  return paragraph;
}

function tenantInspector(panel) {
  panel.append(sectionTitle('Tenant'));
  panel.append(hint('Sin multitenancy, el contenido seleccionado se crea en el Master Tenant y los payloads omiten la cuenta del tenant.'));
  panel.append(textField('Nombre de la organización', state.tenant.name, (value) => {
    state.tenant.name = value;
    state.metadata.name = value;
  }));
  panel.append(textField('Subdominio', state.tenant.subdomain, (value) => { state.tenant.subdomain = value; }, { mono: true }));
  panel.append(hint(`Las personas inician sesión como subdominio\\usuario, por ejemplo ${state.tenant.subdomain || 'subdominio'}\\${state.personas[0]?.username || 'usuario'}.`));
  return panel;
}

function personaInspector(panel, key) {
  const persona = state.personas.find((item) => item.key === key);
  if (!persona) return panel;
  const remove = iconButton('Eliminar', () => {
    state.personas = state.personas.filter((item) => item !== persona);
    selected = 'tenant';
    refresh();
  }, 'danger');
  panel.append(sectionTitle(`Persona: ${persona.key}`, state.personas.length > 1 ? remove : null));
  panel.append(hint('Cada persona genera tres recursos: un rol, una clave Cypher con su contraseña y un usuario.'));
  panel.append(textField('Clave', persona.key, (value) => { persona.key = value; selected = `persona:${value}`; }, { mono: true }));
  panel.append(textField('Nombre del rol', persona.role, (value) => { persona.role = value; }));
  panel.append(textField('Usuario', persona.username, (value) => { persona.username = value; }, { mono: true }));
  panel.append(textField('Correo', persona.email, (value) => { persona.email = value; }, { mono: true }));
  panel.append(selectField('Perfil', persona.profile, PROFILES, (value) => { persona.profile = value; }));
  panel.append(switchField('Acceso al catálogo', persona.catalogAccess !== false, (value) => { persona.catalogAccess = value; },
    'Concede el elemento de catálogo a este rol.'));
  panel.append(switchField('Ejecuta el flujo', Boolean(persona.runsWorkflow), (value) => {
    for (const item of state.personas) item.runsWorkflow = false;
    persona.runsWorkflow = value;
  }, 'La verificación profunda ejecuta el flujo como esta persona.'));

  panel.append(sectionTitle('Permisos', iconButton('Añadir', () => {
    persona.permissions.push({ pattern: '', access: 'source' });
    refresh();
  })));
  panel.append(hint('Cada patrón es una expresión regular que Leroy compara, sin distinguir mayúsculas, con el nombre y el código de los permisos que anuncia el rol base de Morpheus. Sin permisos, se usan las reglas integradas del perfil.'));
  for (const rule of persona.permissions) {
    const row = document.createElement('div');
    row.className = 'rule';
    row.append(textField('Patrón', rule.pattern, (value) => { rule.pattern = value; }, { mono: true, placeholder: 'catalog|service catalog' }));
    row.append(selectField('Acceso', rule.access, ACCESS_LEVELS, (value) => { rule.access = value; }));
    row.append(iconButton('Quitar', () => {
      persona.permissions = persona.permissions.filter((item) => item !== rule);
      refresh();
    }, 'danger'));
    panel.append(row);
  }

  panel.append(sectionTitle('Verificación'));
  panel.append(hint('Rutas que comprueba leroy demo verify --deep iniciando sesión como esta persona.'));
  panel.append(textField('Debe poder acceder a', persona.verify.allow, (value) => { persona.verify.allow = value; }, { mono: true, placeholder: '/api/whoami' }));
  panel.append(textField('No debe poder acceder a', persona.verify.deny, (value) => { persona.verify.deny = value; }, { mono: true, placeholder: '/api/tasks?max=1' }));
  return panel;
}

function environmentFields(item) {
  return [
    textField('Nombre', item.name, (value) => { item.name = value; }),
    textField('Código', item.code, (value) => { item.code = value; }, { mono: true }),
  ];
}

function groupFields(item) {
  return [
    textField('Nombre', item.name, (value) => { item.name = value; }),
    textField('Código', item.code, (value) => { item.code = value; }, { mono: true }),
    textField('Ubicación', item.location, (value) => { item.location = value; }),
  ];
}

function listInspector(panel, title, list, fields, create) {
  panel.append(sectionTitle(title, iconButton('Añadir', () => { list.push(create()); refresh(); })));
  list.forEach((item, index) => {
    const card = document.createElement('div');
    card.className = 'card';
    const head = document.createElement('div');
    head.className = 'card__head';
    const name = document.createElement('strong');
    name.textContent = item.name || `Elemento ${index + 1}`;
    head.append(name, iconButton('Quitar', () => {
      const position = list.indexOf(item);
      if (position >= 0) list.splice(position, 1);
      refresh();
    }, 'danger'));
    card.append(head, ...fields(item));
    panel.append(card);
  });
  if (list.length === 0) panel.append(hint('Sin elementos. Este bloque no creará nada.'));
  return panel;
}

function policiesInspector(panel) {
  panel.append(sectionTitle('Políticas', iconButton('Añadir', () => {
    const type = POLICY_TYPES[0];
    state.policies.push({
      name: type.label, code: `${state.metadata.id}-${type.value}`, type: type.value,
      scope: 'tenant', config: { ...type.config },
    });
    refresh();
  })));
  panel.append(hint('Leroy resuelve el tipo de política por nombre contra /api/policy-types del appliance.'));
  for (const policy of state.policies) {
    const card = document.createElement('div');
    card.className = 'card';
    const head = document.createElement('div');
    head.className = 'card__head';
    const name = document.createElement('strong');
    name.textContent = policy.name;
    head.append(name, iconButton('Quitar', () => {
      state.policies = state.policies.filter((item) => item !== policy);
      refresh();
    }, 'danger'));
    card.append(head);
    card.append(textField('Nombre', policy.name, (value) => { policy.name = value; }));
    card.append(textField('Código', policy.code, (value) => { policy.code = value; }, { mono: true }));
    card.append(selectField('Tipo', policy.type, POLICY_TYPES.map((item) => ({ value: item.value, label: item.label })), (value) => {
      policy.type = value;
      policy.config = { ...POLICY_TYPES.find((item) => item.value === value).config };
    }));
    card.append(selectField('Ámbito', policy.scope, [
      { value: 'tenant', label: 'Todo el tenant' },
      { value: 'groups', label: 'Solo los grupos' },
    ], (value) => { policy.scope = value; }));
    for (const [key, value] of Object.entries(policy.config)) {
      card.append(textField(key, String(value), (next) => {
        policy.config[key] = typeof value === 'number' ? Number(next) || 0 : next;
      }, { mono: true }));
    }
    panel.append(card);
  }
  return panel;
}

function automationInspector(panel, id) {
  const input = state.automation.inputs[0];
  const task = state.automation.tasks[0];
  const workflow = state.automation.workflows[0];
  if (id === 'input' && input) {
    panel.append(sectionTitle('Entrada del flujo'));
    panel.append(hint('Se crea como option type con fieldContext customOptions, que es como llega al flujo.'));
    panel.append(textField('Nombre', input.name, (value) => { input.name = value; }));
    panel.append(textField('Campo', input.fieldName, (value) => {
      input.fieldName = value;
      if (workflow) workflow.input = value;
      for (const item of state.automation.catalogItems) item.input = value;
    }, { mono: true }));
    panel.append(textField('Etiqueta', input.fieldLabel, (value) => { input.fieldLabel = value; }));
    panel.append(textField('Valor por defecto', input.defaultValue, (value) => { input.defaultValue = value; }));
  }
  if (id === 'task' && task) {
    panel.append(sectionTitle('Tarea'));
    panel.append(hint('Tarea Groovy local. Se ejecuta en el appliance, sin necesidad de nube ni instancias.'));
    panel.append(textField('Nombre', task.name, (value) => { task.name = value; }));
    panel.append(textField('Código', task.code, (value) => {
      task.code = value;
      if (workflow) workflow.task = value;
    }, { mono: true }));
    panel.append(textField('Contenido', task.content, (value) => { task.content = value; }, { mono: true, textarea: true }));
  }
  if (id === 'workflow' && workflow) {
    panel.append(sectionTitle('Flujo de trabajo'));
    panel.append(hint('Flujo operativo que enlaza la tarea y la entrada, y que el catálogo expone.'));
    panel.append(textField('Nombre', workflow.name, (value) => { workflow.name = value; }));
    panel.append(textField('Código', workflow.code, (value) => {
      workflow.code = value;
      for (const item of state.automation.catalogItems) item.workflow = value;
    }, { mono: true }));
    panel.append(hint(`Tarea: ${workflow.task} · Entrada: ${workflow.input}`));
  }
  return panel;
}

function catalogInspector(panel) {
  const item = state.automation.catalogItems[0];
  if (!item) return panel;
  panel.append(sectionTitle('Elemento de catálogo'));
  panel.append(hint('Se concede a los roles de las personas marcadas con acceso al catálogo.'));
  panel.append(textField('Nombre', item.name, (value) => { item.name = value; }));
  panel.append(textField('Código', item.code, (value) => { item.code = value; }, { mono: true }));
  panel.append(textField('Categoría', item.category, (value) => { item.category = value; }));
  panel.append(switchField('Activo', item.enabled !== false, (value) => { item.enabled = value; }));
  panel.append(switchField('Destacado', item.featured !== false, (value) => { item.featured = value; }));
  const granted = state.personas.filter((persona) => persona.catalogAccess !== false).map((persona) => persona.key);
  panel.append(hint(granted.length ? `Acceso para: ${granted.join(', ')}` : 'Ninguna persona tiene acceso al catálogo.'));
  return panel;
}

// --- sidebar ---------------------------------------------------------------
function renderSidebar() {
  const identity = el('identity');
  identity.replaceChildren();
  identity.append(textField('ID de la demo', state.metadata.id, (value) => {
    state.metadata.id = value;
    state.metadata.prefix = value;
  }, { mono: true }));
  identity.append(textField('Organización', state.metadata.name, (value) => {
    state.metadata.name = value;
    state.tenant.name = value;
  }));

  const components = el('components');
  components.replaceChildren();
  for (const key of FEATURE_KEYS) {
    components.append(switchField(FEATURE_LABELS[key], state.features[key], () => toggleFeature(key)));
  }
}

function toggleFeature(key) {
  const next = { ...state.features, [key]: !state.features[key] };
  state.features = applyFeatureDependencies(next, key);
}

function renderValidation() {
  const problems = validate(state);
  const list = el('problems');
  list.replaceChildren();
  const status = el('status');
  if (problems.length === 0) {
    status.className = 'status status--ok';
    status.textContent = 'Manifiesto válido para Leroy';
  } else {
    status.className = 'status status--bad';
    status.textContent = `${problems.length} problema(s) que Leroy rechazaría`;
    for (const problem of problems) {
      const item = document.createElement('li');
      const button = document.createElement('button');
      button.type = 'button';
      button.textContent = problem.message;
      button.addEventListener('click', () => {
        if (problem.node) { selected = problem.node; refresh(); }
      });
      item.append(button);
      list.append(item);
    }
  }
  el('download').disabled = problems.length > 0;
  el('copy').disabled = problems.length > 0;
  return problems;
}

function highlight(json) {
  return json
    .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
    .replace(/"([^"\\]*(?:\\.[^"\\]*)*)"(\s*:)?/g, (match, _inner, colon) =>
      (colon ? `<span class="tok-key">${match.slice(0, -colon.length)}</span>${colon}` : `<span class="tok-str">${match}</span>`))
    .replace(/\b(true|false|null)\b/g, '<span class="tok-lit">$1</span>')
    .replace(/(:\s)(-?\d+(?:\.\d+)?)/g, '$1<span class="tok-num">$2</span>');
}

function renderPreview() {
  const manifest = buildManifest(state);
  const json = JSON.stringify(manifest, null, 2);
  el('preview').innerHTML = highlight(json);
  el('command').textContent = `leroy demo plan --file ${state.metadata.id}.json`;
  return json;
}

// --- main refresh ----------------------------------------------------------
function refresh({ inspector = true } = {}) {
  const graph = buildGraph(state);
  canvas.render(state, graph, state.features);
  canvas.select(selected);
  renderSidebar();
  el('count').textContent = String(resourceCount(state));
  el('persona-count').textContent = String(state.personas.length);
  renderValidation();
  renderPreview();
  if (inspector) {
    const panel = el('inspector-body');
    panel.replaceChildren(inspectorFor(selected));
  }
  save();
}

// --- toolbar actions -------------------------------------------------------
function download() {
  const json = JSON.stringify(buildManifest(state), null, 2);
  const blob = new Blob([`${json}\n`], { type: 'application/json' });
  const url = URL.createObjectURL(blob);
  const link = document.createElement('a');
  link.href = url;
  link.download = `${state.metadata.id}.json`;
  link.click();
  URL.revokeObjectURL(url);
  toast(`Descargado ${state.metadata.id}.json`);
}

async function copy() {
  const json = JSON.stringify(buildManifest(state), null, 2);
  try {
    await navigator.clipboard.writeText(`${json}\n`);
    toast('Manifiesto copiado al portapapeles');
  } catch {
    toast('El navegador no permitió copiar; usa Descargar');
  }
}

function importFile(file) {
  const reader = new FileReader();
  reader.onload = () => {
    try {
      state = parseManifest(JSON.parse(String(reader.result)));
      selected = 'tenant';
      canvas.setPositions({});
      refresh();
      canvas.resetPositions();
      toast(`Cargado ${file.name}`);
    } catch (error) {
      toast(`No se pudo leer el manifiesto: ${error.message}`);
    }
  };
  reader.readAsText(file);
}

let toastTimer;
function toast(message) {
  const node = el('toast');
  node.textContent = message;
  node.classList.add('is-visible');
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => node.classList.remove('is-visible'), 2600);
}

function addPersona() {
  const index = state.personas.length + 1;
  const key = `persona-${index}`;
  state.personas.push({
    key,
    role: `${state.metadata.name} Persona ${index}`,
    username: `${state.metadata.id}-persona-${index}`,
    email: `${state.metadata.id}-persona-${index}@example.invalid`,
    profile: 'custom',
    permissions: [],
    verify: { allow: '/api/whoami', deny: '' },
    catalogAccess: true,
    runsWorkflow: false,
  });
  selected = `persona:${key}`;
  refresh();
}

function init() {
  canvas = new Canvas(el('canvas'), {
    onSelect: (id) => { selected = id; refresh(); },
    onToggle: (feature) => { toggleFeature(feature); refresh(); },
    onMoved: () => save(),
    onZoom: (value) => { el('zoom-level').textContent = `${Math.round(value * 100)}%`; },
  });

  const picker = el('scenario');
  for (const scenario of SCENARIOS) {
    const option = document.createElement('option');
    option.value = scenario.id;
    option.textContent = scenario.label;
    picker.append(option);
  }
  picker.addEventListener('change', () => {
    const scenario = scenarioById(picker.value);
    state = scenario.build();
    selected = 'tenant';
    el('scenario-summary').textContent = scenario.summary;
    canvas.setPositions({});
    refresh();
    canvas.resetPositions();
  });

  const restored = restore();
  if (restored?.state) {
    state = restored.state;
    selected = restored.selected || 'tenant';
    canvas.setPositions(restored.positions);
  }
  el('scenario-summary').textContent = scenarioById(picker.value).summary;

  el('download').addEventListener('click', download);
  el('copy').addEventListener('click', copy);
  el('add-persona').addEventListener('click', addPersona);
  el('relayout').addEventListener('click', () => { canvas.resetPositions(); save(); });
  el('zoom-in').addEventListener('click', () => canvas.setZoom(canvas.zoom + 0.1));
  el('zoom-out').addEventListener('click', () => canvas.setZoom(canvas.zoom - 0.1));
  el('zoom-fit').addEventListener('click', () => canvas.fit());
  el('import').addEventListener('change', (event) => {
    const [file] = event.target.files;
    if (file) importFile(file);
    event.target.value = '';
  });
  for (const tab of document.querySelectorAll('.tab')) {
    tab.addEventListener('click', () => {
      for (const other of document.querySelectorAll('.tab')) other.classList.toggle('is-active', other === tab);
      for (const panel of document.querySelectorAll('.tab-panel')) {
        panel.hidden = panel.dataset.panel !== tab.dataset.tab;
      }
    });
  }
  refresh();
}

init();
