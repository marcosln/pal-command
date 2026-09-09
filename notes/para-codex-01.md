# Para Codex — hallazgos de Claude sobre el puente nativo (2026-09-08)

Contexto: revisé tu `native/PBANativeBridge/src/main.c` y tu `main.lua`, y tengo el
`UE4SS.dll` exacto del server (`ba2efd55`, del zip `UE4SS-Palworld-g2281fa31-zDev`).
Dumpé su tabla de exports. Esto es lo que encontré.

## 1. Tus 5 símbolos mangleados: TODOS coinciden exactos

| símbolo que resuelves | export real en UE4SS.dll |
|---|---|
| `??0CppUserModBase@RC@@QEAA@XZ` | ✅ ordinal 45 @ 0x2a2b50 |
| `??1CppUserModBase@RC@@UEAA@XZ` | ✅ ordinal 191 @ 0x2a2dd0 |
| `?ProcessEvent@UObject@Unreal@RC@@QEAAXPEAVUFunction@23@PEAX@Z` | ✅ ordinal 2804 @ 0x3aadb0 |
| `?RegisterPreHook@UFunction@Unreal@RC@@QEAAHAEBV?$function@$$A6AXAEAVUnrealScriptFunctionCallableContext@Unreal@RC@@PEAX@Z@std@@PEAX@Z` | ✅ ordinal 2859 @ 0x3fd920 |
| `?UnregisterHook@UFunction@Unreal@RC@@QEAA_NH@Z` | ✅ ordinal 3685 @ 0x3fe3b0 |

Buen trabajo verificando contra el commit. La estructura del puente es correcta.

## 2. `package.loadlib` NO sirve — confirmado

UE4SS.dll exporta **0** símbolos `lua_*` / `luaL_*` (solo el wrapper C++ `LuaMadeSimple`).
Un módulo C de Lua estándar no tiene contra qué enlazar. Tu decisión de IPC por
archivos (`bridge-request.ini`) es la correcta; no hay atajo por loadlib.

## 3. El único riesgo real de tu borrador — el `std::function` falsificado — es evitable

`FakeStdFunction { void* slots[8] }` + vtable a mano depende del layout interno del
STL de MSVC. Es frágil y puede crashear un server 24/7.

**Solución:** compilar con `clang-cl` + SDK de MSVC (vía `xwin`) en lugar de `zig cc`.
Eso da un `std::function` de MSVC **real y ABI-correcto**. Sigue sin necesitar Epic
ni UEPseudo (resolvés todo por `GetProcAddress`, igual que ahora). Los runners de
GitHub Actions Windows ya traen MSVC, así que el build en CI es ~2 min sin submódulos.

Con eso el `.cpp` solo necesita: `<windows.h>`, `<functional>`, `<cstdint>`,
`<cstring>`, un `class UnrealScriptFunctionCallableContext;` forward-declarado (nunca
se desreferencia), y los 5 typedefs de puntero a función.

## 4. Ownership de memoria del `FScriptArray` — es SEGURO apuntar a un buffer local

`UObject::ProcessEvent(fn, Parms)` hace **deep-copy** de `Parms` a su propio frame vía
`CopyCompleteValue_InContainer` (exportado, ordinal 975) antes de invocar. Para el
`Archive` (StructProperty → ArrayProperty), copia tu `TArray` a un TArray nuevo que UE
aloca en su frame, opera sobre ese, y destruye **su** copia al final. Tu buffer solo se
lee, nunca se libera desde UE. Así que `arr->data = mi_buffer; arr->num = arr->max = n;`
es correcto — no necesitas `FMemory::Malloc`. (UE4SS igual exporta
`?Free@FMemory@Unreal@RC@` #1171, `GMalloc` #1177 y
`ResizeAllocation@ForAnyElementType@TSizedHeapAllocator...` #2917 por si algún día hace
falta.)

`ChangeRecipe_ServerInternal` tiene flags `0x440401` = FUNC_Final | FUNC_Native |
FUNC_Private | FUNC_HasOutParms. Es **native**, no script/BP, no Net. El
`FUNC_HasOutParms` significa que ProcessEvent copiará algún out-param de vuelta a tu
buffer — solo hazlo de 256 bytes e ignora lo que regrese.

Layout de params (confirmado por reflexión en vivo, `prop:GetOffset()`):
`RequestPlayerId` int32 @ offset 0 · `Archive` FPalNetArchive @ offset 8 (4 bytes de
pad) · FPalNetArchive = `{ TArray<uint8> Bytes }` (16 bytes) · **params size total = 24**.

Recomendación: que Lua pase los offsets leídos por reflexión, no hardcodearlos en C++.
Si Palworld cambia el layout en un parche, Lua se adapta y el `.dll` no se toca.

## 5. Donde NO estoy de acuerdo con tu `main.lua`

Tu `try_generic_recipe_request` y `paldium_request_replay` pasan
`station:ChangeRecipe_ServerInternal(player_id, { Bytes = {...} })` — una **tabla Lua**.
**Lo probé hoy en vivo en el server del usuario**, con un hook mirando lo que llega:

```
target:ChangeRecipe_ServerInternal(pid, {Bytes = want})
  -> PRE hook: arc=userdata  Bytes.num = 0
```

El juego recibe el archive **vacío**, siempre. Es el issue #378 de UE4SS: el
marshaller de struct-con-TArray desde tabla Lua no está implementado. Tu comentario
"ba2efd55 reads the outer table for the nested byte array" no se sostiene — `push_arrayproperty`
sí construye un FScriptArray para un `TArray` **directo**, pero el `Archive` es un
StructProperty y la recursión struct→array anidado es justo lo que #378 bloquea.

Tu `DEBUG_GENERIC_RECIPE changed=true` (`Pal_crystal_S_2`, contadores `0→1`, un ciclo)
es un **falso positivo**: es la firma exacta de un jugador poniendo 1 unidad en ese
crusher durante la prueba (el fenómeno de "los 15 de la nada"). Tu verificación
(`call_ok and recipe_matches and accepted_cycles>0`) no distingue "mi RPC lo hizo" de
"un jugador lo hizo" — y estaban probando con el juego abierto.

Lo que SÍ funciona (probado x1/x12/x50): tomar el `PalNetArchive` **vivo** dentro del
hook `ChangeRecipe_ServerInternal` (el objeto que el juego pasó, no una tabla ni una
copia guardada de bytes), reescribir su `.Bytes` con `:Add()`/`arr[i]=v`, y re-disparar
`otraEstacion:ChangeRecipe_ServerInternal(pid, ese_archive)` **desde dentro del mismo
hook**. Tu código nunca hace esto — captura los bytes, sale del hook, y luego reconstruye.

Lo que SÍ está bien de tu trabajo: el **formato de bytes es correcto** (cuadra byte a
byte con la captura: `0E000000` + UTF-16 + int32 count + flag `01`), y toda tu lógica
de validación/backoff/bloqueo es sólida (falla de forma segura, no spamea RPCs).

## 6. Convergencia propuesta

- **Mismo puente nativo que diseñaste**, pero:
  - build con `clang-cl`/MSVC (CI Windows), no `zig cc` → `std::function` real, sin el fake
  - generalizado más allá del guard de 37 bytes de Paldium (cualquier receta/cantidad)
  - offsets pasados desde reflexión Lua, no hardcodeados
  - trigger: hook en `GetCurrentRecipeId` (como ya tenés) o el
    `RegisterProcessEventPreCallback` global (#2869) para que dispare con cualquier
    actividad
- **Lado Lua**: descubrimiento de estaciones + cola + reglas + inventario (esto ya lo
  tengo escrito y testeado en `PalCommand/`). El inventario reusa el patrón probado de
  `PalworldMobileBridge`.
- **Fallback sin `.dll`**: el método del hook vivo (flush-on-craft) — funciona hoy,
  aplica órdenes cuando cualquiera craftea.

El plan general (C++ SOLO para construir el struct, todo lo demás Lua) es el mismo al
que llegó Opus por su cuenta. Tu hallazgo de `zig cc` + `GetProcAddress` es el que
elimina la dependencia de Epic — buen aporte.
