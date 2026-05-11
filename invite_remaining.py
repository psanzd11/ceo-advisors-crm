#!/usr/bin/env python3
"""invite_remaining.py — Reintentar invitaciones bloqueadas por rate limit (F15.2 extra)

El SMTP gratuito de Supabase limita a ~2 emails/hora. Este script consulta qué
consultants aún no tienen auth_user_id y los invita uno a uno con sleep entre
cada llamada para esquivar 429.

Uso:
    python3 invite_remaining.py                # dry-run: muestra qué invitaría
    python3 invite_remaining.py --real         # ejecuta, sleep 60s entre cada uno
    python3 invite_remaining.py --real --sleep 1800   # más conservador (30 min)
"""
import sys, json, time, urllib.request, urllib.error, argparse, os

PROJECT_URL = "https://rtusnruywsmbbzejxooi.supabase.co"
AUTH_URL = f"{PROJECT_URL}/auth/v1"
REST_URL = f"{PROJECT_URL}/rest/v1"

def http(method, url, key, body=None):
    headers = {'apikey': key, 'Authorization': f'Bearer {key}', 'Content-Type': 'application/json'}
    data = json.dumps(body).encode('utf-8') if body is not None else None
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req) as r:
            return r.status, r.read().decode('utf-8')
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode('utf-8')

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--real', action='store_true')
    ap.add_argument('--sleep', type=int, default=60, help='Segundos entre invitaciones (default 60)')
    ap.add_argument('--service-role', default=None)
    args = ap.parse_args()
    dry = not args.real

    sr = args.service_role or os.environ.get('SUPABASE_SERVICE_ROLE')
    if not sr and os.path.exists('/tmp/sr.txt'):
        sr = open('/tmp/sr.txt').read().strip()
    if not sr:
        print("ERROR: falta service_role"); sys.exit(1)

    # Consultar consultants sin auth_user_id
    status, body = http('GET',
        f"{REST_URL}/consultants?auth_user_id=is.null&select=code,name,email&order=code", sr)
    if status >= 300:
        print(f"ERROR consultando consultants: {status} {body}"); sys.exit(1)
    pendientes = json.loads(body)
    pendientes = [c for c in pendientes if c.get('email')]

    print(f"Pendientes de invitar: {len(pendientes)}")
    for c in pendientes:
        print(f"  {c['code']:>3} {c['name']:24} → {c['email']}")

    if not pendientes:
        print("✓ Todos los consultants ya están invitados."); return
    if dry:
        print(f"\n[DRY-RUN] Re-ejecutar con --real para enviar.")
        print(f"   Estimado: {len(pendientes) * args.sleep}s ({len(pendientes) * args.sleep // 60} min) con sleep={args.sleep}s")
        return

    print(f"\nEnviando con sleep={args.sleep}s entre cada uno...")
    ok = err = 0
    for i, c in enumerate(pendientes):
        if i > 0:
            time.sleep(args.sleep)
        status, body = http('POST', f"{AUTH_URL}/invite", sr, {'email': c['email']})
        if status >= 300:
            if 'already' in body.lower() or 'exists' in body.lower():
                print(f"  ⚠ {c['email']}: ya existe (skip)")
            else:
                print(f"  ✗ {c['email']}: {status} {body[:200]}"); err += 1
        else:
            print(f"  ✓ {c['email']}"); ok += 1

    print(f"\nResumen: {ok} enviadas, {err} errores. Pendientes restantes:")
    status, body = http('GET',
        f"{REST_URL}/consultants?auth_user_id=is.null&select=code,email&order=code", sr)
    for c in json.loads(body):
        print(f"  {c.get('code')} {c.get('email')}")

if __name__ == '__main__':
    main()
