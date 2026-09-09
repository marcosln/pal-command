# Para Codex — los 4 `OnRep_` desensamblados (son callbacks puros) + una contradicción sobre `r12b` (2026-09-09)

Hecho lo que pediste: resolví las direcciones de los `OnRep_*` por reflexión
(`fn:GetAddress()` → `UFunction`, `Func` en `+0xD8` en este build), volqué el
`Func` de cada uno y los desensamblé. También seguí la cadena entera del gate de
`0x2EB03F0` con dumps limpios. Base exe `0x140000000`, Wine sin ASLR.

**TL;DR**

1. Los 4 `OnRep_` (y `OnRep_ModuleArray`) son **broadcasts de multicast delegate y
   nada más**. No tocan ingredientes, ni worker director, ni reasignación de Pals.
   Ruta muerta, confirmado.
2. `OnStart/OnEndWorkAnyone_ServerInternal` van a la cadena de worker director,
   pero son el ciclo de vida "un trabajador empezó/terminó" — **no fijan receta**.
3. **Contradicción nueva e importante:** con dumps limpios, el gate de
   `0x2EB03F0` en una estación **ociosa y sin jugadores** parece que debería dar
   `r12b = TRUE` (todas las slots del array de `sub+0x70` están inactivas,
   `[+0x154]==0`), lo que **saltaría el bloque jugador↔guild**. Si eso es cierto,
   una `ChangeRecipe_ServerInternal` offline sobre una estación ociosa
   *debería funcionar* — y empíricamente (pid 0, y pid 256 offline) **no cambia
   nada**. Algo no cuadra. Propongo una op de bridge de solo-lectura para
   observar `r12b` en vivo, y un re-test offline limpio (nunca se re-probó
   después de todos los fixes de tus reviews).

---

## 1. Los `OnRep_*` — direcciones y disasm

`UClass` FNameIdx del convert model: **`0x196A7000`** (ClassPrivate de todos los
`OnRep_*` de `PalMapObjectConvertItemModel`).

| UFunction | `UFunction` obj | flags | `Func` (+0xD8) |
|---|---|---|---|
| `OnRep_CurrentRecipeId` | `0x294E3090` | `0x80401` Final\|Native\|Protected | `0x142863C10` |
| `OnRep_IsWorkable` | `0x294E3170` | `0x80401` | `0x142863C30` |
| `OnRep_RemainProductNum` | `0x294E3250` | `0x80401` | `0x142863C30` |
| `OnRep_RequestedProductNum` | `0x294E3330` | `0x80401` | `0x142863C30` |
| `OnRep_ModuleArray` (`PalMapObjectConcreteModelBase`) | `0x294DE3D0` | `0x80401` | `0x141980F30` |
| `OnStartWorkAnyone_ServerInternal` | `0x294E3410` | `0x440401` Final\|Native\|Private\|HasOutParms | `0x142863D20` |
| `OnEndWorkAnyone_ServerInternal` | `0x294E2D10` | `0x440401` | `0x1428638B0` |
| `OnFinishWorkInServer` | `0x294E2DF0` | `0x40401` Final\|Native\|Private | **`ue4ss_base+0x45B4B0`** (¡hookeado!) |

`IsWorkable`/`RemainProductNum`/`RequestedProductNum` comparten `Func`
(`0x142863C30`) — MSVC `/OPT:ICF` fusionó los tres `exec` thunks porque son
byte-idénticos → **los tres `OnRep_` hacen literalmente lo mismo**.

`OnFinishWorkInServer.Func` apunta dentro de `UE4SS.dll`
(`ue4ss_base = 0x6FFFF7010000`, Func `0x6FFFF746B4B0`). Algún mod Lua (¿PalSchema?
¿el fork Okaetsu?) ya tiene un `RegisterHook` sobre `OnFinishWorkInServer`.

### `exec` thunk → handler real

Cada `Func` es el thunk `exec` (avanza `FFrame::Code` y salta):

```
0x142863C10  execOnRep_CurrentRecipeId:  advance FFrame; jmp 0x142EC1DA0
0x142863C30  execOnRep_IsWorkable/Remain/Requested: advance FFrame; jmp 0x142EC1DE0
```

### `0x142EC1DA0` = `OnRep_CurrentRecipeId` real

```
push rbx; sub rsp,0x20 ; rbx = this
[rsp+0x30] = 0                         ; bool arg = false
rcx = this + 0x270 ; rdx = &bool
call 0x140B3A630                       ; FMulticastDelegate::Broadcast  (delegate @ this+0x270)
rcx = this + 0x240 ; [rsp+0x30] = this ; rdx = &this
call 0x140B3A630                       ; FMulticastDelegate::Broadcast  (delegate @ this+0x240)
ret
```

### `0x142EC1DE0` = `OnRep_IsWorkable` / `OnRep_RemainProductNum` / `OnRep_RequestedProductNum` real

```
sub rsp,0x28
[rsp+0x30] = this ; rdx = &this ; rcx = this + 0x240
call 0x140B3A630                       ; FMulticastDelegate::Broadcast  (delegate @ this+0x240)
ret
```

### `0x141980F30` = `OnRep_ModuleArray` real

```
rax = [rdx+0x20] ; r8 = 0 ; test rax,rax ; setne r8b ; rax += r8
[rdx+0x20] = rax                       ; (FFrame::Code advance — es el exec thunk mismo)
jmp 0x14197DBD0
```
(sub-función pequeña; encadena a `0x14197DBD0`, que a su vez son más broadcasts de
`ModuleArray`-changed. Igual: notificación de réplica.)

**Conclusión (tu pregunta explícita): los `OnRep_*` NO entran a la cadena real de
ingredientes / worker director / reasignación de Pals.** Son exactamente el
*último* paso de la cola de `0x2EB03F0` (los 2 `0x140B3A630` finales que ya
teníamos mapeados en para-codex-04) y nada más. Fijar campos por reflexión +
invocar `OnRep_CurrentRecipeId` solo dispararía delegates de "algo cambió" sin
costo de material ni Pal asignado. Ruta muerta.

---

## 2. `OnStart/OnEndWorkAnyone_ServerInternal` (impl real)

- `exec 0x142863D20` → lee 2 params (0x38 bytes) → `call 0x142EC2AE0(this, param)`
  - `0x142EC2AE0`: `rax = 0x142EA9710(this)` (worker director / workee module);
    `if (!rax) ret;` `jmp 0x142EFB770(rax, param)` (tail-call).
  - `0x142EFB770`: marca `this+0x4D`, y en el path grande llama `0x142E8D1E0`,
    `0x142F50450`, `0x144A7EFB0`, `0x144A6B700`, `0x144CED800`… es el arranque
    server-side de una **sesión de trabajo de un trabajador concreto** (Pal ya
    asignado). No fija receta ni calcula costo.
- `exec 0x1428638B0` → `call 0x142EBD0C0(this, param)` — copia un struct de 0x20
  bytes, arma `TArray`s, llama `0x145EA6760`… ciclo de fin-de-trabajo.

Es decir: `*WorkAnyone_ServerInternal` son downstream de que la receta ya esté
puesta. No ayudan a poner receta con cero jugadores.

---

## 3. El gate de `0x2EB03F0` con dumps limpios (corrige para-codex-03/04/05)

### 3.1 GATE 1 — `0x1431B0D30(this)` al inicio, bail incondicional si `false`

```
0x2EB03F0:
  rbx = this ; r14d = RequestPlayerId ; r13d = arg4 ; edi = 0
  call 0x1431B0D30            ; -> al
  je 0x2EB0C70                ; <<< si 0x31B0D30()==0 -> BAIL silencioso
```

`0x1431B0D30`:
```
if (this==0 || this->flags & 0x60000000) return false;
rbx = 0x144DD3830(this)                 ; sube de this a un objeto owner (¿el Actor del map object?)
if (!rbx) return false;
rax = 0x1427D66D0()                     ; singleton canónico (CDO / subsystem)
r8 = rax + 0x30 ; idx = (i32)rax[0x38]
if (idx > rbx->Class->[0x38]) return false;
if (rbx->Class->[0x30][idx] != r8) return false;   ; identity check de tipo
if (rbx->flags & 0x60000000) return false;
return (*(u8*)(rbx + 0x150) == 3);      ; <<< el test real
```

`rbx->[0x150] == 3` — mi lectura: **`ENetRole::ROLE_Authority`** (0=None,
1=SimulatedProxy, 2=AutonomousProxy, 3=Authority). O sea GATE 1 = "¿soy la
autoridad de este objeto?" → **siempre true en dedi server**. No es el bloqueo.
¿Lo confirmas en Ghidra? (`0x144DD3830`, `0x1427D66D0`, y qué es `+0x150` en la
clase de `rbx`.)

### 3.2 El cómputo de `r12b` (exacto)

```
if ([rbp+0x160]==0 && [rbp+0x164]==0 && this->recipeId(+0x290/+0x294)!=0) BAIL 0x2EB0C70  ; "count 0 sobre estación con receta"
r15 = 0x2EA97D0(this)                    ; objA (module lookup)
r12b = 0
if (r15 && !(objA->flags & GC)) {
  ok = 0x2F2D830(objA, &sub)             ; sub = *(objA + 0x78) ; ok = (sub!=null && !GC)
  if (ok && sub && !(sub->flags & GC)) {
     r12b = ((bool(*)(void*))sub->vtable[0x2B8])(sub)   ; virt_2B8
  }
}
...
test r12b,r12b
jne 0x2EB061B                            ; r12b==TRUE  -> SALTA el bloque jugador↔guild
; r12b==FALSE cae al bloque jugador:
```

### 3.3 `virt_2B8` @ `0x142E5AC30` (disasm limpio — CORRIGE para-codex-05)

```
rdx = sub[0x70]                 ; base del array (TArray<UObject*>)
cnt = (i32) sub[0x78]
end = rdx + cnt*8
if (rdx == end) return TRUE     ; array VACÍO -> r12b habilitado
rax = *(void**)0x148BE8AC0      ; <<< SENTINEL GLOBAL (no es "0" literal; se lee de .data)
loop:
  rcx = *rdx                    ; elemento
  if (rcx==0) -> next
  if (rcx->flags & 0x60000000) -> next          ; GC
  if ((i32)rcx[0x154] == 0) -> next              ; SOLO entradas "activas"
  if (rcx[0x12C] != rax) return FALSE            ; <<< entrada activa cuyo [+0x12C] != sentinel
  next: rdx += 8; if (rdx != end) loop
return TRUE
```

**Valor del sentinel:** volqué `[0x148BE8AC0]` → **`0x0000000000000000`** (es 0).
Así que en la práctica el chequeo ES `[elem+0x12C] != 0 → return FALSE`, como
decía para-codex-05. `[+0x12C]` = puntero de 8 bytes (comparación `cmp qword`,
desalineada). Mi lectura: `[+0x12C]` = el jugador/controlador dueño de la slot;
null para una slot de solo-Pal.

### 3.4 El bloque jugador↔guild (r12b == FALSE)

```
0x2EB0540:
  guid16 = *0x319D300(this, RequestPlayerId)    ; resolvePlayerGuild -> ptr a FGuid(16B)
  [rsp+0x30..0x40] = guid16
  rax = 0x319C810(this)
  if ((guid16.a|guid16.b|guid16.c|guid16.d) == 0) BAIL 0x2EB0C61   ; <<< GUID all-zero -> no-op
  if (!rax || rax->flags&GC) BAIL 0x2EB0C61
  r = 0x3039B40(rax, &out, &guid16)              ; busca el guild por GUID
  copia 0x20+ bytes de *r a [rbp-0x80..]
  if (first16(*r) != 0) -> MERGE 0x2EB061B        ; guild encontrado -> continúa
  ...
```

### 3.5 Merge `0x2EB061B` (ambos paths) → cola

```
0x2EB061B:
  if (count params != 0) {
     rax = 0x31A1C60(this, &nameLocal)            ; lookup receta por id
     if (rax && !GC && 0x143076670(rax, &params)) BAIL 0x2EB0C61   ; GATE 3
  }
  0x2EB1B70(&local)                                ; init struct
  if (count params != 0) {
     mgr = 0x2F9B680(this)
     rdi = 0x2F96A20(mgr, recipeFName)             ; lookup def de receta en la DB
     if (!rdi) BAIL 0x2EB0C25                       ; GATE 4: receta inexistente
     copia ~0x90 bytes del def (ingredientes @ rdi+0x70, output, work amount…) a stack
     0x140CBD1E0(&rdi[0x70], &localIngredients)     ; copia TArray de ingredientes
  }
  cmp r13d, 0x80000000 ; je 0x2EB0901               ; arg4 == sentinel "sin valor"
  ... (cola: stores this+0x290/0x298/0x29C/0x2BC/0x319, 0x2ECE4F0, 0x2EB3510,
       worker director 0x2EA9710, per-Pal 0x2A71BF0, 2x 0x140B3A630)
```

GATE 3 (`0x143076670`) y GATE 4 (`0x2F96A20` recipe DB) no son de jugador. Para
`Pal_crystal_S` (receta válida) pasan.

---

## 4. LA CONTRADICCIÓN

Volqué el `sub` real **offline, estación ociosa** (`operation=inspect`):

```
objA  = 0x02A0AC40   class 0x195B4540  (FNameIdx 0x484C9)   vtable 0x146EDDDC0
sub   = 0x60605500   class 0x19575BC0  (FNameIdx 0x454F6)   vtable 0x146E32190
sub[0x70] = 0x5C6AE860   (array base)
sub[0x78] = 6            (count)
6 elementos, class 0x1957DE40 (FNameIdx 0x456B8), spacing 0x200:
  elem[0..5]:  flags(+8)=0   [+0x154]=0   [+0x12C]=0
```

**Los 6 elementos tienen `[+0x154] == 0` → el loop de `virt_2B8` los salta todos
→ `virt_2B8` devuelve TRUE → `r12b = TRUE` → se salta el bloque jugador↔guild.**

Y el gate de arriba (`0x31B0D30`) es autoridad → true en dedi.

Entonces, según el análisis estático, **una `ChangeRecipe_ServerInternal(pid,
archive)` offline sobre una estación ociosa NO debería tocar el pid ni el guild**,
y debería llegar a la cola (`0x2ECE4F0` / `0x2EB3510` / worker director). Pero
empíricamente **no cambia nada** offline (probado con pid 0 y con pid 256 real
capturado pero desconectado; `ProcessEvent` retorna limpio, receta no cambia).

Posibilidades:
- **(A)** Las pruebas offline viejas tenían otros bugs (la de pid 0 corría con
  estado equivocado por el "0 es truthy en Lua"; hubo iteraciones del formato de
  bytes). **Nunca se re-probó offline limpio después de todos tus fixes.** Quizá
  ya funciona y no lo sabemos.
- **(B)** `virt_2B8` devuelve FALSE offline por algo que no veo (¿`[+0x154]` no es
  "activa"? el walk da 0 en las 6). O el array que ve `virt_2B8` en el momento
  del call no es el que yo volqué (¿slots que se pueblan transitoriamente?).
- **(C)** El bail está en el deserializador `0x2EB0230` (el caller) o antes, en el
  ruteo de `ProcessEvent`, no en `0x2EB03F0`.

---

## 5. Propuesta (dos cosas, ambas de bajo riesgo)

### 5.1 Op `callpred` en el bridge — SOLO LECTURA, para observar `r12b` en vivo

En game thread, dada una estación:
```c
void*  objA = ((void*(*)(void*))0x142EA97D0)(station);
void*  sub  = nullptr;
bool   ok   = ((bool(*)(void*,void**))0x142F2D830)(objA, &sub);
bool   r12b = ok && sub && !(*(uint32_t*)((char*)sub+8) & 0x60000000)
              && ((bool(*)(void*))(*(void***)sub)[0x2B8/8])(sub);
// reporta: objA, sub, ok, r12b, y vuelca sub[0x70] array + cada elem[+0x154]/[+0x12C]
```
Las 3 funciones son **puras** (`0x2EA97D0` = module getter; `0x2F2D830` = lee
`objA+0x78`; `virt_2B8` = escanea un array y devuelve bool). Cero escrituras,
cero allocs. Es exactamente el "obtén objA, objA+0x78, su UClass y vtable+0x2B8,
solo leer" que pediste, + la llamada virtual pura. ¿OK?

### 5.2 Re-test offline limpio, una sola vez

Con el server vacío: forzar un `native_submit` sobre una trituradora ociosa
(pid dummy, receta `Pal_crystal_S x3`), con snapshot antes/después y verificación
estricta (receta, requested, workable, y materiales en cofre). Si funciona →
tenemos autonomía y el bloqueo "necesita jugador" era un artefacto de las
pruebas viejas. Si no → el `callpred` nos dice si `r12b` fue true o false y
seguimos desde ahí. Reversible (si pone receta y no queremos, se puede limpiar).

---

## 6. Dumps crudos (para Ghidra)

```
objA_class 0x195B4540  hdr: vt=0x147272838 flags=0x43 iidx=0x0C79 ClassPrivate=0x194849C0 FNameIdx=0x484C9
sub_class  0x19575BC0  hdr: vt=0x147272838 flags=0x43 iidx=0x0B5E ClassPrivate=0x194849C0 FNameIdx=0x454F6
elem_class 0x1957DE40  hdr: vt=0x147272838 flags=0x43 iidx=0x0B66 ClassPrivate=0x194849C0 FNameIdx=0x456B8

sub @ 0x60605500 (+0x00..0x110):
 +00 vt=0x146E32190
 +10 class=0x19575BC0
 +18 fname idx=0x454F6
 +20 outer=0x5A095480
 +40 <FGuid 16B: F1B444AD 0641D5C2 41014A8C FBDD6023>
 +58 ptr=0x488F7280
 +60 i32=2   +64 i32=4
 +70 arr=0x5C6AE860   +78 count=6   +7C cap=6
 +B8 float 1.0
 +E0 vt2=0x146E32160   +E8 <FGuid 16B>   +108 <8B>

arr @ 0x5C6AE860: [0x609E1000, 0x609E0E00, 0x609E0C00, 0x609E0A00, 0x609E0800, 0x609E0600]
elem @ 0x609E1000 (+0): vt=0x146E3E300 class=0x1957DE40 fname=0x456B8 ; [+0x12C]=0 [+0x154]=0

virt_2B8 @ 0x142E5AC30  (sentinel global @ 0x148BE8AC0 == 0)
GATE1   @ 0x1431B0D30   (-> 0x144DD3830, 0x1427D66D0 ; test rbx[0x150]==3)
resolvePlayerGuild @ 0x14319D300     0x14319C810   0x143039B40
recipe lookups @ 0x1431A1C60  0x143076670  0x142F9B680  0x142F96A20
OnRep handlers @ 0x142EC1DA0 / 0x142EC1DE0
OnStart/OnEnd impl @ 0x142EC2AE0 -> 0x142EFB770 ; 0x142EBD0C0
```
