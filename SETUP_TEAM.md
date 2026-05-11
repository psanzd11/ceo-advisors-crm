# CEO Advisors CRM — Setup para el equipo

Cómo desplegar el CRM para que **todo el equipo** acceda a los mismos datos y documentos sin coste de infra.

## Opción recomendada: carpeta compartida en cloud

El CRM es un único HTML autocontenido + scripts Python + carpeta de docs. Si pones **toda la carpeta** en OneDrive, Dropbox, Google Drive Empresa o similar, cada consultor abre el HTML desde su máquina y ve los mismos datos.

### Pasos

1. **Crear carpeta compartida** llamada `CEO Advisors CRM` en tu cloud de equipo (OneDrive Business / Dropbox Team / Google Drive). Carpeta abierta para los 10 consultores con permisos de **edición**.

2. **Copiar el contenido actual** del CRM ahí. Estructura:
   ```
   CEO Advisors CRM/
   ├── index.html
   ├── CEO_Advisors_CRM_DataTemplate_v2.xlsx
   ├── crm.bat
   ├── inject_data.py
   ├── sync.py
   ├── pupilo_docs/
   ├── processed_exports/
   └── (los demás)
   ```

3. **Cada consultor sincroniza la carpeta** a su máquina (cliente OneDrive/Dropbox/Drive). Asegúrate de marcarla como **"Mantener siempre disponible localmente"** para que `crm.bat` pueda escribir.

4. **Acuerdo del equipo (importante)**: sólo **una persona a la vez** puede ejecutar `crm.bat` para evitar pisar los datos. Workflow propuesto:
   - Cada consultor trabaja en su CRM (browser, localStorage individual).
   - Al final del día, **uno** designado (admin / CEO) recoge los exports JSON de todos por chat/email y ejecuta `sync.py` con cada uno (o uno consolidado).
   - El HTML actualizado se publica al equipo: todos hacen "Recargar" cuando lo abren.

5. **CVs y documentos**: van en `pupilo_docs/`, `cliente_docs/` (se crea solo cuando subas el primer doc). Como vive en la carpeta compartida, todos los ven.

### Limitaciones de este modelo

- ❌ **Edición concurrente**: si 2 consultores editan a la vez en sus browsers, cuando ambos exporten JSON, sólo el último sync persistirá. Mitigación: cada consultor exporta antes de cerrar sesión.
- ❌ **Sin tiempo real**: no se ven los cambios de otros hasta que se regenera + recargan.
- ✅ **Coste**: $0 si ya tenéis OneDrive Business / Dropbox Team / Google Workspace.

### Si esto no es suficiente

Pasar a **Fase 2 — Camino B (Supabase backend)**. Edición concurrente, sincronización en tiempo real, ~$0-25/mes. Hablar con Claude para arrancar.

---

## Checklist de despliegue

- [ ] Carpeta compartida creada y permisos dados al equipo
- [ ] Copia del CRM dentro de la carpeta
- [ ] Cada consultor ha sincronizado la carpeta localmente
- [ ] **Cada consultor ha cambiado su contraseña** (la primera vez que entran, el CRM les fuerza el cambio)
- [ ] Documento interno con el flujo: "trabajas → exportas JSON al final del día → admin sincroniza"
- [ ] Backup mensual de `_v2.xlsx` fuera del cloud principal
