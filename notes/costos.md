# PalCommand — costos de publicar (USD)

Actualizado 2026-09-09. Apple y Cloudflare cobran en dólares.

## Obligatorio

| concepto | costo | notas |
|---|---|---|
| **Apple Developer Program** | **$99/año** | App Store **y** TestFlight. 1 cuenta = apps ilimitadas. Individual (tu nombre) = gratis de tramitar; Organización necesita D-U-N-S (gratis, 1-2 semanas). |
| Comisión de Apple | $0 | Solo 15-30% si vendés la app o hay compras dentro. App gratis sin IAP = $0. |
| Por descarga / usuario | $0 | No existe |
| Reenvío tras rechazo | $0 | Revisión ~1-3 días, reintentos gratis |
| Xcode | $0 | Ya hay Mac |
| Capacitor (wrapper) | $0 | Open source |

## Backend — Cloudflare Worker

El teléfono no puede hablar directo con el host del server (credenciales + CORS), hace falta un proxy.

**Decisión de arquitectura** (afecta quién paga):

| modelo | paga Cloudflare | UX usuario final |
|---|---|---|
| Un Worker por usuario (lo que hay hoy en `cloud/`) | cada usuario | malo: "bajá la app y además desplegá un Worker" |
| **Worker multi-tenant** (vos lo hospedás, usuario mete su token) | **vos** | bueno: bajás la app, pegás token, listo |

Para App Store hay que ir al **multi-tenant**. Costo:

| Cloudflare | free incluye | Workers Paid ($5/mes) |
|---|---|---|
| Workers | 100.000 req/**día** | 10M/mes, luego $0.30/M |
| KV (caché) | 100k lecturas/día, 1k escrituras/día | 10M/mes |

App polleando cada ~30-60s: 1 usuario ≈ 3.000 req/día, 10 usuarios ≈ 30.000/día → **entra en el free tier holgado**. El plan de $5/mes recién con ~30+ usuarios activos o para sacar el límite diario.

**Cloudflare: $0/mes ahora; $5/mes ($60/año) si escala.**

## El servidor de Palworld — NO es costo nuevo

Cada usuario apunta la app a **su propio server** (el que ya paga para jugar). El mod corre ahí. La app no hospeda servers de juego de nadie. (El de prueba en DatHost = ~€14,90/mes, ya se paga para jugar.)

## Opcional

| concepto | costo | ¿hace falta? |
|---|---|---|
| Dominio propio (`palcommand.app`) | ~$12-20/año | No — `algo.workers.dev` sirve |
| Cloudflare Paid | $5/mes | No hasta que escale |
| Publicar el mod en Nexus Mods | $0 | Nexus es gratis |

## Resumen

| escenario | total/año |
|---|---|
| App Store, uso personal + amigos | **$99** (solo Apple) |
| + dominio propio | ~$115 |
| Si se vuelve popular (cientos de usuarios) | ~$160 ($99 + $60 Cloudflare) |

Gasto fijo real hasta que escale mucho: **$99/año y nada más.**
Modelo que evita pagar por usuario: app gratis, sin IAP, backend multi-tenant en free tier, cada quien trae su server.
