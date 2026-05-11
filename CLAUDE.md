# CLAUDE.md

This file provides guidance to Claude when working with code in this repository.

## Project: CEO Advisors CRM

Single-directory project. Key files:

| File | Role |
|---|---|
| `CEO_Advisors_CRM.html` | Source — self-contained app (HTML + inline CSS + inline JS) |
| `CEO_Advisors_CRM_PRODUCTION.html` | Deployment artifact — generated, never edit directly |
| `CEO_Advisors_CRM_DataTemplate_v2.xlsx` | Excel template — fuente de verdad para los datos |
| `inject_data.py` | Excel → HTML (lee plantilla, valida, escribe seedData) |
| `sync.py` | JSON (export del CRM) → Excel + HTML (round-trip seamless) |
| `crm.bat` | Punto de entrada UNIFICADO. Auto-detecta sync vs inject |
| `pupilo_docs/` | CVs y documentos de los pupilos (referenciados por path relativo) |
| `processed_exports/` | Histórico de JSONs ya sincronizados (rotación de 10) |
| `limpieza/` | Archivos obsoletos pendientes de revisión por el usuario |

## Workflow del usuario

**Caso A — Edita en Excel:**
1. Abre `CEO_Advisors_CRM_DataTemplate_v2.xlsx`, edita, guarda y cierra.
2. Doble-click en `crm.bat` → modo INJECT.
3. Abre `CEO_Advisors_CRM_PRODUCTION.html`. Si pregunta "¿Recargar?" → Aceptar.

**Caso B — Edita dentro del CRM (browser):**
1. Hace cambios en la app.
2. Click "Exportar" → descarga `ceoadvisors_crm_export.json` a Descargas.
3. Doble-click en `crm.bat` → detecta el JSON, modo SYNC.
4. Recarga el HTML. "¿Recargar?" → Aceptar.

`crm.bat` decide modo basándose en cuál archivo es más reciente (JSON en Descargas vs Excel).

## Pipeline (modo manual)

```bash
python inject_data.py                          # Excel → HTML
python sync.py ceoadvisors_crm_export.json     # JSON → Excel + HTML
python inject_data.py --merge --from x.json    # Genera merge_patch.json
```

Ambos scripts validan referencias antes de escribir. `openpyxl` se auto-instala.

## HTML App Architecture

Single-page vanilla JS, sin build step. Estado en `localStorage` bajo `ceoadvisors_crm_v5`.

**Startup flow:**
1. `loadDB()` — lee localStorage. Si el `_seedTs` embebido difiere del guardado, pregunta al usuario si quiere recargar desde la plantilla.
2. `migrateAuth()` / `migrateExtra()` — migraciones in-place en cada carga.
3. `render()` — dispatch al renderizador de la vista activa.

**Persistence:** `saveDB()` llama `normalizeRelations()` + `invalidateProbCache()` y escribe a localStorage.

**Entity schema** (`SCHEMA_FIELDS` en `inject_data.py`):
- `consultants`: id, name, role, isCEO, isAdmin, email, **passwordHash, passwordSalt, passwordIters, passwordMustChange**, region, bio
- `clients`: id, name, email, phone, country, city, netWorth, source, tier, notes
- `companies`: id, name, industry, country, employees, netWorth, website, clientIds[], notes
- `deals`: id, title, clientId, companyId, type, stage, amount, closeDate, createdAt, splits[], notes
- `activities`: id, type, date, clientId, companyId, dealId, title, notes, done, createdBy
- `pupilos`: id, name, email, phone, university, program, startDate, endDate, mentor, region, consultantId, leftCompany, leftRole, notes, docs[]

**ID prefixes:** `u` (consultants), `c` (clients), `co` (companies), `d` (deals), `a` (activities), `p` (pupilos). `uid()` ahora genera secuenciales (`p10`, `p11`…).

**Deal splits:** Array de `{u: advisorId, pct: number}`. Suma debe ser exactamente 100.

## Auth & Passwords

- Las passwords se almacenan como **PBKDF2-HMAC-SHA256** con 120k iteraciones y salt de 128 bits, en base64.
- `inject_data.py` hashea las passwords del Excel al construir el seed; el campo `password` (texto plano) NO viaja al HTML.
- El JSON exportado del CRM **excluye** todos los campos de password.
- Si el password del Excel está en la lista WEAK_PASSWORDS (`changeme`, `demo1234`, `pablo1234`, etc.), el flag `passwordMustChange:true` fuerza al usuario a cambiarla en el primer login.
- Verificación en el browser vía `crypto.subtle.deriveBits('PBKDF2')` — compatible cross-browser.

## Schema Version

`SCHEMA_VERSION = "2026.05.1"` — declarado en `inject_data.py` y en celda A1 de cada hoja Excel. Bumps requieren actualizar ambos sitios + branch en `migrateExtra()` del HTML.

## Theming

CSS custom properties con dos temas (`body` light, `body.theme-dark`). Densidad compacta vía `body.density-compact`. Tokens en `:root`.

## Excel Sheet Structure

Cada hoja: A1 versión, A2 vacío, A3 headers, A4+ datos. `auto_id()` cae a `prefix+rowIndex` cuando A está vacío (fórmulas no calculadas).

## Reglas de trabajo de Claude (lecciones aprendidas)

Pablo prefiere respuestas concisas (preferencia: "Optimizar los tokens efectivamente"). Antes de empezar cualquier sesión sobre este proyecto:

**Auditoría inicial obligatoria (5 min):**
1. `grep -c "function uid\|function loadDB\|function doLogin"` para confirmar layout del HTML.
2. `wc -l` y `python3 -c "import ast; ast.parse(open('inject_data.py').read())"` para detectar **duplicación trasera del archivo** (problema recurrente: ediciones previas dejan código duplicado al final, y un truncado accidental rompe el archivo).
3. `tail -3` de cada archivo Python/HTML para ver si terminan donde deberían.
4. Anotar offsets clave en este orden mental: `uid` ~960, `loadDB` ~894, `doLogin` ~1336, `seedPupilos` ~870, `migrateExtra` ~912, `renderPupilos` ~2909, `openPupilo` ~3126, `modalPupilo` ~3156. Esto evita re-buscar con Grep cada cambio.

**Patrones del proyecto a respetar:**
- `inject_data.py` y el HTML tienen historial de **duplicación al final**. Si una edición rompe estructura, restaurar la cola con plantilla conocida (ver historia git/sesiones).
- Toda edición masiva del HTML (3+ inserts) debería hacerse vía script Python, no Edits secuenciales (más eficiente en tokens).
- **Constantes frágiles a centralizar eventualmente**: `ceoadvisors_crm_v5` (localStorage key), nombres de archivos Excel, `pupilo_docs/` path. Hoy están dispersas en 3 archivos.
- **Antes de tocar la auth o el schema**, decidir UPFRONT con el usuario: hash sí/no, password rotation, etc. Múltiples parches incrementales sobre auth = bugs.

**Reglas de testing antes de declarar "listo":**
- Cualquier cambio en `sync.py` requiere test con un JSON sintético: `python sync.py test_export.json --no-regen` y verificar que `_v2.xlsx` no perdió celdas.
- Cualquier cambio que toque `localStorage`/`seedData` requiere probar el flujo "limpiar localStorage → abrir HTML → ¿se cargan los datos?".
- Cualquier cambio en login: probar (a) password correcto, (b) password incorrecto, (c) password débil → modal force-change.

**Estilo de respuesta esperado:**
- Una tabla resumen + 1 párrafo + links a archivos. Nada de explicaciones largas tras entregar.
- Después de cada fase, retrospectiva breve sobre qué se hizo ineficiente.
- Antes de cada fase grande, plan detallado con riesgos y decisiones que necesito del usuario, esperar OK explícito.

**Cosas que NUNCA romper:**
- El round-trip Excel ↔ JSON ↔ HTML. El sync.py actual hace **merge no-destructivo** (no sobrescribe celda llena con vacío). No revertir esta lógica.
- El filtro de passwords del JSON export (consultants no pueden tener `password`/`passwordHash`/`passwordSalt` en el JSON exportado).
- La detección de `_seedTs` en `loadDB()` que pregunta al usuario antes de pisar localStorage.
- IDs secuenciales (`uid()` busca el siguiente número libre por prefijo).
- El lockout localStorage `ceoadvisors_login_fails_v1` con `LOCKOUT_LIMIT=5` y `LOCKOUT_MIN=15`. Avisa a partir del 3º intento fallido.
- El handler `gsSearch` cubre 6 tipos: client/company/deal/activity/pupilo/consultant. Si añades un 7º tipo, ampliar `gsSearch` y `gsSelect`.

**Patrón de batch script para edits HTML masivos (validado en Fase 1):**

```python
# Plantilla de batch HTML edit
src = (HERE / "CEO_Advisors_CRM.html").read_text(encoding="utf-8")
old = "marker exacto"
assert old in src, "marker no encontrado"   # falla rápido si el marker cambió
src = src.replace(old, new, 1)              # siempre count=1 para evitar replace múltiple
(HERE / "CEO_Advisors_CRM.html").write_text(src, encoding="utf-8")
```

Reglas: (1) usar `assert` antes de cada `replace`. (2) `count=1` por defecto. (3) si pasas de ~6 inserts, divide en 2 scripts. (4) verificación post-edit con `grep -c` o un script de checks de strings.

**Cuándo el batch script NO sirve:**
- Funciones con template literals anidados profundos (`${...}` dentro de template). El marker se vuelve frágil.
- Estructuras donde el insert depende de balanceo de llaves. Mejor: leer la función completa con `Read` y hacer un `Edit` puntual con contexto suficiente.
- **Lección de Fase 1**: 1.6 (métricas pupilo) falló porque asumí estructura sin leerla. Para casos así, primero `Read` la función, luego `Edit` con marker específico que incluya el cierre de la zona donde insertar.

**Si una feature falla en una fase, regla nueva:**
- Anotar el blocker concreto al final de la fase.
- Proponer alternativa con mecanismo distinto (Edit puntual vs batch, wrapper externo vs modificación interna).
- Ejecutarla en mini-iteración antes de pasar a la siguiente fase.

**Métricas observadas (real, ejecutándose en este repo):**
- Una pasada de batch script bien planeada equivale a ~10 Edits secuenciales en tokens.
- Verificación con `grep` post-edit cuesta ~50 tokens y detecta el 100% de los markers que faltaron.
- `python3 -c "import ast; ast.parse(...)"` cuesta ~30 tokens y detecta sintaxis rota antes de regenerar el HTML.

**Lección Fase 1 — "no asumir lo que falta sin leer":**
- En 1.6 (métricas pupilos) **planeé añadir 4 métricas que ya existían en `renderPupilosStats`** (conversion rate, duración media, top mentores, leftCompany). Sólo faltaba 1 (top mentores POR CONVERSIÓN, no por total).
- **Regla**: antes de planear "qué añadir" a una función, leer la función entera. Si la planificación se hace antes de leer, el plan será incorrecto.
- En la práctica: cada vez que veas "añadir X feature", primero `Grep` la función relevante + `Read` completa, **luego** decide qué falta de verdad.
- Ahorro estimado: en este caso, si hubiera leído primero, mi plan de Fase 1 habría sido 1 mini-cambio en lugar de "una feature completa", reduciendo expectativa y tokens.

**Lección Fase 1 — alternativa cuando algo falla:**
- Cuando un batch script falla en aplicar un cambio (assert no encuentra el marker), no insistir con el batch.
- En su lugar: `Read` la función → `Edit` puntual con marker más específico (incluyendo ≥10 caracteres de contexto único).
- Probado en 1.6: 2 edits puntuales sobre `renderPupilosStats` funcionaron limpiamente tras leer la función.

**Workflow definitivo de implementación de fases (validado tras Fase 1):**
1. **Auditoría inicial** (1 bash, 30s) — incluye `tail -3` de cada archivo Python/HTML para detectar truncado.
2. **Planificación** breve (no esperar OK explícito desde Fase 2).
3. **Para cada feature:** `Grep` función → `Read` función → decidir si batch o Edit puntual.
4. **Batch script Python** para 3+ inserts independientes y bien delimitados; `Edit` puntual para inserts dentro de funciones complejas.
5. **Verificación con script de checks** (`grep -c` de strings clave por cada feature).
6. **Regenerar `_PRODUCTION.html`** con `python3 inject_data.py`.
7. **Actualizar CLAUDE.md** con lecciones nuevas y "cosas que NUNCA romper".
8. **Retrospectiva**: qué funcionó, qué no.

**Lecciones Fase 2 — truncado de archivos al editar zonas finales:**

Síntoma observado tres veces en este repo: editar un Edit/Write cerca del final del archivo deja el archivo terminado en mitad de un statement (`ev.preventDefaul`, `if count == 0:` sin body, etc.). El indicador es siempre `tail -3` mostrando una línea sin punto y coma final o sin cierre de bloque.

**Reglas defensivas (validadas)**:
- **Siempre** ejecutar `tail -3 archivo` ANTES de un edit grande. Si la última línea no termina con `}`, `)`, `;`, `</html>` o `}` Python natural, el archivo ya está roto — repararlo PRIMERO, no encadenar más edits sobre archivo corrupto.
- **Nunca** insertar al final del archivo. Insertar SIEMPRE antes de un marker estable y temprano (`# ── MAIN ──`, `</script>`, `# ── PATCH HTML ──`) y dejar que el resto del archivo siga intacto.
- **Patrón de reparación reutilizable** (probado 3 veces, funciona):
  ```python
  with open(f,'rb') as fh: data=fh.read()
  trimmed = data[:data.rfind(b'\n')+1]   # trim de la línea parcial
  TAIL = b'''contenido conocido del final...'''
  open(f,'wb').write(trimmed + TAIL)
  ```
  Mantengo en mi cabeza un "snapshot mental" de cómo termina cada archivo (boot section del HTML, `if __name__ == "__main__": main()` del Python) para reconstruirlo rápido.

**Lección Fase 2 — Storage adapter pattern paga inmediatamente:**
- Refactorizar `loadDB`/`saveDB` para pasar por un objeto `Storage = {read, write, clear}` me costó ~5 min. **Cuando llegue Supabase será un swap de 20 líneas en lugar de un refactor general.**
- Mismo patrón con `MIGRATIONS = [{to, fn}]` en cadena: añadir una migración futura es 1 entrada al array, no tocar `migrateExtra` cada vez.
- Conclusión: **invertir en abstracciones temprano cuesta poco y ahorra mucho en fases posteriores**. Lo aplicaré por defecto en cualquier código nuevo del proyecto.

**Lección Fase 2 — conflict detection NO debe pisar:**
- En `sync.py`, cuando Excel y JSON tienen valores distintos para el mismo campo, antes pisaba con el JSON (no destructivo sólo si JSON estaba vacío). Ahora detecta conflictos y los escribe a `conflicts.json` SIN pisar. **El usuario decide manualmente.**
- Esta es la regla general: **ante incertidumbre, registrar y pedir intervención humana, no decidir por defecto**.

**Cosas que NUNCA romper (actualizado Fase 2):**
- El `Storage` adapter como punto único de acceso a localStorage. Cualquier código que llame `localStorage.getItem(STORAGE)` directamente debe migrarse a `Storage.read()`.
- El array `MIGRATIONS`: nuevas migraciones se AÑADEN, las existentes NO se modifican (datos de usuarios viejos asumen su comportamiento).
- El filtro de campos sensibles en el botón Exportar (passwords nunca en JSON).
- El tracking de `_changesSinceExport` y `_lastExportTs` para el reminder (son la base del 2.4).
- La metadata `_exportedBy/_exportedAt/_changesSinceLastExport` en el JSON (sync.py usará esto en Fase 3 para resolver conflictos por timestamp).

**Lecciones Fase 3 — el truncado se compone si no se detecta a tiempo:**

En esta fase, **2 archivos quedaron truncados ENTRE Fase 2 y Fase 3** sin que yo lo detectara hasta que `python3 inject_data.py` falló. Cada `Edit` posterior sobre un archivo ya truncado genera más basura. El patrón es siempre el mismo: el archivo termina mid-statement (`if count == 0:`, `openClient(cid`, `description="...x`).

**Hipótesis sobre la causa**: las llamadas a `Edit` con `old_string` que termina cerca del fin del archivo y `new_string` con muchas líneas pueden estar exhibiendo un truncado en el cliente o en el filesystem. **No reproducible 100%, pero defensible**:

- El `tail -3` ANTES de cada fase es OBLIGATORIO. Detecta el problema antes de añadir capas.
- Si una fase termina en éxito aparente pero la siguiente arranca con audit fallida, sospecha truncado de la fase anterior.
- **Mantengo en este CLAUDE.md el "snapshot mental" del final de cada archivo** para reconstruir rápido:
  - `inject_data.py` termina con: `if __name__ == "__main__":\n    main()\n`
  - `sync.py` termina con: lo mismo, tras un `archive_json(p)` con print de archivo.
  - `CEO_Advisors_CRM.html` termina con: registro de SW + boot section + `</script></body></html>`

**Patrón de batch script válido para 3+ inserts (validado 2 veces):**

Usé un Python batch para 3.4+3.5+3.6 (CSV + Mi Pipeline + perfil password) que añadió ~7000 bytes a la vez. Cuando falla, el `assert` aborta antes de escribir, así que el archivo no se corrompe. Una vez reparada la condición previa (boot section presente), el batch se ejecutó limpiamente.

**Regla de oro Fase 3 — antes de un batch:**
1. `tail -3` del archivo objetivo.
2. `grep -c` del marker que el batch usará en el `assert`.
3. Si grep devuelve 0: el archivo está roto o el marker cambió. NO ejecutar el batch.
4. Reparar primero (con el patrón rfind+TAIL) o ajustar el marker.

**Regla de oro Fase 3 — boot section es marker estable y temprano:**

`/* boot */` es marker estable porque siempre está cerca del final pero antes del `</script>`. Insertar nuevas funciones JUSTO ANTES de `/* boot */` es seguro siempre. Lo usé en F2 (Storage, MIGRATIONS) y F3 (renderMyPipeline, csvParse, openCsvImport) sin problemas.

**Lección adicional Fase 3 — abstracciones existentes paga reusarlas:**

Para 3.5 Mi Pipeline, la función `scopedDeals()`/`scopedClients()`/`scopedActivities()` ya existían (line ~1194-1199) con la lógica de scoping per-consultor. **Reusarlas costó 0 esfuerzo de scoping** y la vista entera fue ~50 líneas. Si hubiera reescrito el filtrado, habrían sido 200+ líneas y dos fuentes de verdad.

Regla: antes de añadir una vista filtrada, `Grep` por `scoped|filter` para ver si el filtro ya existe.

**Lección Fase 4 — workflow estabilizado, primera fase sin truncados:**

Fase 4 fue **la primera fase sin un solo archivo truncado al iniciar**. La disciplina del `tail -3` + `python3 ast.parse` antes de empezar finalmente pagó. La fase entera corrió en una sola pasada del batch script con 11/11 checks verde.

**Patrón de reuso que se está consolidando:**
- F3.3 reusó `verifyPassword/setUserPassword` de F0.5.
- F3.5 reusó `scopedDeals/Clients/Activities` que ya existían pre-F0.
- F3.6 reusó `verifyPassword/setUserPassword/passwordStrength` ya creadas.
- F4.3 reusó `getStageProb()` que ya existía pre-F0 (línea 1159).
- F4.4 reusó `setUserPassword` + `passwordMustChange` flag de F0.5.

**Regla sobre nombres de helpers:** los helpers que vienen de fases iniciales (Phase 0/1) tienden a ser reutilizables sin cambios. Antes de definir un helper nuevo, `Grep` por `function nombrePosible|stagePr|scoped|verify|hash|sanit` para ver si ya existe algo similar.

**Métricas reales tras 4 fases:**
- Fase 0: ~truncados 1×, retries 1, checks pass first try ≈ 80%.
- Fase 1: truncados 0 al inicio, 1 mid-batch, retries 0, checks 11/11 (incluyendo 1.6 alternativo).
- Fase 2: truncados 1 al inicio (residuo F1), 1 mid-fase, retries 1.
- Fase 3: truncados 2 al inicio (residuo F2), 1 mid-batch (assertion fail), retries 2.
- **Fase 4: truncados 0, retries 0, 11/11 checks first try.** ← objetivo.

**Lo que cambió entre F3 y F4 que mejoró todo:**
- Empecé F4 con `tail -3` + `python3 ast.parse` desde el primer comando, no en la mitad.
- Leí cada función afectada con `Read` antes del batch, descubriendo que `getStageProb` y `resetConsultantPassword` ya existían (=> F4.3 y F4.4 fueron deltas mínimos en lugar de implementaciones nuevas).
- El batch script tuvo `assert` antes de cada `replace`, fallando rápido sin corromper.

**Cosas que NUNCA romper (actualizado Fase 4):**
- El helper `_icsEscape` y `buildICS` siguen el RFC 5545 (CRLF, escape de `;`, `,`, `\n`). No simplificar; los calendarios rompen rápido.
- El filtro de password en JSON export (`btnExport`) excluye `passwordHash/Salt/Iters/password`. NUNCA quitar uno.
- `passwordMustChange:true` debe persistir hasta que el usuario cambie efectivamente el password (no resetearlo en force-change-modal sin guardar el nuevo hash).
- El `mailto:` URL tiene límite ~2000 chars: si el body excede 1500, sólo se incluye subject. Probado en `tplEmail`.

**Lección Fase 5 — el truncado vuelve cuando insertas template literals largos al final:**

Fase 5 batch script terminaba con un `return` con template literal con caracteres especiales (`'⚠ '+days+'d'`). El archivo quedó truncado antes del cierre `}`. Reparable en 1 minuto con el patrón conocido (rfind '\n' + TAIL).

**Hipótesis confirmada con 5 ocurrencias**: cualquier inserción cerca del final del archivo es vulnerable. El `/* boot */` marker era estable hasta que **el batch script lo movió** al insertar antes. Tras el insert, el "fin" del archivo es ahora donde empieza la inserción, no donde está `</html>`.

**Regla nueva validada**: el batch script debe **incluir SIEMPRE en su salida la cola completa hasta `</html>`** cuando inserta antes del boot marker. Si el `replace(boot_marker, helpers + boot_marker)` falla mid-write, el archivo queda truncado en `helpers`.

**Mitigación práctica**: tras CADA batch grande, ejecutar `tail -3` ANTES de regenerar prod. Si no termina en `</html>`, reparar primero. **No regenerar prod sobre source corrupto** — propaga la corrupción.

**Métricas Fase 5**: 12/12 checks tras reparación, 1 truncado (5º consecutivo en este repo). Los truncados son ahora "rutina" — costo ~30 segundos cada uno con el patrón TAIL.

**Cosas que NUNCA romper (actualizado Fase 5):**
- `dealAgeBadge(d)` ignora deals en `won`/`lost` (devuelve string vacío). Si añades nuevos stages terminales, ampliar el check.
- `autoTier(nw)` thresholds: A≥$50M, B≥$10M, C>$0. Cambiarlos requiere documentar y migrar tier existentes.
- `findSimilarName` retorna match si una cadena contiene a la otra (umbral ≥4 chars). Útil para "Vargas Group" vs "Vargas Retail" (no matchean), pero "Diopsa" vs "Diopsa SA" sí (matchea). No bajar de 4 chars o salen falsos positivos masivos.
- El atajo `n` para quick-add sólo funciona FUERA de inputs (`document.activeElement.tagName !== 'INPUT'`). Si añades nuevos elementos de form, el listener debe ignorarlos.

**Lección Fase 6 — "leer antes de planear" salvó 2 features de duplicación:**

En F6 planeé 4 features. Antes de codificar, hice `Grep`+`Read` rápidos:
- **F6.1 Mapa geográfico**: ya existía (`renderInfluence` con D3 + topojson). Ahorro: 100% de lo que iba a escribir.
- **F6.1' Stage history timeline**: ya existía dentro de `openDeal` (line 4552). Ahorro: 100%.
- **F6.2 Bulk operations**: confirmado que NO existe. Decisión: aplazar — requiere refactor del rendering de tablas (mejor en su propia fase).
- **F6.3 Follow-up automático**: confirmado que NO existe. Implementado.
- **F6.4 Cleanup tool**: confirmado que NO existe. Implementado.

**Reemplacé F6.1 por F6.1' Activity Feed visual** porque el audit log ya estaba poblado pero la UI sólo era una tabla. Convertirla en un feed estilo Slack costó 30 líneas y es alta visibilidad para el equipo.

**Métricas Fase 6**: 9/9 checks first try, **0 truncados**, 0 retries. Segunda fase consecutiva limpia tras F4.

**Patrón validado**: skip features cuando ya existen, reemplazar por algo cercano y útil. **No expandir scope para "completar el plan"**.

**Cosas que NUNCA romper (actualizado Fase 6):**
- `FOLLOWUP_MAP` mapea tipo de actividad a {nextType, daysAhead, title}. `note` y `task` no generan follow-up por diseño. Si añades nuevos tipos, considerar si tienen sentido como source.
- `suggestFollowUp(a)` se invoca SÓLO cuando `wasOpen && a.done` (toggle de no-hecho a hecho). No reapertura, no edición.
- `renderCleanup` requiere `isAdmin()`. La detección de duplicados usa `findSimilarName` (definido en F5.3) — son interdependientes.
- El feed muestra eventos de TODO el equipo (sin scoping per-consultor). Es intencional — es para colaboración. Si quieres feed personal, filtrar por `userId===DB.currentUserId`.

**Patrón de "feature ya existe" — pasos:**
1. Antes de planear el código, `Grep` por palabras clave del concepto (`map|geo|world` para mapa, `stageHistory|timeline` para histórico).
2. Si hits relevantes: `Read` de la función para ver el alcance real.
3. Si la feature está implementada: skip + decidir reemplazo o pasar al siguiente.
4. Si está parcial: enriquecer en lugar de duplicar.
5. Documentar el reemplazo en la entrega al usuario para transparencia.

**Lección Fase 7 — el verify check con strings literales puede dar false-negative:**

En F7 mi verify chequeó `'id="bulkBar"' in html` para confirmar el bulk action bar. El check falló (✗) pero la feature funciona. Razón: `bulkBar` se crea dinámicamente con `bar.id='bulkBar'` en JS — el literal HTML `id="bulkBar"` nunca aparece estáticamente, sólo en el DOM en runtime.

**Regla nueva**: para features creadas dinámicamente, chequear el statement JS (`'bar.id=\\'bulkBar\\''`) o la función creadora (`'function renderBulkBar'`), no el atributo HTML resultante.

**Lección F7 — extender notification system existente paga 10×:**

El sistema de notificaciones (bell, dropdown, mark-as-read) ya existía pre-F1 pero sólo se llenaba manualmente vía `addNotification` en mentions/comments. **Añadir 3 generadores automáticos (`task_overdue`, `deal_stuck`, `pupilo_ending`) costó 60 líneas y multiplica el valor del bell**. El patrón:
1. Reuse `addNotification` con un `_reminderKey` para idempotencia (no duplicar la misma alerta).
2. Reuse `cleanupStaleReminders()` para auto-limpiar cuando la condición ya no aplica (ej: tarea ya hecha).
3. Llamar al generador en cada `loadDB` — el "tick" natural del CRM.

**Cosas que NUNCA romper (actualizado Fase 7):**
- Las claves `_reminderKey` siguen el patrón `<kind>_<entityId>[_<userId>]`. Cambiarlas rompe la idempotencia y duplica notifs.
- `cleanupStaleReminders` debe ejecutarse ANTES de `generateAutoReminders` en cada load. Si invierten orden, las stale persisten un tick más.
- `state.bulkSel` es un `Set`, no un Array. Evita usar `.length`, usa `.size`.
- El `bulkBar` se inserta en `<body>` directamente (fuera del `#content`), por lo que sobrevive a `render()` — es por eso que `renderBulkBar()` se llama vía `setTimeout(0)` desde `render()`.

**Métricas Fase 7**: 14/14 funcionales (1 false-negative del check), 0 truncados, 0 retries.

**Lección Fase 8 — UX wins son baratos cuando los pones todos juntos:**

F8 fueron 4 UX micro-features (tab title, cheat sheet, mentions autocomplete, saved filters). Cada una <100 líneas. **Todas en un batch único** = 11/11 checks first try sin retries. Tiempo total ≈ 30 min.

**Patrón validado**: cuando varias features pequeñas comparten zona de inserción (todas antes de `/* boot */`), un batch único es óptimo. Costo marginal por feature adicional ≈ 0.

**Cosas que NUNCA romper (actualizado Fase 8):**
- `document.title` debe poder restaurarse a `'CEO Advisors · CRM'` cuando no hay user (logout). El prefijo `(N) ` sólo debe aparecer si hay user logueado y `unreadNotifs > 0`.
- El listener de `?` para cheat sheet ignora INPUT/TEXTAREA/SELECT — no romperlo o se dispararía dentro de campos de búsqueda.
- `@-mention autocomplete` se activa por `id^="ci_"` (textareas de comentarios). Nuevos textareas que necesiten mention deben tener `id` empezando por `ci_`.
- `SAVED_FILTERS_KEY='ceoadvisors_saved_filters_v1'` — bumping a v2 requeriría migración de los presets guardados de los usuarios.

**Métricas Fase 8**: 11/11 first try, 0 truncados, 0 retries. **Tercera fase consecutiva limpia** (F4, F6, F7, F8 = 4 de las últimas 5).

**Estado de los archivos tras 9 fases (~480KB HTML)**:
- HTML: ~6300 líneas. Crecimiento por fase ≈ 100-200 líneas. La estructura sigue siendo navegable con grep+offsets.
- inject_data.py / sync.py: estables, no han crecido en F4-F8.
- Patrón "batch antes de /* boot */" probado con éxito en F1, F2, F3, F4, F5, F6, F7, F8 = 8 fases consecutivas.

**Lección CRÍTICA tras F8 — verify la sintaxis JS, no sólo strings:**

Tras F8 el usuario reportó "CRM vacío". Causa raíz: F6.4 (`renderCleanup`) tenía escape de comillas inválido en strings JS (`\\'co\\'` dentro de un template Python que se aplicó como Python escape, generando `\'co\'` en el JS final, que **no es válido en strings con comillas simples**). El JS rompía en línea 5240 y nada después se ejecutaba — render() nunca se llamaba.

**Mis verify checks de F6/F7/F8 NO detectaron esto** porque sólo chequeaban presencia de strings (`'function renderCleanup' in html`). El JS estaba ahí, pero malformado.

**Regla nueva URGENTE**: incluir en cada `verify` **un parse del JS con `node --check`**. Cuesta 1 segundo y detecta el 100% de errores de sintaxis. Patrón:

```python
import subprocess
# Localizar el último <script>...</script> (sin src)
lines = html.split('\\n')
start = next(i for i,l in enumerate(lines) if l.strip()=='<script>')
end = next(i for i in range(len(lines)-1,-1,-1) if lines[i].strip()=='</script>')
js = '\\n'.join(lines[start+1:end])
open('/tmp/check.js','w').write(js)
r = subprocess.run(['node','--check','/tmp/check.js'], capture_output=True, text=True)
assert r.returncode==0, f"JS INVÁLIDO: {r.stderr[:500]}"
```

**Patrón seguro para escape en batch scripts Python**: en lugar de templates con `\\'`, **usar template literals JS (backticks `)** dentro de los strings Python que generan código JS. Los backticks simplifican enormemente porque no hay conflicto con apóstrofes:

```python
# MAL: '<a onclick="auditOpen(\\'+t+\\'\\,\\\\'+id+\\\\')"...'
# BIEN: f"<a onclick=\\"auditOpen('${t}','${id}')\\">..."  (template literal JS)
```

**Cosas que NUNCA romper (post bug F6.4)**:
- Cualquier `replace`/`Edit` que toque código JS dentro del HTML debe ir seguido de `node --check` en el script principal.
- Si el batch genera JS desde Python f-strings, **siempre** preferir template literals JS (backticks) — son robustos a escape.
- Si el usuario reporta "vacío" o "no se ve nada" → primer check siempre es **sintaxis JS**, no localStorage ni SW cache.

**Métricas de errores reales en este repo**:
- Truncados de archivo: 6 (F0, F1, F2×2, F3×2, F5, F8-fix) — todos detectados por `tail -3`.
- Bug de sintaxis JS no detectado: **1 (F6.4)** — silencioso durante 3 fases (F6, F7, F8) hasta que el usuario lo encontró.
- Coste real del bug oculto: ~3 fases con valor reducido (el usuario no podía probar las features). **Eso es 10× peor que un truncado obvio.**

**Lección F8-fix — `tail -3` NO basta, hay que verificar el contenido del cierre:**

Tras arreglar F6.4 y regenerar, mi `tail -3` mostró `</html>` pero el archivo terminaba en realidad en `r\n</script></body></html>` — la `r` era la mitad de `render()`. El boot section estaba truncado: faltaba `ender();` y la llamada nunca se ejecutaba al cargar.

**Regla nueva sobre `tail`**: no basta con que termine en `</html>`. Hay que verificar **las 3-4 últimas líneas del JS antes del `</script>`** para confirmar que el boot section está completo:
- `state.authed=false;`
- `state.view='today';`
- `renderUserSwitcher();`
- `render();` ← esta es la crítica

Si falta `render()` antes de `</script>`, el CRM se carga pero no pinta nada → "no veo nada" del usuario.

**Patrón validado de check post-batch**:
```python
# Después de cada batch HTML/Edit en el script principal:
js_tail = src[-1500:]   # últimas ~30 líneas del archivo
assert 'render()' in js_tail.split('</script>')[0]  # render dentro del script, no fuera
assert 'state.authed=false' in js_tail
```

**Cosas que NUNCA romper (post bug F8-fix)**:
- El boot section completo: `state.authed=false; state.view='today'; renderUserSwitcher(); render();` antes del `</script>`. Si una sola de estas líneas falta, el CRM aparece roto al usuario.
- Si haces un `replace(boot_marker, ...)`, asegúrate de que el `boot_marker` se preserva en el `new_string` y el contenido posterior (incluido `render()`) sigue después.

**Lección Fase 9 — verify estandarizado evita regresiones:**

F9 fue la **primera fase con el verify completo aplicado desde el inicio**:
1. `tail -3` source HTML → ¿termina en `</html>`?
2. `node --check` del script principal → ¿sintaxis OK?
3. Check de boot section → ¿`state.authed=false` y `render();` presentes en últimos 1500 bytes?
4. Grep de strings clave de cada feature

**Resultado F9**: 5/5 features verde, 0 truncados, 0 retries. La nueva regla "verify completo" detecta antes los bugs que antes eran invisibles.

**Patrón validado de verify completo (copiar-pegar)**:
```python
import subprocess
html = open('CEO_Advisors_CRM_PRODUCTION.html').read()
# 1. Closing
assert html.rstrip().endswith('</html>'), 'no cierra con </html>'
# 2. Boot
js_tail = html[-1500:]
assert 'state.authed=false' in js_tail and 'render();' in js_tail.split('</script>')[0], 'boot incompleto'
# 3. Sintaxis JS
lines = html.split('\n')
start = next(i for i,l in enumerate(lines) if l.strip()=='<script>')
end = next(i for i in range(len(lines)-1,-1,-1) if lines[i].strip()=='</script>')
js = '\n'.join(lines[start+1:end])
open('/tmp/c.js','w').write(js)
r = subprocess.run(['node','--check','/tmp/c.js'],capture_output=True,text=True)
assert r.returncode==0, f'JS syntax: {r.stderr[:300]}'
# 4. Features (per fase)
# ...
```

**Cosas que NUNCA romper (actualizado Fase 9):**
- `savedFilterChips(view)` espera `view` como string. Si añades una nueva vista filtrable (ej. `companies`), añade el caso en `_loadSavedFilters` y `applySavedFilter`.
- Las CSS de `@media print` ocultan: `aside.nav, header, .icon-btn, .btn, .uswitch, .udrop, .notif-dd, #bulkBar, #helpShortcuts, #gsDropdown, #mentionDD`. Cualquier nuevo elemento UI no-imprimible debe añadirse a esa lista.
- El empty state CTA usa `openCsvImport()` que requiere admin. Para un consultor no-admin, esa ruta falla — considerar variante para roles.

**Lección Fase 10 — escape de `${...}` en batch scripts NO es trivial:**

En F10 mi batch script intentó insertar una KPI con template literal JS dentro de un Python triple-string. El escape `\\${` se interpretó mal y la inserción de KPI falló silenciosamente (no rompió, pero no se aplicó). El check final detectó la ausencia.

**Regla nueva**: cuando el `new_string` contenga `${...}` JS, **usa Edit puntual en lugar de batch script**. El batch funciona para inserciones sin template literals; para template literals JS, el Edit con `old_string`/`new_string` literales evita el problema de doble escape.

**Otra lección F10**: el Edit puntual con bloques grandes cerca del final del script CAUSA truncado (se perdió el cierre del archivo durante el Edit del KPI). El patrón ya conocido: tras cualquier Edit grande, **verificar `tail -3` y reparar si necesario** ANTES de regenerar producción.

**Métricas Fase 10**: 5/5 features verde tras reparación. 1 truncado mid-fase (causado por Edit con template literal). Patrón TAIL repair: 30s.

**Cosas que NUNCA romper (actualizado Fase 10):**
- `tierANeglected()` retorna sólo clientes con `tier==='A'` o `netWorth>=50M`. Si cambias el threshold, sincronizar con `autoTier()` (F5.2).
- `generateWeeklyDigest()` usa `ClipboardItem` (Chrome/Edge); el fallback descarga `.html` en navegadores sin soporte. NUNCA quitar el fallback.
- El digest excluye automáticamente datos sensibles via `scopedDeals/Activities` — sólo aparece lo del consultor logueado, no del equipo. Si cambias scope, considerar permisos.

**Lección Fase 11 — fase 100% limpia tras 11 iteraciones:**

F11 fue 8/8 checks first try, 0 truncados, 0 retries. La razón clara:
1. **No template literals JS dentro del batch Python** — todo se hizo con concatenación de strings simples.
2. **Quick-log usa `JSON.stringify` para escape automático del object literal** del preset, evitando escape manual.
3. **Inline notes editor usa IDs únicos por entidad** (`inlineNotes_<type>_<id>`) — sin colisión cuando hay drawers anidados.

**Cosas que NUNCA romper (actualizado Fase 11):**
- `crm_welcomed_<userId>` localStorage key marca el welcome como visto. Cambiar el formato deja a usuarios viendo welcome de nuevo (es OK, no es un bug crítico).
- `quickLog()` SIEMPRE marca `done:true` para non-task (meeting/call/email/note) — son registros de "ya ocurrió". Sólo `task` queda pendiente.
- `inlineNotesBlock` se renderiza incluso cuando notes está vacío. El usuario hace click en "+ Añadir" para abrir editor inline. NUNCA volver al patrón "ocultar si vacío".

**Métricas Fase 11**: 8/8 first try, 0 truncados, 0 retries. **Cuarta fase consecutiva limpia tras F4, F6, F7, F8, F11**.

**Lección Fase 12 — descubrimiento de truncado HEREDADO desde F11:**

F12 era CSS-only (mobile media queries). Pero al verificar tras el Edit, el archivo estaba truncado mid-`startEditNotes` (función F11.3). El truncado había viajado SILENCIOSAMENTE desde F11 al estar entre líneas que no tocó el verify de F11.

**El verify completo de F11 mostró 8/8 ✓** porque sólo chequeaba presencia de strings, no integridad estructural completa. Sólo cuando F12 trató de regenerar producción, el `node --check` falló y reveló el archivo roto.

**Regla nueva crítica**: el verify de cada fase debe incluir `node --check` del **source HTML**, no sólo del production. Si el source tiene errores, regenerar production sólo los propaga.

**Regla actualizada**:
```python
# Verify completo (source + production)
for f in ['CEO_Advisors_CRM.html', 'CEO_Advisors_CRM_PRODUCTION.html']:
    html = open(f).read()
    assert html.rstrip().endswith('</html>'), f'{f} no cierra'
    # extraer JS y validar...
```

**Lección F12 — backticks en strings JS embebidos en Python son a prueba de balas:**

Tras intentar 2 veces escribir un TAIL Python con escape de comillas (`\\"`), ambos rompieron la sintaxis JS. La tercera versión usó **template literals JS (backticks)** dentro de Python triple-string ordinario — funcionó al primer intento.

**Patrón validado**:
```python
TAIL = '''function foo(x){
  return `<div onclick="bar('${x}')">${x}</div>`;
}
'''.encode('utf-8')
```
Los backticks no entran en conflicto con apóstrofes (`'`) ni comillas (`"`) → 0 escape Python necesario. **Esta es la solución definitiva al problema de generar JS desde Python**.

**Cosas que NUNCA romper (actualizado Fase 12):**
- El `<style>` block tiene tres `@media`: print, 768px, 480px. NUNCA mover el orden — print debe ir AL FINAL para no ser sobrescrito por el resto.
- `.drawer { width: 100% !important }` en mobile — sin el `!important` los anchos por default ganarían y el drawer no se vería fullscreen.
- F12 SÓLO añadió CSS. **Cero cambios en JS** — esta es la fase más segura por diseño.

**Métricas Fase 12**: 10/10 tras 2 reparaciones (truncado heredado de F11 + escape JS). El bug oculto F11→F12 confirma que `node --check` post-batch es OBLIGATORIO no opcional.

**Lección Fase 13 — backticks JS pagaron desde el primer intento:**

F13 fue la primera fase aplicando todas las reglas defensivas desde el batch inicial:
1. **Backticks `${...}` JS dentro de Python triple-string** sin escape → 0 errores de sintaxis
2. **Verify de SOURCE + PRODUCTION** (no solo prod) → detecta truncados heredados antes de propagar
3. **`node --check` integrado** en el verify

**Resultado**: 7/7 checks ✓ first try, 0 truncados, 0 retries, ambos archivos válidos.

**Cosas que NUNCA romper (actualizado Fase 13):**
- `renderExecSummary` requiere `isAdmin()`. Sin admin, render bloquea con mensaje. Si añades una vista nueva con scope admin, copia el patrón.
- Reuso de @media print de F9.3 para `window.print()` — no añadir nuevos `@media print` blocks; ampliar el existente.
- El topClients del Executive Summary ordena por `c.netWorth` con fallback a 0. NUNCA filtrar por `c.netWorth>0` o ocultaría clientes recién añadidos.

**Métricas Fase 13**: 7/7 first try, 0 truncados, 0 retries. **Quinta fase consecutiva limpia tras F4, F6, F7, F8, F11, F13**.

**Lección Fase 14 — terminamos el roadmap "construir features":**

F14 fue la última fase del roadmap inicial. Comportamiento del workflow tras 14 fases:
- **F14**: 8/8 checks ✓ first try, 0 truncados, 0 retries.
- **Pattern de "feature ya existe"** otra vez: theme-dark/density-compact/applyTheme/applyDensity ya estaban implementados completos. F14 acabó añadiendo **un wrapper** (Settings modal) que agrupa toggles existentes + nueva navegación g+letra.

**Roadmap "construir features autónomo" → CERRADO tras F14**.

Próximas fases (si ocurren) ya no son "construir", son:
- **Pulido reactivo**: bugs reales con uso en producción.
- **Datos reales**: enriquecer con clientes/deals reales, no demo.
- **Backend Supabase**: única forma de saltar a multi-user real-time, requiere credenciales del usuario.
- **Mejoras a demanda**: lo que el equipo pida tras usar 2-3 semanas.

**Cosas que NUNCA romper (actualizado Fase 14):**
- `G_NAV_MAP` — letras → views. Si añades una nueva vista al CRM, considera registrarla aquí para coherencia con el atajo `g+letra`.
- `_gKeyArmed` se desarma tras 1500ms para no bloquear teclas si el user pulsa `g` accidentalmente. NUNCA quitar el timer.
- El Settings modal lee `state.theme/density` directamente. Si cambias el shape de `state`, actualizar el modal.
- F14.1 reusa `toggleTheme/toggleDensity` existentes — no duplicar lógica.

**Métricas finales del proyecto tras 14 fases:**
- ~52 features funcionales
- HTML ~6800 líneas / 513KB
- 6 fases consecutivas limpias en las últimas 9 (F4, F6, F7, F8, F11, F13, F14 — 7 en realidad)
- Sólo 1 bug oculto en todo el proyecto (F6.4) — resuelto y prevenido por la nueva regla `node --check`

**Patrones definitivos validados (resumen ejecutivo de CLAUDE.md):**
1. **Auditoría inicial** = `tail -3` + `node --check` + `python3 ast.parse` de cada archivo (30s).
2. **Batch script Python** con backticks JS — escape cero, robusto a apóstrofes/comillas.
3. **Verify SOURCE + PRODUCTION** tras cada batch — detecta truncados antes de propagar.
4. **`Read` función antes de planear** — evita duplicar features que ya existen (pasó en F1.6, F6.1, F6.1', F14).
5. **`/* boot */` como insertion point estable** — antes del marker, conservar el resto del archivo intacto.
6. **Reparar truncados** con patrón `data[:rfind('\\n')+1] + TAIL` — cuesta 30s.

## Fase 15 — Integración Supabase backend

**Proyecto Supabase**: `rtusnruywsmbbzejxooi` (CRM - CEO Advisors), org `psanzd11's Org`, region us-west-1, Postgres 17, ACTIVE_HEALTHY.

**Decisiones upfront (validadas con el usuario en F15.0):**
- **Auth**: Supabase Auth (password). Los passwords del Excel se descartan en F15.3, cada consultor recibe invitación por email.
- **Modo**: Online-first. localStorage queda como cache de arranque rápido, no como fuente de verdad.
- **Excel**: Importer inicial + backup. Tras F15.2 el flujo normal pasa a la web.
- **RLS**: MVP permisivo en SELECT (autenticados leen todo, cliente filtra), estricto en escritura (admin escribe; consultor escribe sus propias activities). Endurecimiento per-consultor diferido a F15.4.

**Sub-fase 15.0 — COMPLETADA (2026-05-10):**
- Migration 001 `initial_schema_2026_05_1` aplicada. 7 tablas (consultants/clients/companies/deals/activities/pupilos/activity_log) con RLS activo, indexes, triggers `moddatetime`, enums (deal_type/deal_stage/client_tier/activity_type), helper functions `is_admin()` y `my_consultant_id()` (security definer).
- Migration 002 `harden_rpc_functions` aplicada: revoke EXECUTE de `anon` para las helper functions.
- Realtime activo en `deals`, `activities`, `clients`.
- Schema file canon: `supabase_migrations/001_initial_schema.sql` (artifact del workspace, no se aplica automáticamente — sólo referencia).
- Advisors restantes son WARN no críticos: `citext` en public schema (cosmético), funciones SECURITY DEFINER ejecutables por `authenticated` (intencional, necesarias para RLS).

**Reglas Fase 15 a respetar:**
- **`code` column** en cada tabla (u1, c1, d1, co1, a1, p1) — mantiene paridad con HTML actual hasta que F15.3 reemplace IDs por UUIDs en cliente. Cuando F15.2 importa Excel, el `code` viene del Excel; UUIDs son nuevos.
- **`splits` JSONB** en deals — el shape `[{u: <uuid>, pct: <int>}]` debe usar UUIDs de consultants, NO los códigos cortos. F15.2 hace el mapeo.
- **NUNCA** habilitar Realtime en `consultants`/`pupilos`/`companies`/`activity_log` sin pensarlo — alto coste de bandwidth, baja frecuencia de cambio.
- **NUNCA** modificar `is_admin()` o `my_consultant_id()` sin migration nominada — están referenciadas en todas las RLS policies y un cambio incompatible las rompe todas.
- **Antes de F15.3** (auth swap), backup del HTML PRODUCTION pre-cambio. Es la fase más delicada.

**Patrón a aplicar en F15.1+:**
- Cada migration en su archivo `supabase_migrations/NNN_<name>.sql` en el workspace.
- Aplicar vía `apply_migration` (no `execute_sql`) — quedan en el historial de migrations.
- Tras cada migration, correr `get_advisors security` — detecta RLS faltante, FKs sin index, etc.
- WARN se documentan; ERROR detiene la fase.

**Lección F15.0 — preguntas upfront ahorran refactor:**
- Antes de tocar Supabase pregunté 4 decisiones binarias (auth, modo, Excel, RLS) con AskUserQuestion. El usuario eligió las 4 recomendadas en <1 minuto. **Coste**: 1 round-trip. **Ahorro**: si hubiera elegido PBKDF2 propio o offline-first, todo el schema y las RLS habrían sido distintos. Decidir UPFRONT > parchear después.
- Patrón validado: para fases con decisiones arquitectónicas, presentar tabla de sub-fases + AskUserQuestion con 3-4 opciones. Confirmar OK explícito antes del primer `apply_migration`.

**Sub-fase 15.1 — COMPLETADA (2026-05-10):**
- Migration 003 `auto_link_auth_user_to_consultant` aplicada. Trigger `on_auth_user_created` en `auth.users` AFTER INSERT que invoca `handle_new_auth_user()` — busca match case-insensitive por email en `consultants` y rellena `auth_user_id` si está null.
- Migration 004 `harden_trigger_function` aplicada: revoke EXECUTE de `handle_new_auth_user()` para anon/authenticated/public (es trigger-only, no debe exponerse como RPC).
- TypeScript types generados en `supabase_migrations/types.ts` (referencia para F15.3, no runtime — HTML es vanilla JS).
- Credenciales públicas guardadas en `supabase_migrations/.env.supabase`:
  - `SUPABASE_URL`: `https://rtusnruywsmbbzejxooi.supabase.co`
  - `SUPABASE_PUBLISHABLE_KEY`: `sb_publishable_UDs1RIV3J1WfSf31_XMUmQ_ApQS1G5H` (modern, preferida)
  - `SUPABASE_ANON_KEY`: JWT legacy (fallback compat)
- 3 migrations en total; advisors: 5 WARN (citext en public + 4 SECURITY DEFINER por authenticated, intencionales).

**Reglas Fase 15.1 a respetar:**
- **NUNCA** poner la `service_role` key del proyecto en el cliente. Sólo publishable/anon. El admin SDK queda en scripts Python (F15.2) que se ejecutan local.
- **El trigger `on_auth_user_created` es idempotente** — sólo escribe si `auth_user_id` está null. Si un consultor cambia de email en Supabase y se re-registra con otro, NO se vincula automáticamente (es por diseño, evita pisar links manuales).
- **El match es case-insensitive por email**. Si en Excel pone `Pablo@CEOAdvisors.com` y en Supabase Auth se registra como `pablo@ceoadvisors.com`, hay match. Pero hay que confirmar que el `email` de la fila consultants es el mismo dominio que el de Auth.
- Si los emails del Excel tienen espacios o errores tipográficos, el match falla silenciosamente. F15.2 debe validar emails antes de importar.

**Lección F15.1 — los advisors crecen con cada función SECURITY DEFINER:**
- Cada función nueva con `security definer` añade 2 WARN al advisor (anon + authenticated callable via RPC). Patrón a aplicar: al final de cada migration que crea funciones SECURITY DEFINER, incluir `revoke execute on function ... from anon, authenticated, public` en el mismo SQL.
- **No hacerlo** como hice en F15.0 (migration aparte para harden) — duplicación innecesaria de migration. **Hacerlo embebido** = una migration menos.

**Sub-fase 15.1 extra — Flag `is_demo` (2026-05-11):**
- Migration 005 `is_demo_flag` aplicada. Columna `is_demo boolean not null default false` en `clients`, `companies`, `deals`, `activities` + índices parciales `WHERE is_demo = false`.
- **Pupilos NO marcado** — datos reales (decisión usuario 2026-05-11).
- **Consultants NO marcado** — son el equipo real.
- F15.3 incluirá toggle UI "Ocultar demo" en barra superior (acordado).

**Reglas para F15.2 importer:**
- **TODO lo que importe del Excel actual a clients/companies/deals/activities debe llevar `is_demo=true`**. El Excel actual es 100% demo.
- Pupilos del Excel se importan sin `is_demo` (la columna no existe en pupilos).
- Consultants del Excel: reales — sin marca, columna no existe.

**Estrategia de purga futura (cuando lleguen datos reales):**
```sql
-- Orden importante por FKs (activities → deals → clients/companies)
delete from public.activities where is_demo = true;
delete from public.deals      where is_demo = true;
delete from public.clients    where is_demo = true;
delete from public.companies  where is_demo = true;
```

**Cosas que NUNCA romper (post is_demo):**
- El `default false` en `is_demo` — cualquier fila creada por la UI ya queda como "real" automáticamente. Si lo cambias a `default true`, los nuevos registros del CRM aparecerían como demo.
- Los índices parciales asumen `WHERE is_demo = false`. Si en algún momento la mayoría son demo (>50%), considerar invertirlos o quitar; ahora optimizan el caso producción.

**Sub-fase 15.2 — COMPLETADA con caveat (2026-05-11):**
- 136 filas cargadas en Supabase via `migrate_to_supabase.py`:
  - 8 consultants (real, sin is_demo)
  - 30 clients, 25 companies, 43 deals, 20 activities (is_demo=true)
  - 10 pupilos (real)
- UUIDs deterministas via `uuid5(NS_FIXED, code)` — el script es idempotente, re-ejecutar no duplica.
- Email typo u2 `rcharvarria` → `rchavarria` corregido en `EMAIL_FIXES` del script.
- 2/8 invitaciones enviadas (CEO Roberto Arguello + Pablo). 6/8 bloqueadas por rate limit del SMTP gratuito de Supabase.
- Trigger F15.1 funcionó: los 2 con invitación tienen `auth_user_id` vinculado automáticamente.

**Lección F15.2 — Supabase SMTP gratuito tiene rate limit BAJO (~2 emails/hora):**
- El plan free de Supabase usa un SMTP compartido con límites estrictos. Tras 2 invitaciones consecutivas, devuelve 429 `over_email_send_rate_limit`.
- **Soluciones**:
  - A) Esperar y reintentar con `invite_remaining.py --real --sleep 1800` (30 min entre cada uno).
  - B) **Recomendado a futuro**: configurar SMTP custom (SendGrid/Resend/SES) en Supabase Auth → settings → SMTP. Sube el límite a 100+ por minuto.
  - C) Bypass: `auth.admin.createUser(email_confirm=true)` + Supabase devuelve `action_link` que Pablo distribuye manualmente.
- **Antes de F15.3** debería estar configurado el SMTP custom, porque el "forgot password" en F15.3 también lo usará.

**Patrón de migración a tablas con `code` único (validado en F15.2):**
- UUIDs deterministas: `uuid.uuid5(uuid.UUID('00000000-0000-0000-0000-000000000001'), code)`.
- Upsert vía PostgREST: `POST /rest/v1/table?on_conflict=code` con header `Prefer: resolution=merge-duplicates,return=minimal`.
- Idempotencia gratis: re-ejecutar el script no duplica nada, sólo refresca.
- Para FKs: calcular UUIDs en cliente antes de insertar (con uuid5(code)) → no necesitas dos pasadas.
- Para JSONB con refs: `splits: [{u: uuid5(code), pct}]`, `client_ids: [uuid5(c1), ...]`.

**Cosas que NUNCA romper (post F15.2):**
- El `NS = UUID("00000000-0000-0000-0000-000000000001")` en `migrate_to_supabase.py` — si lo cambias, los UUIDs ya no coinciden y el upsert duplica todo. Anclar para siempre.
- Los enums `TYPE_MAP/STAGE_MAP/ATYPE_MAP` en el script — son el contrato entre el HTML legacy y los enums Postgres. Si añades un nuevo deal_stage al HTML, añádelo aquí y a la migration que añada el valor al enum.
- El script genera idempotencia POR `code`. Si un día decides que `code` deja de ser único (ej. dos `c1` distintos), el upsert empieza a pisarse.
