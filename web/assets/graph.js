// The canvas: one box per group of Morpheus resources, wired by the
// dependencies Leroy actually applies. Boxes drag, toggle, and drive selection.

const NODE_WIDTH = 208;
const COLUMN_GAP = 244;
const ROW_GAP = 144;
const ORIGIN_X = 40;
const ORIGIN_Y = 32;

// Edges mirror real ordering in leroy.sh: the tenant role is created before the
// tenant, users are created inside it, policies reference group IDs, and the
// workflow binds the task and the input that the catalog item then exposes.
export function buildGraph(state) {
  const f = state.features;
  const nodes = [];
  const edges = [];
  const push = (node) => { nodes.push(node); return node.id; };

  push({
    id: 'tenant-role', column: 0, row: 0, group: 'rbac',
    title: 'Rol de tenant', subtitle: 'Rol de cuenta para la organización',
    feature: 'multitenancy', count: 1, chips: ['/api/roles'],
  });
  push({
    id: 'tenant', column: 1, row: 0, group: 'rbac',
    title: 'Tenant', subtitle: state.tenant.name || 'Sin nombre',
    feature: 'multitenancy', count: 1, chips: [state.tenant.subdomain || 'sin subdominio', '/api/accounts'],
  });
  edges.push(['tenant-role', 'tenant']);

  state.personas.forEach((persona, index) => {
    const id = `persona:${persona.key}`;
    const chips = [persona.profile];
    if (persona.permissions.length > 0) chips.push(`${persona.permissions.length} permiso(s)`);
    if (persona.runsWorkflow) chips.push('ejecuta el flujo');
    if (persona.catalogAccess === false) chips.push('sin catálogo');
    push({
      id, column: 2, row: index, group: 'persona',
      title: persona.key, subtitle: persona.username || 'sin usuario',
      feature: 'roles', count: 3, chips,
      detail: 'rol, Cypher, usuario',
    });
    edges.push(['tenant', id]);
  });

  push({
    id: 'environments', column: 0, row: 1, group: 'infra',
    title: 'Entornos', subtitle: `${state.environments.length} etiqueta(s) de entorno`,
    feature: 'environments', count: state.environments.length,
    chips: state.environments.slice(0, 3).map((item) => item.code),
  });
  push({
    id: 'groups', column: 1, row: 1, group: 'infra',
    title: 'Grupos', subtitle: `${state.groups.length} grupo(s) de infraestructura`,
    feature: 'groups', count: state.groups.length,
    chips: state.groups.slice(0, 3).map((item) => item.code),
  });
  push({
    id: 'policies', column: 1, row: 2, group: 'infra',
    title: 'Políticas', subtitle: `${state.policies.length} política(s) de gobierno`,
    feature: 'policies', count: state.policies.length,
    chips: state.policies.slice(0, 4).map((item) => item.type),
  });
  edges.push(['groups', 'policies']);

  push({
    id: 'input', column: 3, row: 0, group: 'automation',
    title: 'Entrada', subtitle: state.automation.inputs[0]?.fieldName || 'sin entrada',
    feature: 'automation', count: state.automation.inputs.length, chips: ['/api/library/option-types'],
  });
  push({
    id: 'task', column: 3, row: 1, group: 'automation',
    title: 'Tarea', subtitle: state.automation.tasks[0]?.code || 'sin tarea',
    feature: 'automation', count: state.automation.tasks.length, chips: ['groovy', '/api/tasks'],
  });
  push({
    id: 'workflow', column: 3, row: 2, group: 'automation',
    title: 'Flujo de trabajo', subtitle: state.automation.workflows[0]?.code || 'sin flujo',
    feature: 'automation', count: state.automation.workflows.length, chips: ['operation', '/api/task-sets'],
  });
  edges.push(['input', 'workflow'], ['task', 'workflow']);

  push({
    id: 'catalog', column: 3, row: 3, group: 'catalog',
    title: 'Catálogo', subtitle: state.automation.catalogItems[0]?.name || 'sin elemento',
    feature: 'catalog', count: state.automation.catalogItems.length, chips: ['autoservicio'],
  });
  edges.push(['workflow', 'catalog'], ['input', 'catalog']);
  for (const persona of state.personas) {
    if (persona.catalogAccess !== false) edges.push([`persona:${persona.key}`, 'catalog']);
  }

  return { nodes, edges };
}

export function defaultPosition(node) {
  return {
    x: ORIGIN_X + node.column * COLUMN_GAP,
    y: ORIGIN_Y + node.row * ROW_GAP,
  };
}

export class Canvas {
  constructor(root, handlers) {
    this.root = root;
    this.handlers = handlers;
    this.positions = new Map();
    this.selected = null;
    this.zoom = 1;
    this.fitted = false;
    this.content = { width: 0, height: 0 };
    this.svg = root.querySelector('.edges');
    this.layer = root.querySelector('.nodes');
    this.elements = new Map();
    this.graph = { nodes: [], edges: [] };
    this.#bindPanning();
  }

  setZoom(value) {
    this.zoom = Math.min(1.4, Math.max(0.4, Math.round(value * 100) / 100));
    this.#applyZoom();
    this.handlers.onZoom?.(this.zoom);
  }

  // Shrinks to fit the first time the graph is laid out, so the automation
  // chain is visible on arrival instead of waiting off the right edge.
  fit() {
    const available = this.root.clientWidth - 24;
    if (available <= 0 || this.content.width <= 0) return;
    this.setZoom(Math.max(0.7, Math.min(1, available / this.content.width)));
  }

  #applyZoom() {
    const scale = `scale(${this.zoom})`;
    this.layer.style.transform = scale;
    this.svg.style.transform = scale;
    this.layer.style.width = `${this.content.width * this.zoom}px`;
    this.layer.style.height = `${this.content.height * this.zoom}px`;
  }

  setPositions(stored) {
    this.positions = new Map(Object.entries(stored || {}).map(([id, pos]) => [id, { ...pos }]));
  }

  exportPositions() {
    return Object.fromEntries(this.positions);
  }

  resetPositions() {
    this.positions.clear();
    for (const node of this.graph.nodes) this.positions.set(node.id, defaultPosition(node));
    this.#place();
    this.#drawEdges();
  }

  render(state, graph, features) {
    this.graph = graph;
    this.features = features;
    this.layer.replaceChildren();
    this.elements.clear();
    for (const node of graph.nodes) {
      if (!this.positions.has(node.id)) this.positions.set(node.id, defaultPosition(node));
      const element = this.#nodeElement(node);
      this.elements.set(node.id, element);
      this.layer.append(element);
    }
    // Positions of removed personas would otherwise linger and grow the canvas.
    const live = new Set(graph.nodes.map((node) => node.id));
    for (const id of [...this.positions.keys()]) if (!live.has(id)) this.positions.delete(id);
    this.#place();
    this.#drawEdges();
  }

  select(id) {
    this.selected = id;
    for (const [nodeId, element] of this.elements) {
      element.classList.toggle('is-selected', nodeId === id);
    }
  }

  #nodeElement(node) {
    const enabled = this.features[node.feature] !== false;
    const element = document.createElement('article');
    element.className = `node node--${node.group}`;
    element.dataset.id = node.id;
    element.tabIndex = 0;
    element.classList.toggle('is-off', !enabled);
    element.setAttribute('aria-label', `${node.title}, ${enabled ? 'activo' : 'desactivado'}`);

    const header = document.createElement('header');
    const title = document.createElement('h3');
    title.textContent = node.title;
    const toggle = document.createElement('button');
    toggle.type = 'button';
    toggle.className = 'node__toggle';
    toggle.setAttribute('role', 'switch');
    toggle.setAttribute('aria-checked', String(enabled));
    toggle.title = enabled ? 'Desactivar este bloque' : 'Activar este bloque';
    toggle.addEventListener('click', (event) => {
      event.stopPropagation();
      this.handlers.onToggle(node.feature);
    });
    header.append(title, toggle);

    const subtitle = document.createElement('p');
    subtitle.className = 'node__sub';
    subtitle.textContent = node.subtitle;

    const chips = document.createElement('ul');
    chips.className = 'node__chips';
    for (const chip of (node.chips || []).filter(Boolean)) {
      const item = document.createElement('li');
      item.textContent = chip;
      chips.append(item);
    }

    const count = document.createElement('span');
    count.className = 'node__count';
    count.textContent = node.detail ? `${node.count} recursos: ${node.detail}` : `${node.count} recurso(s)`;

    element.append(header, subtitle, chips, count);
    element.addEventListener('pointerdown', (event) => this.#startDrag(event, node, element));
    element.addEventListener('keydown', (event) => this.#onKey(event, node, element));
    element.addEventListener('click', () => this.handlers.onSelect(node.id));
    return element;
  }

  #onKey(event, node, element) {
    const step = event.shiftKey ? 24 : 8;
    const position = this.positions.get(node.id);
    const moves = { ArrowLeft: [-step, 0], ArrowRight: [step, 0], ArrowUp: [0, -step], ArrowDown: [0, step] };
    if (moves[event.key]) {
      event.preventDefault();
      position.x = Math.max(0, position.x + moves[event.key][0]);
      position.y = Math.max(0, position.y + moves[event.key][1]);
      this.#placeOne(node.id, element);
      this.#drawEdges();
      this.handlers.onMoved();
      return;
    }
    if (event.key === 'Enter') {
      event.preventDefault();
      this.handlers.onSelect(node.id);
    }
    if (event.key === ' ') {
      event.preventDefault();
      this.handlers.onToggle(node.feature);
    }
  }

  #startDrag(event, node, element) {
    if (event.target.closest('.node__toggle')) return;
    if (event.button !== 0) return;
    const position = this.positions.get(node.id);
    const startX = event.clientX;
    const startY = event.clientY;
    const originX = position.x;
    const originY = position.y;
    element.setPointerCapture(event.pointerId);
    element.classList.add('is-dragging');
    const move = (moveEvent) => {
      position.x = Math.max(0, originX + (moveEvent.clientX - startX) / this.zoom);
      position.y = Math.max(0, originY + (moveEvent.clientY - startY) / this.zoom);
      this.#placeOne(node.id, element);
      this.#drawEdges();
    };
    const end = () => {
      element.classList.remove('is-dragging');
      element.removeEventListener('pointermove', move);
      element.removeEventListener('pointerup', end);
      element.removeEventListener('pointercancel', end);
      this.handlers.onMoved();
    };
    element.addEventListener('pointermove', move);
    element.addEventListener('pointerup', end);
    element.addEventListener('pointercancel', end);
  }

  #bindPanning() {
    this.root.addEventListener('pointerdown', (event) => {
      if (event.target !== this.root && event.target !== this.svg) return;
      const startX = event.clientX;
      const startY = event.clientY;
      const left = this.root.scrollLeft;
      const top = this.root.scrollTop;
      this.root.classList.add('is-panning');
      const move = (moveEvent) => {
        this.root.scrollLeft = left - (moveEvent.clientX - startX);
        this.root.scrollTop = top - (moveEvent.clientY - startY);
      };
      const end = () => {
        this.root.classList.remove('is-panning');
        window.removeEventListener('pointermove', move);
        window.removeEventListener('pointerup', end);
      };
      window.addEventListener('pointermove', move);
      window.addEventListener('pointerup', end);
    });
  }

  #placeOne(id, element) {
    const position = this.positions.get(id);
    element.style.transform = `translate(${position.x}px, ${position.y}px)`;
  }

  #place() {
    let maxX = 0;
    let maxY = 0;
    for (const [id, element] of this.elements) {
      this.#placeOne(id, element);
      const position = this.positions.get(id);
      maxX = Math.max(maxX, position.x + NODE_WIDTH);
      maxY = Math.max(maxY, position.y + 160);
    }
    this.content = { width: maxX + 80, height: maxY + 80 };
    this.svg.setAttribute('width', String(this.content.width));
    this.svg.setAttribute('height', String(this.content.height));
    this.svg.setAttribute('viewBox', `0 0 ${this.content.width} ${this.content.height}`);
    this.#applyZoom();
    if (!this.fitted) {
      this.fitted = true;
      this.fit();
    }
  }

  #drawEdges() {
    const paths = [];
    for (const [from, to] of this.graph.edges) {
      const source = this.positions.get(from);
      const target = this.positions.get(to);
      if (!source || !target) continue;
      const sourceNode = this.graph.nodes.find((node) => node.id === from);
      const targetNode = this.graph.nodes.find((node) => node.id === to);
      const live = this.features[sourceNode.feature] !== false && this.features[targetNode.feature] !== false;
      const sourceElement = this.elements.get(from);
      const height = sourceElement ? sourceElement.offsetHeight : 120;
      const targetElement = this.elements.get(to);
      const targetHeight = targetElement ? targetElement.offsetHeight : 120;
      const cls = `edge${live ? '' : ' edge--off'}`;
      if (target.x - source.x > NODE_WIDTH * 0.5) {
        const x1 = source.x + NODE_WIDTH;
        const y1 = source.y + height / 2;
        const x2 = target.x;
        const y2 = target.y + targetHeight / 2;
        const curve = Math.max(36, (x2 - x1) / 2);
        paths.push(`<path class="${cls}" d="M ${x1} ${y1} C ${x1 + curve} ${y1}, ${x2 - curve} ${y2}, ${x2} ${y2}" />`);
      } else {
        const downwards = target.y >= source.y;
        const x1 = source.x + NODE_WIDTH / 2;
        const y1 = downwards ? source.y + height : source.y;
        const x2 = target.x + NODE_WIDTH / 2;
        const y2 = downwards ? target.y : target.y + targetHeight;
        const curve = Math.max(28, Math.abs(y2 - y1) / 2);
        const bend = downwards ? curve : -curve;
        paths.push(`<path class="${cls}" d="M ${x1} ${y1} C ${x1} ${y1 + bend}, ${x2} ${y2 - bend}, ${x2} ${y2}" />`);
      }
    }
    this.svg.innerHTML = paths.join('');
  }
}
