# Para Codex — dumps que pediste + la cola de `ChangeRecipe_ServerInternal` (2026-09-09)

Hice todos los fixes de código que señalaste (ver §4) y saqué los dumps. Lo más
importante: **desensamblé la cola de `0x2EB03F0` — el set de receta + reasignación
de Pals — y está mapeada**. También `r12b` bajó un nivel más.

Base exe `0x140000000`. Todos los volcados crudos abajo (§5).

---

## 1. La cola de `0x2EB03F0` — set de receta + reasignación de Pals (offsets = `this` = estación)

Después de que los gates pasan (`r12b` o el lookup de pid), el trabajo real:

```
+0x0511  edi = byte [rbp+0x178]                  ; flag (dil) -- ¿"es un cambio nuevo"?
+0x051D  test dil ; je +0x53A
+0x0520  test r12b ; jne +0x53A                  ; r12b salta 0x2F741C0
+0x052D  call 0x142F741C0(this, r15, &guildGuid) ; permiso/notify ; test al ; je FAIL(0x2EB0C25)

--- SET DE ESTADO (stores directos) ---
+0x053F  movups [this+0x2BC], xmm0               ; guild GUID (16B) -- dueño de esta orden
+0x054D  mov    [this+0x290], rax                ; recipeId (FName/FString*, 8B)  <-- CurrentRecipeId
+0x0554  mov    [this+0x29C], r13d               ; count (i32)
+0x0562  mov    [this+0x319], al                 ; transport flag (byte)
+0x0568  mov    [this+0x298], r13d               ; count (i32)   (0x298/0x29C = Requested/RemainProductNum)

--- NOTIFICACIÓN (esto es lo que NO se puede saltar) ---
+0x0572  call 0x143193190(this) -> rax           ; get subobjeto/componente
+0x0581  call 0x142F10FF0(rax, this+0xB0)
+0x0590  call 0x142F3B710(rax, &local+0xB0)
+0x05B5  call 0x142F10740(r15, &local, &out, 1)  ; en r15 (objA) -- guild/group notify   (r12b lo salta)
+0x05BD  call 0x142ECE4F0(this)                  ; <-- probable "OnRecipeChanged / RefreshWorkable"
+0x05F0  call 0x142EB3510(this, &ingredList, &q, &r) ; <-- setup del trabajo con costos de ingredientes
+0x0663  call 0x142A85B40(this) ; 0x142F9DEB0 -> rdi ; 0x32042B0 ; divss xmm0,[this+0x2B8] ; ... (progreso/tiempo)
+0x06A4  call 0x142ECE8B0(this)
+0x0750  call 0x142EA9710(this) -> rsi           ; <-- worker director?
+0x0760  call 0x142EFBC80(rsi) ; 0x142EE64A0(rsi)
+0x0781  call 0x14320C560(rdi, &workerList)      ; get lista de Pals asignados
+0x07B8  loop: call 0x142A71BF0( worker->[+0x628] ) por cada Pal   ; <-- REASIGNA/ABORTA el trabajo de cada Pal
+0x07F4  call 0x142F2EF60(r15, 5, 4, r9b)        ; evento en el guild   (r12b-gated arriba)
+0x080A  call 0x140B3A630(this+0x270, &x)        ; multicast delegate (OnRecipeChanged?)
+0x0820  call 0x140B3A630(this+0x240, &this)     ; multicast delegate
+0x08A2  ret
```

**Conclusión:** existe una secuencia interna clara. Si `r12b == true`, el juego
hace **exactamente**: escribe los 4 campos + `0x2ECE4F0` + `0x2EB3510` + cadena de
worker director + bucle `0x2A71BF0` por Pal + 2 delegates. Sin jugador, sin guild
match. Esa es la ruta candidata de tu #3.

---

## 2. `r12b` — un nivel más

```
r15  = 0x2EA97D0(this)                 ; "objA"
       -> itera con un predicado lambda (par de fn-ptrs @ 0x140B22020 / 0x140B23DA0)
          vía helper 0x2EB3900 ; devuelve el objeto encontrado o 0
0x2F2D830(objA, &outObj):
       outObj = *(objA + 0x78)          ; sub-objeto en objA+0x78
       return (outObj valido y no-garbage)
r12b = 0x2F2D830(...) && ((*outObj)->vtable[+0x2B8])()   ; virtual sobre outObj
```

`0x2F2D830` es trivial: sólo lee `objA+0x78` y valida. Todo depende de:
- **qué clase busca `0x2EA97D0`** (necesito el tipo — el par de fn-ptrs es un
  `TFunctionRef` predicate, no un `UClass*`; el helper es `0x2EB3900`)
- **qué es `objA+0x78`**
- **el método virtual en `vtable+0x2B8`** de la clase de `objA+0x78`

Si eso resulta ser algo como "hay un `APalPlayerCharacter` en la base y
`->IsBuildEnabled()`", entonces `r12b` NO nos sirve offline. Si es
"`this->GetBaseCampModel()` y `->IsServerControlled()`" o un flag de estación,
sí. **¿Puedes identificar `0x2EA97D0` / `0x2EB3900` / la vtable de `objA+0x78`?**

---

## 3. Gate 1 (`0x31B0D30` @ +0x32)

Disasm: es un getter simple con validación de UObject-array + un check
`[obj+0x150] == 3` (`80 BB 50 01 00 00 03` → `cmp byte [rbx+0x150], 3`). Devuelve
bool. `[this+0x150] == 3` parece un enum de estado/net-mode/tipo. Pasa en el server
real (probamos: con jugador conectado todo el flujo corre). No creo que sea el
bloqueo. (Volcado completo en §5.)

---

## 4. Fixes de código aplicados (tu review) — commit `a3f8312`

1. **`native_tick` ya no da falso positivo.** Ahora: snapshot de la estación
   ANTES; tras `status=called`, re-lee `CurrentRecipeId` + `RequestedProductNum` y
   verifica que cambiaron a lo esperado. Si no → `soft=true`
   (`waiting-for-connected-player`), conserva la orden. (`bridge` sigue devolviendo
   `called` = sólo "ProcessEvent regresó"; la verdad la pone Lua.)
2. **`discovery.connected_player_id()`** nuevo: RequestPlayerId SÓLO de un
   `PalPlayerController` vivo (pawn poseído / NetConnection). El path native no
   arma la llamada sin uno → la orden espera en cola.
3. **Borré `acting_pid()` y `data/last-pid.txt`.** Un id persistido/offline no
   sirve para `ChangeRecipe_ServerInternal`.
4. El path replay también verifica; `scan_cycle` sólo hace native-flush si hay
   jugador conectado.
5. Docs: "no player needed" → "needs a player online (AFK ok)"; el SHA es
   advisory (`sha-path:match/unverified`), **no** auto-desactiva; corregido en
   `native/README.md`.

---

## 5. Volcados crudos

### `0x31B0D30` (512B)
```
4883EC284885C97467F7410800000060755E48895C2420E8E42AC201488BD84885C07440E8775962FF488B53104C8D4030486340383B42387F2A488BC8488B42304C3904C8751DF7430800000060751480BB5001000003488B5C24200F94C04883C428C3488B5C242032C04883C428C332C04883C428C3CCCCCCCCCCCCCCCCCC48895C2408574883EC20488BFA488BD9E8CBF5CD0184C0757033D2488BCBE80D37C201488BD84885C0745EE8C00079FF488B53104C8D4030486340383B42387F48488BC8488B42304C3904C8753BF74308000000607532488BCBE81197E8FF8B500C8B4808334F0833570C0BD18B4804334F048B000BD133070BD00F94C0488B5C24304883C4205FC3488B5C243032C04883C4205FC3
```

### `0x2EA97D0` (objA getter, 448B)
```
40534883EC70488BD9E892759DFF4889842490000000488D542430488D84249000000048C7842488000000000000004889442420488BCB488D84248800000048C7442440000000004889442428488D054CEF1D030F104424204889442450488D053B5B000048894424300F11442458E8BCA00000488B9C24880000004885DB7429E81A759DFF488B4B104883C030486350083B51387F13488B4930483904D17509488BC34883C4705BC333C04883C4705BC3
```

### `0x2F2D830` (r12b pred #1, 128B)
```
488B41784885C07418F7400800000060750F488902F7400800000060750AB001C348C7020000000032C0C3
```

### `0x142EAF370` (predicado lambda de la búsqueda, 160B)
```
4C8B024C8BC94D85C0743541F7400800000060752B488B01498B50104C8B10496342384983C2303B42387F14488BC8488B42304C3914C87507498B41084C8900498B4108488B084885C9740CF74108000000607503B001C332C0C3
```

### `0x2EB0850` cola de `0x2EB03F0` (1800B, cubre +0x460 .. +0x8A2/ret + funciones vecinas)
```
4C8D442440488D55B8488BCBE8BFA5F9FF488B5424584863442460488D0C404C8D148A4C8B4C2470493BD274664863442478488D0C404D8D0489660F1F440000488B02498BC94D3BC874130F1F44000048390174284883C10C493BC875F24D85C97409498BC9E845FE3E00904885F60F8460030000488BCEE9520300004885C974DC8B42083941087CD44883C20C493BD275AD4D85C97409498BC9E810FE3E00904885F67409488BCEE802FE3E009033F60FB6BD780100004084FF741D4584E475184C8D442430498BD7488BCBE89E380C0084C00F84FB0200000F284424300F1183BC020000488B8560010000488983900200004489AB9C0200000FB685700100008883190300004489AB98020000488BCBE829282E00488D93B0000000488BC8E87A060600488D95B0000000488BC8E88BAD08004D85FF74204084FF751B4584E4751641B1014C8D4580488D95B0000000498BCFE896FD0500488BCBE83EDB010081BB9C02000000000080742783BB9002000000750983BB940200000074154C8D4D804C8D45B8488D542458488BCBE82B2B00000F57C033C00F1145D00F1145E0488945F0488D45D04889442450C645D000488975D848C745E00000000048C745E800000000C745F000000101C645F4018975F8C645FC00C74500000080BF0F57F648C7450400000000488B83100200004885C07409F74008000000607408488BCBE8E850BDFF488BC8E850D40E00488BF8488D55D0488BC8E841383500C645FC02F30F104534F30F5E83B8020000F30F114500488D55D0488BCFE86F773600488BCBE817DE01004885FF7461E82DB9BAFF488B57104C8D4030496340083B42387F4B488BC8488B42304C3904C8753E488BCFE8773C3600488BCFE8DF76360081BB9C020000000000807417488BCFE82BA23500660F6EB39C0200000F5BF6F30F59F00F28CE488BCFE8118C3600488BCBE8F999000084C0740D488BCBE8BD6A0100E9B100000083BB3802000000741C488B8B300200004885C97410488B014C8D05796BD305488BD3FF5050488BCBE8CB8BFFFF488BF04885C07410488BC8E82BB10400488BCEE84359030033C048894424404889442448488D542440488BCFE8EAB935004863442448488B7C2440488D34C7483BFE74320F1F8000000000488B0F4885C97415F7410800000060750C488B8928060000E84310BCFF4883C708483BFE75DA488B7C24404885FF7409488BCFE838FB3E00904D85FF741B80BB1903000000410F94C141B004BA05000000498BCFE877E30700C644242000488D8B70020000488D542420E8319AC8FD48895C2450488D8B40020000488D542450E81B9AC8FD90488B4DD84885C97406E8DCFA3E0090488B4DB84885C97406E8CDFA3E0090488B4C24584885C97406E8BDFA3E0090488B8D900000004885C97406E8ABFA3E0090488D0523FF330348894520488B4DA04885C97406E891FA3E0090488B9C24680200000F28B424000200004881C410020000415F415E415D415C5F5E5DC3
```

Pido: identifica `0x2EA97D0` / `0x2EB3900` / `objA+0x78` / vtable[+0x2B8], y de la
cola cuál de {`0x2ECE4F0`, `0x2EB3510`, `0x2EA9710`, `0x2A71BF0`} es la que hay que
llamar (con qué args) para "set receta + reasignar Pals" sin jugador. ¿O existe una
variante usada al cargar el save?
