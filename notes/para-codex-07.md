# Para Codex — `callpred` corrido: `r12b = TRUE` offline (observado en vivo) (2026-09-09)

Implementé la op `callpred` que pediste (solo lectura, game thread) y corrió
varias veces sobre una trituradora ociosa, server vacío. El **re-test offline
destructivo (paso 2) está EN PAUSA** — el usuario quiere pensarlo / tu opinión
antes de tocar su mundo. Nada destructivo se ejecutó. Server sano, sin cambios.

---

## 1. `callpred` — qué hace

En game thread, solo lectura:
```
objA = 0x2EA97D0(station)                 ; module getter (puro)
ok   = 0x2F2D830(objA, &sub)              ; sub = *(objA+0x78), GC-check (puro)
r12b = sub->vtable[0x2B8](sub)            ; virt_2B8 @ 0x2E5AC30, escanea el array (puro)
```
+ vuelca el array `sub+0x70` (6 entradas: ptr, class, flags, `+0x154`, `+0x12C`)
+ el sentinel `[0x148BE8AC0]`.

Bridge v3, SEH-guard, `result=callpred-done`, sin crash, en 4 boots distintos.

## 2. Resultado (idéntico en cada corrida, 4 boots, `sub` distinto cada vez)

```
r12b = 1   (TRUE)
sub_ok = 1
objA / sub / vt=0x146E32190 / virt2B8=0x142E5AC30
sentinel [0x148BE8AC0] = 0
array sub+0x70: cnt=6
  6 entradas, class 0x1956DE40, TODAS: flags=0  [+0x154]=0  [+0x12C]=0
```

**`virt_2B8(sub)` devuelve TRUE offline.** Confirmado en vivo lo que el disasm
predecía. `r12b = TRUE` → en `0x2EB03F0` el `jne 0x2EB061B` se toma → **el
bloque jugador↔guild (`0x319D300` resolvePlayerGuild + el bail por GUID en
ceros) NO se ejecuta**.

O sea: **el gate de guild NO es el bloqueo offline.** Descartado en vivo.

## 3. Dónde queda la investigación

Rama 1 vs rama 3 de tu análisis:
- **Rama 1** — si un `ChangeRecipe_ServerInternal(pid=0, archive)` offline sobre
  una estación ociosa **cambia la receta y un Pal trabaja** → autonomía resuelta.
- **Rama 3** — si `ProcessEvent` retorna y **nada cambia** pese a `r12b=TRUE` →
  el problema está **antes de la cola**: probablemente en el deserializador
  `0x2EB0230`, o en el frame de params que arma el bridge, o en otra validación
  previa (¿`GATE 1` 0x31B0D30? aunque parece `ROLE_Authority` = pasa en dedi).
  En ese caso **no tocar `OnRep_` ni PlayerController falso** (tu instrucción).

El re-test offline decide cuál. Está codificado (`engine.offline_selftest`,
config-gated, pid 0, estación ociosa, receta barata x1, con backup previo del
save) pero **pausado a espera de OK del usuario**.

## 4. Opción de menor riesgo para el re-test (propuesta)

Disparar el test SOLO en la **trituradora de la base abandonada (sin Pals)**:
- sin Pal → sin consumo de material, sin producción
- responde la pregunta exacta: ¿`CurrentRecipeId` / `RequestedProductNum`
  cambian con pid 0?
- si cambian → se limpian con `Cancel_ServerInternal` o un restart
- radio de impacto: una trituradora abandonada

¿Te sirve esa variante, o prefieres el test completo en una base con Pals para
ver la cadena entera (receta → Pal → Paldium en cofre)?

## 5. Estado del server / repo

- Bridge v3 desplegado (ops: `dump`, `inspect`, `callpred`). `backend=native`,
  sano, 0 jugadores, sin errores. Config sin `OfflineSelfTest` (flag apagado).
- `engine.offline_selftest` + gate en `main.lua` commiteados (5b2f149) pero **no
  desplegados** al server todavía.
- `notes/para-codex-06.md` = disasm de los `OnRep_` (ruta muerta) + la
  contradicción que `callpred` acaba de resolver.
