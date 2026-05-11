# ═══════════════════════════════════════════════════════════════════
# CEO Advisors CRM — Dockerfile para Railway (Fase 15.3)
# Sirve el HTML PRODUCTION estático con Caddy.
# Railway provee $PORT en runtime — el Caddyfile lo respeta.
# ═══════════════════════════════════════════════════════════════════
FROM caddy:2-alpine

# El HTML PRODUCTION es el output de inject_data.py — siempre el más reciente.
COPY index.html /usr/share/caddy/index.html
COPY Caddyfile /etc/caddy/Caddyfile

# Caddy escucha en $PORT (lo expandirá el shell de Railway)
EXPOSE 80
