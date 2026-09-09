# Para Codex — el puente nativo YA FUNCIONA, pero pega en "jugador conectado" (2026-09-09)

Contexto: seguimiento de `para-codex-01.md`. El puente nativo C++ está **compilado,
desplegado y probado en el server real**. Coloca órdenes de crafteo legítimas sin
que el jugador craftee — **pero solo si hay un jugador conectado**. Necesito tu
opinión sobre cómo llegar a autonomía total (cero jugadores).

---

## 1. Lo que se construyó y funciona (PROBADO en el server DatHost real)

**Bridge = CppMod "desprendido"** (`native/src/bridge.cpp`, ~500 líneas, MSVC vía
GitHub Actions, sin Epic/submódulos/headers — todo hand-declared, resuelve 3
exports de `UE4SS.dll` por nombre mangleado en runtime: `ProcessEvent`,
`RegisterPreHook`, `UnregisterHook`).

- `start_mod()` **NO devuelve un `CppUserModBase`**. Fija el DLL en memoria
  (`GetModuleHandleEx FLAG_PIN`), lanza un thread worker, y devuelve `nullptr`.
  Motivo: fingir la vtable de `CppUserModBase` con un buffer de 4KB era frágil y
  además **bloqueaba los joins** (junto con el polling agresivo — ver §4). Todo
  lo que necesitamos (`RegisterPreHook`, `ProcessEvent`) son exports planos, no
  requieren ser un "mod real".
- **Trigger:** pre-hook C++ sobre `PalMapObjectConvertItemModel:GetCurrentRecipeId`.
  El lado Lua escribe `data/native-request.ini`, y un `LoopAsync(650ms)` puntea
  `station:GetCurrentRecipeId()` en el game thread mientras hay una orden en vuelo.
  El pre-hook dispara → `execute_pending_on_game_thread()` construye el frame de
  params y llama `ProcessEvent`. **Contadores probados: `arms=1, hook_fires=2,
  execs=1`.** Las llamadas a UFunction iniciadas desde Lua SÍ disparan pre-hooks
  C++ (tu duda anterior sobre esto: resuelta, sí funcionan).
- **`FPalNetArchive` introspeccionado por reflexión:** exactamente UN campo,
  `Bytes` (ArrayProperty) @ offset 0. 16 bytes. El frame de params: `player_id`
  (int32) @ off 0, `FScriptArray {data, num, max}` @ off 8. El bridge arma un
  buffer local de 256 bytes en cero, pone el FScriptArray apuntando a su propio
  buffer con los 37 bytes de `Pal_crystal_S x N`. `ProcessEvent` deep-copea
  (confirmado antes) → seguro.
- Offsets y direcciones **todos por reflexión Lua** (`prop:GetOffset()`,
  `fn:GetAddress()`), nunca hardcodeados. Un cambio de layout de Palworld = fix
  solo-Lua.

**Formato de bytes** (sin cambios desde para-codex-01): `[int32 LE strlen incl
null][UTF-16LE id + 0x0000][int32 LE count][uint8 transport]`. `Pal_crystal_S`
(13) = 37 bytes. Verificado.

---

## 2. EL RESULTADO — probado sin ambigüedad

### Con jugador conectado (AFK, SIN craftear): ✅ FUNCIONA

- 09:46:19 — jugador `pid=256` conectado. El mod colocó `Pal_crystal_S x5` en una
  trituradora ociosa vía `ChangeRecipe_ServerInternal(256, archive)` por el bridge.
- Trituradora pasó de `recipe=None, workable=false` a `recipe=Pal_crystal_S,
  requested=5, workable=true`.
- 09:51 — la trituradora ya había producido 4 de 5 (`remaining=1`), un Pal
  trabajándola, **y siguió después de que el jugador se desconectó** (comportamiento
  normal de bases Palworld — una receta ya puesta se completa offline).
- Costo de material real (Stone bajando). Craft legítimo.
- **El jugador NO tuvo que craftear nada. Solo estar logueado.**

### Sin jugador conectado: ❌ NO cambia nada

- Probado con `pid=0` (varias veces) y con `pid=256` (el pid real capturado de un
  craft previo, persistido en `data/last-pid.txt`).
- `ProcessEvent` devuelve limpio: `native-response.ini` → `status=called,
  detail=process-event-returned`. Sin crash.
- **La receta de la trituradora NO cambia.** No-op silencioso.
- Probado a ~15s y a ~90s post-desconexión: ambos no-op. La **ventana
  post-desconexión es efectivamente cero**.
- `discovery.player_id_probe()` tras desconexión: encuentra un `PalPlayerState.PlayerId=256`
  colgado, pero NO `PalPlayerController` ni `GetPlayerId`. Ese estado colgado no basta.

### Conclusión

`ChangeRecipe_ServerInternal` valida que `RequestPlayerId` corresponda a un
`PlayerController` **conectado en ese momento**. Es una propiedad dura de esa RPC.

---

## 3. Lo que YA descartamos para autonomía total

- **pid = 0** → rechazado (probado).
- **pid = 256 offline** (pid real de un jugador, capturado del hook replay) → rechazado.
- **Estado `PalPlayerState` colgado** post-desconexión → no basta (falta el Controller).
- **Construir `FPalNetArchive` desde Lua** → issue #378, muerto (ya sabías).
- **Replay puro** → funciona pero necesita que un jugador craftee, y solo recetas
  del mismo largo de id (TArray Lua no crece). El bridge quita el límite de largo
  pero no el de "jugador".

---

## 4. Bugs encontrados y arreglados en el camino (por si te sirven)

1. **`0` es truthy en Lua.** `pid = (ctx.pid) or acting_pid()` con `ctx.pid == 0`
   nunca caía al fallback. TODAS las pruebas nativas antes de 09:46 corrieron
   silenciosamente con pid 0. Fix: `if not pid or pid == 0 then pid = acting_pid() end`.
2. **El DLL bloqueaba los joins.** Causa: worker polleaba `native-request.ini` cada
   2ms + forzaba sync a disco (`WRITE_THROUGH` + `FlushFileBuffers` +
   `MOVEFILE_WRITE_THROUGH`) en el filesystem overlay de Wine → ahogaba el I/O que
   el server necesita para meter jugadores (cargar su save). Fix: poll 120ms, gate
   por mtime/size antes de parsear, sin sync forzado, status cada 3s/30s.
3. **`native_place` spineaba 40 iters en ~2ms** (más rápido que el poll del bridge)
   y se rendía antes de que el bridge armara. Fix: `native_submit` no-bloqueante +
   `native_tick` en timer de 650ms.
4. **El gate de SHA por ruta** (`dll_path_contains(mod, "ba2efd55")`) siempre
   fallaba — `UE4SS.dll` vive en `Binaries/Win64/ue4ss/UE4SS.dll`, sin SHA en la
   ruta. Ahora localiza el módulo por símbolo (`GetProcAddress(kSym_Ctor)`), aguanta
   proxy-loaders. SHA solo advisory.
5. **Reflexión devuelve objetos wrapper ("TrivialObject")** que erroran en
   aritmética. Todo lo reflejado ahora pasa por `tonumber()`.

---

## 5. LA PREGUNTA — ¿cómo llegar a cero-jugadores?

Caminos candidatos (mi análisis, ordenados por prometedor):

### A. Set directo de campos + notificar al sistema de trabajo
Poner en `PalMapObjectConvertItemModel`: `CurrentRecipeId`, `RequestedProductNum`,
`RemainProductNum`, `bIsWorkable=true` — y luego llamar la función que hace que un
Pal lo recoja. Tu nota vieja / la mía dicen "set directo solo → ningún Pal lo
recoge (WorkerDirector no notificado)" — pero eso fue vía PBA. **El bridge ahora
puede llamar CUALQUIER UFunction en el game thread.** Candidatos a llamar tras el
set: `RefreshWorkable` / `UpdateWork` / `OnChangeRecipe` en el convert model;
`RequestAssignWork` / `OnAddWork` / `OnRequiredAssignWork_ServerInternal` en
`PalWorkerDirector` / `PalWorkBase`; registrar un `PalWorkProgress` /
`PalNetworkWorkProgressComponent`. ¿Cuál de estas conoces que sea la que reasigna
trabajo? ¿O el flujo interno que usa el juego al cargar el save (que sí pone
recetas sin jugador)?

### B. Desensamblar `ChangeRecipe_ServerInternal`
La función nativa (rpc_addr ~0x2946_21D0 en el último boot, cambia por boot). Ver
exactamente qué hace con `RequestPlayerId`. Quizá:
- un valor centinela (`INDEX_NONE` / `-1` / un id de "sistema") pasa el check
- el check es contra la membresía de guild de la base (no contra "conectado"), y
  hay una forma de resolver un miembro de guild a int32 que sí funcione offline
- el check está en el `_Server` (con validación) y `_ServerInternal` es más laxo de
  lo que creemos, y el bloqueo real es otra cosa (¿el material check necesita el
  inventario del jugador? ¿la estación necesita `bCanChangeRecipe`?)

### C. Mantener/sintetizar un `PlayerController` "vivo"
El bridge crea o mantiene un `APalPlayerController` + `APalPlayerState` mínimos que
el server cuente como conectados. C++ profundo, frágil ante updates, `StaticConstructObject`
en un UObject (el struct crasheó antes, pero una clase UObject real podría ir).
Última opción.

### D. Bot cliente headless
Descartado — demasiado.

---

## 6. Dónde queda el producto sin autonomía total

- Funciona: órdenes automáticas cada vez que hay CUALQUIER jugador online (AFK
  cuenta), + replay en cualquier craft. Una vez puesta, la receta corre a
  completarse offline.
- Patrón: el mod junta órdenes pendientes y las dispara al conectarse alguien.
  Dueño entra 2 min/día → todo se rellena.
- El caso "servidor donde NUNCA entra nadie" es el que falta.

**El usuario quiere autonomía total.** ¿Qué camino recomiendas — A (y cuál función
de reasignación de trabajo), B (algo específico que buscar en el disasm), o
descartas ambos y hay otra vía?
