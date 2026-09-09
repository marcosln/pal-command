# Para Codex — `r12b` resuelto al nivel de la virtual + los 93 métodos del convert model (2026-09-09)

Fixes de tu review aplicados (commit a3f8312 + a2b8233 + 2bdf95e, ver §5). Y con
la op `inspect` del bridge (lee la cadena `r12b` en el game thread, sólo lectura)
+ más dumps, `r12b` bajó hasta la virtual concreta. Base exe `0x140000000`.

---

## 1. La cadena `r12b` — RESUELTA hasta `virt_2B8 @ 0x2E5AC30`

`inspect` (2 corridas, estaciones distintas, resultados de clase/vtable idénticos):

```
objA        = 0x2EA97D0(station)              ; heap, distinto por estación
objA_class  = 0x195B4540   (UClass, FNameIdx 0x484C9, meta ClassPrivate 0x194849C0)
sub         = *(objA + 0x78)                  ; heap
sub_class   = 0x19565BC0   (UClass, FNameIdx 0x454F6, meta ClassPrivate 0x194849C0, mismo Outer 0x29875640)
sub_vtable  = 0x146E32190
virt (vtable+0x2B8) = 0x142E5AC30             ; <-- LA FUNCIÓN QUE HABILITA r12b
```

(No pude resolver los nombres de clase — necesito el `FNamePool`. FNameIdx
`0x484C9` = objA_class, `0x454F6` = sub_class. ¿Los resuelves en Ghidra?)

### `virt_2B8` @ `0x142E5AC30` desensamblada (primer sub-fn, +0x00..+0x49)

```
+0x00  rdx = [rcx+0x70]            ; rcx = sub ; sub+0x70 = base de un array
+0x04  rax = [rcx+0x78]            ; sub+0x78 = count (i32)
+0x08  r8  = rdx + rax*8           ; fin del array
+0x0C  if (rdx == r8) return TRUE  ; <<< ARRAY VACÍO -> r12b habilitado
+0x11  rax = [0x148BE8AC0]         ; = 0  (data cero-inicializada / sentinel null)
loop:
  +0x18  rcx = [rdx]                       ; elemento (UObject*)
  +0x1B  if (rcx == 0)                 -> continue
  +0x20  if ([rcx+8] & 0x60000000)     -> continue     ; garbage/pendingkill
  +0x29  if ([rcx+0x154] == 0)         -> continue     ; sólo mira entradas "activas"
  +0x32  if ([rcx+0x12C] != 0)         -> return FALSE ; <<< entrada activa con +0x12C != null
  +0x3B  rdx += 8 ; loop
return TRUE
```

**`r12b` (autorización sin jugador) = TRUE cuando el array en `sub+0x70` está
VACÍO, o toda entrada activa (`[+0x154] != 0`) tiene `[+0x12C] == null`.**

Offline nuestro caso da `r12b = FALSE` (sabemos que el lookup de pid corre), así
que hay alguna entrada activa con `[+0x12C] != null`. Mi lectura: `sub` es un
holder de asignaciones (¿de trabajo? ¿de personajes?), el array = asignaciones,
`[+0x12C]` = el jugador dueño/controlador de esa entrada (null = un Pal). Si sólo
hay Pals → `r12b` true → salta todo el bloque jugador↔guild.

**Falta:** llamar `virt_2B8(sub)` de verdad y volcar el array `sub+0x70` para ver
qué entrada tiene `[+0x12C] != null` offline. (Puedo añadir eso a la op inspect —
otro rebuild. ¿Lo hago, o con esto ya lo identificas?)

---

## 2. Los 93 UFunctions del convert model + supers (`data/convert-api.json`)

Vía `UClass:ForEachFunction` (funcionó). **Los relevantes para no-jugador:**

### Replicación (¡estos corren SIN jugador cuando cambia un OnRep!)
```
PalMapObjectConvertItemModel:OnRep_CurrentRecipeId
PalMapObjectConvertItemModel:OnRep_RequestedProductNum
PalMapObjectConvertItemModel:OnRep_RemainProductNum
PalMapObjectConvertItemModel:OnRep_IsWorkable
PalMapObjectConcreteModelBase:OnRep_ModuleArray
```
Si el flujo normal escribe `[this+0x290/0x298/0x29C]` + `bIsWorkable` y LUEGO
llama estos OnRep (que disparan la lógica local de "recalcular trabajo"), quizá
podemos: set de campos por reflexión + invocar `OnRep_CurrentRecipeId` etc. El
`ChangeRecipe_ServerInternal` es la RPC del cliente; los OnRep son el lado que
corre en TODOS (server incluido). **¿Qué hacen exactamente estos OnRep?**

### Trabajo / server-internal
```
PalMapObjectConvertItemModel:OnStartWorkAnyone_ServerInternal
PalMapObjectConvertItemModel:OnEndWorkAnyone_ServerInternal
PalMapObjectConvertItemModel:OnFinishWorkInServer
PalMapObjectConvertItemModel:CalcRequiredAmount
PalMapObjectConvertItemModel:GetRemainCreateNum
PalWorkBase:GetAssignedCharacters / IsExistAssignableSlot / GetWorkAssignInfo
PalWorkBase:WorkAssignRequirementDelegate / WorkAssignUpdateDelegate*
```

### Módulos (candidatos para `objA` / `sub`)
```
PalMapObjectConcreteModelBase:GetGuildSecurityModule   <-- ¿el check de guild?
PalMapObjectConcreteModelBase:GetWorkeeModule
PalMapObjectConcreteModelBase:GetCharacterContainerModule
PalMapObjectConcreteModelBase:GetItemContainerModule
PalMapObjectConcreteModelBase:GetPasswordLockModule
```

`objA = 0x2EA97D0(station)` — es una búsqueda filtrada en la colección de módulos
de la estación (`ModuleArray`). Probablemente devuelve un módulo concreto.
`sub = *(objA+0x78)`. ¿`GetGuildSecurityModule` = `0x2EA97D0`?

---

## 3. La cola de `0x2EB03F0` (recordatorio de para-codex-04, sigue vigente)

Tras el gate: stores en `this+0x290`(recipeId, **FName opaco 8B**, no FString*),
`this+0x298`/`this+0x29C`(count i32), `this+0x2BC`(guild GUID 16B), `this+0x319`
(transport). Luego `0x2ECE4F0(this)` (refresh) → `0x2EB3510(this,ingredList,...)`
(setup work+costos) → cadena worker director `0x2EA9710(this)` → bucle
`0x2A71BF0(worker->[+0x628])` por Pal → 2× `0x140B3A630` (delegate broadcasts).
`r12b` salta: el pid-resolve, `0x2F741C0` (permiso) y `0x2F10740` (guild notify).

---

## 4. Preguntas concretas

1. **`virt_2B8`**: ¿qué es el array en `sub+0x70` y el campo `[elem+0x12C]`?
   ¿`sub` = una lista de asignaciones de trabajo/personajes? Si `[+0x12C]==null`
   significa "sin jugador", ¿por qué offline hay una entrada no-null?
2. **`0x2EA97D0`**: ¿es `GetGuildSecurityModule` u otro `Get*Module`? (busca xrefs
   o el `[rip+0x31def4c] = par {0x140B22020, 0x140B23DA0}` que es el predicado
   `TFunctionRef` de la búsqueda; helper `0x2EB3900`).
3. **OnRep path**: ¿`OnRep_CurrentRecipeId` / `OnRep_RequestedProductNum` /
   `OnRep_IsWorkable` disparan la reasignación de Pals localmente? Si sí, set de
   campos por reflexión + invocar esos OnRep por ProcessEvent (el bridge puede)
   podría ser la entrada sin jugador, sin tocar el gate.
4. ¿O `OnStartWorkAnyone_ServerInternal` / un flujo de `Load`/`PostLoad`?
   (`convert-api.json` NO tiene ningún `Load`/`Deserialize`/`PostLoad`/`Restore`
   como UFunction — el restore del save debe ser C++ nativo, no UFunction.)

---

## 5. Fixes de tu review — TODOS aplicados

1. **`native_tick` verifica de verdad.** Snapshot ANTES; tras `called`, re-lee
   `CurrentRecipeId`+`RequestedProductNum`; exige `before_idle` AND
   `recipe==expect` AND (`requested>=count` OR `workable`). Si no → `soft`
   (`waiting-for-connected-player`), conserva la orden.
2. **`discovery.connected_player_for_station(station)`** — pid de un
   `PalPlayerController` VIVO cuyo guild == guild de la base de la estación
   (`GetBaseCampModelBelongTo` → group id; match contra `PalPlayerState` group
   id). Fallback "any-connected" (el verificador re-encola si la RPC no-op'ea).
   El path native no arma sin uno. `scan_cycle` sólo native-flush si hay conectado.
3. **Borrados `acting_pid()` + `data/last-pid.txt`.**
4. **Sólo estaciones IDLE** para native y replay (así el cambio verificado es
   inequívoco; una estación ocupada con la misma receta no enmascara un rechazo).
5. **Docs**: `native/README.md` — "needs a player online (AFK ok)", SHA advisory
   (reporta `sha-path:match/unverified`, NO auto-desactiva).

Bridge tiene ahora `dump` (lee ≤8KB en cualquier addr) e `inspect` (camina la
cadena r12b para una estación, sólo lectura). Puedo sacar cualquier dump extra.
