# Constructor de demos Leroy

Constructor gráfico de manifiestos para demostraciones de HPE Morpheus. Produce
un manifiesto JSON de esquema 2 que Leroy aplica sin conversión:

```bash
leroy demo plan  --file mi-demo.json
leroy demo apply --file mi-demo.json
```

## Cómo se usa

1. Elige un escenario de partida (plataforma, banca, retail, telco, sector público).
2. Ajusta identidad, personas, entornos, grupos, políticas y automatización.
3. Activa o desactiva bloques con el interruptor de cada caja del lienzo.
4. Descarga el manifiesto o copia el JSON, y aplícalo con Leroy.

Las cajas se arrastran, se seleccionan para editarlas y se mueven con las
flechas del teclado cuando tienen el foco. Las líneas dibujan las dependencias
reales que Leroy aplica: el rol de tenant antes del tenant, los usuarios dentro
de él, las políticas sobre los grupos, y la entrada y la tarea dentro del flujo
que el catálogo expone.

El trabajo en curso se guarda en el navegador. Ningún dato sale de la página:
no hay servidor, ni analítica, ni llamadas a Morpheus. Un manifiesto nunca
contiene contraseñas; Leroy las genera con Cypher en el momento de aplicar.

## Desarrollo

```bash
make web            # sirve el constructor en http://localhost:8765/
make web-manifests  # imprime el manifiesto de cada escenario
make check          # incluye los cruces entre el constructor y leroy.sh
```

No hay compilación ni dependencias: HTML, CSS y módulos ES servidos tal cual,
igual que el resto del proyecto se limita a bash, curl y jq.

| Archivo | Responsabilidad |
| --- | --- |
| `index.html` | Estructura de la página. |
| `assets/schema.js` | Modelo del manifiesto, reglas de dependencias y validación. |
| `assets/scenarios.js` | Escenarios de demostración. |
| `assets/graph.js` | Lienzo: cajas, aristas, arrastre y zoom. |
| `assets/app.js` | Inspector, validación, vista previa e importación y exportación. |
| `tools/emit-manifests.mjs` | Ejecuta la lógica del constructor fuera del navegador, para las pruebas. |

## Por qué la validación está duplicada

`assets/schema.js` repite las reglas de `validate_manifest` de `leroy.sh`. Es
duplicación deliberada: el constructor es estático y no puede ejecutar bash. Si
cambias las reglas en `leroy.sh`, cámbialas aquí también. `make check` ejecuta
cada escenario a través de `validate_manifest` y compara el recuento de
recursos de ambas implementaciones, así que una divergencia rompe CI.

## Publicación

`.github/workflows/pages.yml` publica este directorio en GitHub Pages en cada
push a `main` que toque `web/`. Requiere que Pages esté configurado en el
repositorio con origen «GitHub Actions».
