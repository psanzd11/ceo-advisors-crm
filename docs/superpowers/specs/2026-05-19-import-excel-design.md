# Import de Excel + cleanup botones JSON legacy

**Fecha:** 2026-05-19
**Estado:** Aprobado por Pablo
**Autor:** brainstorming session
**Spec previo:** `2026-05-19-clientes-empresas-libreta-compartida-design.md` (prerrequisito, ya implementado en commit `77ce577`)

---

## 1. Motivación

Permitir a cualquier consultor importar de golpe su cartera (clientes / empresas / deals) desde un Excel. Casos de uso reales:
- Onboarding de un consultor nuevo que llega con su libreta de contactos en otro CRM o en una hoja personal.
- Migración desde sistemas ad-hoc (caso concreto: un consultor que mantiene su pipeline en un chat de Perplexity y quiere migrar).
- Carga inicial de prospectos cuando se entra en un nuevo mercado o vertical.

Hasta hoy esto requería que el CEO/admin recibiera el Excel, lo procesara manualmente o usara el script `migrate_to_supabase.py`. Con la libreta compartida ya implementada (`F-LibretaCompartida`), cualquier consultor puede insertar clientes/empresas/deals que serán visibles para todo el equipo, así que tiene sentido abrir el import al UI.

Como cambios adyacentes en la misma zona del header, se retiran los botones **Importar JSON** y **Exportar JSON** que quedaron obsoletos tras la migración a Supabase:
- Importar JSON era el modo legacy `replace` / `merge` del pipeline pre-Supabase (Excel → `inject_data.py` → HTML). Ya no aplica.
- Exportar JSON está cubierto por el backup diario automático vía GitHub Actions (commit `5c7c0de`). Si Pablo necesita un dump puntual, lo hace desde Supabase MCP.

## 2. Alcance

### Dentro
- Botón nuevo **"Importar Excel"** en el header (todos los autenticados).
- Botón nuevo **"Plantilla"** que descarga un `.xlsx` vacío con las 3 hojas, headers y 1 fila de ejemplo.
- Flujo cliente-side completo: parse → validate → preview con conteos y warnings → confirm → apply.
- Soporte de 3 hojas: `Clients`, `Companies`, `Deals` con IDs temporales para crosslink entre hojas.
- Dedup por email (case-insensitive) en Clients contra la BD existente. Skip silencioso de duplicados.
- Splits hardcoded: el importador como A1 al 100% en cada deal. Editable post-import desde la UI normal.
- Eliminación de los botones `#btnImport`, `#btnExport`, su input file `#importFileInput`, sus listeners y la función `_backupToast` asociada.

### Fuera (futuros specs)
- Import de **Activities** (llamadas, emails, reuniones). Las activities post-import se crean desde la UI.
- Import de **Pupilos** (gestión separada con docs, no aplica a este flujo).
- Splits declarables en Excel (columnas A1/A2/A3 + %). Si en uso real lo piden, lo añadimos.
- Mapeo flexible de columnas con wizard ("esta columna de tu Excel = Name"). Solo formato exacto en v1.
- Batching del flush en lotes de 50 filas. Solo si vemos lag en uso real.
- Toast consolidado de Realtime para imports masivos. Hoy se muestran individuales.

## 3. Formato del template Excel

### Hoja 1 — `Clients`

| Columna | Tipo | Obligatorio | Notas |
|---|---|---|---|
| ID | texto | no | ID temporal (`cli1`, `cli2`...) usado para que las hojas Companies/Deals puedan referenciar este cliente. Si vacío, se genera. |
| Name | texto | **sí** | Nombre completo. Si vacío → fila omitida con warning. |
| Email | texto | no | Recomendado. Si ya existe en BD (case-insensitive) → fila omitida silenciosamente. |
| Phone | texto | no | |
| Country | texto | no | Default `'—'` si vacío. |
| City | texto | no | |
| Net Worth USD | número | no | Default 0. Sin símbolo, sin separadores. |
| Source | texto | no | Whitelist: `Referral`, `Outbound`, `Inbound`, `Conference`, `Partner`, `Other`. Inválido → default `Other`. |
| Tier | texto | no | Whitelist: `A`, `B`, `C`, `D`. Vacío o inválido → `autoTier(netWorth)`. |
| Notes | texto | no | |

### Hoja 2 — `Companies`

| Columna | Tipo | Obligatorio | Notas |
|---|---|---|---|
| ID | texto | no | ID temporal (`co1`, `co2`...). |
| Name | texto | **sí** | Si vacío → fila omitida con warning. |
| Industry | texto | no | |
| Country | texto | no | Default `'—'`. |
| Employees | número | no | Default 0. |
| Net Worth USD | número | no | Default 0. |
| Linked Client IDs | texto | no | Uno o varios IDs temporales de la hoja Clients separados por coma. Ej: `cli1, cli3`. IDs no encontrados se filtran con warning. |
| Website | texto | no | Dominio sin `http://`. |
| Notes | texto | no | |

### Hoja 3 — `Deals`

| Columna | Tipo | Obligatorio | Notas |
|---|---|---|---|
| ID | texto | no | ID temporal (`d1`, `d2`...). |
| Title | texto | **sí** | Si vacío → fila omitida con warning. |
| Client ID | texto | no | ID temporal de la hoja Clients. Si no encontrado → deal creado con `clientId=''` + warning. |
| Company ID | texto | no | Idem para Companies. |
| Type | texto | no | Whitelist (extraída de `DEAL_TYPES` en `index.html:804`): `sale`, `finance`, `expand`, `advise`, `wealth`. Inválido → default `advise`. |
| Stage | texto | no | Whitelist (extraída de `PIPELINE_STAGES` en `index.html:811`): `prospect`, `qualified`, `proposal`, `negotiation`, `won`, `lost`. Inválido → default `prospect`. |
| Amount USD | número | no | Default 0. |
| Expected Close | fecha | no | Formato `YYYY-MM-DD`. Inválido o vacío → `''`. |
| Notes | texto | no | |

### Reglas globales

- Fila 1 = headers literales. Match **case-insensitive**; se aceptan variantes en español de las columnas obligatorias (`Nombre`→`Name`).
- Datos desde fila 2.
- Máximo 200 filas por hoja. Filas 201+ se ignoran con warning.
- Splits NO se importan: el importador queda como A1 al 100% en cada deal generado. Editable post-import.
- Activities NO se importan en v1; si la hoja existe se ignora en silencio.
- Pupilos NO se importan; idem.

## 4. Cambios en la barra del header

### Eliminar
- `<button id="btnReload">` (línea 766-768) — la función `reloadFromTemplate()` queda viva porque la usa también el panel Settings (línea ~7435).
- `<button id="btnCsvImport">` (línea 769) — eliminar también la función `openCsvImport()` completa (línea ~6504). El nuevo Excel importer la sustituye.
- `<button id="btnImport">` (línea 770)
- `<input id="importFileInput" type="file" accept=".json">` (línea 773)
- `<button id="btnExport">` (línea 775)
- Listener click de `#btnImport` y handler `change` de `#importFileInput` (líneas ~6220-6260).
- Listener click de `#btnExport` (líneas ~6104-6122).
- Helpers de backup/export obsoletos: `_changesSinceExport` (línea 1749), `_lastExportTs` (línea 1750), `_backupToastShown` (línea 6125), funciones `maybeBackupReminder` (6126), `showBackupToast` (6134), `showPostExportModal` (6148). Quitar también la llamada `_changesSinceExport++` y `maybeBackupReminder()` dentro de `saveDB()` (líneas 1754-1756). Keys de localStorage `crm_changes_since_export` y `crm_last_export_ts` se borran defensivamente.

### Añadir
- `<button id="btnImportXLSX">` con icono upload + label "Importar Excel". Click → `openImportExcel()`.
- `<button id="btnDownloadTemplate">` con icono download pequeño + label "Plantilla". Click → `downloadImportTemplate()`.
- `<input id="importXLSXInput" type="file" accept=".xlsx,.xls" style="display:none">` para el file picker.

### Sin cambio
- `#btnExportXLSX` (Excel export — útil para sacar la libreta como .xlsx).
- `#btnDigest`, `#btnHideDemo`, `#btnNew`.

### Permisos
- Ambos botones disponibles para cualquier autenticado. Sin guard `isCEO() || isAdmin()`.

## 5. Arquitectura del importer

Todo en cliente, dentro de `index.html`. Sin edge function nueva. Las RLS abiertas en `F-LibretaCompartida` permiten que un consultor inserte clients/companies/deals; las RPC existentes `upsert_clients_if_newer`, `upsert_companies_if_newer`, `upsert_deals_if_newer` se siguen usando vía el `flushSupabase` normal.

### Funciones nuevas

| Función | Responsabilidad |
|---|---|
| `downloadImportTemplate()` | Genera un `.xlsx` con las 3 hojas, headers correctos y 1 fila de ejemplo por hoja. Reutiliza `loadSheetJS()`. |
| `openImportExcel()` | Trigger del `#importXLSXInput`. Orquesta el flujo cuando el usuario selecciona archivo. |
| `parseExcelImport(workbook)` | Convierte el workbook de SheetJS en `{clients:[], companies:[], deals:[]}` raw. Detecta headers en case-insensitive con alias en español. |
| `validateImport(raw)` | Aplica todas las reglas de la sección 6. Devuelve `{valid, errors, warnings, dedupSkipped, truncated}`. |
| `renderImportPreviewModal(report)` | Modal con resumen, warnings, botones Cancelar / Confirmar. Devuelve `Promise<boolean>`. |
| `applyImport(valid)` | Asigna UUIDs vía `uid(prefix)`, resuelve crosslinks de IDs temporales a IDs reales, fija `splits=[{u: currentUserId, pct: 100}]` para deals, push a `DB.{clients,companies,deals}`, llama `saveDB()` (que dispara `flushSupabase` por debounce). |

Las 6 funciones viven inline en el `<script>` de `index.html`, insertadas **antes** del marker `/* boot */` siguiendo la convención del proyecto.

### Flujo de datos

```
[Click Importar Excel]
        ↓
[file input → SheetJS workbook]
        ↓
[parseExcelImport]  →  raw {clients[],companies[],deals[]}
        ↓
[validateImport]  →  report {valid, errors, warnings, ...}
        ↓
[renderImportPreviewModal]  →  user confirms? ─── no → abort
        ↓ yes
[applyImport]
  ├── For each client in valid.clients:
  │     · skip si email ya en DB
  │     · id = uid('c'); mapa tempId→realId
  │     · DB.clients.push({id, name, email, ..., is_demo: false})
  ├── For each company in valid.companies:
  │     · id = uid('co')
  │     · clientIds = (Linked Client IDs split by comma) mapeados via mapa tempId→realId
  │     · DB.companies.push(...)
  ├── For each deal in valid.deals:
  │     · id = uid('d')
  │     · clientId = mapa.get(temp) ?? ''
  │     · companyId = mapa.get(temp) ?? ''
  │     · splits = [{u: DB.currentUserId, pct: 100}]
  │     · stage_history = [{stage: deal.stage, at: nowIso}]
  │     · DB.deals.push(...)
  ├── saveDB()
        ↓
[toast verde + render()]
```

### Persistencia
`saveDB()` ya dispara `scheduleSupabaseFlush()` con debounce 500ms. El batch flush envía vía RPC `upsert_*_if_newer` que acepta arrays jsonb — el upsert masivo se hace en 3 llamadas (una por tipo). Si la red falla, las filas quedan en la queue persistida (`ceoadvisors_supa_queue_v1`) y se reintentan al reconectar. Comportamiento existente, sin regresión.

## 6. Reglas de validación

### Filas saltadas (warning, no abort)

| Hoja | Condición | Warning |
|---|---|---|
| Clients | `Name` vacío | "Clients fila N: Name obligatorio — omitido" |
| Clients | `Email` ya existe en DB.clients (case-insensitive, trim) | "Clients fila N: email X ya existe — omitido" |
| Companies | `Name` vacío | "Companies fila N: Name obligatorio — omitido" |
| Deals | `Title` vacío | "Deals fila N: Title obligatorio — omitido" |
| Cualquiera | Fila 201+ en hoja con >200 filas | "Sheet X: 234 filas, se importan las primeras 200" |

### Crosslinks huérfanos (warning, no skip)

| Caso | Acción | Warning |
|---|---|---|
| Deal apunta a Client ID temporal no encontrado | `clientId = ''` | "Deals fila N: Client ID 'cli5' no existe — creado sin cliente" |
| Deal apunta a Company ID temporal no encontrado | `companyId = ''` | Análogo |
| Company `Linked Client IDs` con un ID temporal no encontrado | Filtrar ese ID del array | "Companies fila N: cliente 'cli9' no existe — ignorado" |

### Coerción silenciosa (sin warning, comportamiento documentado)

| Campo | Recibido | Acción |
|---|---|---|
| `Source` | No en whitelist | Default `'Other'` |
| `Tier` | Vacío o no en {A,B,C,D} | `autoTier(netWorth)` |
| `Type` (deal) | No en whitelist | Default `'advise'` |
| `Stage` (deal) | No en whitelist | Default `'prospect'` |
| `Country` | Vacío | Default `'—'` |
| `Net Worth USD`, `Amount USD`, `Employees` | Vacío o no numérico | Default 0 |
| `Expected Close` | Vacío o parse fail | Default `''` |

### Abort total (un solo caso)
- Archivo no es un .xlsx parseable, o no contiene ninguna de las 3 hojas con nombre reconocible.
- Alert: "Archivo Excel no válido — descarga la plantilla y úsala como referencia." Reset input. No se abre modal.

## 7. Modal de preview

Layout textual (renderizado con el helper `shell()` o `modal-back` existente):

```
┌─ Importar Excel ──────────────────────────────────────────┐
│                                                            │
│  Resumen                                                   │
│  ─────────                                                 │
│  ✓ Clients   :  47 nuevos    (3 omitidos por duplicado)   │
│  ✓ Companies :  12 nuevos                                  │
│  ✓ Deals     :  28 nuevos    (todos a tu nombre, 100%)    │
│                                                            │
│  Advertencias (5)                          [▾ expandir]   │
│  ─────────────                                             │
│  · Clients fila 14: Name vacío — fila omitida              │
│  · Clients fila 22: email pedro@x.com ya existe — omitido │
│  · Deals fila 7: apunta a cli99 inexistente — sin cliente │
│  · Deals fila 11: Type "lead" inválido → default 'advise'  │
│  · ... (1 más)                                             │
│                                                            │
│  [ Cancelar ]                          [ Confirmar import ]│
└────────────────────────────────────────────────────────────┘
```

**Reglas del modal:**
- Las advertencias arrancan colapsadas si hay >3; expandible.
- Confirmar lanza `applyImport`, cierra modal, muestra toast verde "Importado: X clientes, Y empresas, Z deals" + `render()`.
- Cancelar cierra modal y resetea el input (para que reintentar con archivo corregido funcione sin recargar página).
- Si tras validar hay 0 filas válidas en las 3 hojas: muestra "Nada que importar — corrige el archivo y reintenta", solo botón Cancelar.

## 8. Riesgos y mitigaciones

| Riesgo | Severidad | Mitigación |
|---|---|---|
| Headers en otro idioma o capitalización rara | Medio | Match case-insensitive + alias en español para columnas obligatorias. Si no hay match → hoja se omite con warning. |
| 200 × 3 = 600 inserts vía 3 RPC calls saturan Supabase | Bajo | Las RPC `upsert_*_if_newer` aceptan jsonb arrays; 200 filas es manejable. Si vemos lag en uso real, paginar en lotes de 50 (otro spec). |
| Realtime echo: otros consultores reciben N toasts de "cliente creado" | Bajo | Aceptado. Si se vuelve ruidoso, batch-toast otro spec. |
| Usuario sube .xls antiguo | Bajo | SheetJS lo lee. Input acepta `.xlsx,.xls`. |
| Macros / contenido sospechoso en el .xlsx | Bajo | SheetJS solo lee valores de celda; no ejecuta nada. |
| Import a medias por error de red | Bajo | Las filas push'eadas quedan en queue persistida y se reintentan. Comportamiento existente. |
| Colisión de UUIDs con seed demo | Bajo | `uid(prefix)` busca el siguiente libre globalmente. Sin colisión. |
| El usuario sube por error un Excel sin las hojas esperadas (ej. solo "Pupilos") | Bajo | Hoja desconocida se ignora. Si las 3 hojas esperadas faltan → abort con mensaje claro. |
| Eliminar `btnImport` JSON rompe un flujo crítico que no he considerado | Medio | Audit del código antes de eliminar: confirmar que `btnImport` solo se llama desde el listener; ningún otro path JS lo invoca. Buscar referencias antes de borrar. |
| Eliminar `btnExport` JSON elimina dependencias del backup toast (`_backupToastShown`) | Bajo | Auditar `_backupToast` y derivados. Si el botón `<button onclick="...btnExport...">` en el toast es la única referencia, eliminar también ese subset. |

## 9. Plan de implementación (alto nivel)

Sin entrar en detalle (eso es el plan):

1. **Limpieza UI:** eliminar `#btnImport`, `#btnExport`, `#importFileInput`, sus listeners y código asociado. Verificar `_backupToast`.
2. **Header nuevo:** añadir `#btnImportXLSX`, `#btnDownloadTemplate`, `#importXLSXInput`.
3. **Funciones importer:** implementar `downloadImportTemplate`, `parseExcelImport`, `validateImport`, `renderImportPreviewModal`, `applyImport`, `openImportExcel` antes de `/* boot */`.
4. **Verificación manual:** descargar plantilla, rellenar 3-5 filas de prueba en cada hoja con crosslinks, importar como un consultor no-admin, confirmar que los registros aparecen y persisten en Supabase.
5. **Verificación con Excel real de Perplexity** (cuando llegue del consultor de Pablo).
6. **Commit + push a main.** Railway redeploya.

## 10. Decisiones tomadas

- **Cliente-side puro**, sin edge function. Las RLS y RPC existentes soportan el caso.
- **Splits no editables en Excel** — el importador como A1 100%; editable post-import.
- **Activities fuera del v1**.
- **Dedup silencioso por email**, no preview con elección caso a caso.
- **Crosslinks huérfanos crean rows con clientId/companyId vacíos**, no abortan.
- **Errores de validación saltan filas individuales**, no abortan toda la importación. Solo abort por archivo inválido en raíz.
- **Plantilla descargable incluida** desde el primer release — bonus para tu consultor con Perplexity.
- **Limpieza de botones JSON legacy** se hace en este mismo spec (misma zona del HTML, lógica obsoleta tras la migración a Supabase).
- **200 filas por hoja** como techo. Suficiente para una libreta personal de un consultor.
