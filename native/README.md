# PalCommand native bridge

A C++ DLL that dispatches `ChangeRecipe_ServerInternal` from a game-thread hook,
so PalCommand can place craft orders without a player having to craft first.

**Needs one player connected.** `ChangeRecipe_ServerInternal` is a silent no-op
when nobody is online, so the native backend requires **at least one connected
player** — anyone, AFK, never has to craft. Orders queue until someone connects,
then flush automatically. (Zero-player autonomy is a separate, later goal; the
disassembly notes are in `notes/para-codex-03.md` … `para-codex-07.md`.)

Everything else (station discovery, inventory, the order queue, standing rules,
the cloud/app layer) stays in Lua. This DLL is an optional drop-in: install it and
`PalCommand` switches from the `replay` backend to `native`.

## Why this is safe

* **No RE-UE4SS source, no UEPseudo, no Epic account.** It resolves the 3 UE4SS
  exports it needs (`ProcessEvent`, `RegisterPreHook`, `UnregisterHook`) by
  mangled name via `GetProcAddress` from the already-loaded `UE4SS.dll`. (Verified
  against the server's build, `ba2efd55`; `CppUserModBase` ctor/dtor are resolved
  too as a sanity check but are optional.)
* **Built with MSVC** so `std::function` is ABI-identical to UE4SS's — no faked
  STL layout.
* **Fails closed on a bad build.** If those exports don't resolve, `start_mod`
  writes `data/native-status.ini` `state=disabled` and does nothing. The build SHA
  is **advisory only** — it is reported in the status file (`sha-path:match` /
  `unverified`) but does not gate execution. `start_mod` pins the DLL and returns
  `nullptr` (it is not a real `CppUserModBase`); the worker thread + on-demand
  pre-hook do all the work.
* **Reads, never frees.** `ProcessEvent` deep-copies the parameter block into its
  own frame (`CopyCompleteValue`) and destroys only that copy, so pointing the
  archive's array header at a local buffer is safe.
* **Layout from Lua.** Parameter offsets come from live reflection on the Lua
  side, never hard-coded here — a Palworld layout change is a Lua-only fix.
* **Game thread only.** `ProcessEvent` runs inside a pre-hook on
  `GetCurrentRecipeId`, which always fires on the game thread.

## Build

### CI (recommended)

Push the repo; `.github/workflows/native-build.yml` builds it on `windows-latest`
and uploads `PalCommand-native-dll` (contains `PalCommand/dlls/main.dll`).

### Local (Windows + MSVC)

```bat
native\build.bat            rem targets UE4SS ba2efd55
native\build.bat <sha>      rem target a different build
```

### Local (macOS/Linux cross-compile)

`clang-cl` + [`xwin`](https://github.com/Jake-Shadle/xwin) for the MSVC CRT:

```bash
xwin --accept-license splat --output /tmp/xwin
clang-cl --target=x86_64-pc-windows-msvc /LD /EHsc /std:c++17 /MD \
  /imsvc /tmp/xwin/crt/include /imsvc /tmp/xwin/sdk/include/ucrt \
  /imsvc /tmp/xwin/sdk/include/um /imsvc /tmp/xwin/sdk/include/shared \
  -DPALCOMMAND_UE4SS_SHA=\"ba2efd55\" \
  native/src/bridge.cpp -Fe:out/main.dll \
  -link -libpath:/tmp/xwin/crt/lib/x64 -libpath:/tmp/xwin/sdk/lib/ucrt/x64 \
  -libpath:/tmp/xwin/sdk/lib/um/x64 kernel32.lib user32.lib
```

## Install

```
<server>\Pal\Binaries\Win64\ue4ss\Mods\PalCommand\
  dlls\main.dll          <- this build
  enabled.txt
  Scripts\*.lua          <- the Lua mod
```

Restart the server. `data/native-status.ini` should read `state=ready`.

## IPC contract (`data/native-*.ini`)

Lua writes `native-request.ini`:

```ini
[request]
complete=1
request_id=<monotonic>
operation=call            ; or "arm" / "cancel"
trigger_function=<hex addr of PalMapObjectConvertItemModel:GetCurrentRecipeId>
station=<hex addr of the target station UObject>
target_function=<hex addr of ChangeRecipe_ServerInternal UFunction>
player_id=<int32 net id>
player_offset=0
archive_offset=8
bytes_offset=0
params_size=24
archive_hex=0E0000005000...01
```

Lua then calls `station:GetCurrentRecipeId()` to fire the hook. The bridge writes
`native-response.ini` with `status=called` / `status=error` and `detail=...`.
