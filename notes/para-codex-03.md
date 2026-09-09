# Para Codex — disasm de `ChangeRecipe_ServerInternal` (2026-09-09)

Le añadí al bridge una op `dump` (lee hasta 8 KiB en cualquier dirección → hex a
`data/native-dump.ini`). Desactivé temporalmente el hook replay de Lua para dejar
`UFunction::Func` pristino (con el hook, `Func` apunta al trampolín FNV-1a de
UE4SS). Con eso tracé toda la cadena. Todos los RVA son sobre `Pal-Win64-Shipping.exe`
base `0x140000000` (sin ASLR bajo Wine; direcciones deterministas por boot).

---

## 1. Cadena de llamadas

```
UFunction ChangeRecipe_ServerInternal  (heap, UFunction*)
  Func @ offset 0xD8  ->  0x142862CF0   (rva 0x2862CF0)  execChangeRecipe_ServerInternal (thunk)
     thunk: P_GET int32 RequestPlayerId; P_GET_STRUCT FPalNetArchive& ;
            call  0x142EB0230(this, &frame_stuff, RequestPlayerId)
  0x142EB0230  (rva 0x2EB0230)  = deserializador del FPalNetArchive
     lee  [int32 strlen][UTF-16 id][int32 count][u8 transport]  de archive->Bytes (TArray @ +8)
     construye FString recipeId, y llama:
       0x142EB03F0(this, int32 RequestPlayerId, FString* recipeId, int32 count, u8 transportFlag)
  0x142EB03F0  (rva 0x2EB03F0)  = LA IMPLEMENTACIÓN REAL  (args ya desempaquetados, SIN archive)
```

**Nota fuerte:** `0x142EB03F0` toma args planos. Si se pudiera llamar directo con
`(this, playerId, &recipeFString, count, transport)` te saltas todo el archive.
Pero `0x142EB03F0` TODAVÍA tiene el check del jugador (ver §2).

---

## 2. El gate dentro de `0x142EB03F0` — dónde muere el caso offline

```
+0x032  call  rva 0x31B0D30 ; test al ; je <fin>          ; gate 1 (HasAuthority-like; pasa en dedi)
+0x06A  call  rva 0x2EA97D0 (rcx=this)  -> r15            ; getter objeto A
+0x0AB  call  rva 0x2F2D830 (rcx=r15, rdx=&local) ; test al ; je -> r12b=0
+0x0C6  mov rax,[rcx] ; call [rax+0x2B8] () ; test al ; je -> r12b=0   ; virtual sobre &local
+0x0D3  mov  r12b, 1                                       ; "autorizado SIN jugador"
        (else +0x0D8: xor r12b, r12b)
...
+0x146  test r12b, r12b
+0x149  jne  +0x22A                                        ; r12b==1  -> SE SALTA todo el check de jugador
+0x14F  mov  r8d, r14d                                     ; r14d = RequestPlayerId
+0x152  mov  rdx, rbx  (this)
+0x155  lea  rcx, [rsp+0x70]  (out, 16 bytes)
+0x15A  call rva 0x319D300 (out16, this, RequestPlayerId)  ; resuelve el jugador -> struct 16 bytes (forma FGuid)
+0x15F  movups xmm0,[rax] ; movaps [rsp+0x30], xmm0        ; copia 16 bytes de *rax
+0x167  mov  rcx, rbx
+0x16A  call rva 0x319C810 (this)  -> rax                  ; group/guild dueño de la estación (?)
+0x16F  ecx = [rsp+0x3c] | [rsp+0x38] | [rsp+0x34] | [rsp+0x30]
+0x17F  je   0x142EB0C60                                   ; <<< si esos 16 bytes == 0  -> BAIL (no-op)
+0x185  test rax, rax
+0x188  je   0x142EB0C60                                   ; rax null  -> BAIL
+0x18E  test [rax+8], 0x60000000 ; jne 0x142EB0C60         ; rax garbage/pendingkill -> BAIL
... (checks pasan) ...
+0x22A .. +0x87F   set de receta real + notificación a workers   (bail target 0x142EB0C6F / 0x142EB0C60 al final)
```

**Comportamiento observado que encaja exacto:**
- jugador 256 CONECTADO → `0x319D300` devuelve FGuid no-cero → checks pasan → receta cambia, Pal trabaja, costo real, se completa offline. ✅
- jugador 256 DESCONECTADO (mismo pid, o pid 0) → `0x319D300` devuelve FGuid cero → `je 0x142EB0C60` → no-op silencioso. ❌  (`ProcessEvent` devuelve limpio; `native-response` dice `status=called`)

Es decir: **es un check de membresía de guild/grupo, y resuelve el guild del
jugador vía `RequestPlayerId` de una forma que da cero cuando el jugador no está
conectado.** `r12b` lo saltaría entero.

---

## 3. Lo que necesito que identifiques (IDA/Ghidra sobre Pal-Win64-Shipping.exe v1.0.4.102642)

| rva | qué es (mi hipótesis) | por qué importa |
|---|---|---|
| `0x2EB03F0` | `APalMapObjectConvertItemModel::ChangeRecipe_ServerInternal` (impl) | el núcleo |
| `0x2EA97D0` | getter objeto A (rcx=this) → r15 | entrada a `r12b` |
| `0x2F2D830` | predicado `r12b` #1 (rcx=r15, rdx=&local out) | ¿qué valida? ¿se puede forzar? |
| vtbl `+0x2B8` de la clase de `&local` | predicado `r12b` #2 (virtual) | ¿nombre del método? |
| `0x319D300` | `RequestPlayerId` → FGuid (guild/grupo del jugador) | **el que falla offline** |
| `0x319C810` | estación → group/guild dueño | el otro lado del match |
| `0x31B0D30` | gate 1 (HasAuthority?) | |
| tail `+0x22A..+0x87F` | set receta + assign work: llama a `0x2E5881F`, `0x2EB753F`, `0x2E4BAFF`, `0x2E4AE1F`, `0x2ECE4EF`, `0x2F1073F`, `0x2F10FEF`, `0x2F3B70F`, `0x2F741BF`, `0x2F96A1F`, `0x2F9B67F`, `0x3039B3F`, `0x307666F`, `0x319318F`, `0x31A1C5F` | **¿cuál es "SetCurrentRecipe + RequestAssignWork"?** ese es el que queremos llamar directo |

### Preguntas

1. **`r12b`** — ¿qué es `0x2F2D830` + el virtual `[+0x2B8]`? Si es algo como
   `IsRunningDedicatedServer` / `bServerAuthoritative` / `bIgnorePlayerRequirement`
   / "el request vino de la consola RCON" → forzarlo gana sin tocar el jugador.
2. **`0x319D300`** — ¿itera solo `GetWorld()->GetPlayerControllerIterator()`
   (conectados), o hay una variante que lee el guild del jugador del save
   (`UPalPlayerDataStorage` / `UPalGroupManager::GetGroupByPlayer`)? El mod puede
   resolver el guild GUID del jugador offline por reflexión — pero esta fn toma
   `int32 playerId`, no un GUID.
3. **Tail** — ¿cuál de esas llamadas es el "set receta + assign work" puro? El
   bridge puede llamar cualquier UFunction o dirección nativa en el game thread
   con args controlados, y leer/volcar memoria. Si me dices `(this, recipeFName,
   count, transport)` y qué fn, lo llamo directo saltándome `0x2EB03F0` entero.
4. ¿O el flujo que usa el juego al **cargar el save** para restaurar recetas de
   estaciones? Ese no tiene jugador por definición.

**NO quiero patchear código del juego** (frágil ante updates) salvo último recurso.

---

## 4. Volcados crudos (para que desensambles local)

### `execChangeRecipe_ServerInternal` thunk @ 0x142862CF0 (240 bytes)
```
48895C24084889742418574883EC30488BDA488BF133FF897C2448E8C078CA00488BCB48397B2074104C8D442448488B5318E899EDCA00EB1C4C8B8388000000498B402048898388000000488D542448E8ABEDCA0048897C242048897C242848897B3848897B40488BCB48837B200074104C8D442420488B5318E851EDCA00EB1C4C8B8388000000498B402048898388000000488D542420E863EDCA00488B43384C8D4424204885C04C0F45C0488B43204885C0400F95C74803F848897B208B542448488BCEE875D4640090488B4C24204885C97406E835D9A30090488B5C2440488B7424504883C4305FC3
```

### `0x142EB0230` deserializador (primeros 448 bytes)
```
488BC4488958208950104889480855565741544155415641574883EC704D8BE033FF48897888488978908BF7488978988978A48BDF8958A04D6340084183F8040F8C3A010000498B142448630A41BF0400000085C90F8825010000745C488BD94803DB4881FBFFFFFF7F0F87100100008BEF85DB0F88060100004C63FB4983C7044D3BF80F8FF600000085DB7E04488D6A04894C244833D2488D4C2440E88E53C8FF448BC3488BD5488B742440488BCEE87B64FF028B5C2448458BEF4C8BF748897C24308BEF48897C243885DB743D79098BCBE8C854C7FDEB177E158BD3488D4C2430E858A1C7FD8B6C24384C8B7424304C63C34D03C04863C5498D0C46488BD6E82A64FF0203EB896C24384885F67409488BCEE8B7033F0090488D15635F1D0385ED490F45D641B801000000488D8C24C0000000E866C14D00488B9C24C00000004D85F67409498BCEE881033F00904585FF782E4963D74D63442408488D4204493BC07F1D498B0C248B3C0A4963D5488D4205493BC07F0A0FB6441104EB05488BDF32C0C64424280088442420448BCF4C8BC38B9424B8000000488B8C24B0000000E818000000
```

### `0x142EB03F0` impl (primeros 1536 bytes de ~2200)
```
488BC4488958204C89401855565757415441564157488DA8B8FEFFFF4881EC100200000F2970B8458BE9448BF2488BD933FFE80809300084C00F844008000039BD60010000750839BD64010000741839BB900200000F852408000039BB940200000F8518080000488BCBE87093FFFF4C8BF848897DB039BD60010000755A39BD64010000755239BB90020000750839BB9402000074424D85FF743DF74008000000607534488D55B0498BCFE88FD3070084C07424488B4DB04885C9741BF74108000000607512488B01FF90B802000084C0740541B401EB034532E448897C243048897C24380F1005B3A1D3050F1145800F100DB8A1D3050F114D90488D45A0488944245048897DA048633DB8A1D305488B35A9A1D305897DA885FF750733F68975ACEB224533C08BD7488D4DA0E85D99C7FD4C8BC74D03C0488BD6488B4DA0E82B62FF0233F64584E40F85DB000000458BC6488BD3488D4C2470E8B0CD2E000F10000F29442430488BCBE8B0C22E008B4C243C0B4C24380B4C24340B4C24300F84EB0600004885C00F84E2060000F74008000000600F85D50600004C8D442430488D95C8000000488BC8E8A0951800900F10000F1145800F1048100F114D90488D7820488D45A0483BC7742C488B4DA04885C97405E835013F00488B07488945A04889378B47088945A88B470C8945AC48C7470800000000488B8DE80000004885C97406E806013F00908B45800B45840B45880B458C75128B45900B45940B45980B459C0F844606000083BD6001000000750983BD6401000000743D0F28442430660F7F442470488D542470488BCBE81B162F004885C07420F74008000000607517488D9560010000488BC8E80E601C0084C00F85F7050000488D4D20E8FD14000090488974245848C744246000000000488975B848C745C00000000083BD6001000000750D83BD64010000000F845D020000488BCBE8D4AF0E00488B9560010000488BC8E865630E00488BF84885C00F845E050000488B480848894D288B4810894D30F30F104014F30F1145348B4818894D38488B481C48894D3C488B482448894D448B402C89454C488B4730488945508B4738894558488B473C4889455C8B4744894564488B4748488945688B4750894570488B4754488945748B475C89457C0FB647608885800000008B4764898584000000F30F104768F30F118588000000488D5770488D8D90000000E87DCAE0FD8B87800000008985A00000004181FD000000800F84850100004C8D4C24584C8B8560010000488BD3488BCBE88D80FAFF4863442460488D0C40488B442458488D1488483BC2741B488D48086690418BC50FAF018901488D490C488D41F8483BC275EB4889751048C7451800000000488D5510488D4D20E8626D000041B1024C8D45B8488D542430488BCBE80EB3F9FF488974247048C744247800000000488D4424404889442450488974244048637D18897C2448488B751085FF750833C08944244CEB244533C08BD7488D4C2440E8EA01CEFD4C8BC749C1E003488BD6488B4C2440E8165FFF02904C8D4C24704C8D442440488D55B8488BCBE8BFA5F9FF
```

(puedo volcar cualquier dirección adicional que pidas — sube el bridge la op `dump`.)

---

## 5. Log parcial de una orden que SÍ funcionó (jugador conectado)

- 09:46:19 — jugador pid 256 conectado (AFK, no crafteó). Mod colocó `Pal_crystal_S x5`
  en trituradora ociosa de base-2 vía el bridge.
- Antes: `recipe=None, requested=0, remaining=0, workable=false`
- Después: `recipe=Pal_crystal_S, requested=5, remaining=5, workable=true`
- 09:51 — `remaining=1` (produjo 4), un Pal trabajándola, Stone bajando. Siguió tras
  desconectarse el jugador (recetas ya puestas se completan offline).
- `native-response.ini`: `status=called, detail=process-event-returned`.

(Un log 100% limpio — estación antes/después + Stone exacto descontado + Pal
asignado por nombre + producto final en cofre — lo saco cuando digas; necesita
jugador conectado + ~3 min para que el Pal termine un batch.)

---

## 6. Confirmaciones que pediste

- **Polling / joins:** el bridge v4 ya NO bloquea joins. Causa raíz del bloqueo
  anterior: el worker polleaba `native-request.ini` cada 2ms + `FlushFileBuffers` +
  `MOVEFILE_WRITE_THROUGH` sobre el filesystem overlay de Wine → ahogaba el I/O de
  save/join. Fix: poll 120ms, gate por mtime/size antes de parsear, sin sync
  forzado, status cada 3s (activo) / 30s (idle). Con el v4 puesto, un jugador se
  conectó sin problema (log `ServerAcknowledgePossession` + PBA `CLIENT_READINESS`).
- **CPU:** el `native poll` de Lua (`LoopAsync` 650ms) ahora sólo salta al game
  thread cuando `engine._native_pending ~= nil`; idle = una lectura de campo Lua y
  return. El worker C++ idle = 1 `GetFileAttributesExW` cada 120ms. Despreciable.
- **Limitación temporal (explícita):** autonomía total (cero jugadores) NO resuelta.
  Por ahora automatiza mientras haya CUALQUIER jugador conectado (AFK cuenta, sin
  craftear); las órdenes quedan en cola hasta entonces; y replay en cualquier craft.
