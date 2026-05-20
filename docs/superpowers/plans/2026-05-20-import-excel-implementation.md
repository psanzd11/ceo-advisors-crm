# Import Excel + cleanup botones legacy — Plan de implementación

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Añadir 2 botones nuevos al header (`Importar Excel`, `Plantilla`) que permiten a cualquier consultor subir su libreta desde un `.xlsx` con 3 hojas (Clients/Companies/Deals), con preview + dedup + crosslink. Como cambio adyacente, eliminar 4 botones legacy del header y sus helpers de export JSON.

**Architecture:** Toda la lógica vive cliente-side en `index.html`. Reutiliza `loadSheetJS()`, `uid()`, `autoTier()`, `saveDB()` y las RPC `upsert_*_if_newer` existentes. 6 funciones nuevas insertadas antes del marker `/* boot */` (línea 7993). Sin nuevas tablas, sin nuevas RPC, sin edge functions.

**Tech Stack:** Vanilla JS embebido en `index.html` + SheetJS (xlsx@0.18.5 via CDN, ya cargado por el export XLSX). Supabase JS client v2 ya cargado. RLS abiertas a INSERT/UPDATE para todos los autenticados (commit `77ce577`, libreta compartida).

**Spec:** `docs/superpowers/specs/2026-05-19-import-excel-design.md`

---

## Pre-flight: auditoría inicial (obligatoria antes de empezar)

- [ ] **Step P1: Confirmar el JS parsea hoy y el archivo termina bien**

Run (PowerShell):
```powershell
$html = Get-Content "C:\Users\psanz\Desktop\Claudio\CEO Advisors CRM\index.html" -Raw
$lines = $html -split "`n"
$s = 0; for($i=0; $i -lt $lines.Length; $i++){ if($lines[$i].Trim() -eq '<script>'){ $s=$i; break } }
$e = 0; for($i=$lines.Length-1; $i -ge 0; $i--){ if($lines[$i].Trim() -eq '</script>'){ $e=$i; break } }
$lines[($s+1)..($e-1)] -join "`n" | Out-File "$env:TEMP\check.js" -Encoding utf8
node --check "$env:TEMP\check.js"
Get-Content "C:\Users\psanz\Desktop\Claudio\CEO Advisors CRM\index.html" -Tail 3
```
Expected: `node --check` returns silently (exit 0). Tail termina en `</html>`.

- [ ] **Step P2: Verificar líneas exactas de los markers**

Run:
```powershell
Select-String -Path "C:\Users\psanz\Desktop\Claudio\CEO Advisors CRM\index.html" -Pattern '^/\* boot \*/$|^id="btnReload"|^id="btnCsvImport"|^id="btnImport"|^id="btnExport"' -SimpleMatch:$false | Select-Object LineNumber, Line
```
También:
```powershell
Select-String -Path "C:\Users\psanz\Desktop\Claudio\CEO Advisors CRM\index.html" -Pattern "_changesSinceExport|_lastExportTs|_backupToastShown|maybeBackupReminder|showBackupToast|showPostExportModal|reloadFromTemplate|openCsvImport" | Group-Object Filename | Select-Object Count
```
Expected: las líneas coinciden con las del spec. Si difieren significativamente (movimiento mayor desde la escritura del plan), reconcilia el plan con la realidad antes de proseguir.

- [ ] **Step P3: Confirmar que `reloadFromTemplate` se sigue usando en el panel Settings**

Run:
```powershell
Select-String -Path "C:\Users\psanz\Desktop\Claudio\CEO Advisors CRM\index.html" -Pattern "reloadFromTemplate" | Where-Object { $_.LineNumber -ne 766 -and $_.LineNumber -ne 1726 } | Select-Object LineNumber, Line
```
Expected: al menos una coincidencia en `~7435` ("Resetear localStorage"). Si la única referencia restante fuera del botón header y la definición es esa, **mantenemos la función** y solo eliminamos el botón del header.

---

## File Structure

**Único archivo modificado:** `C:\Users\psanz\Desktop\Claudio\CEO Advisors CRM\index.html`

**Zonas afectadas:**
1. Header (líneas ~766-783): eliminar 4 botones y 1 input, añadir 2 botones y 1 input.
2. `saveDB()` (líneas ~1751-1758): quitar 3 líneas del contador de export JSON.
3. Helpers obsoletos (líneas ~1749-1750 + ~6102-6260 + ~6504-~6560 aprox): eliminar 4 listeners + 4 funciones + 3 globals.
4. Sección nueva antes de `/* boot */` (línea ~7993): insertar 6 funciones nuevas.

**Sin tests automatizados:** verificación es `node --check` + grep markers + smoke manual.

---

## Task 1: Cleanup — eliminar 4 botones legacy y helpers obsoletos

**Files:**
- Modify: `C:\Users\psanz\Desktop\Claudio\CEO Advisors CRM\index.html`

Este task es destructivo. Una sola pasada por todas las eliminaciones, un solo commit que deja el HTML "limpio pero sin import Excel todavía". Si algo falla en producción tras este commit, el rollback con `git revert HEAD` deja el CRM en el estado pre-cleanup; el header tendrá 4 botones legacy pero todo lo demás sigue funcional.

- [ ] **Step 1: Eliminar los 4 botones del header**

Edit `index.html`:

`old_string` (líneas 766-777 exactas):
```
        <button class="btn outline" id="btnReload" title="Recargar datos desde la plantilla embebida (uso tras inject.bat)" onclick="reloadFromTemplate()">
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M3 12a9 9 0 0 1 15.5-6.36L21 8"/><path d="M21 3v5h-5"/><path d="M21 12a9 9 0 0 1-15.5 6.36L3 16"/><path d="M3 21v-5h5"/></svg>Recargar
        </button>
        <button class="btn outline" id="btnCsvImport" title="Importar masivamente desde CSV (clientes/empresas/pupilos)" onclick="openCsvImport()"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><rect x="3" y="3" width="18" height="18" rx="2"/><path d="M8 12h8M12 8v8"/></svg>CSV</button>
        <button class="btn outline" id="btnImport" title="Importar datos desde JSON">
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M12 21V9m0 0l-4 4m4-4l4 4M5 3h14"/></svg>Importar
        </button>
        <input type="file" id="importFileInput" accept=".json" style="display:none">
        <button class="btn outline" id="btnDigest" title="Genera tu digest semanal (al portapapeles)" onclick="generateWeeklyDigest()"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M4 4h16v16H4z"/><path d="M4 9h16M9 4v16"/></svg>Digest</button>
        <button class="btn outline" id="btnExport" title="Exportar a JSON (backup completo)">
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M12 3v12m0 0l-4-4m4 4l4-4M5 21h14"/></svg>Exportar
        </button>
```

`new_string`:
```
        <button class="btn outline" id="btnDigest" title="Genera tu digest semanal (al portapapeles)" onclick="generateWeeklyDigest()"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M4 4h16v16H4z"/><path d="M4 9h16M9 4v16"/></svg>Digest</button>
```

(Los botones `btnExportXLSX` y `btnNew` quedan inmediatamente después y no se tocan.)

- [ ] **Step 2: Quitar referencias del contador de export en `saveDB()`**

Edit `index.html`:

`old_string` (líneas 1748-1758):
```
/* saveDB tracking: incrementa contador de cambios para el reminder de backup */
let _changesSinceExport = parseInt(localStorage.getItem('crm_changes_since_export')||'0',10) || 0;
let _lastExportTs = parseInt(localStorage.getItem('crm_last_export_ts')||'0',10) || 0;
function saveDB(){
  normalizeRelations();invalidateProbCache();
  Storage.write(JSON.stringify(DB));
  _changesSinceExport++;
  try{localStorage.setItem('crm_changes_since_export',String(_changesSinceExport))}catch(e){}
  maybeBackupReminder();
  try{ scheduleSupabaseFlush() }catch(e){ console.warn('supa schedule:',e) }
}
```

`new_string`:
```
function saveDB(){
  normalizeRelations();invalidateProbCache();
  Storage.write(JSON.stringify(DB));
  try{ scheduleSupabaseFlush() }catch(e){ console.warn('supa schedule:',e) }
}
```

- [ ] **Step 3: Eliminar listener de `btnExport` + función `showPostExportModal` + helpers de toast**

Edit `index.html`:

`old_string` (líneas 6102-6172, bloque completo):
```
/* ──────────── export ──────────── */
const SCHEMA_VERSION='2026.05.1';
$('#btnExport').addEventListener('click',()=>{
  /* Filtrar campos sensibles antes de exportar JSON */
  const safe=JSON.parse(JSON.stringify(DB));
  (safe.consultants||[]).forEach(c=>{delete c.passwordHash;delete c.passwordSalt;delete c.passwordIters;delete c.password});
  safe.schemaVersion=SCHEMA_VERSION;
  /* 2.5 Team-handoff metadata: quién exportó, cuándo, cuántos cambios desde el último export */
  const me = findConsultant(DB.currentUserId);
  safe._exportedBy = me ? {id:me.id, name:me.name, email:me.email} : null;
  safe._exportedAt = new Date().toISOString();
  safe._changesSinceLastExport = _changesSinceExport;
  safe._auditCount = (DB.audit||[]).length;
  const fname = `ceoadvisors_crm_export_${new Date().toISOString().slice(0,10)}_${(me?me.id:'unknown')}.json`;
  const blob=new Blob([JSON.stringify(safe,null,2)],{type:'application/json'});
  const a=document.createElement('a');a.href=URL.createObjectURL(blob);a.download=fname;a.click();
  /* Reset del contador y timestamp tras export exitoso */
  _changesSinceExport=0; _lastExportTs=Date.now();
  try{localStorage.setItem('crm_changes_since_export','0');localStorage.setItem('crm_last_export_ts',String(_lastExportTs))}catch(e){}
  setTimeout(()=>showPostExportModal(fname),200);
});

/* 2.4 Auto-backup reminder ─ avisa si hay 30+ cambios o pasaron 4h sin export */
let _backupToastShown=false;
function maybeBackupReminder(){
  if(_backupToastShown)return;
  const hours = _lastExportTs ? (Date.now()-_lastExportTs)/3600000 : 999;
  if(_changesSinceExport>=30 || (hours>=4 && _changesSinceExport>=5)){
    _backupToastShown=true;
    showBackupToast(hours);
  }
}
function showBackupToast(hours){
  const t=document.createElement('div');
  t.id='backupToast';
  t.style.cssText='position:fixed;bottom:24px;right:24px;z-index:9998;background:var(--surface);border:1px solid var(--brand);border-left:4px solid var(--brand);border-radius:10px;padding:14px 18px;box-shadow:0 8px 32px rgba(0,0,0,.18);max-width:340px;font-size:13px';
  const lastTxt = _lastExportTs ? `Hace ${Math.round(hours)}h sin exportar` : 'Aún no has exportado';
  t.innerHTML=`
    <div style="font-weight:600;color:var(--ink);margin-bottom:4px">📥 Backup recomendado</div>
    <div class="muted" style="margin-bottom:10px;line-height:1.5">${_changesSinceExport} cambios sin guardar a JSON. ${lastTxt}.</div>
    <div class="flex gap-s">
      <button class="btn sm primary" onclick="document.getElementById('backupToast').remove();_backupToastShown=false;document.getElementById('btnExport').click()">Exportar ahora</button>
      <button class="btn sm ghost" onclick="document.getElementById('backupToast').remove()">Más tarde</button>
    </div>`;
  document.body.appendChild(t);
}
function showPostExportModal(fname){
  const f = fname || 'ceoadvisors_crm_export.json';
  const ov=document.createElement('div');
  ov.style.cssText='position:fixed;inset:0;background:rgba(0,0,0,.55);z-index:9999;display:flex;align-items:center;justify-content:center;padding:20px';
  ov.innerHTML=`
    <div style="background:var(--surface);border-radius:12px;max-width:480px;padding:28px;box-shadow:0 20px 60px rgba(0,0,0,.3);border:1px solid var(--line)">
      <div style="font-size:42px;margin-bottom:8px">✓</div>
      <h2 style="margin:0 0 6px;color:var(--ink);font-size:20px">JSON exportado</h2>
      <div class="muted" style="margin-bottom:16px">Archivo: <code style="background:var(--surface-2);padding:2px 6px;border-radius:4px;font-size:12px">${f}</code> (en tu carpeta Descargas)</div>
      <div style="background:var(--surface-2);padding:14px 16px;border-radius:8px;margin-bottom:16px;border-left:3px solid var(--brand)">
        <div style="font-weight:600;margin-bottom:6px">Para sincronizar con el Excel:</div>
        <ol style="margin:0;padding-left:20px;line-height:1.7;font-size:13.5px">
          <li>Abre la carpeta del CRM (donde está <code>crm.bat</code>)</li>
          <li>Doble-click en <code>crm.bat</code></li>
          <li>El script detecta el JSON y actualiza el Excel + HTML</li>
        </ol>
      </div>
      <div class="muted" style="font-size:12px;margin-bottom:14px">El JSON no contiene contraseñas. Es seguro compartirlo como backup.</div>
      <div style="display:flex;gap:8px;justify-content:flex-end">
        <button class="btn outline" onclick="this.closest('div[style*=fixed]').remove()">Cerrar</button>
      </div>
    </div>`;
  document.body.appendChild(ov);
  ov.addEventListener('click',e=>{if(e.target===ov)ov.remove()});
}
```

`new_string`:
```
const SCHEMA_VERSION='2026.05.1';
```

(`SCHEMA_VERSION` se conserva porque la usa `btnExportXLSX` (línea 6189) y otros sitios. Solo se elimina el listener de btnExport y sus helpers.)

- [ ] **Step 4: Eliminar listener de `btnImport` + handler de `importFileInput`**

Edit `index.html`:

`old_string` (líneas 6219-6260):
```
/* ──────────── import (replace + merge) ──────────── */
$('#btnImport').addEventListener('click',()=>{
  if(!isCEO()&&!DB.consultants.find(c=>c.id===DB.currentUserId)?.isAdmin){alert('Solo el CEO o un Admin puede importar datos.');return;}
  $('#importFileInput').click();
});
$('#importFileInput').addEventListener('change',e=>{
  const file=e.target.files[0];if(!file)return;
  const reader=new FileReader();
  reader.onload=ev=>{
    try{
      const imported=JSON.parse(ev.target.result);
      // Schema drift warning
      if(imported.schemaVersion&&imported.schemaVersion!==SCHEMA_VERSION){
        if(!confirm(`Schema del archivo (${imported.schemaVersion}) ≠ schema del CRM (${SCHEMA_VERSION}).\n¿Continuar de todos modos?`)){e.target.value='';return;}
      }
      // MERGE MODE: añade solo IDs nuevos, no toca lo existente
      if(imported._mode==='merge'){
        const counts={consultants:0,clients:0,companies:0,deals:0,activities:0,pupilos:0};
        for(const k of Object.keys(counts)){
          const existing=new Set((DB[k]||[]).map(x=>x.id));
          const incoming=imported[k]||[];
          const news=incoming.filter(x=>!existing.has(x.id));
          DB[k]=(DB[k]||[]).concat(news);
          counts[k]=news.length;
        }
        migrateAuth(DB);migrateExtra(DB);saveDB();render();
        const summary=Object.entries(counts).map(([k,n])=>`${k}:+${n}`).join(' | ');
        alert(`✓ Merge aplicado. ${summary}\n\nNo se modificaron registros existentes.`);
        e.target.value='';return;
      }
      // REPLACE MODE
      if(!imported.consultants||!imported.clients||!imported.deals){alert('Archivo JSON inválido — faltan secciones requeridas.');return;}
      if(!confirm(`¿Reemplazar todos los datos con los del archivo "${file.name}"?\n\nEsta acción no se puede deshacer. Se recomienda exportar primero como respaldo.`))return;
      Object.assign(DB,imported);
      migrateAuth(DB);migrateExtra(DB);saveDB();
      render();
      alert('✓ Datos importados correctamente.');
    }catch(err){alert('Error al leer el archivo: '+err.message);}
    e.target.value='';
  };
  reader.readAsText(file);
});
```

`new_string`: (vacío — eliminar el bloque entero)

```
```

- [ ] **Step 5: Eliminar `openCsvImport()` completa**

Encontrar el bloque exacto a eliminar:
```powershell
Select-String -Path "C:\Users\psanz\Desktop\Claudio\CEO Advisors CRM\index.html" -Pattern "^function openCsvImport|^function csvParse" | Select-Object LineNumber, Line
```

Inspeccionar visualmente con `Read` desde la línea de `function openCsvImport` y leer hasta encontrar la línea con `^}` que cierra la función (espera que sea aprox 50-60 líneas más abajo). Eliminar el bloque entero con `Edit` usando el contenido exacto que leíste como `old_string` y `""` como `new_string`.

NOTA: `csvParse()` es un helper independiente. Verificar con grep si tiene otros callsites — si solo lo usa `openCsvImport`, eliminarlo también. Si tiene más callsites (búsqueda global, otra herramienta), mantenerlo.

- [ ] **Step 6: Verificar JS parsea tras el cleanup**

Run:
```powershell
$html = Get-Content "C:\Users\psanz\Desktop\Claudio\CEO Advisors CRM\index.html" -Raw
$lines = $html -split "`n"
$s = 0; for($i=0; $i -lt $lines.Length; $i++){ if($lines[$i].Trim() -eq '<script>'){ $s=$i; break } }
$e = 0; for($i=$lines.Length-1; $i -ge 0; $i--){ if($lines[$i].Trim() -eq '</script>'){ $e=$i; break } }
$lines[($s+1)..($e-1)] -join "`n" | Out-File "$env:TEMP\check.js" -Encoding utf8
node --check "$env:TEMP\check.js"
```
Expected: exit 0, sin output.

- [ ] **Step 7: Verificar que no quedan referencias huérfanas a las funciones/ids eliminados**

Run:
```powershell
Select-String -Path "C:\Users\psanz\Desktop\Claudio\CEO Advisors CRM\index.html" -Pattern "btnImport[^X]|btnExport[^X]|btnReload|btnCsvImport|importFileInput|_changesSinceExport|_lastExportTs|_backupToastShown|maybeBackupReminder|showBackupToast|showPostExportModal|openCsvImport"
```

Expected:
- `reloadFromTemplate` referenciada solo en su definición (línea ~1726) y en el panel Settings (línea ~7435). Eso es OK.
- `btnImport`, `btnExport`, `btnReload`, `btnCsvImport`, `importFileInput`: 0 coincidencias.
- `_changesSinceExport`, `_lastExportTs`, `_backupToastShown`, `maybeBackupReminder`, `showBackupToast`, `showPostExportModal`, `openCsvImport`: 0 coincidencias.

Si quedan referencias huérfanas, eliminar también esas referencias (probablemente en strings de UI o atajos de teclado).

- [ ] **Step 8: Tail check**

Run:
```powershell
Get-Content "C:\Users\psanz\Desktop\Claudio\CEO Advisors CRM\index.html" -Tail 3
```
Expected: termina en `</html>`.

- [ ] **Step 9: Commit (sin push todavía — el plan agrupa con Task 7)**

NO commitear aún. El cleanup + el import Excel van en commits separados pero ambos antes del push final, para permitir un único `git revert` si algo va mal en producción.

Salvar el estado actual:
```powershell
git diff --stat
git add index.html
git diff --cached --stat
```

Expected: 1 file changed, ~150 deletions, 0 insertions (aprox).

---

## Task 2: Añadir botones nuevos en el header

**Files:**
- Modify: `C:\Users\psanz\Desktop\Claudio\CEO Advisors CRM\index.html`

- [ ] **Step 1: Insertar los 2 botones nuevos + input file**

Tras el Task 1, donde antes estaban btnReload/btnCsvImport/btnImport/importFileInput/btnDigest/btnExport queda solo `btnDigest`. Insertar **antes** de `btnDigest`:

Edit `index.html`:

`old_string`:
```
        <button class="btn outline" id="btnDigest" title="Genera tu digest semanal (al portapapeles)" onclick="generateWeeklyDigest()"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M4 4h16v16H4z"/><path d="M4 9h16M9 4v16"/></svg>Digest</button>
```

`new_string`:
```
        <button class="btn outline" id="btnDownloadTemplate" title="Descargar plantilla Excel para importar (3 hojas: Clients/Companies/Deals)" onclick="downloadImportTemplate()"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M12 3v12m0 0l-4-4m4 4l4-4M5 21h14"/><rect x="3" y="3" width="18" height="3" rx="0.5" fill="currentColor" fill-opacity="0.1"/></svg>Plantilla</button>
        <button class="btn outline" id="btnImportXLSX" title="Importar cartera desde Excel (Clients/Companies/Deals)"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M12 21V9m0 0l-4 4m4-4l4 4M5 3h14"/></svg>Importar Excel</button>
        <input type="file" id="importXLSXInput" accept=".xlsx,.xls" style="display:none">
        <button class="btn outline" id="btnDigest" title="Genera tu digest semanal (al portapapeles)" onclick="generateWeeklyDigest()"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M4 4h16v16H4z"/><path d="M4 9h16M9 4v16"/></svg>Digest</button>
```

- [ ] **Step 2: Verificar que el HTML sigue válido**

Run:
```powershell
Select-String -Path "C:\Users\psanz\Desktop\Claudio\CEO Advisors CRM\index.html" -Pattern '^.*id="btnImportXLSX"|^.*id="btnDownloadTemplate"|^.*id="importXLSXInput"|^.*id="btnDigest"' | Select-Object LineNumber, Line
```
Expected: 4 coincidencias en orden Plantilla → Importar Excel → Input → Digest.

`node --check` del JS no aplica aquí (no se tocó JS aún). Las funciones `downloadImportTemplate()` y el listener de `btnImportXLSX` se añaden en tasks siguientes — por ahora los botones existen pero no hacen nada. Acceptable interim state — no commitear todavía.

---

## Task 3: Función `downloadImportTemplate`

**Files:**
- Modify: `C:\Users\psanz\Desktop\Claudio\CEO Advisors CRM\index.html` (insertar bloque antes de `/* boot */`)

- [ ] **Step 1: Insertar la función**

Localizar la línea con `/* boot */` (debe ser cerca del final, aprox línea 7990 tras los cleanups). Editar para insertar el bloque **antes** de `/* boot */`:

Edit `index.html`:

`old_string`:
```
/* boot */
state.authed=false;
```

`new_string`:
```
/* ──────────── F-ImportExcel: plantilla descargable ──────────── */
function downloadImportTemplate(){
  loadSheetJS().then(XLSX=>{
    const wb=XLSX.utils.book_new();

    const clientsHdr=['ID','Name','Email','Phone','Country','City','Net Worth USD','Source','Tier','Notes'];
    const clientsEx =['cli1','Juan Pérez','juan.perez@example.com','+34 600 123 456','Spain','Madrid',5000000,'Referral','B','Cliente referido por X — interesado en wealth management'];
    XLSX.utils.book_append_sheet(wb, XLSX.utils.aoa_to_sheet([clientsHdr, clientsEx]), 'Clients');

    const companiesHdr=['ID','Name','Industry','Country','Employees','Net Worth USD','Linked Client IDs','Website','Notes'];
    const companiesEx =['co1','Acme Holdings','Real Estate','Spain',45,12000000,'cli1','acme.com','Holding familiar — Juan es el patriarca'];
    XLSX.utils.book_append_sheet(wb, XLSX.utils.aoa_to_sheet([companiesHdr, companiesEx]), 'Companies');

    const dealsHdr=['ID','Title','Client ID','Company ID','Type','Stage','Amount USD','Expected Close','Notes'];
    const dealsEx =['d1','Venta participación Acme','cli1','co1','sale','prospect',8000000,'2026-09-30','Lead inicial — pendiente NDA'];
    XLSX.utils.book_append_sheet(wb, XLSX.utils.aoa_to_sheet([dealsHdr, dealsEx]), 'Deals');

    XLSX.writeFile(wb, 'ceoadvisors_import_template.xlsx');
  }).catch(err=>alert('Error cargando SheetJS: '+err.message));
}

/* boot */
state.authed=false;
```

- [ ] **Step 2: Verificar JS parsea**

Run:
```powershell
$html = Get-Content "C:\Users\psanz\Desktop\Claudio\CEO Advisors CRM\index.html" -Raw
$lines = $html -split "`n"
$s = 0; for($i=0; $i -lt $lines.Length; $i++){ if($lines[$i].Trim() -eq '<script>'){ $s=$i; break } }
$e = 0; for($i=$lines.Length-1; $i -ge 0; $i--){ if($lines[$i].Trim() -eq '</script>'){ $e=$i; break } }
$lines[($s+1)..($e-1)] -join "`n" | Out-File "$env:TEMP\check.js" -Encoding utf8
node --check "$env:TEMP\check.js"
```
Expected: exit 0.

- [ ] **Step 3: Smoke test manual (opcional, recomendado)**

Si tienes un servidor local corriendo, abrir devtools console y ejecutar `downloadImportTemplate()`. Debe descargarse un archivo `ceoadvisors_import_template.xlsx` con 3 hojas, headers correctos, 1 fila de ejemplo cada una. Abrir el archivo en Excel/LibreOffice para validar.

Si no hay servidor local, defer el smoke a Task 7.

---

## Task 4: Función `parseExcelImport`

**Files:**
- Modify: `C:\Users\psanz\Desktop\Claudio\CEO Advisors CRM\index.html` (insertar antes de `/* boot */`, después de `downloadImportTemplate`)

- [ ] **Step 1: Insertar la función**

Edit `index.html`:

`old_string`:
```
    XLSX.writeFile(wb, 'ceoadvisors_import_template.xlsx');
  }).catch(err=>alert('Error cargando SheetJS: '+err.message));
}

/* boot */
state.authed=false;
```

`new_string`:
```
    XLSX.writeFile(wb, 'ceoadvisors_import_template.xlsx');
  }).catch(err=>alert('Error cargando SheetJS: '+err.message));
}

/* ──────────── F-ImportExcel: parser ──────────── */
/* Mapa de aliases case-insensitive header -> campo canónico. */
const _impHeaderAlias = {
  clients: {
    'id':'id','nombre':'name','name':'name','email':'email','correo':'email','phone':'phone','teléfono':'phone','telefono':'phone',
    'country':'country','pais':'country','país':'country','city':'city','ciudad':'city',
    'net worth usd':'netWorth','net worth':'netWorth','networth':'netWorth','patrimonio':'netWorth',
    'source':'source','fuente':'source','tier':'tier','notes':'notes','notas':'notes'
  },
  companies: {
    'id':'id','name':'name','nombre':'name','empresa':'name','industry':'industry','industria':'industry',
    'country':'country','pais':'country','país':'country','employees':'employees','empleados':'employees',
    'net worth usd':'netWorth','net worth':'netWorth','networth':'netWorth',
    'linked client ids':'clientIds','clientes vinculados':'clientIds','website':'website','web':'website',
    'notes':'notes','notas':'notes'
  },
  deals: {
    'id':'id','title':'title','titulo':'title','título':'title',
    'client id':'clientId','cliente':'clientId','company id':'companyId','empresa':'companyId',
    'type':'type','tipo':'type','stage':'stage','etapa':'stage','fase':'stage',
    'amount usd':'amount','amount':'amount','monto':'amount','importe':'amount',
    'expected close':'closeDate','fecha cierre':'closeDate','notes':'notes','notas':'notes'
  }
};

/* parseExcelImport(workbook) → { clients:[{...,_row:N}], companies:[...], deals:[...] }
   Devuelve raw, sin validar valores. _row es el número de fila Excel (1-indexed con header en fila 1)
   para que los mensajes de error/warning sean accionables. */
function parseExcelImport(wb){
  const out={clients:[],companies:[],deals:[]};
  const sheetMap={Clients:'clients',Companies:'companies',Deals:'deals'};
  for(const [sheetName, kind] of Object.entries(sheetMap)){
    const sheet=wb.Sheets[sheetName];
    if(!sheet) continue;
    const rows=XLSX.utils.sheet_to_json(sheet,{header:1,defval:'',raw:false});
    if(!rows.length) continue;
    const rawHeaders=(rows[0]||[]).map(h=>String(h||'').trim().toLowerCase());
    const aliasMap=_impHeaderAlias[kind];
    const colMap={}; // canonicalField -> column index
    rawHeaders.forEach((h,i)=>{ const canonical=aliasMap[h]; if(canonical) colMap[canonical]=i; });
    for(let r=1;r<rows.length;r++){
      const row=rows[r]||[];
      // Skip filas totalmente vacías
      if(row.every(c=>String(c||'').trim()==='')) continue;
      const obj={_row:r+1};
      for(const [field,colIdx] of Object.entries(colMap)){
        obj[field]=String(row[colIdx]==null?'':row[colIdx]).trim();
      }
      out[kind].push(obj);
    }
  }
  return out;
}

/* boot */
state.authed=false;
```

- [ ] **Step 2: Verificar JS parsea**

Run:
```powershell
$html = Get-Content "C:\Users\psanz\Desktop\Claudio\CEO Advisors CRM\index.html" -Raw
$lines = $html -split "`n"
$s = 0; for($i=0; $i -lt $lines.Length; $i++){ if($lines[$i].Trim() -eq '<script>'){ $s=$i; break } }
$e = 0; for($i=$lines.Length-1; $i -ge 0; $i--){ if($lines[$i].Trim() -eq '</script>'){ $e=$i; break } }
$lines[($s+1)..($e-1)] -join "`n" | Out-File "$env:TEMP\check.js" -Encoding utf8
node --check "$env:TEMP\check.js"
```
Expected: exit 0.

---

## Task 5: Función `validateImport`

**Files:**
- Modify: `C:\Users\psanz\Desktop\Claudio\CEO Advisors CRM\index.html` (insertar tras `parseExcelImport`)

- [ ] **Step 1: Insertar la función**

Edit `index.html`:

`old_string`:
```
    out[kind].push(obj);
    }
  }
  return out;
}

/* boot */
state.authed=false;
```

`new_string`:
```
    out[kind].push(obj);
    }
  }
  return out;
}

/* ──────────── F-ImportExcel: validador ──────────── */
const _IMP_LIMIT=200;
const _IMP_SOURCE_WHITELIST=new Set(['Referral','Outbound','Inbound','Conference','Partner','Other']);
const _IMP_TIER_WHITELIST=new Set(['A','B','C','D']);
const _IMP_TYPE_WHITELIST=new Set(['sale','finance','expand','advise','wealth']);
const _IMP_STAGE_WHITELIST=new Set(['prospect','qualified','proposal','negotiation','won','lost']);

function _impNum(v){const n=parseFloat(String(v||'').replace(/[^0-9.\-]/g,''));return isFinite(n)?Math.round(n):0;}
function _impNorm(v){return String(v||'').trim();}
function _impLower(v){return _impNorm(v).toLowerCase();}

/* Devuelve {valid:{clients,companies,deals}, warnings:[strings], stats:{...}} */
function validateImport(raw){
  const warnings=[];
  const existingEmails=new Set((DB.clients||[]).map(c=>_impLower(c.email)).filter(e=>e));

  // ── Truncar por límite ──
  const truncated={};
  for(const kind of ['clients','companies','deals']){
    if((raw[kind]||[]).length>_IMP_LIMIT){
      truncated[kind]=raw[kind].length;
      raw[kind]=raw[kind].slice(0,_IMP_LIMIT);
      warnings.push(`${kind}: ${truncated[kind]} filas, máximo ${_IMP_LIMIT} — se importarán solo las primeras ${_IMP_LIMIT}.`);
    }
  }

  // ── Clients ──
  const validClients=[];
  const seenTempIds={clients:new Set(),companies:new Set(),deals:new Set()};
  for(const c of (raw.clients||[])){
    const name=_impNorm(c.name);
    if(!name){warnings.push(`Clients fila ${c._row}: Name obligatorio — fila omitida.`);continue;}
    const email=_impNorm(c.email);
    if(email && existingEmails.has(email.toLowerCase())){
      warnings.push(`Clients fila ${c._row}: email ${email} ya existe — omitido.`);
      continue;
    }
    if(email) existingEmails.add(email.toLowerCase()); // dedup dentro del mismo archivo
    const tempId=_impNorm(c.id);
    if(tempId) seenTempIds.clients.add(tempId);
    const nw=_impNum(c.netWorth);
    const sourceRaw=_impNorm(c.source);
    const source=_IMP_SOURCE_WHITELIST.has(sourceRaw)?sourceRaw:'Other';
    const tierRaw=_impNorm(c.tier).toUpperCase();
    const tier=_IMP_TIER_WHITELIST.has(tierRaw)?tierRaw:autoTier(nw);
    validClients.push({
      _tempId: tempId, _row: c._row,
      name, email, phone:_impNorm(c.phone),
      country:_impNorm(c.country)||'—', city:_impNorm(c.city),
      netWorth: nw, source, tier, notes:_impNorm(c.notes)
    });
  }

  // ── Companies ──
  const validCompanies=[];
  for(const co of (raw.companies||[])){
    const name=_impNorm(co.name);
    if(!name){warnings.push(`Companies fila ${co._row}: Name obligatorio — fila omitida.`);continue;}
    const tempId=_impNorm(co.id);
    if(tempId) seenTempIds.companies.add(tempId);
    // Parse Linked Client IDs y verificar que existan en clients
    const linkedRaw=_impNorm(co.clientIds);
    const linkedTempIds=linkedRaw?linkedRaw.split(',').map(s=>s.trim()).filter(Boolean):[];
    const linkedValid=[];
    for(const t of linkedTempIds){
      if(seenTempIds.clients.has(t)) linkedValid.push(t);
      else warnings.push(`Companies fila ${co._row}: cliente "${t}" no existe en hoja Clients — ignorado.`);
    }
    validCompanies.push({
      _tempId: tempId, _row: co._row,
      name, industry:_impNorm(co.industry),
      country:_impNorm(co.country)||'—',
      employees:_impNum(co.employees), netWorth:_impNum(co.netWorth),
      _linkedTempIds: linkedValid,
      website:_impNorm(co.website), notes:_impNorm(co.notes)
    });
  }

  // ── Deals ──
  const validDeals=[];
  for(const d of (raw.deals||[])){
    const title=_impNorm(d.title);
    if(!title){warnings.push(`Deals fila ${d._row}: Title obligatorio — fila omitida.`);continue;}
    const tempId=_impNorm(d.id);
    if(tempId) seenTempIds.deals.add(tempId);
    let clientTempId=_impNorm(d.clientId);
    if(clientTempId && !seenTempIds.clients.has(clientTempId)){
      warnings.push(`Deals fila ${d._row}: Client ID "${clientTempId}" no existe — creado sin cliente.`);
      clientTempId='';
    }
    let companyTempId=_impNorm(d.companyId);
    if(companyTempId && !seenTempIds.companies.has(companyTempId)){
      warnings.push(`Deals fila ${d._row}: Company ID "${companyTempId}" no existe — creado sin empresa.`);
      companyTempId='';
    }
    const typeRaw=_impLower(d.type);
    const type=_IMP_TYPE_WHITELIST.has(typeRaw)?typeRaw:'advise';
    const stageRaw=_impLower(d.stage);
    const stage=_IMP_STAGE_WHITELIST.has(stageRaw)?stageRaw:'prospect';
    validDeals.push({
      _row: d._row,
      title, _clientTempId: clientTempId, _companyTempId: companyTempId,
      type, stage,
      amount:_impNum(d.amount),
      closeDate:_impNorm(d.closeDate),
      notes:_impNorm(d.notes)
    });
  }

  return {
    valid: { clients: validClients, companies: validCompanies, deals: validDeals },
    warnings,
    stats: {
      clients: validClients.length,
      companies: validCompanies.length,
      deals: validDeals.length,
      clientsSkipped: (raw.clients||[]).length - validClients.length,
      companiesSkipped: (raw.companies||[]).length - validCompanies.length,
      dealsSkipped: (raw.deals||[]).length - validDeals.length
    }
  };
}

/* boot */
state.authed=false;
```

- [ ] **Step 2: Verificar JS parsea**

Run:
```powershell
$html = Get-Content "C:\Users\psanz\Desktop\Claudio\CEO Advisors CRM\index.html" -Raw
$lines = $html -split "`n"
$s = 0; for($i=0; $i -lt $lines.Length; $i++){ if($lines[$i].Trim() -eq '<script>'){ $s=$i; break } }
$e = 0; for($i=$lines.Length-1; $i -ge 0; $i--){ if($lines[$i].Trim() -eq '</script>'){ $e=$i; break } }
$lines[($s+1)..($e-1)] -join "`n" | Out-File "$env:TEMP\check.js" -Encoding utf8
node --check "$env:TEMP\check.js"
```
Expected: exit 0.

---

## Task 6: Función `applyImport`

**Files:**
- Modify: `C:\Users\psanz\Desktop\Claudio\CEO Advisors CRM\index.html` (insertar tras `validateImport`)

- [ ] **Step 1: Insertar la función**

Edit `index.html`:

`old_string`:
```
      dealsSkipped: (raw.deals||[]).length - validDeals.length
    }
  };
}

/* boot */
state.authed=false;
```

`new_string`:
```
      dealsSkipped: (raw.deals||[]).length - validDeals.length
    }
  };
}

/* ──────────── F-ImportExcel: aplicador ──────────── */
function applyImport(valid){
  const nowIso=new Date().toISOString();
  const myId=DB.currentUserId;

  // Resolve temp IDs -> IDs reales
  const cliMap=new Map(); // tempId -> realId
  const coMap=new Map();

  for(const c of valid.clients){
    const id=uid('c');
    if(c._tempId) cliMap.set(c._tempId,id);
    DB.clients.push({
      id, name:c.name, email:c.email, phone:c.phone,
      country:c.country, city:c.city,
      netWorth:c.netWorth, source:c.source, tier:c.tier,
      notes:c.notes, comments:[], tags:[]
    });
  }

  for(const co of valid.companies){
    const id=uid('co');
    if(co._tempId) coMap.set(co._tempId,id);
    const clientIds=(co._linkedTempIds||[]).map(t=>cliMap.get(t)).filter(Boolean);
    DB.companies.push({
      id, name:co.name, industry:co.industry,
      country:co.country, employees:co.employees, netWorth:co.netWorth,
      clientIds, website:co.website, notes:co.notes, comments:[]
    });
  }

  for(const d of valid.deals){
    const id=uid('d');
    const clientId=d._clientTempId?(cliMap.get(d._clientTempId)||''):'';
    const companyId=d._companyTempId?(coMap.get(d._companyTempId)||''):'';
    DB.deals.push({
      id, title:d.title, clientId, companyId,
      type:d.type, stage:d.stage,
      amount:d.amount, closeDate:d.closeDate, notes:d.notes,
      splits:[{u:myId,pct:100}],
      stage_history:[{stage:d.stage,at:nowIso,by:myId}],
      comments:[], tags:[],
      createdAt: nowIso
    });
  }

  saveDB();
}

/* boot */
state.authed=false;
```

- [ ] **Step 2: Verificar JS parsea**

Run:
```powershell
$html = Get-Content "C:\Users\psanz\Desktop\Claudio\CEO Advisors CRM\index.html" -Raw
$lines = $html -split "`n"
$s = 0; for($i=0; $i -lt $lines.Length; $i++){ if($lines[$i].Trim() -eq '<script>'){ $s=$i; break } }
$e = 0; for($i=$lines.Length-1; $i -ge 0; $i--){ if($lines[$i].Trim() -eq '</script>'){ $e=$i; break } }
$lines[($s+1)..($e-1)] -join "`n" | Out-File "$env:TEMP\check.js" -Encoding utf8
node --check "$env:TEMP\check.js"
```
Expected: exit 0.

---

## Task 7: Modal preview + orchestrator `openImportExcel`

**Files:**
- Modify: `C:\Users\psanz\Desktop\Claudio\CEO Advisors CRM\index.html` (insertar tras `applyImport` + wire button listener cerca del bottom del script)

- [ ] **Step 1: Insertar `renderImportPreviewModal` y `openImportExcel`**

Edit `index.html`:

`old_string`:
```
  saveDB();
}

/* boot */
state.authed=false;
```

`new_string`:
```
  saveDB();
}

/* ──────────── F-ImportExcel: modal preview + orchestrator ──────────── */
function renderImportPreviewModal(report){
  return new Promise(resolve=>{
    const {stats, warnings} = report;
    const totalValid = stats.clients + stats.companies + stats.deals;
    const dupSkipText = stats.clientsSkipped>0 ? ` (${stats.clientsSkipped} omitidos)` : '';
    const ov=document.createElement('div');
    ov.style.cssText='position:fixed;inset:0;background:rgba(0,0,0,.55);z-index:9999;display:flex;align-items:center;justify-content:center;padding:20px';
    const warningsHTML = warnings.length
      ? `<details ${warnings.length<=3?'open':''} style="margin-top:14px"><summary style="cursor:pointer;font-weight:600;color:var(--ink)">Advertencias (${warnings.length})</summary><ul style="margin:8px 0 0;padding-left:20px;font-size:12.5px;line-height:1.55;color:var(--muted);max-height:240px;overflow:auto">${warnings.map(w=>`<li>${w.replace(/</g,'&lt;')}</li>`).join('')}</ul></details>`
      : '';
    const confirmDisabled = totalValid===0;
    ov.innerHTML=`
      <div style="background:var(--surface);border-radius:12px;max-width:560px;width:100%;padding:24px 26px;box-shadow:0 20px 60px rgba(0,0,0,.3);border:1px solid var(--line)">
        <h2 style="margin:0 0 12px;color:var(--ink);font-size:19px">Importar Excel — Preview</h2>
        ${totalValid===0
          ? '<div style="background:var(--surface-2);padding:14px;border-radius:8px;border-left:3px solid var(--amber,#d97706);font-size:13px">Nada que importar — corrige el archivo y reintenta.</div>'
          : `<div style="background:var(--surface-2);padding:14px 16px;border-radius:8px;font-size:13.5px;line-height:1.85">
              <div>✓ <b>Clients</b> &nbsp;: ${stats.clients} nuevos${dupSkipText}</div>
              <div>✓ <b>Companies</b>: ${stats.companies} nuevos</div>
              <div>✓ <b>Deals</b> &nbsp;&nbsp;: ${stats.deals} nuevos <span class="muted" style="font-size:11.5px">(todos a tu nombre, A1 100%)</span></div>
            </div>`}
        ${warningsHTML}
        <div style="display:flex;gap:8px;justify-content:flex-end;margin-top:18px">
          <button class="btn ghost" id="impCancel">Cancelar</button>
          ${confirmDisabled ? '' : '<button class="btn primary" id="impConfirm">Confirmar import</button>'}
        </div>
      </div>`;
    document.body.appendChild(ov);
    const close=ok=>{ov.remove();resolve(ok);};
    ov.querySelector('#impCancel').addEventListener('click',()=>close(false));
    const cf=ov.querySelector('#impConfirm');
    if(cf) cf.addEventListener('click',()=>close(true));
    ov.addEventListener('click',e=>{if(e.target===ov)close(false);});
  });
}

function openImportExcel(){
  const input=$('#importXLSXInput');
  if(!input) return;
  input.value=''; // reset
  input.onchange = async (e)=>{
    const file=e.target.files[0];
    if(!file) return;
    let wb;
    try{
      const XLSX=await loadSheetJS();
      const buf=await file.arrayBuffer();
      wb=XLSX.read(buf,{type:'array'});
    }catch(err){
      alert('Archivo Excel no válido — descarga la plantilla y úsala como referencia.\n\nDetalle: '+err.message);
      return;
    }
    const hasAny=['Clients','Companies','Deals'].some(s=>wb.Sheets[s]);
    if(!hasAny){
      alert('El archivo no contiene ninguna de las hojas esperadas (Clients, Companies, Deals).\n\nDescarga la plantilla y úsala como referencia.');
      return;
    }
    const raw=parseExcelImport(wb);
    const report=validateImport(raw);
    const ok=await renderImportPreviewModal(report);
    if(!ok) return;
    applyImport(report.valid);
    try{ render(); }catch(_){}
    const s=report.stats;
    alert(`✓ Importado: ${s.clients} clientes, ${s.companies} empresas, ${s.deals} deals.`);
  };
  input.click();
}

/* Listener del botón Importar Excel */
$('#btnImportXLSX')?.addEventListener('click', openImportExcel);

/* boot */
state.authed=false;
```

- [ ] **Step 2: Verificar JS parsea**

Run:
```powershell
$html = Get-Content "C:\Users\psanz\Desktop\Claudio\CEO Advisors CRM\index.html" -Raw
$lines = $html -split "`n"
$s = 0; for($i=0; $i -lt $lines.Length; $i++){ if($lines[$i].Trim() -eq '<script>'){ $s=$i; break } }
$e = 0; for($i=$lines.Length-1; $i -ge 0; $i--){ if($lines[$i].Trim() -eq '</script>'){ $e=$i; break } }
$lines[($s+1)..($e-1)] -join "`n" | Out-File "$env:TEMP\check.js" -Encoding utf8
node --check "$env:TEMP\check.js"
```
Expected: exit 0.

- [ ] **Step 3: Verificar markers de las 6 funciones nuevas**

Run:
```powershell
Select-String -Path "C:\Users\psanz\Desktop\Claudio\CEO Advisors CRM\index.html" -Pattern "^function downloadImportTemplate|^function parseExcelImport|^function validateImport|^function applyImport|^function renderImportPreviewModal|^function openImportExcel" | Select-Object LineNumber, Line
```
Expected: 6 coincidencias, todas en líneas cercanas al final del `<script>` (>7000).

- [ ] **Step 4: File integrity check**

Run:
```powershell
Get-Content "C:\Users\psanz\Desktop\Claudio\CEO Advisors CRM\index.html" -Tail 3
```
Expected: termina en `</html>`.

---

## Task 8: Verificación manual

**Files:** ninguno (verificación runtime).

- [ ] **Step 1: Arrancar servidor local**

Run en otra terminal:
```powershell
cd "C:\Users\psanz\Desktop\Claudio\CEO Advisors CRM"
python -m http.server 8000
```
Abrir http://localhost:8000 en navegador. Login como un consultor no-admin (ej. Roberto / u2 si tienes credenciales; si no, login como Pablo y verificar las acciones igualmente — el plan ya verificó RLS para no-admin via SQL impersonation).

- [ ] **Step 2: Smoke test — descargar plantilla**

Click "Plantilla". Debería descargarse `ceoadvisors_import_template.xlsx`. Abrirlo en Excel/LibreOffice. Verificar:
- 3 hojas con nombres exactos: `Clients`, `Companies`, `Deals`.
- Cada hoja tiene los headers correctos en fila 1.
- Cada hoja tiene 1 fila de ejemplo en fila 2 (Juan Pérez / Acme Holdings / Venta participación Acme).

- [ ] **Step 3: Smoke test — import del template tal cual**

Click "Importar Excel". Seleccionar el `.xlsx` recién descargado. Debería aparecer modal:
- Resumen: Clients 1, Companies 1, Deals 1.
- Warnings: 0 (o muy pocos).
- Botón "Confirmar import" habilitado.

Click "Confirmar import". Verificar:
- Alert: "✓ Importado: 1 clientes, 1 empresas, 1 deals."
- Vista Clientes muestra "Juan Pérez".
- Vista Empresas muestra "Acme Holdings".
- Vista Deals muestra "Venta participación Acme" con cliente vinculado a Juan Pérez y empresa Acme Holdings, splits = tú al 100%.

- [ ] **Step 4: Verificar persistencia en Supabase**

Esperar 1-2 segundos (debounce del flush). Usar MCP `mcp__claude_ai_Supabase__execute_sql` con project_id `rtusnruywsmbbzejxooi`:
```sql
select code, name, email, country, source, tier, net_worth from public.clients where email='juan.perez@example.com';
select code, name, industry, client_ids from public.companies where name='Acme Holdings';
select code, title, type, stage, amount, splits from public.deals where title='Venta participación Acme';
```
Expected: cada query devuelve 1 fila con los datos correctos. `client_ids` en companies contiene el UUID del cliente Juan Pérez. `splits` en deals = `[{"u":"<currentUserId>","pct":100}]`.

- [ ] **Step 5: Cleanup**

Borrar los 3 registros de prueba via MCP (como admin):
```sql
delete from public.deals where title='Venta participación Acme';
delete from public.companies where name='Acme Holdings';
delete from public.clients where email='juan.perez@example.com';
```

- [ ] **Step 6: Smoke test — dedup por email**

Re-importar el mismo `.xlsx`. Esta vez el preview debería mostrar "Clients: 1 nuevos (0 omitidos)" la primera vez, y "Clients: 0 nuevos (1 omitidos)" la segunda. Cancelar tras verificar.

Si el comportamiento dedup no se observa (porque cleaned), crear primero un cliente con email `juan.perez@example.com` como admin, luego repetir el import — verificar que ese email se omite.

- [ ] **Step 7: Smoke test — Excel inválido**

Crear un archivo `.xlsx` con hojas mal nombradas (ej. `Test`) o subir un `.json` renombrado a `.xlsx`. Click Importar Excel y seleccionarlo. Debería aparecer alert con el mensaje "Archivo Excel no válido..." o "no contiene ninguna de las hojas esperadas". El modal NO se debe abrir.

- [ ] **Step 8: Smoke test — botones legacy no aparecen**

Inspeccionar visualmente el header. Confirmar:
- "Recargar" NO está.
- "CSV" NO está.
- "Importar" (JSON) NO está.
- "Exportar" (JSON) NO está.
- "Plantilla" SÍ está.
- "Importar Excel" SÍ está.
- "Digest" sigue.
- "Excel" (export) sigue.
- "Nuevo" sigue.

---

## Task 9: Commit y deploy

**Files:** los cambios acumulados en `index.html`.

- [ ] **Step 1: Revisar el diff**

Run:
```powershell
git status
git diff --stat
git diff index.html | Select-Object -First 200
```

Expected:
- 1 archivo modificado: `index.html`.
- `--stat` muestra: ~250 deletions, ~200 insertions (números aproximados).

- [ ] **Step 2: Commit**

```powershell
git add index.html
git commit -m @'
Feat: import Excel + cleanup botones legacy del header

- Anade boton "Importar Excel" + "Plantilla" con flujo completo:
  parse 3 hojas (Clients/Companies/Deals) -> validate con whitelists
  y dedup por email -> modal preview con conteos/warnings -> applyImport
  con UUIDs reales y crosslinks resueltos.
- Importador queda como A1 100% en cada deal (editable post-import).
- Limite 200 filas/hoja. Crosslinks huerfanos crean rows sin cliente
  con warning.
- Cleanup: elimina btnReload, btnCsvImport, btnImport (JSON),
  btnExport (JSON) y sus listeners. Elimina openCsvImport,
  showPostExportModal, showBackupToast, maybeBackupReminder y los
  contadores _changesSinceExport/_lastExportTs (obsoletos tras la
  migracion a Supabase + backup diario via GH Actions).
- reloadFromTemplate() queda viva porque la usa el panel Settings.

Prerequisito: F-LibretaCompartida (commit 77ce577).
Spec: docs/superpowers/specs/2026-05-19-import-excel-design.md
Plan: docs/superpowers/plans/2026-05-20-import-excel-implementation.md

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
'@
```

- [ ] **Step 3: Verificar el commit**

Run:
```powershell
git log -1 --stat
```
Expected: 1 archivo modificado con totales coherentes.

- [ ] **Step 4: Push a main (dispara redeploy en Railway)**

Run:
```powershell
git push origin main
```
Expected: push limpio.

- [ ] **Step 5: Smoke test en producción**

Esperar ~60-90s para que Railway redeploye. Abrir https://ceo-advisors-crm-production.up.railway.app, login, repetir Task 8 Steps 2-3 (descargar plantilla + import del template tal cual + verificación SQL).

- [ ] **Step 6: Rollback si algo falla**

Si en producción algo se rompe:
```powershell
git revert HEAD --no-edit && git push origin main
```
Railway re-redeploya la versión anterior en ~1 min. Los registros de prueba importados (si hubiera alguno) NO se borran automáticamente; admin los limpia con SQL si hace falta.

---

## Conocido — limitación v1

Si el Excel tiene `Clients` con un email que ya existe en BD (la fila se dedup-skip), y luego un `Deal` en la misma importación apunta a ese ID temporal: el deal se crea **huérfano** (`clientId=''`) con warning. Idealmente apuntaría al UUID existente del cliente en BD. No se implementa en v1 porque añade complejidad sobre un edge case que probablemente no aplica al caso real (Perplexity rara vez generará un Excel con clientes que el consultor ya tiene en CRM). Si en uso real se vuelve común, v2 puede añadir un `dedupedToExistingId` map en `validateImport` y reusar esos UUIDs en `applyImport`.

## Definition of Done

- [ ] `node --check` del JS extraído pasa tras cada task.
- [ ] El header solo contiene los botones esperados (sin btnReload, btnCsvImport, btnImport, btnExport).
- [ ] No quedan referencias huérfanas en el código a las funciones/ids eliminados.
- [ ] `downloadImportTemplate()` genera un `.xlsx` válido con 3 hojas + headers + ejemplo.
- [ ] El flujo import end-to-end funciona: plantilla → editar → importar → preview → confirmar → registros en Supabase.
- [ ] Dedup por email funciona (re-import del mismo Excel ignora duplicados).
- [ ] Archivo inválido produce alert y NO abre modal.
- [ ] Commit pusheado a main, deploy Railway OK, smoke test en producción pasa.
- [ ] Pablo notificado.
