# CEO Advisors CRM — Schema 2026.05.1

_Auto-generado por `inject_data.py` el 2026-05-10T01:03:25._

## Entidades

| Entidad | Prefijo ID | Campos | Cantidad actual |
|---|---|---|---|
| `consultants` | `u` | `id`, `name`, `role`, `isCEO`, `isAdmin`, `email`, `password`, `region`, `bio` | 10 |
| `clients` | `c` | `id`, `name`, `email`, `phone`, `country`, `city`, `netWorth`, `source`, `tier`, `notes` | 30 |
| `companies` | `co` | `id`, `name`, `industry`, `country`, `employees`, `netWorth`, `website`, `clientIds`, `notes` | 25 |
| `deals` | `d` | `id`, `title`, `clientId`, `companyId`, `type`, `stage`, `amount`, `closeDate`, `createdAt`, `splits`, `notes` | 43 |
| `activities` | `a` | `id`, `type`, `date`, `clientId`, `companyId`, `dealId`, `title`, `notes`, `done`, `createdBy` | 20 |
| `pupilos` | `p` | `id`, `name`, `email`, `university`, `program`, `startDate`, `endDate`, `mentor`, `region`, `consultantId`, `leftCompany`, `leftRole`, `notes` | 11 |

## Notas de campos especiales

- `consultants` tienen `passwordHash`, `passwordSalt`, `passwordIters`, `passwordMustChange` adicionales (PBKDF2-HMAC-SHA256).
- `pupilos` tienen `docs[]` con `{name, path, mime, uploadedAt}` o `{name, dataUrl, ...}`.
- `clients` y `companies` y `deals` también soportan `docs[]` y `comments[]`.
- `deals` tienen `splits[]` con `{u: consultantId, pct: number}` que deben sumar 100.
- `deals` tienen `stageHistory[]` con `{stage, ts}` para tracking.
- `activities` tienen `done` y `assignedTo` (consultantId).

## Reglas de validación (`inject_data.py`)

- IDs únicos por entidad (sin duplicados).
- Toda referencia (`clientId`, `companyId`, `mentor`, `consultantId`, `createdBy`, `splits[].u`) debe existir.
- `splits` deben sumar exactamente 100.
- Passwords débiles (lista WEAK_PASSWORDS) marcan `passwordMustChange:true`.

## Migraciones (en HTML, `MIGRATIONS` array)

Cada migración tiene `{to: N, fn}`. Se aplican en cadena si el `_schemaApplied` del DB guardado es menor que `to`. **Bumps de schema requieren** añadir nueva entrada al array, no modificar las anteriores.