#!/usr/bin/env python3
"""migrate_to_supabase.py — Importer Excel/HTML → Supabase (Fase 15.2)

Lee el seedData del HTML actual (porque el Excel está encriptado), genera UUIDs
deterministas vía uuid5(code), mapea FKs y splits, y carga las tablas en orden:
  consultants → clients → companies → deals → activities → pupilos
Luego envía invitaciones de Supabase Auth a cada consultant.

Idempotente: usa upsert con `on_conflict=code` — re-ejecutar es seguro.

Uso (desde el directorio del proyecto):
    # Re-extraer seedData del HTML (requiere node)
    node /tmp/run.js > /tmp/seed.json

    python3 migrate_to_supabase.py                  # DRY-RUN por defecto
    python3 migrate_to_supabase.py --real           # ejecuta
    python3 migrate_to_supabase.py --real --skip-invite   # sin invitaciones

Service-role key: leída de --service-role, $SUPABASE_SERVICE_ROLE, o /tmp/sr.txt.
"""
import sys, json, uuid, time, urllib.request, urllib.error, argparse, os

PROJECT_URL = "https://rtusnruywsmbbzejxooi.supabase.co"
REST_URL = f"{PROJECT_URL}/rest/v1"
AUTH_URL = f"{PROJECT_URL}/auth/v1"
NS = uuid.UUID("00000000-0000-0000-0000-000000000001")  # namespace fijo para uuid5

EMAIL_FIXES = {
    'u2': 'rchavarria@ceoadvisors.com',  # typo corregido (era rcharvarria)
}

def code_to_uuid(code: str) -> str:
    return str(uuid.uuid5(NS, code))

def http(method, url, key, body=None, prefer=None):
    headers = {
        'apikey': key,
        'Authorization': f'Bearer {key}',
        'Content-Type': 'application/json',
    }
    if prefer:
        headers['Prefer'] = prefer
    data = json.dumps(body).encode('utf-8') if body is not None else None
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req) as r:
            return r.status, r.read().decode('utf-8')
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode('utf-8')

def upsert_table(table, rows, key, dry_run):
    if not rows:
        print(f"  (vacío, skip {table})"); return
    if dry_run:
        print(f"  [DRY] would upsert {len(rows)} rows into {table}")
        sample = dict(rows[0])
        # truncate large fields para el sample
        for k,v in list(sample.items()):
            if isinstance(v,str) and len(v)>80: sample[k] = v[:77]+'…'
        print(f"        sample[0]: {json.dumps(sample, ensure_ascii=False)}")
        return
    url = f"{REST_URL}/{table}?on_conflict=code"
    BATCH = 50
    for i in range(0, len(rows), BATCH):
        chunk = rows[i:i+BATCH]
        status, body = http('POST', url, key, chunk,
                            prefer='resolution=merge-duplicates,return=minimal')
        if status >= 300:
            print(f"  ✗ ERROR {status} upserting {table}[{i}:{i+len(chunk)}]: {body[:500]}")
            sys.exit(1)
    print(f"  ✓ upserted {len(rows)} rows into {table}")

# Mapeo de enums: el seed usa nombres legacy del CRM HTML, el schema Supabase usa los nuevos
TYPE_MAP = {
    'expand':'mandate','advise':'advisor','wealth':'retainer','sale':'mandate',
    'finance':'mandate','retainer':'retainer','equity':'equity','board':'board',
    'mandate':'mandate','advisor':'advisor','other':'other',
}
STAGE_MAP = {
    'qualified':'contact','proposal':'proposal','negotiation':'negotiation',
    'won':'won','lost':'lost','prospect':'lead','lead':'lead','contact':'contact',
    'on-hold':'on-hold','onhold':'on-hold','closed-won':'won','closed-lost':'lost',
}
ATYPE_MAP = {'meeting':'meeting','call':'call','email':'email','note':'note','task':'task','other':'other'}

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--real', action='store_true', help='Ejecutar de verdad (default: dry-run)')
    ap.add_argument('--seed', default='/tmp/seed.json')
    ap.add_argument('--service-role', default=None)
    ap.add_argument('--skip-invite', action='store_true', help='Saltar invitaciones de Auth')
    args = ap.parse_args()
    dry = not args.real

    sr = args.service_role or os.environ.get('SUPABASE_SERVICE_ROLE')
    if not sr and os.path.exists('/tmp/sr.txt'):
        sr = open('/tmp/sr.txt').read().strip()
    if not sr:
        print("ERROR: falta service_role (--service-role, env SUPABASE_SERVICE_ROLE, o /tmp/sr.txt)")
        sys.exit(1)

    print(f"Modo: {'DRY-RUN (sin tocar Supabase)' if dry else '★ REAL ★'}")
    print(f"Seed: {args.seed}")
    seed = json.load(open(args.seed))

    # 1. CONSULTANTS — datos reales, sin is_demo
    consultants = []
    for c in seed['consultants']:
        email = (EMAIL_FIXES.get(c['id']) or c.get('email','')).strip()
        consultants.append({
            'id': code_to_uuid(c['id']),
            'code': c['id'],
            'name': c['name'],
            'role': c.get('role','Advisor') or 'Advisor',
            'is_ceo': bool(c.get('isCEO', False)),
            'is_admin': bool(c.get('isAdmin', False)),
            'email': email or None,
            'region': c.get('region','') or None,
            'bio': c.get('bio','') or None,
        })
    print(f"\n[1/6] CONSULTANTS: {len(consultants)}")
    upsert_table('consultants', consultants, sr, dry)

    # 2. CLIENTS — is_demo=true
    clients = []
    for c in seed['clients']:
        clients.append({
            'id': code_to_uuid(c['id']),
            'code': c['id'],
            'name': c['name'],
            'email': c.get('email') or None,
            'phone': c.get('phone') or None,
            'country': c.get('country') or None,
            'city': c.get('city') or None,
            'net_worth': int(c.get('netWorth') or 0),
            'source': c.get('source') or None,
            'tier': c.get('tier') if c.get('tier') in ('A','B','C','D') else None,
            'notes': c.get('notes') or None,
            'is_demo': True,
        })
    print(f"\n[2/6] CLIENTS: {len(clients)} (is_demo=true)")
    upsert_table('clients', clients, sr, dry)

    # 3. COMPANIES — is_demo=true, client_ids JSONB mapeados a UUIDs
    companies = []
    for co in seed['companies']:
        companies.append({
            'id': code_to_uuid(co['id']),
            'code': co['id'],
            'name': co['name'],
            'industry': co.get('industry') or None,
            'country': co.get('country') or None,
            'employees': int(co.get('employees') or 0),
            'net_worth': int(co.get('netWorth') or 0),
            'website': co.get('website') or None,
            'client_ids': [code_to_uuid(cid) for cid in (co.get('clientIds') or [])],
            'notes': co.get('notes') or None,
            'is_demo': True,
        })
    print(f"\n[3/6] COMPANIES: {len(companies)} (is_demo=true)")
    upsert_table('companies', companies, sr, dry)

    # 4. DEALS — is_demo=true, splits JSONB con UUIDs
    deals = []
    for d in seed['deals']:
        splits = []
        for s in (d.get('splits') or []):
            if s.get('u'):
                splits.append({'u': code_to_uuid(s['u']), 'pct': int(s.get('pct') or 0)})
        deals.append({
            'id': code_to_uuid(d['id']),
            'code': d['id'],
            'title': d['title'],
            'client_id': code_to_uuid(d['clientId']) if d.get('clientId') else None,
            'company_id': code_to_uuid(d['companyId']) if d.get('companyId') else None,
            'type': TYPE_MAP.get((d.get('type') or 'mandate').lower(), 'mandate'),
            'stage': STAGE_MAP.get((d.get('stage') or 'lead').lower(), 'lead'),
            'amount': int(d.get('amount') or 0),
            'close_date': d.get('closeDate') or None,
            'splits': splits,
            'notes': d.get('notes') or None,
            'is_demo': True,
        })
    print(f"\n[4/6] DEALS: {len(deals)} (is_demo=true)")
    upsert_table('deals', deals, sr, dry)

    # 5. ACTIVITIES — is_demo=true
    activities = []
    for a in seed['activities']:
        activities.append({
            'id': code_to_uuid(a['id']),
            'code': a['id'],
            'type': ATYPE_MAP.get((a.get('type') or 'note').lower(), 'note'),
            'date': a.get('date') or None,
            'client_id': code_to_uuid(a['clientId']) if a.get('clientId') else None,
            'company_id': code_to_uuid(a['companyId']) if a.get('companyId') else None,
            'deal_id': code_to_uuid(a['dealId']) if a.get('dealId') else None,
            'title': a.get('title') or None,
            'notes': a.get('notes') or None,
            'done': bool(a.get('done', False)),
            'created_by': code_to_uuid(a['createdBy']) if a.get('createdBy') else None,
            'is_demo': True,
        })
    print(f"\n[5/6] ACTIVITIES: {len(activities)} (is_demo=true)")
    upsert_table('activities', activities, sr, dry)

    # 6. PUPILOS — datos reales, sin is_demo
    pupilos = []
    for p in seed['pupilos']:
        pupilos.append({
            'id': code_to_uuid(p['id']),
            'code': p['id'],
            'name': p['name'],
            'email': p.get('email') or None,
            'university': p.get('university') or None,
            'program': p.get('program') or None,
            'start_date': p.get('startDate') or None,
            'end_date': p.get('endDate') or None,
            'mentor': p.get('mentor') or None,        # texto (puede ser u1, u2... o nombre)
            'region': p.get('region') or None,
            'consultant_id': code_to_uuid(p['consultantId']) if p.get('consultantId') else None,
            'left_company': p.get('leftCompany') or None,
            'left_role': p.get('leftRole') or None,
            'notes': p.get('notes') or None,
            'docs': p.get('docs') or [],
        })
    print(f"\n[6/6] PUPILOS: {len(pupilos)}")
    upsert_table('pupilos', pupilos, sr, dry)

    # 7. INVITE consultants (Supabase Auth Admin API)
    if not args.skip_invite:
        print(f"\n[INVITE] Enviando invitaciones por email a consultants...")
        invited = errored = skipped = 0
        for c in consultants:
            email = c['email']
            if not email:
                print(f"  ⚠ {c['code']} {c['name']}: sin email, skip"); skipped += 1; continue
            if dry:
                print(f"  [DRY] would invite: {c['code']:>3} {c['name']:24} → {email}")
                continue
            status, body = http('POST', f"{AUTH_URL}/invite", sr, {'email': email})
            if status >= 300:
                if 'already' in body.lower() or 'exists' in body.lower() or status == 422:
                    print(f"  ⚠ {email}: ya invitado/existe (skip)"); skipped += 1
                else:
                    print(f"  ✗ {email}: {status} {body[:200]}"); errored += 1
            else:
                print(f"  ✓ invitado: {email}"); invited += 1
            time.sleep(0.4)  # ~150/min rate limit
        if not dry:
            print(f"\n  Resumen invitaciones: {invited} enviadas, {skipped} skip, {errored} errores")

    print(f"\n{'═'*50}")
    print(f"{'DRY-RUN' if dry else 'IMPORT REAL'} completado.")
    if dry:
        print(f"Para ejecutar de verdad: python3 migrate_to_supabase.py --real")

if __name__ == '__main__':
    main()
