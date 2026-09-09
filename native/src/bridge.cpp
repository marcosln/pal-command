// PalCommand native bridge -- the one operation UE4SS-Lua cannot do (issue #378):
// construct an FPalNetArchive parameter and dispatch a UFunction with it.
//
// Design
// ------
//   * Loaded by UE4SS as a C++ mod (PalCommand/dlls/main.dll).
//   * Resolves the handful of UE4SS.dll exports it needs by *mangled name* via
//     GetProcAddress -- no linking against UE4SS, no RE-UE4SS source tree, no
//     UEPseudo, no Epic account. Built with MSVC / clang-cl so std::function is
//     ABI-identical to the one UE4SS.dll expects.
//   * Verifies it is running against the exact UE4SS build it was written for
//     (SHA in the DLL path). On any mismatch it disables itself and does nothing.
//   * A background thread polls a request file written by the Lua side. A pre-hook
//     on a harmless getter (PalMapObjectConvertItemModel:GetCurrentRecipeId) gives
//     us a callback that always runs on the game thread; that is where we build
//     the parameter frame and call ProcessEvent.
//   * Parameter offsets are supplied by the Lua side (from live reflection), never
//     hard-coded, so a Palworld layout change is a Lua-only fix.
//
// Memory: ProcessEvent deep-copies the parameter block (CopyCompleteValue) into
// its own frame before invoking and destroys only that copy, so pointing the
// archive's FScriptArray at a local buffer is safe -- UE never frees it.

#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <cstdint>
#include <cstring>
#include <cstdio>
#include <atomic>
#include <functional>
#include <string>

// ---------------------------------------------------------------- config

#ifndef PALCOMMAND_UE4SS_SHA
#define PALCOMMAND_UE4SS_SHA "ba2efd55"   // advisory: reported in status, never a hard gate
#endif
#define PALCOMMAND_BRIDGE_VERSION 2

static constexpr uint32_t kMaxArchiveBytes = 512;
static constexpr uint32_t kMaxParamsBytes  = 256;
// Idle poll cadence. Kept slow: heavy INI polling on the Wine/overlay filesystem
// was starving the game thread's save/join I/O. Native orders tolerate ~1s latency
// (the Lua side pokes on a 650ms timer anyway).
static constexpr DWORD    kPollIntervalMs  = 120;

// ---------------------------------------------------------------- UE4SS ABI

// Opaque; we never dereference it. Only needed so the std::function signature
// matches the one UE4SS.dll was compiled with (type-erased, so layout is the
// same regardless, but keep it honest).
namespace RC::Unreal { class UnrealScriptFunctionCallableContext; }
using CallableContext = RC::Unreal::UnrealScriptFunctionCallableContext;
using HookCallback = std::function<void(CallableContext&, void*)>;

using Fn_CppUserModCtor  = void (*)(void* self);
using Fn_CppUserModDtor  = void (*)(void* self);
using Fn_ProcessEvent    = void (*)(void* object, void* function, void* params);
using Fn_RegisterPreHook  = int  (*)(void* ufunction, const HookCallback& cb, void* custom_data);
using Fn_UnregisterHook  = bool (*)(void* ufunction, int callback_id);

// TArray's header: { data ptr, int32 num, int32 max }. 16 bytes on x64.
struct FScriptArrayHeader {
    void*   data;
    int32_t num;
    int32_t max;
};

// mangled names verified against UE4SS.dll (SHA ba2efd55) export table
static const char* kSym_Ctor           = "??0CppUserModBase@RC@@QEAA@XZ";
static const char* kSym_Dtor           = "??1CppUserModBase@RC@@UEAA@XZ";
static const char* kSym_ProcessEvent   = "?ProcessEvent@UObject@Unreal@RC@@QEAAXPEAVUFunction@23@PEAX@Z";
static const char* kSym_RegisterPreHook = "?RegisterPreHook@UFunction@Unreal@RC@@QEAAHAEBV?$function@$$A6AXAEAVUnrealScriptFunctionCallableContext@Unreal@RC@@PEAX@Z@std@@PEAX@Z";
static const char* kSym_UnregisterHook = "?UnregisterHook@UFunction@Unreal@RC@@QEAA_NH@Z";

// ---------------------------------------------------------------- globals

static HMODULE            g_module = nullptr;
static HMODULE            g_ue4ss = nullptr;
static void*              g_mod_object = nullptr;
static char               g_resolve_detail[256] = "not-run";
static Fn_CppUserModDtor  g_dtor = nullptr;
static Fn_ProcessEvent    g_process_event = nullptr;
static Fn_RegisterPreHook g_register_pre_hook = nullptr;
static Fn_UnregisterHook  g_unregister_hook = nullptr;

static HANDLE             g_stop_event = nullptr;
static HANDLE             g_worker = nullptr;
static CRITICAL_SECTION   g_lock;
static bool               g_lock_ready = false;

static wchar_t            g_root[MAX_PATH * 2];
static wchar_t            g_request_path[MAX_PATH * 2];
static wchar_t            g_response_path[MAX_PATH * 2];
static wchar_t            g_status_path[MAX_PATH * 2];

static void*              g_trigger_fn = nullptr;
static int                g_trigger_id = -1;
static bool               g_trigger_hooked = false;

enum class PendingState { Idle, Armed, Executing, Done };

struct PendingCall {
    uint64_t request_id = 0;
    void*    station = nullptr;
    void*    function = nullptr;
    int32_t  player_id = 0;
    uint32_t player_offset = 0;
    uint32_t archive_offset = 0;
    uint32_t bytes_offset = 0;      // FScriptArray header offset within the struct
    uint32_t params_size = 0;
    uint32_t byte_count = 0;
    bool     is_inspect = false;    // read-only r12b-chain inspection, not a call
    void*    inspect_fn = nullptr;  // 0x2EA97D0 (objA getter) for the inspect op
    uint8_t  bytes[kMaxArchiveBytes] = {0};
};

// filled by an inspect op, read back from native-inspect.ini
static char g_inspect_result[512] = "";

static std::atomic<PendingState> g_pending_state{PendingState::Idle};
static PendingCall  g_pending;
static const char*  g_last_result = "none";
static uint64_t     g_last_seen_request = 0;

// instrumentation -- surfaced in native-status.ini so a stuck call is diagnosable
static std::atomic<uint32_t> g_arm_count{0};       // requests armed
static std::atomic<uint32_t> g_hook_fire_count{0}; // trigger pre-hook entered
static std::atomic<uint32_t> g_exec_count{0};      // execute_pending_on_game_thread ran to ProcessEvent
static std::atomic<int>      g_trigger_raw_id{-999};
static const char*           g_trigger_detail = "not-armed";

// ---------------------------------------------------------------- helpers

static bool append_child(wchar_t* dst, size_t cap, const wchar_t* root, const wchar_t* name) {
    int n = _snwprintf_s(dst, cap, _TRUNCATE, L"%ls\\%ls", root, name);
    return n > 0;
}

static bool init_paths() {
    DWORD len = GetModuleFileNameW(g_module, g_root, (DWORD)(sizeof(g_root) / sizeof(wchar_t)));
    if (len == 0 || len >= sizeof(g_root) / sizeof(wchar_t)) return false;
    // .../PalCommand/dlls/main.dll -> strip file, strip "dlls"
    wchar_t* p = wcsrchr(g_root, L'\\'); if (!p) return false; *p = 0;
    p = wcsrchr(g_root, L'\\'); if (!p) return false; *p = 0;
    return append_child(g_request_path, sizeof(g_request_path) / sizeof(wchar_t), g_root, L"data\\native-request.ini")
        && append_child(g_response_path, sizeof(g_response_path) / sizeof(wchar_t), g_root, L"data\\native-response.ini")
        && append_child(g_status_path, sizeof(g_status_path) / sizeof(wchar_t), g_root, L"data\\native-status.ini");
}

static void write_atomic(const wchar_t* path, const char* text) {
    wchar_t tmp[MAX_PATH * 2];
    _snwprintf_s(tmp, _TRUNCATE, L"%ls.tmp", path);
    // No WRITE_THROUGH / FlushFileBuffers: forcing a disk sync here (many times a
    // minute, on the Wine overlay fs) was part of what starved game-thread I/O.
    HANDLE h = CreateFileW(tmp, GENERIC_WRITE, FILE_SHARE_READ, nullptr, CREATE_ALWAYS,
                           FILE_ATTRIBUTE_NORMAL, nullptr);
    if (h == INVALID_HANDLE_VALUE) return;
    DWORD want = (DWORD)strlen(text), got = 0;
    bool ok = WriteFile(h, text, want, &got, nullptr) && got == want;
    CloseHandle(h);
    if (ok) MoveFileExW(tmp, path, MOVEFILE_REPLACE_EXISTING);
    else DeleteFileW(tmp);
}

static void write_status(const char* state, uint64_t rid, const char* detail) {
    char buf[640];
    _snprintf_s(buf, _TRUNCATE,
                "[bridge]\nversion=%d\nstate=%s\nrequest_id=%llu\nue4ss_sha=%s\ndetail=%s\n"
                "arms=%u\nhook_fires=%u\nexecs=%u\ntrigger_id=%d\ntrigger_detail=%s\npending=%d\n",
                PALCOMMAND_BRIDGE_VERSION, state, (unsigned long long)rid,
                PALCOMMAND_UE4SS_SHA, detail ? detail : "none",
                g_arm_count.load(), g_hook_fire_count.load(), g_exec_count.load(),
                g_trigger_raw_id.load(), g_trigger_detail,
                (int)g_pending_state.load());
    write_atomic(g_status_path, buf);
}

static void write_response(uint64_t rid, const char* status, const char* detail) {
    char buf[512];
    _snprintf_s(buf, _TRUNCATE,
                "[bridge]\nversion=%d\nrequest_id=%llu\nstatus=%s\ndetail=%s\n",
                PALCOMMAND_BRIDGE_VERSION, (unsigned long long)rid, status, detail ? detail : "none");
    write_atomic(g_response_path, buf);
}

static bool readable(const void* addr, size_t bytes) {
    if (!addr || !bytes) return false;
    MEMORY_BASIC_INFORMATION mbi;
    if (VirtualQuery(addr, &mbi, sizeof(mbi)) != sizeof(mbi)) return false;
    if (mbi.State != MEM_COMMIT) return false;
    if (mbi.Protect & (PAGE_GUARD | PAGE_NOACCESS)) return false;
    uintptr_t start = (uintptr_t)addr;
    uintptr_t end = (uintptr_t)mbi.BaseAddress + mbi.RegionSize;
    return start <= end && bytes <= end - start;
}

static bool dll_path_contains(HMODULE mod, const char* needle) {
    wchar_t path[MAX_PATH * 2];
    DWORD len = GetModuleFileNameW(mod, path, (DWORD)(sizeof(path) / sizeof(wchar_t)));
    if (len == 0) return false;
    char narrow[MAX_PATH * 2];
    int n = WideCharToMultiByte(CP_UTF8, 0, path, -1, narrow, sizeof(narrow), nullptr, nullptr);
    if (n <= 0) return false;
    return strstr(narrow, needle) != nullptr;
}

// ---------------------------------------------------------------- ini parse

static bool ini_str(const wchar_t* key, char* out, DWORD out_size) {
    wchar_t wide[1024];
    DWORD n = GetPrivateProfileStringW(L"request", key, L"", wide,
                                       (DWORD)(sizeof(wide) / sizeof(wchar_t)), g_request_path);
    if (n == 0 || n >= sizeof(wide) / sizeof(wchar_t) - 1) return false;
    return WideCharToMultiByte(CP_UTF8, 0, wide, -1, out, (int)out_size, nullptr, nullptr) > 0;
}

static uint64_t ini_u64(const wchar_t* key, int base, bool* ok) {
    char v[64];
    if (!ini_str(key, v, sizeof(v))) { *ok = false; return 0; }
    char* end = nullptr;
    unsigned long long r = _strtoui64(v, &end, base);
    *ok = end && *end == '\0' && end != v;
    return r;
}

static int64_t ini_i64(const wchar_t* key, bool* ok) {
    char v[64];
    if (!ini_str(key, v, sizeof(v))) { *ok = false; return 0; }
    char* end = nullptr;
    long long r = _strtoi64(v, &end, 10);
    *ok = end && *end == '\0' && end != v;
    return r;
}

static bool parse_hex(const char* hex, uint8_t* out, uint32_t* count) {
    size_t len = strlen(hex);
    if (len == 0 || (len & 1) || len > kMaxArchiveBytes * 2) return false;
    for (size_t i = 0; i < len / 2; ++i) {
        char pair[3] = { hex[2 * i], hex[2 * i + 1], 0 };
        char* end = nullptr;
        long v = strtol(pair, &end, 16);
        if (*end || v < 0 || v > 255) return false;
        out[i] = (uint8_t)v;
    }
    *count = (uint32_t)(len / 2);
    return true;
}

// ---------------------------------------------------------------- the game-thread callback

// SEH-guarded so a bad frame is reported, not a silent crash. Kept in its own
// leaf function (no C++ objects) so __try/__except is legal here.
static const char* invoke_process_event(void* obj, void* fn, void* params) {
    __try {
        g_process_event(obj, fn, params);
        return "process-event-returned";
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return "process-event-crashed";
    }
}

// Read-only: call the objA getter for `station`, then walk objA -> *(objA+0x78) ->
// vtable -> [vtable+0x2B8]. No state change. Fills g_inspect_result.
static const char* inspect_r12b_chain(void* station, void* get_objA) {
    __try {
        using Fn = void* (*)(void*);
        void* objA = ((Fn)get_objA)(station);
        uint64_t sub = 0, objA_cls = 0, sub_cls = 0, vt = 0, virt2b8 = 0;
        if (readable(objA, 0x80)) {
            objA_cls = *(uint64_t*)((uint8_t*)objA + 0x10);
            sub = *(uint64_t*)((uint8_t*)objA + 0x78);
        }
        if (readable((void*)sub, 0x2C0)) {
            sub_cls = *(uint64_t*)((uint8_t*)sub + 0x10);
            vt = *(uint64_t*)sub;
        }
        if (readable((void*)vt, 0x2C0)) virt2b8 = *(uint64_t*)((uint8_t*)vt + 0x2B8);
        _snprintf_s(g_inspect_result, _TRUNCATE,
                    "objA=%llX objA_class=%llX sub=%llX sub_class=%llX vtable=%llX virt_2B8=%llX",
                    (unsigned long long)(uintptr_t)objA, (unsigned long long)objA_cls,
                    (unsigned long long)sub, (unsigned long long)sub_cls,
                    (unsigned long long)vt, (unsigned long long)virt2b8);
        return "inspected";
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        _snprintf_s(g_inspect_result, _TRUNCATE, "inspect-faulted");
        return "inspect-crashed";
    }
}

static void execute_pending_on_game_thread() {
    PendingState expected = PendingState::Armed;
    if (!g_pending_state.compare_exchange_strong(expected, PendingState::Executing)) return;
    g_exec_count.fetch_add(1);

    PendingCall call;
    EnterCriticalSection(&g_lock);
    call = g_pending;
    LeaveCriticalSection(&g_lock);

    const char* result = "unknown";
    if (call.is_inspect) {
        result = inspect_r12b_chain(call.station, call.inspect_fn);
        EnterCriticalSection(&g_lock);
        g_last_result = result;
        g_pending_state.store(PendingState::Done);
        LeaveCriticalSection(&g_lock);
        return;
    }
    if (!readable(call.station, sizeof(void*))) {
        result = "station-unreadable";
    } else if (!readable(call.function, sizeof(void*))) {
        result = "function-unreadable";
    } else if (call.params_size == 0 || call.params_size > kMaxParamsBytes
               || call.player_offset + sizeof(int32_t) > call.params_size
               || call.archive_offset + call.bytes_offset + sizeof(FScriptArrayHeader) > call.params_size
               || call.byte_count == 0 || call.byte_count > kMaxArchiveBytes) {
        result = "layout-invalid";
    } else {
        alignas(16) uint8_t params[kMaxParamsBytes];
        memset(params, 0, sizeof(params));
        memcpy(params + call.player_offset, &call.player_id, sizeof(call.player_id));
        auto* arr = reinterpret_cast<FScriptArrayHeader*>(params + call.archive_offset + call.bytes_offset);
        arr->data = call.bytes;                       // read-only; ProcessEvent deep-copies
        arr->num  = (int32_t)call.byte_count;
        arr->max  = (int32_t)call.byte_count;
        result = invoke_process_event(call.station, call.function, params);
    }

    EnterCriticalSection(&g_lock);
    g_last_result = result;
    g_pending_state.store(PendingState::Done);
    LeaveCriticalSection(&g_lock);
}

// ---------------------------------------------------------------- worker thread

static bool ensure_trigger(void* trigger, const char** err) {
    if (!readable(trigger, sizeof(void*))) { *err = "trigger-unreadable"; return false; }
    if (g_trigger_hooked && g_trigger_fn == trigger) return true;
    if (g_pending_state.load() != PendingState::Idle) { *err = "bridge-busy"; return false; }
    if (g_trigger_hooked) {
        g_unregister_hook(g_trigger_fn, g_trigger_id);
        g_trigger_hooked = false;
        g_trigger_fn = nullptr;
    }
    static HookCallback cb = [](CallableContext&, void*) {
        g_hook_fire_count.fetch_add(1);
        execute_pending_on_game_thread();
    };
    int id = g_register_pre_hook(trigger, cb, nullptr);
    g_trigger_raw_id.store(id);
    if (id < 0) { *err = "hook-register-failed"; g_trigger_detail = "register-returned-negative"; return false; }
    g_trigger_fn = trigger;
    g_trigger_id = id;
    g_trigger_hooked = true;
    g_trigger_detail = "registered";
    return true;
}

static void handle_request() {
    bool ok = false;

    // Cheap gate: only parse the ini when its mtime/size changed since last look.
    // Avoids ~10 GetPrivateProfile* file opens per poll on the Wine overlay fs.
    static FILETIME s_last_write = {};
    static LONGLONG s_last_size = -1;
    WIN32_FILE_ATTRIBUTE_DATA fad;
    if (!GetFileAttributesExW(g_request_path, GetFileExInfoStandard, &fad)) return;
    LONGLONG sz = ((LONGLONG)fad.nFileSizeHigh << 32) | fad.nFileSizeLow;
    if (fad.ftLastWriteTime.dwLowDateTime == s_last_write.dwLowDateTime
        && fad.ftLastWriteTime.dwHighDateTime == s_last_write.dwHighDateTime
        && sz == s_last_size) return;
    s_last_write = fad.ftLastWriteTime;
    s_last_size = sz;

    if (GetPrivateProfileIntW(L"request", L"complete", 0, g_request_path) != 1) return;

    uint64_t rid = ini_u64(L"request_id", 10, &ok);
    if (!ok || rid == 0 || rid == g_last_seen_request) return;
    g_last_seen_request = rid;

    char op[16] = {0};
    if (!ini_str(L"operation", op, sizeof(op))) { write_response(rid, "error", "operation-missing"); return; }

    // "dump" -- read up to 8 KiB from an address, write it as hex. Pure inspection,
    // no game thread, no trigger. Used to disassemble ChangeRecipe_ServerInternal.
    if (strcmp(op, "dump") == 0) {
        void* addr = (void*)(uintptr_t)ini_u64(L"dump_addr", 16, &ok);
        uint32_t len = ok ? (uint32_t)ini_u64(L"dump_len", 10, &ok) : 0;
        if (!addr || !ok || len == 0 || len > 8192) { write_response(rid, "error", "dump-args"); return; }
        if (!readable(addr, len)) { write_response(rid, "error", "dump-unreadable"); return; }
        static uint8_t snap[8192];
        bool copied = false;
        __try { memcpy(snap, addr, len); copied = true; } __except (EXCEPTION_EXECUTE_HANDLER) {}
        if (!copied) { write_response(rid, "error", "dump-copy-faulted"); return; }
        // hex into a big buffer written next to the response
        static char hexbuf[8192 * 2 + 256];
        int n = _snprintf_s(hexbuf, _TRUNCATE, "[dump]\nrequest_id=%llu\naddr=%llX\nlen=%u\nexe_base=%llX\nue4ss_base=%llX\nhex=",
                            (unsigned long long)rid, (unsigned long long)(uintptr_t)addr, len,
                            (unsigned long long)(uintptr_t)GetModuleHandleW(nullptr),
                            (unsigned long long)(uintptr_t)g_ue4ss);
        for (uint32_t i = 0; i < len && n < (int)sizeof(hexbuf) - 4; ++i)
            n += _snprintf_s(hexbuf + n, sizeof(hexbuf) - n, _TRUNCATE, "%02X", snap[i]);
        _snprintf_s(hexbuf + n, sizeof(hexbuf) - n, _TRUNCATE, "\n");
        wchar_t dump_path[MAX_PATH * 2];
        _snwprintf_s(dump_path, _TRUNCATE, L"%ls\\data\\native-dump.ini", g_root);
        write_atomic(dump_path, hexbuf);
        write_response(rid, "dumped", "ok");
        return;
    }

    void* trigger = (void*)(uintptr_t)ini_u64(L"trigger_function", 16, &ok);
    if (!ok || !trigger) { write_response(rid, "error", "trigger-missing"); return; }

    const char* err = nullptr;
    if (!ensure_trigger(trigger, &err)) { write_response(rid, "error", err); write_status("error", rid, err); return; }

    if (strcmp(op, "arm") == 0) {
        write_response(rid, "armed", "trigger-ready");
        write_status("armed", rid, "trigger-ready");
        return;
    }
    if (strcmp(op, "cancel") == 0) {
        PendingState st = g_pending_state.load();
        if (st == PendingState::Armed) g_pending_state.store(PendingState::Idle);
        write_response(rid, "canceled", "");
        return;
    }

    // read-only inspection of the r12b chain for a station (Codex step 3)
    if (strcmp(op, "inspect") == 0) {
        PendingCall ci;
        ci.request_id = rid;
        ci.is_inspect = true;
        ci.station    = (void*)(uintptr_t)ini_u64(L"station", 16, &ok);       if (!ok || !ci.station)    { write_response(rid, "error", "station-invalid"); return; }
        ci.inspect_fn = (void*)(uintptr_t)ini_u64(L"inspect_fn", 16, &ok);    if (!ok || !ci.inspect_fn) { write_response(rid, "error", "inspect-fn-invalid"); return; }
        PendingState ex = PendingState::Idle;
        if (!g_pending_state.compare_exchange_strong(ex, PendingState::Armed)) { write_response(rid, "error", "bridge-busy"); return; }
        EnterCriticalSection(&g_lock); g_pending = ci; g_last_result = "none"; LeaveCriticalSection(&g_lock);
        g_arm_count.fetch_add(1);
        write_response(rid, "call-armed", "inspect-armed");
        return;
    }

    if (strcmp(op, "call") != 0) { write_response(rid, "error", "operation-invalid"); return; }

    PendingCall c;
    c.request_id = rid;
    c.station  = (void*)(uintptr_t)ini_u64(L"station", 16, &ok);           if (!ok || !c.station)  { write_response(rid, "error", "station-invalid"); return; }
    c.function = (void*)(uintptr_t)ini_u64(L"target_function", 16, &ok);   if (!ok || !c.function) { write_response(rid, "error", "target-function-invalid"); return; }
    { int64_t p = ini_i64(L"player_id", &ok); if (!ok) { write_response(rid, "error", "player-id-invalid"); return; } c.player_id = (int32_t)p; }
    c.player_offset  = (uint32_t)ini_u64(L"player_offset", 10, &ok);  if (!ok) { write_response(rid, "error", "player-offset-invalid"); return; }
    c.archive_offset = (uint32_t)ini_u64(L"archive_offset", 10, &ok); if (!ok) { write_response(rid, "error", "archive-offset-invalid"); return; }
    c.bytes_offset   = (uint32_t)ini_u64(L"bytes_offset", 10, &ok);   if (!ok) { write_response(rid, "error", "bytes-offset-invalid"); return; }
    c.params_size    = (uint32_t)ini_u64(L"params_size", 10, &ok);    if (!ok) { write_response(rid, "error", "params-size-invalid"); return; }

    char hex[kMaxArchiveBytes * 2 + 4] = {0};
    if (!ini_str(L"archive_hex", hex, sizeof(hex)) || !parse_hex(hex, c.bytes, &c.byte_count)) {
        write_response(rid, "error", "archive-hex-invalid");
        return;
    }

    PendingState expected = PendingState::Idle;
    if (!g_pending_state.compare_exchange_strong(expected, PendingState::Armed)) {
        write_response(rid, "error", "bridge-busy");
        return;
    }
    EnterCriticalSection(&g_lock);
    g_pending = c;
    g_last_result = "none";
    LeaveCriticalSection(&g_lock);
    g_arm_count.fetch_add(1);
    write_response(rid, "call-armed", "waiting-for-game-thread");
    write_status("call-armed", rid, "waiting-for-game-thread");
}

static void reap_done() {
    if (g_pending_state.load() != PendingState::Done) return;
    uint64_t rid;
    const char* result;
    bool was_inspect;
    EnterCriticalSection(&g_lock);
    rid = g_pending.request_id;
    result = g_last_result;
    was_inspect = g_pending.is_inspect;
    g_pending = PendingCall{};
    g_last_result = "none";
    LeaveCriticalSection(&g_lock);
    g_pending_state.store(PendingState::Idle);
    if (was_inspect) {
        char buf[640];
        _snprintf_s(buf, _TRUNCATE, "[inspect]\nrequest_id=%llu\nresult=%s\n%s\n",
                    (unsigned long long)rid, result, g_inspect_result);
        wchar_t ip[MAX_PATH * 2];
        _snwprintf_s(ip, _TRUNCATE, L"%ls\\data\\native-inspect.ini", g_root);
        write_atomic(ip, buf);
        write_response(rid, "inspected", g_inspect_result);
        write_status("armed", rid, "inspected");
        return;
    }
    bool called = strcmp(result, "process-event-returned") == 0;
    write_response(rid, called ? "called" : "error", result);
    write_status("armed", rid, result);
}

static DWORD WINAPI worker(LPVOID) {
    write_status("ready", 0, g_resolve_detail);
    uint32_t tick = 0;
    while (WaitForSingleObject(g_stop_event, kPollIntervalMs) == WAIT_TIMEOUT) {
        reap_done();
        handle_request();
        // refresh the status file every ~3s while armed/executing so counters are
        // observable; while fully idle, back off to ~every 30s.
        ++tick;
        PendingState psn = g_pending_state.load();
        uint32_t every = (psn == PendingState::Idle) ? 250u : 25u;   // *120ms
        if ((tick % every) == 0) {
            PendingState ps = g_pending_state.load();
            const char* s = ps == PendingState::Idle ? "ready"
                          : ps == PendingState::Armed ? "call-armed"
                          : ps == PendingState::Executing ? "executing" : "done";
            write_status(s, g_pending.request_id, g_last_result);
        }
    }
    reap_done();
    return 0;
}

// ---------------------------------------------------------------- symbol resolution

// Locate the module that actually exports the UE4SS C++ ABI. Usually UE4SS.dll,
// but proxy loaders (dwmapi/xinput/d3d11) and future renames mean we probe by
// symbol rather than trusting the name or the install path.
static HMODULE locate_ue4ss() {
    const wchar_t* names[] = { L"UE4SS.dll", L"dwmapi.dll", L"xinput1_3.dll",
                               L"xinput1_4.dll", L"d3d11.dll", L"dinput8.dll", nullptr };
    for (int i = 0; names[i]; ++i) {
        HMODULE m = GetModuleHandleW(names[i]);
        if (m && GetProcAddress(m, kSym_Ctor)) return m;
    }
    return GetModuleHandleW(L"UE4SS.dll");   // may be null; caller reports it
}

static bool resolve_symbols(Fn_CppUserModCtor* ctor) {
    g_ue4ss = locate_ue4ss();
    if (!g_ue4ss) {
        _snprintf_s(g_resolve_detail, _TRUNCATE, "UE4SS module not loaded");
        return false;
    }

    // The three we actually call. ctor/dtor are resolved too (sanity) but optional.
    g_process_event     = reinterpret_cast<Fn_ProcessEvent>(GetProcAddress(g_ue4ss, kSym_ProcessEvent));
    g_register_pre_hook = reinterpret_cast<Fn_RegisterPreHook>(GetProcAddress(g_ue4ss, kSym_RegisterPreHook));
    g_unregister_hook   = reinterpret_cast<Fn_UnregisterHook>(GetProcAddress(g_ue4ss, kSym_UnregisterHook));
    if (ctor)  *ctor  = reinterpret_cast<Fn_CppUserModCtor>(GetProcAddress(g_ue4ss, kSym_Ctor));
    g_dtor = reinterpret_cast<Fn_CppUserModDtor>(GetProcAddress(g_ue4ss, kSym_Dtor));

    const char* missing = !g_process_event ? "ProcessEvent"
                        : !g_register_pre_hook ? "RegisterPreHook"
                        : !g_unregister_hook ? "UnregisterHook" : nullptr;
    if (missing) {
        _snprintf_s(g_resolve_detail, _TRUNCATE, "missing export: %s", missing);
        return false;
    }
    const bool sha_in_path = dll_path_contains(g_ue4ss, PALCOMMAND_UE4SS_SHA);
    _snprintf_s(g_resolve_detail, _TRUNCATE, "ok sha-path:%s ctor:%s",
                sha_in_path ? "match" : "unverified", (ctor && *ctor) ? "y" : "n");
    return true;
}

// ---------------------------------------------------------------- entry points

extern "C" __declspec(dllexport) void* start_mod() {
    if (!init_paths()) return nullptr;

    Fn_CppUserModCtor ctor = nullptr;
    if (!resolve_symbols(&ctor)) {
        write_status("disabled", 0, g_resolve_detail);
        return nullptr;
    }

    // We deliberately do NOT hand UE4SS a CppUserModBase object. Faking that vtable
    // is fragile and unnecessary: everything we need (RegisterPreHook, ProcessEvent)
    // is a plain export. Pin the DLL so the code + worker thread survive even if
    // UE4SS unloads us for returning null, then run entirely from the worker thread
    // and the on-demand game-thread pre-hook.
    HMODULE pin = nullptr;
    GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_PIN | GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS,
                       reinterpret_cast<LPCWSTR>(&start_mod), &pin);

    InitializeCriticalSection(&g_lock);
    g_lock_ready = true;
    g_pending_state.store(PendingState::Idle);

    g_stop_event = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    if (g_stop_event) g_worker = CreateThread(nullptr, 0, worker, nullptr, 0, nullptr);
    if (!g_worker) write_status("disabled", 0, "worker-thread-failed");
    else write_status("ready", 0, "started-detached");

    return nullptr;   // not a real CppUserModBase -- no virtuals will be called on garbage
}

extern "C" __declspec(dllexport) void uninstall_mod(void* mod) {
    if (g_stop_event) SetEvent(g_stop_event);
    if (g_worker) { WaitForSingleObject(g_worker, 3000); CloseHandle(g_worker); g_worker = nullptr; }
    if (g_stop_event) { CloseHandle(g_stop_event); g_stop_event = nullptr; }
    if (g_trigger_hooked && g_unregister_hook) {
        g_unregister_hook(g_trigger_fn, g_trigger_id);
        g_trigger_hooked = false;
    }
    if (g_lock_ready) { DeleteCriticalSection(&g_lock); g_lock_ready = false; }
    if (mod && g_dtor) g_dtor(mod);
    if (mod) HeapFree(GetProcessHeap(), 0, mod);
    g_mod_object = nullptr;
}

BOOL WINAPI DllMain(HINSTANCE inst, DWORD reason, LPVOID) {
    if (reason == DLL_PROCESS_ATTACH) {
        g_module = inst;
        DisableThreadLibraryCalls(inst);
    }
    return TRUE;
}
