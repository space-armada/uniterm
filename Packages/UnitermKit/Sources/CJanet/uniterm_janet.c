#include "uniterm_janet.h"

#include <crt_externs.h>
#include <malloc/malloc.h>
#include <math.h>
#include <pthread.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <termios.h>
#include <unistd.h>

#include "janet.h"
#include "uniterm_line.h"
#include "uniterm_text.h"

/*
 * The allocator wrapper. janetconf.h routes every Janet allocation here. The count is the heap's
 * own size for each block, so a realloc that grows in place is still exact.
 *
 * A block that would take the count past the cap is never granted. Janet's out-of-memory path is
 * not safe to unwind, so the wrapper ends the process instead of returning null.
 */
static uint64_t live_bytes;
static uint64_t memory_cap = UNITERM_JANET_DEFAULT_MEMORY_CAP;

/*
 * The failure path formats nothing and uses no stdio. The text is built when the cap is set, and
 * the default text is a literal for the default cap. The failure path only calls write.
 */
static char limit_message[160] =
    "uniterm: out of memory. A script or REPL may hold at most 1024 MiB, so uniterm ended it.\n";
static void (*limit_hook)(void *userdata);
static void *limit_hook_userdata;

void uniterm_janet_set_memory_cap(uint64_t bytes) {
    memory_cap = bytes;

    snprintf(limit_message, sizeof(limit_message),
             "uniterm: out of memory. A script or REPL may hold at most %llu MiB, so uniterm ended "
             "it.\n",
             (unsigned long long)(bytes >> 20));
}

uint64_t uniterm_janet_memory_cap(void) {
    return memory_cap;
}

void uniterm_janet_set_memory_limit_hook(void (*hook)(void *userdata), void *userdata) {
    limit_hook_userdata = userdata;
    limit_hook = hook;
}

static void memory_limit_exceeded(void) __attribute__((noreturn));

/*
 * Runs on the VM thread, inside an allocation. Stdout is not flushed, since a flush is stdio, and
 * output the script printed but not yet flushed is lost. The hook sends the notice through the
 * connection's own send, which takes the lock the watchdog's pong takes, so the two never
 * interleave. The VM thread holds no connection lock while it allocates, so taking it cannot
 * deadlock against itself.
 */
static void memory_limit_exceeded(void) {
    if (limit_hook != NULL) limit_hook(limit_hook_userdata);

    ssize_t ignored = write(STDERR_FILENO, limit_message, strlen(limit_message));

    (void)ignored;
    _exit(UNITERM_JANET_EXIT_MEMORY_LIMIT);
}

static void count_add(size_t bytes) {
    __atomic_fetch_add(&live_bytes, (uint64_t)bytes, __ATOMIC_RELAXED);
}

static void count_sub(size_t bytes) {
    __atomic_fetch_sub(&live_bytes, (uint64_t)bytes, __ATOMIC_RELAXED);
}

/* Ends the process when `extra` more bytes would pass the cap. */
static void require_room(uint64_t extra) {
    uint64_t live = __atomic_load_n(&live_bytes, __ATOMIC_RELAXED);

    if (extra > memory_cap || live > memory_cap - extra) memory_limit_exceeded();
}

void *uniterm_janet_malloc(size_t size) {
    require_room((uint64_t)size);

    void *block = malloc(size);

    if (block != NULL) count_add(malloc_size(block));

    return block;
}

void *uniterm_janet_calloc(size_t count, size_t size) {
    uint64_t total = (uint64_t)count * (uint64_t)size;

    if (count != 0 && total / count != (uint64_t)size) memory_limit_exceeded();

    require_room(total);

    void *block = calloc(count, size);

    if (block != NULL) count_add(malloc_size(block));

    return block;
}

void *uniterm_janet_realloc(void *pointer, size_t size) {
    size_t old_size = pointer != NULL ? malloc_size(pointer) : 0;

    if ((uint64_t)size > (uint64_t)old_size) require_room((uint64_t)size - (uint64_t)old_size);

    void *block = realloc(pointer, size);

    if (block != NULL) {
        count_sub(old_size);
        count_add(malloc_size(block));
    }

    return block;
}

void uniterm_janet_free(void *pointer) {
    if (pointer == NULL) return;

    count_sub(malloc_size(pointer));
    free(pointer);
}

uint64_t uniterm_janet_live_bytes(void) {
    return __atomic_load_n(&live_bytes, __ATOMIC_RELAXED);
}

const char *uniterm_janet_version(void) {
    return JANET_VERSION;
}

/*
 * No file, network, process, or FFI access, no native modules, no threads, no environment, no
 * signals, and no chroot. Janet's sandbox cannot be widened once it is applied, so a caller that
 * grants a capability clears its bit before the run.
 */
const uint32_t uniterm_janet_default_sandbox =
    JANET_SANDBOX_SANDBOX | JANET_SANDBOX_SUBPROCESS | JANET_SANDBOX_NET | JANET_SANDBOX_FFI |
    JANET_SANDBOX_FS | JANET_SANDBOX_DYNAMIC_MODULES | JANET_SANDBOX_ENV | JANET_SANDBOX_SIGNAL |
    JANET_SANDBOX_CHROOT | JANET_SANDBOX_THREADS;

typedef struct capability_name {
    const char *name;
    uint32_t flags;
} capability_name;

/* The names Janet's `sandbox` accepts, minus "all". janet.c keeps its own table private. */
static const capability_name capability_names[] = {
    {"asm", JANET_SANDBOX_ASM},
    {"chroot", JANET_SANDBOX_CHROOT},
    {"compile", JANET_SANDBOX_COMPILE},
    {"env", JANET_SANDBOX_ENV},
    {"exit", JANET_SANDBOX_EXIT},
    {"ffi", JANET_SANDBOX_FFI},
    {"ffi-define", JANET_SANDBOX_FFI_DEFINE},
    {"ffi-jit", JANET_SANDBOX_FFI_JIT},
    {"ffi-use", JANET_SANDBOX_FFI_USE},
    {"fs", JANET_SANDBOX_FS},
    {"fs-read", JANET_SANDBOX_FS_READ},
    {"fs-temp", JANET_SANDBOX_FS_TEMP},
    {"fs-write", JANET_SANDBOX_FS_WRITE},
    {"hrtime", JANET_SANDBOX_HRTIME},
    {"locale", JANET_SANDBOX_LOCALE},
    {"modules", JANET_SANDBOX_DYNAMIC_MODULES},
    {"net", JANET_SANDBOX_NET},
    {"net-connect", JANET_SANDBOX_NET_CONNECT},
    {"net-listen", JANET_SANDBOX_NET_LISTEN},
    {"sandbox", JANET_SANDBOX_SANDBOX},
    {"signal", JANET_SANDBOX_SIGNAL},
    {"subprocess", JANET_SANDBOX_SUBPROCESS},
    {"threads", JANET_SANDBOX_THREADS},
    {"unmarshal", JANET_SANDBOX_UNMARSHAL},
};

int uniterm_janet_capability_flags(const char *name, uint32_t *flags) {
    for (size_t index = 0; index < sizeof(capability_names) / sizeof(capability_names[0]);
         index++) {
        if (strcmp(capability_names[index].name, name) == 0) {
            *flags = capability_names[index].flags;

            return 0;
        }
    }

    return -1;
}

/*
 * The host is per thread, like Janet's own VM. Janet calls a host function with no way to carry a
 * pointer, so the running script's host is found here.
 */
static __thread const uniterm_host *active_host;

static int32_t checked_status_level(Janet value) {
    if (janet_keyeq(value, "info")) return UNITERM_STATUS_INFO;
    if (janet_keyeq(value, "warning")) return UNITERM_STATUS_WARNING;
    if (janet_keyeq(value, "error")) return UNITERM_STATUS_ERROR;

    janet_panic("the level must be :info, :warning, or :error");
}

static Janet cfun_api_version(int32_t argc, Janet *argv) {
    (void)argv;
    janet_fixarity(argc, 0);

    return janet_wrap_integer(UNITERM_JANET_API_VERSION);
}

static Janet cfun_post_status(int32_t argc, Janet *argv) {
    janet_fixarity(argc, 2);

    int32_t level = checked_status_level(argv[0]);
    JanetString text = janet_getstring(argv, 1);
    int32_t length = janet_string_length(text);

    if (length > UNITERM_JANET_MAX_STATUS_BYTES) {
        janet_panicf("the text is %d bytes, and the most is %d", length,
                     UNITERM_JANET_MAX_STATUS_BYTES);
    }

    const uniterm_host *host = active_host;

    if (host == NULL || host->post_status == NULL) janet_panic("post-status is not available");

    char error[UNITERM_JANET_ERROR_CAPACITY];
    error[0] = '\0';

    int32_t status = host->post_status(host->userdata, level, text, (size_t)length, error,
                                       sizeof(error));

    error[sizeof(error) - 1] = '\0';

    if (status != 0) janet_panicf("%s", error[0] != '\0' ? error : "the host refused the call");

    return janet_wrap_nil();
}

/*
 * The calls other than post-status. Each function checks its script's arguments here, writes the
 * call in the wire's encoding, and hands the bytes to the host in one callback. The reply comes
 * back as bytes, and this file turns them into Janet values, so no Swift frame ever sits between
 * a Janet error and the code that catches it.
 */

enum {
    CALL_LIST_WINDOWS = 2,
    CALL_LIST_PANES = 3,
    CALL_OPEN_PANE = 4,
    CALL_OPEN_TAB = 5,
    CALL_SEND = 6,
    CALL_SEND_COMMAND = 7,
    CALL_REQUEST_LAYOUT = 8,
    CALL_READ_CLIPBOARD = 9,
    CALL_WRITE_CLIPBOARD = 10,
    CALL_OPEN_FORM = 11,
    CALL_WAIT_FORM = 12,
    CALL_DISCARD_FORM = 13
};

/* The largest ID a script may hold. Every integer below it is exact in a double. */
#define MAX_ID 9007199254740991.0
#define MAX_VALUE_DEPTH 8
#define MAX_VALUE_STRING 4096
#define MAX_VALUE_KEY 32
#define MAX_VALUE_FIELDS 64
#define MAX_JSON_DEPTH 16
#define MAX_JSON_FIELDS 64
#define MAX_SCHEMA_VERSION 2147483647.0

static void put_u8(JanetBuffer *buffer, uint8_t value) {
    janet_buffer_push_u8(buffer, value);
}

static void put_u16(JanetBuffer *buffer, uint16_t value) {
    put_u8(buffer, (uint8_t)(value >> 8));
    put_u8(buffer, (uint8_t)(value & 0xFF));
}

static void put_u32(JanetBuffer *buffer, uint32_t value) {
    put_u16(buffer, (uint16_t)(value >> 16));
    put_u16(buffer, (uint16_t)(value & 0xFFFF));
}

static void put_id(JanetBuffer *buffer, uint64_t value) {
    put_u32(buffer, (uint32_t)(value >> 32));
    put_u32(buffer, (uint32_t)(value & 0xFFFFFFFF));
}

/* Strict UTF-8: no overlong forms, no surrogates, nothing above U+10FFFF. */
int uniterm_valid_utf8(const uint8_t *bytes, int32_t length) {
    int32_t index = 0;

    while (index < length) {
        uint8_t lead = bytes[index];
        int32_t extra;
        uint32_t scalar;

        if (lead < 0x80) {
            index += 1;
            continue;
        } else if (lead >= 0xC2 && lead <= 0xDF) {
            extra = 1;
            scalar = lead & 0x1F;
        } else if (lead >= 0xE0 && lead <= 0xEF) {
            extra = 2;
            scalar = lead & 0x0F;
        } else if (lead >= 0xF0 && lead <= 0xF4) {
            extra = 3;
            scalar = lead & 0x07;
        } else {
            return 0;
        }

        if (index + extra >= length) return 0;

        for (int32_t step = 1; step <= extra; step++) {
            uint8_t next = bytes[index + step];

            if ((next & 0xC0) != 0x80) return 0;

            scalar = (scalar << 6) | (next & 0x3F);
        }

        if (extra == 2 && (scalar < 0x800 || (scalar >= 0xD800 && scalar <= 0xDFFF))) return 0;
        if (extra == 3 && (scalar < 0x10000 || scalar > 0x10FFFF)) return 0;

        index += extra + 1;
    }

    return 1;
}

/*
 * An ID is an exact integer from zero to 2^53 - 1. A number that is not finite, not whole, or out
 * of that range is the script's mistake, and the message says which.
 */
static uint64_t checked_id(Janet value, const char *what) {
    if (!janet_checktype(value, JANET_NUMBER)) janet_panicf("%s must be a number", what);

    double number = janet_unwrap_number(value);

    if (isnan(number) || isinf(number)) janet_panicf("%s must be a finite number", what);
    if (number != floor(number)) janet_panicf("%s must be a whole number", what);
    if (number < 0) janet_panicf("%s must not be negative", what);
    if (number > MAX_ID) janet_panicf("%s is too large", what);

    return (uint64_t)number;
}

static void require_reference(Janet reference) {
    if (!janet_checktype(reference, JANET_STRUCT) && !janet_checktype(reference, JANET_TABLE)) {
        janet_panic("a reference must be a struct or a table such as {:window 1 :pane 2}");
    }
}

static uint64_t required_id(Janet reference, const char *key) {
    Janet value = janet_get(reference, janet_ckeywordv(key));

    if (janet_checktype(value, JANET_NIL)) janet_panicf("the reference has no :%s", key);

    char what[32];

    snprintf(what, sizeof(what), "the :%s", key);

    return checked_id(value, what);
}

static uint64_t window_of(Janet reference) {
    require_reference(reference);

    return required_id(reference, "window");
}

/*
 * A pane reference holds a window and a pane. It may hold a tab too, as a tab reference does. Keys
 * beyond these are ignored, so a script may pass a reference it got from a longer one.
 */
static void put_pane_reference(JanetBuffer *buffer, Janet reference) {
    require_reference(reference);

    put_id(buffer, required_id(reference, "window"));
    put_id(buffer, required_id(reference, "pane"));

    Janet tab = janet_get(reference, janet_ckeywordv("tab"));

    if (janet_checktype(tab, JANET_NIL)) {
        put_u8(buffer, 0);
    } else {
        put_u8(buffer, 1);
        put_id(buffer, checked_id(tab, "the :tab"));
    }
}

static void check_text(JanetString text, const char *what, int32_t limit, int forbid_slash);
static void put_text(JanetBuffer *buffer, JanetString text);

/*
 * A target is a pane reference, or {:nearest kind} for the nearest pane of an applet type to the
 * caller's own pane. The app picks the nearest pane among those the caller may control, in the
 * caller's window, so a nearest target names no window.
 */
static void put_target(JanetBuffer *buffer, Janet reference) {
    require_reference(reference);

    Janet nearest = janet_get(reference, janet_ckeywordv("nearest"));

    if (janet_checktype(nearest, JANET_NIL)) {
        put_u8(buffer, 0);
        put_pane_reference(buffer, reference);
        return;
    }

    if (!janet_checktype(janet_get(reference, janet_ckeywordv("window")), JANET_NIL) ||
        !janet_checktype(janet_get(reference, janet_ckeywordv("pane")), JANET_NIL)) {
        janet_panic("a :nearest target names no :window or :pane");
    }

    if (!janet_checktype(nearest, JANET_KEYWORD)) {
        janet_panic("the :nearest kind must be a keyword such as :browser");
    }

    JanetString kind = janet_unwrap_keyword(nearest);

    check_text(kind, "the :nearest kind", UNITERM_JANET_MAX_KIND_BYTES, 1);
    put_u8(buffer, 1);
    put_text(buffer, kind);
}

static void check_text(JanetString text, const char *what, int32_t limit, int forbid_slash) {
    int32_t length = janet_string_length(text);

    if (length == 0) janet_panicf("%s must not be empty", what);

    if (length > limit) janet_panicf("%s is %d bytes, and the most is %d", what, length, limit);

    if (memchr(text, 0, (size_t)length) != NULL) janet_panicf("%s must not hold a NUL byte", what);

    if (forbid_slash && memchr(text, '/', (size_t)length) != NULL) {
        janet_panicf("%s must be a name, not a path", what);
    }

    if (!uniterm_valid_utf8(text, length)) janet_panicf("%s is not UTF-8", what);
}

static void put_text(JanetBuffer *buffer, JanetString text) {
    put_u16(buffer, (uint16_t)janet_string_length(text));
    janet_buffer_push_bytes(buffer, text, janet_string_length(text));
}

/* A directory must be an absolute path. A relative one would resolve against the helper's own. */
static JanetString checked_directory(Janet value) {
    if (!janet_checktype(value, JANET_STRING)) janet_panic("the :directory must be a string");

    JanetString text = janet_unwrap_string(value);

    check_text(text, "the :directory", UNITERM_JANET_MAX_DIRECTORY_BYTES, 0);

    if (text[0] != '/') {
        janet_panic("the :directory must be an absolute path, because the script's own "
                    "directory is never used");
    }

    return text;
}

static void put_optional_directory(JanetBuffer *buffer, Janet value) {
    if (janet_checktype(value, JANET_NIL)) {
        put_u8(buffer, 0);

        return;
    }

    put_u8(buffer, 1);
    put_text(buffer, checked_directory(value));
}

/*
 * Options follow the positional arguments as keyword and value pairs. A nil value stands for an
 * option left out. An unknown or repeated option is the script's mistake.
 */
typedef struct call_options {
    Janet axis;
    Janet directory;
    Janet control;
} call_options;

/* A call that splits takes :axis and :control too. Every call that opens takes :directory. */
static call_options parse_options(int32_t argc, Janet *argv, int32_t first, int allow_axis) {
    call_options options = {janet_wrap_nil(), janet_wrap_nil(), janet_wrap_nil()};
    int seen_axis = 0;
    int seen_directory = 0;
    int seen_control = 0;

    if ((argc - first) % 2 != 0) janet_panic("each option needs a value, as in :directory \"/tmp\"");

    for (int32_t index = first; index < argc; index += 2) {
        if (allow_axis && janet_keyeq(argv[index], "axis")) {
            if (seen_axis++) janet_panic("the :axis is given twice");

            options.axis = argv[index + 1];
        } else if (allow_axis && janet_keyeq(argv[index], "control")) {
            if (seen_control++) janet_panic("the :control is given twice");

            options.control = argv[index + 1];
        } else if (janet_keyeq(argv[index], "directory")) {
            if (seen_directory++) janet_panic("the :directory is given twice");

            options.directory = argv[index + 1];
        } else {
            janet_panic(allow_axis ? "the options are :axis, :control, and :directory"
                                   : "the only option is :directory");
        }
    }

    return options;
}

/* Reads one value from a reply and moves past it. Returns 0 when the bytes are not a value. */
static int skip_value(const uint8_t **cursor, const uint8_t *end, int depth) {
    if (depth > MAX_VALUE_DEPTH || *cursor >= end) return 0;

    uint8_t tag = *(*cursor)++;

    switch (tag) {
    case 0:
    case 1:
    case 2:
        return 1;

    case 3: {
        if (end - *cursor < 8) return 0;

        uint64_t value = 0;

        for (int step = 0; step < 8; step++) value = (value << 8) | *(*cursor)++;

        return value <= (uint64_t)MAX_ID;
    }

    case 7: {
        if (end - *cursor < 8) return 0;

        uint64_t bits = 0;

        for (int step = 0; step < 8; step++) bits = (bits << 8) | *(*cursor)++;

        double number;

        memcpy(&number, &bits, sizeof(number));

        return isfinite(number);
    }

    case 4: {
        if (end - *cursor < 4) return 0;

        uint32_t length = 0;

        for (int step = 0; step < 4; step++) length = (length << 8) | *(*cursor)++;

        if (length > MAX_VALUE_STRING || (size_t)(end - *cursor) < length) return 0;
        if (!uniterm_valid_utf8(*cursor, (int32_t)length)) return 0;

        *cursor += length;

        return 1;
    }

    case 5: {
        if (end - *cursor < 2) return 0;

        uint32_t count = ((uint32_t)(*cursor)[0] << 8) | (*cursor)[1];

        *cursor += 2;

        for (uint32_t index = 0; index < count; index++) {
            if (!skip_value(cursor, end, depth + 1)) return 0;
        }

        return 1;
    }

    case 6: {
        if (end - *cursor < 2) return 0;

        uint32_t count = ((uint32_t)(*cursor)[0] << 8) | (*cursor)[1];

        *cursor += 2;

        if (count > MAX_VALUE_FIELDS) return 0;

        const uint8_t *keys[MAX_VALUE_FIELDS];
        uint8_t key_lengths[MAX_VALUE_FIELDS];

        for (uint32_t index = 0; index < count; index++) {
            if (*cursor >= end) return 0;

            uint8_t length = *(*cursor)++;

            if (length == 0 || length > MAX_VALUE_KEY || end - *cursor < length) return 0;

            for (uint8_t step = 0; step < length; step++) {
                if ((*cursor)[step] <= 0x20 || (*cursor)[step] >= 0x7F) return 0;
            }

            for (uint32_t earlier = 0; earlier < index; earlier++) {
                if (key_lengths[earlier] == length && memcmp(keys[earlier], *cursor, length) == 0) {
                    return 0;
                }
            }

            keys[index] = *cursor;
            key_lengths[index] = length;
            *cursor += length;

            if (!skip_value(cursor, end, depth + 1)) return 0;
        }

        return 1;
    }

    default:
        return 0;
    }
}

/* Builds a Janet value from bytes that skip_value accepted, so it never has to refuse any. */
static Janet decode_value(const uint8_t **cursor) {
    uint8_t tag = *(*cursor)++;

    switch (tag) {
    case 1:
        return janet_wrap_false();

    case 2:
        return janet_wrap_true();

    case 3: {
        uint64_t value = 0;

        for (int step = 0; step < 8; step++) value = (value << 8) | *(*cursor)++;

        return janet_wrap_number((double)value);
    }

    case 7: {
        uint64_t bits = 0;

        for (int step = 0; step < 8; step++) bits = (bits << 8) | *(*cursor)++;

        double number;

        memcpy(&number, &bits, sizeof(number));

        return janet_wrap_number(number);
    }

    case 4: {
        uint32_t length = 0;

        for (int step = 0; step < 4; step++) length = (length << 8) | *(*cursor)++;

        Janet text = janet_wrap_string(janet_string(*cursor, (int32_t)length));

        *cursor += length;

        return text;
    }

    case 5: {
        uint32_t count = ((uint32_t)(*cursor)[0] << 8) | (*cursor)[1];

        *cursor += 2;

        JanetArray *array = janet_array((int32_t)count);

        for (uint32_t index = 0; index < count; index++) {
            janet_array_push(array, decode_value(cursor));
        }

        return janet_wrap_array(array);
    }

    case 6: {
        uint32_t count = ((uint32_t)(*cursor)[0] << 8) | (*cursor)[1];

        *cursor += 2;

        JanetKV *record = janet_struct_begin((int32_t)count);

        for (uint32_t index = 0; index < count; index++) {
            uint8_t length = *(*cursor)++;
            Janet key = janet_wrap_keyword(janet_keyword(*cursor, length));

            *cursor += length;

            janet_struct_put(record, key, decode_value(cursor));
        }

        return janet_wrap_struct(janet_struct_end(record));
    }

    default:
        return janet_wrap_nil();
    }
}

/* The keyword a failure kind from the app goes by in a structured error. */
static const char *failure_kind_name(int32_t status) {
    switch (status - UNITERM_JANET_APP_FAILURE_BASE) {
    case 1: return "bad-argument";
    case 2: return "refused";
    case 4: return "not-found";
    case 5: return "unsupported";
    case 6: return "reply-lost";
    case 7: return "busy";
    case 8: return "ended";
    default: return "failed";
    }
}

/* Raises a struct of :kind and :message, which a script can tell apart without reading words. */
static void panic_failure(const char *kind, const char *text) {
    JanetKV *record = janet_struct_begin(2);

    janet_struct_put(record, janet_ckeywordv("kind"), janet_ckeywordv(kind));
    janet_struct_put(record, janet_ckeywordv("message"), janet_cstringv(text));
    janet_panicv(janet_wrap_struct(janet_struct_end(record)));
}

/* Set when the host cut a wait short because of an interrupt. The shim's ask reads and clears it. */
static int call_interrupted;

/*
 * Runs one call through the host and turns its reply into a Janet value. A failure raises the
 * app's text. With `structured`, it raises a struct of :kind and :message instead, so a script
 * can tell a refusal from its own mistake without reading the words. With `raw`, the reply is not
 * a value: its first byte is 1 when text follows and 0 when there is none, and the text is
 * returned as a string of any length the frame holds.
 */
static Janet invoke_reply(JanetBuffer *request, int structured, int raw) {
    const uniterm_host *host = active_host;

    if (host == NULL || host->call == NULL) janet_panic("this function is not available");

    char error[UNITERM_JANET_ERROR_CAPACITY];
    uint8_t *reply = NULL;
    size_t reply_length = 0;

    error[0] = '\0';

    int32_t status = host->call(host->userdata, request->data, (size_t)request->count, &reply,
                                &reply_length, error, sizeof(error));

    error[sizeof(error) - 1] = '\0';

    if (status == UNITERM_JANET_CALL_INTERRUPTED) {
        free(reply);
        call_interrupted = 1;

        return janet_wrap_nil();
    }

    if (status != 0) {
        free(reply);

        const char *text = error[0] != '\0' ? error : "the host refused the call";

        if (structured) panic_failure(failure_kind_name(status), text);

        janet_panicf("%s", text);
    }

    if (raw) {
        int readable = reply != NULL && reply_length > 0 && reply[0] <= 1
                       && (reply[0] == 1 || reply_length == 1)
                       && uniterm_valid_utf8(reply + 1, (int32_t)(reply_length - 1));

        if (!readable) {
            free(reply);
            janet_panic("uniterm sent a reply that could not be read");
        }

        Janet text = reply[0] == 1 ? janet_stringv(reply + 1, (int32_t)(reply_length - 1))
                                   : janet_wrap_nil();

        free(reply);

        return text;
    }

    if (reply == NULL || reply_length == 0) {
        free(reply);

        return janet_wrap_nil();
    }

    const uint8_t *cursor = reply;
    const uint8_t *end = reply + reply_length;
    int readable = skip_value(&cursor, end, 0) && cursor == end;

    if (!readable) {
        free(reply);
        janet_panic("uniterm sent a reply that could not be read");
    }

    cursor = reply;

    Janet value = decode_value(&cursor);

    free(reply);

    return value;
}

static Janet invoke_call(JanetBuffer *request, int structured) {
    return invoke_reply(request, structured, 0);
}

static Janet invoke(JanetBuffer *request) {
    return invoke_call(request, 0);
}

static Janet cfun_list_windows(int32_t argc, Janet *argv) {
    (void)argv;
    janet_fixarity(argc, 0);

    JanetBuffer *request = janet_buffer(8);

    put_u16(request, CALL_LIST_WINDOWS);

    return invoke(request);
}

static Janet cfun_list_panes(int32_t argc, Janet *argv) {
    janet_fixarity(argc, 1);

    JanetBuffer *request = janet_buffer(16);

    put_u16(request, CALL_LIST_PANES);
    put_id(request, window_of(argv[0]));

    return invoke(request);
}

static Janet cfun_open_pane(int32_t argc, Janet *argv) {
    janet_arity(argc, 2, -1);

    if (!janet_checktype(argv[0], JANET_KEYWORD)) {
        janet_panic("the applet kind must be a keyword such as :terminal");
    }

    JanetString kind = janet_unwrap_keyword(argv[0]);

    check_text(kind, "the applet kind", UNITERM_JANET_MAX_KIND_BYTES, 1);

    call_options options = parse_options(argc, argv, 2, 1);
    JanetBuffer *request = janet_buffer(64);

    put_u16(request, CALL_OPEN_PANE);
    put_text(request, kind);
    put_target(request, argv[1]);

    if (janet_checktype(options.axis, JANET_NIL)) {
        put_u8(request, 0);
    } else if (janet_keyeq(options.axis, "row")) {
        put_u8(request, 1);
    } else if (janet_keyeq(options.axis, "column")) {
        put_u8(request, 2);
    } else {
        janet_panic("the :axis must be :row or :column");
    }

    put_optional_directory(request, options.directory);

    if (janet_checktype(options.control, JANET_NIL) || janet_keyeq(options.control, "disconnected")) {
        put_u8(request, 0);
    } else if (janet_keyeq(options.control, "remote-controlled")) {
        put_u8(request, 1);
    } else {
        janet_panic("the :control must be :disconnected or :remote-controlled");
    }

    return invoke(request);
}

static Janet cfun_open_tab(int32_t argc, Janet *argv) {
    janet_arity(argc, 1, -1);

    call_options options = parse_options(argc, argv, 1, 0);
    JanetBuffer *request = janet_buffer(64);

    put_u16(request, CALL_OPEN_TAB);
    put_target(request, argv[0]);
    put_optional_directory(request, options.directory);

    return invoke(request);
}

static Janet cfun_send(int32_t argc, Janet *argv) {
    janet_fixarity(argc, 3);

    if (!janet_checktype(argv[1], JANET_STRING)) janet_panic("the file name must be a string");

    JanetString name = janet_unwrap_string(argv[1]);

    check_text(name, "the file name", UNITERM_JANET_MAX_FILE_NAME_BYTES, 1);

    if (name[0] == '.') janet_panic("the file name must not start with a dot");

    const uint8_t *bytes = NULL;
    int32_t length = 0;

    if (janet_checktype(argv[2], JANET_STRING)) {
        bytes = janet_unwrap_string(argv[2]);
        length = janet_string_length(bytes);
    } else if (janet_checktype(argv[2], JANET_BUFFER)) {
        JanetBuffer *content = janet_unwrap_buffer(argv[2]);

        bytes = content->data;
        length = content->count;
    } else {
        janet_panic("the content must be a string or a buffer");
    }

    if (length > UNITERM_JANET_MAX_SEND_BYTES) {
        janet_panicf("the content is %d bytes, and the most is %d", length,
                     UNITERM_JANET_MAX_SEND_BYTES);
    }

    JanetBuffer *request = janet_buffer(length + 64);

    put_u16(request, CALL_SEND);
    put_target(request, argv[0]);
    put_text(request, name);
    janet_buffer_push_bytes(request, bytes, length);

    return invoke(request);
}

/* Names what the JSON writer writes, such as "the arguments", in its errors, and holds its limit. */
typedef struct json_context {
    const char *what;
    int32_t limit;

    /* Raises a too-large error as a struct of :kind and :message, as the call's own failures are. */
    int structured;
} json_context;

static void json_text(JanetBuffer *out, const uint8_t *text, int32_t length,
                      const json_context *context) {
    if (!uniterm_valid_utf8(text, length)) janet_panicf("a string in %s is not UTF-8", context->what);

    janet_buffer_push_u8(out, '"');

    for (int32_t index = 0; index < length; index++) {
        uint8_t byte = text[index];

        if (byte == '"' || byte == '\\') {
            janet_buffer_push_u8(out, '\\');
            janet_buffer_push_u8(out, byte);
        } else if (byte == '\n' || byte == '\r' || byte == '\t') {
            janet_buffer_push_u8(out, '\\');
            janet_buffer_push_u8(out, byte == '\n' ? 'n' : byte == '\r' ? 'r' : 't');
        } else if (byte < 0x20) {
            char escaped[8];

            snprintf(escaped, sizeof(escaped), "\\u%04x", byte);
            janet_buffer_push_cstring(out, escaped);
        } else {
            janet_buffer_push_u8(out, byte);
        }
    }

    janet_buffer_push_u8(out, '"');
}

static void json_too_large(const json_context *context) {
    if (context->structured) {
        char message[128];

        snprintf(message, sizeof(message), "%s would be more than %d bytes as JSON", context->what,
                 context->limit);
        panic_failure("bad-argument", message);
    }

    janet_panicf("%s would be more than %d bytes as JSON", context->what, context->limit);
}

/*
 * Writes a Janet value as JSON, for an applet command's arguments or a layout. A struct or table
 * becomes an object whose keys are keywords or strings, an array or tuple becomes an array, and a
 * keyword value becomes a string. Anything else, a number that is not finite, text that is not
 * UTF-8, a repeated key, or a value past the bounds is the script's mistake, and nothing is sent.
 */
static void json_value(JanetBuffer *out, Janet value, int depth, const json_context *context) {
    if (depth > MAX_JSON_DEPTH) janet_panicf("too many levels of nesting in %s", context->what);

    if (out->count > context->limit) json_too_large(context);

    switch (janet_type(value)) {
    case JANET_NIL:
        janet_buffer_push_cstring(out, "null");
        return;

    case JANET_BOOLEAN:
        janet_buffer_push_cstring(out, janet_unwrap_boolean(value) ? "true" : "false");
        return;

    case JANET_NUMBER: {
        double number = janet_unwrap_number(value);
        char text[40];

        if (!isfinite(number)) janet_panicf("a number in %s is not finite", context->what);

        if (number == floor(number) && fabs(number) <= MAX_ID) {
            snprintf(text, sizeof(text), "%.0f", number);
        } else {
            snprintf(text, sizeof(text), "%.17g", number);
        }

        janet_buffer_push_cstring(out, text);
        return;
    }

    case JANET_STRING:
    case JANET_KEYWORD:
    case JANET_SYMBOL: {
        const uint8_t *text = janet_unwrap_string(value);

        json_text(out, text, janet_string_length(text), context);
        return;
    }

    case JANET_BUFFER: {
        JanetBuffer *buffer = janet_unwrap_buffer(value);

        json_text(out, buffer->data, buffer->count, context);
        return;
    }

    case JANET_ARRAY:
    case JANET_TUPLE: {
        const Janet *items = NULL;
        int32_t count = 0;

        janet_indexed_view(value, &items, &count);
        janet_buffer_push_u8(out, '[');

        for (int32_t index = 0; index < count; index++) {
            if (index > 0) janet_buffer_push_u8(out, ',');

            json_value(out, items[index], depth + 1, context);
        }

        janet_buffer_push_u8(out, ']');
        return;
    }

    case JANET_STRUCT:
    case JANET_TABLE: {
        const JanetKV *entries = NULL;
        int32_t count = 0;
        int32_t capacity = 0;
        const uint8_t *keys[MAX_JSON_FIELDS];
        int32_t key_lengths[MAX_JSON_FIELDS];
        int32_t written = 0;

        janet_dictionary_view(value, &entries, &count, &capacity);

        if (count > MAX_JSON_FIELDS) {
            janet_panicf("an object in %s has more than %d fields", context->what, MAX_JSON_FIELDS);
        }

        janet_buffer_push_u8(out, '{');

        for (const JanetKV *entry = janet_dictionary_next(entries, capacity, NULL); entry != NULL;
             entry = janet_dictionary_next(entries, capacity, entry)) {
            if (!janet_checktypes(entry->key, JANET_TFLAG_KEYWORD | JANET_TFLAG_STRING)) {
                janet_panicf("a key in %s must be a keyword or a string", context->what);
            }

            const uint8_t *key = janet_unwrap_string(entry->key);
            int32_t length = janet_string_length(key);

            for (int32_t earlier = 0; earlier < written; earlier++) {
                if (key_lengths[earlier] == length && memcmp(keys[earlier], key, (size_t)length) == 0) {
                    janet_panicf("a key in %s is given twice", context->what);
                }
            }

            keys[written] = key;
            key_lengths[written] = length;

            if (written > 0) janet_buffer_push_u8(out, ',');

            written++;
            json_text(out, key, length, context);
            janet_buffer_push_u8(out, ':');
            json_value(out, entry->value, depth + 1, context);
        }

        janet_buffer_push_u8(out, '}');
        return;
    }

    default:
        janet_panicf("%s cannot hold a %T", context->what, value);
    }
}

/* Writes a struct or table as one JSON object, within the context's limit. */
static JanetBuffer *json_object(Janet value, const json_context *context) {
    JanetBuffer *json = janet_buffer(64);

    json_value(json, value, 0, context);

    if (json->count > context->limit) json_too_large(context);

    return json;
}

/* One part of a schema version: a whole number from 0 to the wire's largest. */
static uint32_t schema_part(Janet value, const char *what) {
    if (!janet_checktype(value, JANET_NUMBER)) {
        janet_panicf("the schema version %s must be a number", what);
    }

    double part = janet_unwrap_number(value);

    if (!isfinite(part) || part != floor(part) || part < 0 || part > MAX_SCHEMA_VERSION) {
        janet_panicf("the schema version %s must be a whole number that is not negative", what);
    }

    return (uint32_t)part;
}

/*
 * Reads a schema version: a [major minor] tuple or array, or a bare whole number n, which means
 * [n 0]. Anything else is the script's mistake, and nothing is sent.
 */
static void schema_version(Janet value, uint32_t *major, uint32_t *minor) {
    if (janet_checktypes(value, JANET_TFLAG_TUPLE | JANET_TFLAG_ARRAY)) {
        const Janet *parts;
        int32_t count;

        if (!janet_indexed_view(value, &parts, &count) || count != 2) {
            janet_panic("the schema version must be a [major minor] tuple");
        }

        *major = schema_part(parts[0], "major");
        *minor = schema_part(parts[1], "minor");

        return;
    }

    if (!janet_checktype(value, JANET_NUMBER)) {
        janet_panic("the schema version must be a number or a [major minor] tuple");
    }

    *major = schema_part(value, "number");
    *minor = 0;
}

static Janet cfun_send_command(int32_t argc, Janet *argv) {
    janet_arity(argc, 4, 5);

    if (!janet_checktype(argv[1], JANET_KEYWORD)) {
        janet_panic("the applet type must be a keyword such as :fixture-slides");
    }

    JanetString type = janet_unwrap_keyword(argv[1]);

    check_text(type, "the applet type", UNITERM_JANET_MAX_KIND_BYTES, 1);

    uint32_t major;
    uint32_t minor;

    schema_version(argv[2], &major, &minor);

    if (!janet_checktypes(argv[3], JANET_TFLAG_KEYWORD | JANET_TFLAG_STRING)) {
        janet_panic("the command must be a keyword or a string such as :show-slide");
    }

    JanetString command = janet_unwrap_string(argv[3]);

    check_text(command, "the command", UNITERM_JANET_MAX_COMMAND_NAME_BYTES, 1);

    Janet arguments = argc > 4 ? argv[4] : janet_wrap_nil();
    json_context context = {"the arguments", UNITERM_JANET_MAX_COMMAND_ARGUMENT_BYTES, 1};
    JanetBuffer *json;

    if (janet_checktype(arguments, JANET_NIL)) {
        json = janet_buffer(4);
        janet_buffer_push_cstring(json, "{}");
    } else if (janet_checktypes(arguments, JANET_TFLAG_STRUCT | JANET_TFLAG_TABLE)) {
        json = json_object(arguments, &context);
    } else {
        janet_panic("the arguments must be a struct or a table");
    }

    JanetBuffer *request = janet_buffer(json->count + 128);

    put_u16(request, CALL_SEND_COMMAND);
    put_target(request, argv[0]);
    put_text(request, type);
    put_u32(request, major);
    put_u32(request, minor);
    put_text(request, command);
    put_u32(request, (uint32_t)json->count);
    janet_buffer_push_bytes(request, json->data, json->count);

    return invoke_call(request, 1);
}

/*
 * A layout is a struct or table the app reads as JSON: {:split :row :children [...]} for a split,
 * {:pane id} for a pane already open, and {:open kind ...} for a new one. The shim checks only
 * that it is data it can write. The app checks its meaning, since the app trusts no helper.
 */
static Janet cfun_request_layout(int32_t argc, Janet *argv) {
    janet_fixarity(argc, 2);

    if (!janet_checktypes(argv[1], JANET_TFLAG_STRUCT | JANET_TFLAG_TABLE)) {
        janet_panic("the layout must be a struct or a table such as {:split :row :children [...]}");
    }

    json_context context = {"the layout", UNITERM_JANET_MAX_LAYOUT_BYTES, 1};
    JanetBuffer *json = json_object(argv[1], &context);
    JanetBuffer *request = janet_buffer(json->count + 64);

    put_u16(request, CALL_REQUEST_LAYOUT);
    put_target(request, argv[0]);
    put_u32(request, (uint32_t)json->count);
    janet_buffer_push_bytes(request, json->data, json->count);

    return invoke_call(request, 1);
}

static Janet cfun_read_clipboard(int32_t argc, Janet *argv) {
    (void)argv;
    janet_fixarity(argc, 0);

    JanetBuffer *request = janet_buffer(8);

    put_u16(request, CALL_READ_CLIPBOARD);

    return invoke_reply(request, 1, 1);
}

/* The text may be empty. A longer text is refused rather than cut, so the clipboard never holds
 * a part of what the script meant. */
static Janet cfun_write_clipboard(int32_t argc, Janet *argv) {
    janet_fixarity(argc, 1);

    JanetString text = janet_getstring(argv, 0);
    int32_t length = janet_string_length(text);

    if (length > UNITERM_JANET_MAX_CLIPBOARD_BYTES) {
        janet_panicf("the text is %d bytes, and the most is %d", length,
                     UNITERM_JANET_MAX_CLIPBOARD_BYTES);
    }

    if (!uniterm_valid_utf8(text, length)) janet_panic("the text is not UTF-8");

    JanetBuffer *request = janet_buffer(length + 8);

    put_u16(request, CALL_WRITE_CLIPBOARD);
    put_text(request, text);

    return invoke_call(request, 1);
}

/*
 * The spec is JSON text. The app reads it strictly and checks every field, so the shim checks only
 * that the text fits the wire and is UTF-8. A script that builds a spec as a struct writes the
 * text first.
 */
static Janet cfun_open_form(int32_t argc, Janet *argv) {
    janet_fixarity(argc, 1);

    JanetString spec = janet_getstring(argv, 0);
    int32_t length = janet_string_length(spec);

    if (length > UNITERM_JANET_MAX_FORM_BYTES) {
        janet_panicf("the form spec is %d bytes, and the most is %d", length,
                     UNITERM_JANET_MAX_FORM_BYTES);
    }

    if (!uniterm_valid_utf8(spec, length)) janet_panic("the form spec is not UTF-8");

    JanetBuffer *request = janet_buffer(length + 16);

    put_u16(request, CALL_OPEN_FORM);
    put_u32(request, (uint32_t)length);
    janet_buffer_push_bytes(request, spec, length);

    return invoke_call(request, 1);
}

static Janet cfun_wait_form(int32_t argc, Janet *argv) {
    janet_fixarity(argc, 1);

    JanetBuffer *request = janet_buffer(16);

    put_u16(request, CALL_WAIT_FORM);
    put_id(request, checked_id(argv[0], "the form"));

    return invoke_call(request, 1);
}

static Janet cfun_discard_form(int32_t argc, Janet *argv) {
    janet_fixarity(argc, 1);

    JanetBuffer *request = janet_buffer(16);

    put_u16(request, CALL_DISCARD_FORM);
    put_id(request, checked_id(argv[0], "the form"));

    return invoke_call(request, 1);
}

/*
 * Asking a form from a struct.
 *
 * The converter writes the struct as the spec's JSON, and checks the spelling Janet scripts use
 * for it. Keys are keywords, and so are the ids and the closed words, `:type`, `:block`, `:level`,
 * `:role`, and `:mode`. Text, choices, and string defaults are strings. A string where a keyword
 * belongs, or a keyword where a string belongs, is refused before anything is sent. The one place
 * keys are strings is a table block's `:rows`, whose keys are text the user reads.
 *
 * The app reads the JSON strictly and checks every field, so the converter checks only spelling.
 */

typedef enum form_scope { FORM_PLAIN, FORM_ROWS } form_scope;

static void form_refuse(const char *format, ...) __attribute__((noreturn, format(printf, 1, 2)));

/* Raises a struct of :kind :bad-argument and the formatted :message, as the app's refusal of a spec does. */
static void form_refuse(const char *format, ...) {
    char message[UNITERM_JANET_ERROR_CAPACITY];
    va_list arguments;

    va_start(arguments, format);
    vsnprintf(message, sizeof(message), format, arguments);
    va_end(arguments);
    panic_failure("bad-argument", message);
    abort();
}

typedef struct form_word {
    const char *key;
    const char *example;
} form_word;

/* The keys whose values are keywords, each with an example for the message. */
static const form_word form_words[] = {{"id", ":region"},   {"type", ":string"},
                                       {"block", ":paragraph"}, {"level", ":warning"},
                                       {"role", ":primary"}, {"mode", ":open"}};

static const form_word *form_word_for(const uint8_t *key, int32_t length) {
    for (size_t index = 0; index < sizeof(form_words) / sizeof(form_words[0]); index++) {
        const char *name = form_words[index].key;

        if ((size_t)length == strlen(name) && memcmp(key, name, (size_t)length) == 0) {
            return &form_words[index];
        }
    }

    return NULL;
}

/*
 * The shortest decimal that reads back as the same double, so `0.1` is written as 0.1 and not as
 * 0.10000000000000001. A whole number below 10^15 is written with no exponent.
 */
static void format_shortest(char *text, size_t size, double number) {
    if (number == 0) number = 0;

    if (number == floor(number) && fabs(number) < 1e15) {
        snprintf(text, size, "%.0f", number);

        return;
    }

    for (int precision = 1; precision <= 17; precision++) {
        snprintf(text, size, "%.*g", precision, number);

        if (strtod(text, NULL) == number) return;
    }
}

static void form_value(JanetBuffer *out, Janet value, int depth, const char *field,
                       form_scope scope, const json_context *context);

static void form_object(JanetBuffer *out, Janet value, int depth, form_scope scope,
                        const json_context *context) {
    const JanetKV *entries = NULL;
    int32_t count = 0;
    int32_t capacity = 0;
    int32_t written = 0;

    janet_dictionary_view(value, &entries, &count, &capacity);
    janet_buffer_push_u8(out, '{');

    for (const JanetKV *entry = janet_dictionary_next(entries, capacity, NULL); entry != NULL;
         entry = janet_dictionary_next(entries, capacity, entry)) {
        int wants_string = scope == FORM_ROWS;

        if (janet_checktype(entry->key, wants_string ? JANET_STRING : JANET_KEYWORD) == 0) {
            if (wants_string) {
                form_refuse("a key in a table block's :rows must be a string, since it is text "
                            "the user reads");
            }

            if (janet_checktype(entry->key, JANET_STRING)) {
                form_refuse("the key \"%s\" in the form must be a keyword, such as :text",
                            (const char *)janet_unwrap_string(entry->key));
            }

            form_refuse("a key in the form must be a keyword, such as :text");
        }

        const uint8_t *key = janet_unwrap_string(entry->key);
        int32_t length = janet_string_length(key);

        if (written > 0) janet_buffer_push_u8(out, ',');

        written++;
        json_text(out, key, length, context);
        janet_buffer_push_u8(out, ':');

        char name[64];

        snprintf(name, sizeof(name), "the :%.*s", length > 40 ? 40 : length, (const char *)key);

        const form_word *word = scope == FORM_PLAIN ? form_word_for(key, length) : NULL;

        if (word != NULL) {
            if (!janet_checktype(entry->value, JANET_KEYWORD)) {
                form_refuse("%s must be a keyword, such as %s", name, word->example);
            }

            const uint8_t *text = janet_unwrap_keyword(entry->value);

            json_text(out, text, janet_string_length(text), context);

            continue;
        }

        if (scope == FORM_ROWS && !janet_checktype(entry->value, JANET_STRING)) {
            form_refuse("a value in a table block's :rows must be a string");
        }

        int is_rows = scope == FORM_PLAIN && length == 4 && memcmp(key, "rows", 4) == 0;

        form_value(out, entry->value, depth + 1, name, is_rows ? FORM_ROWS : FORM_PLAIN, context);
    }

    janet_buffer_push_u8(out, '}');
}

static void form_value(JanetBuffer *out, Janet value, int depth, const char *field,
                       form_scope scope, const json_context *context) {
    if (depth > MAX_JSON_DEPTH) form_refuse("the form nests more than %d levels", MAX_JSON_DEPTH);

    if (out->count > context->limit) json_too_large(context);

    switch (janet_type(value)) {
    case JANET_NIL:
        janet_buffer_push_cstring(out, "null");
        return;

    case JANET_BOOLEAN:
        janet_buffer_push_cstring(out, janet_unwrap_boolean(value) ? "true" : "false");
        return;

    case JANET_NUMBER: {
        double number = janet_unwrap_number(value);
        char text[40];

        if (!isfinite(number)) form_refuse("%s must be a finite number", field);

        format_shortest(text, sizeof(text), number);
        janet_buffer_push_cstring(out, text);
        return;
    }

    case JANET_STRING: {
        const uint8_t *text = janet_unwrap_string(value);

        json_text(out, text, janet_string_length(text), context);
        return;
    }

    case JANET_BUFFER: {
        JanetBuffer *buffer = janet_unwrap_buffer(value);

        json_text(out, buffer->data, buffer->count, context);
        return;
    }

    case JANET_KEYWORD:
        form_refuse("%s must be a string, since only ids and the words :type, :block, :level, "
                    ":role, and :mode are keywords",
                    field);

    case JANET_ARRAY:
    case JANET_TUPLE: {
        const Janet *items = NULL;
        int32_t count = 0;

        janet_indexed_view(value, &items, &count);
        janet_buffer_push_u8(out, '[');

        for (int32_t index = 0; index < count; index++) {
            if (index > 0) janet_buffer_push_u8(out, ',');

            form_value(out, items[index], depth + 1, field, FORM_PLAIN, context);
        }

        janet_buffer_push_u8(out, ']');
        return;
    }

    case JANET_STRUCT:
    case JANET_TABLE:
        form_object(out, value, depth, scope, context);
        return;

    default:
        form_refuse("%s cannot hold a %s", field, janet_type_names[janet_type(value)]);
    }
}

static JanetBuffer *form_json(Janet spec) {
    json_context context = {"the form spec", UNITERM_JANET_MAX_FORM_BYTES, 1};
    JanetBuffer *json = janet_buffer(256);

    form_value(json, spec, 0, "the form", FORM_PLAIN, &context);

    if (json->count > context.limit) json_too_large(&context);

    return json;
}

/* Spells the result's `:action` and `:outcome` as keywords, as the spec spells an id. */
static Janet form_result(Janet decoded) {
    if (!janet_checktype(decoded, JANET_STRUCT)) return decoded;

    const JanetKV *entries = janet_unwrap_struct(decoded);
    int32_t count = janet_struct_length(entries);
    int32_t capacity = janet_struct_capacity(entries);
    JanetKV *copy = janet_struct_begin(count);

    for (const JanetKV *entry = janet_dictionary_next(entries, capacity, NULL); entry != NULL;
         entry = janet_dictionary_next(entries, capacity, entry)) {
        Janet value = entry->value;

        if ((janet_keyeq(entry->key, "action") || janet_keyeq(entry->key, "outcome"))
            && janet_checktype(value, JANET_STRING)) {
            JanetString text = janet_unwrap_string(value);

            value = janet_wrap_keyword(janet_keyword(text, janet_string_length(text)));
        }

        janet_struct_put(copy, entry->key, value);
    }

    return janet_wrap_struct(janet_struct_end(copy));
}

/*
 * Frees a form's handle after the form is done or the wait failed. A failure here, such as a
 * handle the app already freed, changes nothing the script needs, so it is dropped.
 */
static void discard_form_quietly(uint64_t handle) {
    JanetTryState state;

    if (janet_try(&state) == JANET_SIGNAL_OK) {
        JanetBuffer *request = janet_buffer(16);

        put_u16(request, CALL_DISCARD_FORM);
        put_id(request, handle);
        invoke_call(request, 1);
    }

    janet_restore(&state);
}

/*
 * Opens a form, waits for the user, and returns the result as a struct. The handle is discarded on
 * every way out. An error from the wait is discarded under and raised again as it was. A wait that
 * an interrupt cut short was discarded by the host's own call, so the function returns nil and the
 * interrupt stops the script.
 */
static Janet cfun_ask(int32_t argc, Janet *argv) {
    janet_fixarity(argc, 1);

    if (!janet_checktypes(argv[0], JANET_TFLAG_STRUCT | JANET_TFLAG_TABLE)) {
        form_refuse("the form must be a struct or a table such as {:items [...]}");
    }

    JanetBuffer *json = form_json(argv[0]);
    JanetBuffer *request = janet_buffer(json->count + 16);

    put_u16(request, CALL_OPEN_FORM);
    put_u32(request, (uint32_t)json->count);
    janet_buffer_push_bytes(request, json->data, json->count);

    uint64_t handle = checked_id(invoke_call(request, 1), "the form");
    JanetTryState state;
    Janet result = janet_wrap_nil();

    call_interrupted = 0;

    if (janet_try(&state) == JANET_SIGNAL_OK) {
        JanetBuffer *wait = janet_buffer(16);

        put_u16(wait, CALL_WAIT_FORM);
        put_id(wait, handle);
        result = invoke_call(wait, 1);
        janet_restore(&state);
    } else {
        Janet failure = state.payload;

        janet_restore(&state);
        discard_form_quietly(handle);
        janet_panicv(failure);
    }

    if (call_interrupted) {
        call_interrupted = 0;

        return janet_wrap_nil();
    }

    discard_form_quietly(handle);

    return form_result(result);
}

static const JanetReg uniterm_cfuns[] = {
    {"api-version", cfun_api_version,
     "(uniterm/api-version)\n\nThe version of the host API. It stays 0 until uniterm's "
     "maintainers declare it version 1. A change that breaks a script lands in place."},
    {"post-status", cfun_post_status,
     "(uniterm/post-status level text)\n\nPosts a message to the status bar. The level is "
     ":info, :warning, or :error."},
    {"list-windows", cfun_list_windows,
     "(uniterm/list-windows)\n\nReturns the script's own window as an array of one "
     "{:window id :pane id :control mode}, with :title and :key when its pane is "
     "remote-controlled. A script outside any pane gets an error."},
    {"list-panes", cfun_list_panes,
     "(uniterm/list-panes window)\n\nReturns the panes the script may control in its own window "
     "as an array of structs with :window, :pane, :applet, :control, :title, :focused, :tabs, and "
     ":directory when the applet reports one. Returns nil for any other window."},
    {"open-pane", cfun_open_pane,
     "(uniterm/open-pane kind pane &named axis control directory)\n\nSplits a pane the script "
     "may control and starts an applet in the new one, in the script's group. The kind is "
     ":terminal, :data-viewer, :map-viewer, :image-viewer, :text-viewer, or :browser. The axis "
     "is :row or :column. The control is :disconnected, the default, or :remote-controlled. The "
     "directory is an absolute path, and defaults to the one the pane reports. The pane may be "
     "{:nearest kind}. Returns the new pane's reference."},
    {"open-tab", cfun_open_tab,
     "(uniterm/open-tab pane &named directory)\n\nOpens a tab in a pane that has tabs and "
     "returns the tab's reference. The directory is an absolute path, and defaults to the one the "
     "pane reports. The pane may be {:nearest kind}."},
    {"send", cfun_send,
     "(uniterm/send pane name content)\n\nSends content to a viewer pane. The name is a file "
     "name such as \"report.csv\", and its extension picks how the viewer reads the content. "
     "The pane of a terminal refuses it. The pane may be {:nearest kind}, such as "
     "{:nearest :data-viewer}."},
    {"send-command", cfun_send_command,
     "(uniterm/send-command pane applet-type schema-version command &opt arguments)\n\nSends one "
     "command to the applet of a pane the script may control, and returns the applet's reply. "
     "The applet type and the command schema version are the ones the script was written for. "
     "The version is a [major minor] tuple, or a whole number n, which means [n 0]. The applet "
     "takes its own major and any minor up to its own, and refuses the rest. The command is a "
     "keyword or a string, and the arguments a struct or a table. A failure raises a struct of "
     ":kind and :message, where :kind is :bad-argument, :refused, :not-found, :unsupported, or "
     ":failed, or :reply-lost when the command ran and its reply could not reach the script. The "
     "pane may be {:nearest kind}."},
    {"request-layout", cfun_request_layout,
     "(uniterm/request-layout pane layout)\n\nLays out the script's own subtree, starting from a "
     "pane the script may control, and returns {:window id :panes [...]} with one reference for "
     "each leaf of the layout, in order. A split is {:split :row or :column :children [...]}, an "
     "open pane is {:pane id}, and a new pane is {:open kind} with :control, :directory, and :exec "
     "{:argv [...] :directory path :environment-keys [...]} as options. Any node may take "
     ":weight. The first layout holds the starting pane and new panes, and wraps them in a group "
     "the script owns. A later one from the same pane places every pane of that group once. A "
     "driver a layout declares runs only once the user chooses Run. A failure raises a struct of "
     ":kind and :message, and nothing changes. The kind is :busy while another layout from the "
     "script is still being prepared."},
    {"read-clipboard", cfun_read_clipboard,
     "(uniterm/read-clipboard)\n\nReturns the clipboard's plain text, or nil when it holds none. "
     "Reading is a permission of its own, apart from writing and from pane control. The user "
     "approves it in uniterm, and the call waits until the user answers. A failure raises a struct "
     "of :kind and :message, where :kind is :refused when the user denied it or the script may not "
     "ask, :busy while too many of the script's requests wait, or :failed."},
    {"write-clipboard", cfun_write_clipboard,
     "(uniterm/write-clipboard text)\n\nReplaces the clipboard with plain text, at most 32 KiB. "
     "Writing is a permission of its own, apart from reading and from pane control. The user "
     "approves it in uniterm, and the call waits until the user answers. A failure raises a struct "
     "of :kind and :message, as uniterm/read-clipboard does, and leaves the clipboard as it was."},
    {"open-form", cfun_open_form,
     "(uniterm/open-form spec)\n\nShows a form to the user and returns its handle at once. The "
     "spec is the form's JSON text, at most 32 KiB, which uniterm reads strictly. Asking is a "
     "permission of its own, :ask-user, which gives no pane control. A failure raises a struct of "
     ":kind and :message, where :kind is :bad-argument for a spec uniterm refuses, :busy while "
     "this program or this window holds as many forms as it may, :refused, or :failed."},
    {"wait-form", cfun_wait_form,
     "(uniterm/wait-form form)\n\nWaits for the user to finish a form and returns the result as a "
     "struct. Reading does not consume the result, so it may be read again until the handle is "
     "discarded. The wait has no deadline. A failure raises a struct of :kind and :message, where "
     ":kind is :ended when the form ended before the user answered it, or :not-found for a handle "
     "that is not open."},
    {"discard-form", cfun_discard_form,
     "(uniterm/discard-form form)\n\nFrees a form's handle. A form still open closes as ended, "
     "and a wait on it fails as :ended."},
    {"ask", cfun_ask,
     "(uniterm/ask form)\n\nShows a form to the user, waits for the answer, and returns the result "
     "as a struct. The form is a struct such as {:title \"Deploy\" :items [{:id :region :text "
     "\"Which region?\" :type :choice :choices [\"us-east\" \"eu-west\"]}] :actions [{:id :deploy "
     ":label \"Deploy\" :role :primary} {:id :cancel :role :cancel}]}. Keys, ids, and the words "
     ":type, :block, :level, :role, and :mode are keywords. Text, choices, and string defaults are "
     "strings, and so are the keys of a table block's :rows. A submitted form returns {:form "
     "handle :submission 1 :action :deploy :answers {:region \"us-east\"}}. A cancel button "
     "returns {:form handle :outcome :cancelled :action :cancel}, and closing the form returns "
     "{:form handle :outcome :dismissed}. The form's handle is discarded however the call ends. "
     "A failure raises a struct of :kind and :message, where :kind is :bad-argument for a form "
     "uniterm refuses, :busy while this program or this window holds as many forms as it may, "
     ":refused, :ended when the form ended before the user answered it, or :failed. Ctrl-C stops "
     "the script and closes the form."},
    {NULL, NULL, NULL}};

/*
 * The helpers that are written in Janet over `ask`. Each asks one question and returns its answer,
 * or nil when the user cancelled or closed the form. The source runs once for each run, in a scope
 * that sees only the core environment and `ask`, and its public bindings join the module.
 */
static const char *const helper_names[] = {"ask-confirm", "ask-text",  "ask-choose",
                                           "ask-number",  "ask-color", "ask-file"};

static const char helper_source[] =
    "(defn- answer-of [result]\n"
    "  (when (nil? (result :outcome)) ((result :answers) :answer)))\n"
    "\n"
    "(defn- question [prompt type extra]\n"
    "  (def item @{:id :answer :text prompt :type type :required true})\n"
    "  (eachp [key value] extra (when (not (nil? value)) (put item key value)))\n"
    "  (answer-of (ask {:items [(table/to-struct item)]})))\n"
    "\n"
    "(defn ask-confirm\n"
    "  \"(uniterm/ask-confirm prompt)\\n\\nAsks a yes or no question. Returns true for Yes, false for "
    "No, and nil when the user closed the form.\""
    "\n"
    "  [prompt]\n"
    "  (def result (ask {:items [{:block :paragraph :text prompt}]\n"
    "                    :actions [{:id :yes :label \"Yes\" :role :primary}\n"
    "                              {:id :no :label \"No\" :role :cancel}]}))\n"
    "  (cond\n"
    "    (= (result :action) :yes) true\n"
    "    (= (result :outcome) :cancelled) false))\n"
    "\n"
    "(defn ask-text\n"
    "  \"(uniterm/ask-text prompt &named default pattern)\\n\\nAsks for one line of text. The "
    "pattern is an ECMA-262 regular expression that the text must match. Returns the text, or nil "
    "when the user cancelled or closed the form.\""
    "\n"
    "  [prompt &named default pattern]\n"
    "  (question prompt :string\n"
    "           {:default default :validate (when pattern {:pattern pattern})}))\n"
    "\n"
    "(defn ask-choose\n"
    "  \"(uniterm/ask-choose prompt choices &named multiple other)\\n\\nAsks for one of the "
    "choices, or with :multiple some of them, as an array. With :other the user may type a choice "
    "of their own, which only one choice allows. Returns nil when the user cancelled or closed the "
    "form.\""
    "\n"
    "  [prompt choices &named multiple other]\n"
    "  (when (and multiple other)\n"
    "    (error {:kind :bad-argument :message \"a multiple choice cannot take :other\"}))\n"
    "  (question prompt (if multiple :multi :choice)\n"
    "           {:choices choices :other (when other true)}))\n"
    "\n"
    "(defn ask-number\n"
    "  \"(uniterm/ask-number prompt &named integer min max)\\n\\nAsks for a number, a whole one "
    "with :integer. Returns the number, or nil when the user cancelled or closed the form.\""
    "\n"
    "  [prompt &named integer min max]\n"
    "  (question prompt (if integer :integer :number)\n"
    "           {:validate (when (or min max)\n"
    "                        (table/to-struct\n"
    "                          (merge (if min @{:minimum min} @{}) (if max @{:maximum max} @{}))))}))\n"
    "\n"
    "(defn ask-color\n"
    "  \"(uniterm/ask-color prompt)\\n\\nAsks for a color. Returns it as #rrggbbaa, or nil when the "
    "user cancelled or closed the form.\""
    "\n"
    "  [prompt]\n"
    "  (question prompt :color {}))\n"
    "\n"
    "(defn ask-file\n"
    "  \"(uniterm/ask-file prompt &named mode types)\\n\\nAsks for a path. The mode is :open, the "
    "default, :directory, or :save, and the types are UTIs such as \\\"public.json\\\". Returns the "
    "path, or nil when the user cancelled or closed the form.\""
    "\n"
    "  [prompt &named mode types]\n"
    "  (question prompt :file {:mode mode :types types}))\n";

const char *uniterm_janet_module_function(size_t index) {
    size_t cfuns = sizeof(uniterm_cfuns) / sizeof(uniterm_cfuns[0]) - 1;
    size_t helpers = sizeof(helper_names) / sizeof(helper_names[0]);

    if (index < cfuns) return uniterm_cfuns[index].name;

    return index - cfuns < helpers ? helper_names[index - cfuns] : NULL;
}

/*
 * Defines the helpers in Janet over `ask` and puts them in the module. The caller roots `module`.
 * The helper source runs Janet code, which can collect, so the scope is rooted here until its
 * bindings are copied out.
 */
static int helper_gc_stress;

void uniterm_janet_set_helper_gc_stress(int enabled) {
    helper_gc_stress = enabled;
}

static void register_helpers(JanetTable *env, JanetTable *module) {
    JanetTable *scope = janet_table(0);
    Janet ignored;

    janet_gcroot(janet_wrap_table(scope));

    scope->proto = env;
    janet_table_put(scope, janet_csymbolv("ask"),
                    janet_table_get(module, janet_csymbolv("ask")));

    if (helper_gc_stress) janet_collect();

    if (janet_dostring(scope, helper_source, "uniterm-module", &ignored) != 0) {
        janet_gcunroot(janet_wrap_table(scope));
        janet_panic("the uniterm module's helpers did not install");
    }

    for (size_t index = 0; index < sizeof(helper_names) / sizeof(helper_names[0]); index++) {
        Janet name = janet_csymbolv(helper_names[index]);

        janet_table_put(module, name, janet_table_get(scope, name));
    }

    janet_gcunroot(janet_wrap_table(scope));
}

/*
 * Makes `(import uniterm)` find the module without a file. Janet's import checks the module cache
 * before it looks for a path, so a table placed there is the module.
 */
static void register_module(JanetTable *env) {
    JanetTable *module = janet_table(0);

    janet_gcroot(janet_wrap_table(module));
    janet_cfuns(module, "uniterm", uniterm_cfuns);
    register_helpers(env, module);

    Janet cache_binding = janet_table_get(env, janet_csymbolv("module/cache"));
    Janet cache_value = janet_table_get(janet_unwrap_table(cache_binding), janet_ckeywordv("value"));

    janet_table_put(janet_unwrap_table(cache_value), janet_cstringv("uniterm"),
                    janet_wrap_table(module));
    janet_gcunroot(janet_wrap_table(module));
}

static void fill_failure(uniterm_script_failure *failure, int32_t line, int32_t column,
                         const char *message) {
    failure->line = line;
    failure->column = column;

    strncpy(failure->message, message, sizeof(failure->message) - 1);
    failure->message[sizeof(failure->message) - 1] = '\0';
}

/*
 * Describes a value that Janet raised, for the message. Turning a value into text can raise too,
 * so it runs under its own boundary and falls back to a fixed message.
 */
static void describe_value(Janet value, int32_t line, int32_t column,
                           uniterm_script_failure *failure) {
    JanetTryState state;

    if (janet_try(&state) == JANET_SIGNAL_OK) {
        fill_failure(failure, line, column, (const char *)janet_to_string(value));
        janet_restore(&state);
    } else {
        janet_restore(&state);
        fill_failure(failure, line, column, "Janet raised an error that could not be described");
    }
}

/*
 * The innermost Janet frame that has a source position. A frame in a C function has none, so the
 * walk goes on to the caller.
 */
static int runtime_position(JanetFiber *fiber, int32_t *line, int32_t *column) {
    while (fiber->child != NULL) fiber = fiber->child;

    int32_t index = fiber->frame;

    while (index > 0) {
        JanetStackFrame *frame = (JanetStackFrame *)(fiber->data + index - JANET_FRAME_SIZE);
        index = frame->prevframe;

        if (frame->func == NULL || frame->pc == NULL) continue;

        JanetFuncDef *def = frame->func->def;

        if (def->sourcemap == NULL) continue;

        int32_t offset = (int32_t)(frame->pc - def->bytecode);

        *line = def->sourcemap[offset].line;
        *column = def->sourcemap[offset].column;

        return 1;
    }

    return 0;
}

/*
 * Stopping a running form.
 *
 * One SIGINT handler serves a script run and the REPL. It raises Janet's interrupt only while a
 * form runs. A signal that arrives with nothing running would leave the interrupt counter raised
 * and stop the next form at its first instruction, so it does nothing then.
 *
 * Ctrl-C and the app's stop request meet here. The app's request arrives on the helper's reader
 * thread, which signals the VM's own thread with pthread_kill. The handler is then the only code
 * that raises the interrupt.
 *
 * The gate and the count are kept by one thread only when the process's other threads block
 * SIGINT. Both modes do that: the helper blocks it before it starts any other thread, and the VM
 * thread unblocks it once its handler is installed.
 *
 * The handler only touches atomics and calls write.
 */
static JanetVM *interrupt_vm;
static pthread_t interrupt_thread;
static int interrupt_thread_set;
static int interrupt_evaluating;
static int interrupt_fired;
static int interrupt_hard;
static int interrupt_trace;
static int run_sigint_requested;

static void interrupt_on_sigint(int signal_number) {
    (void)signal_number;

    int running = __atomic_load_n(&interrupt_evaluating, __ATOMIC_SEQ_CST);

    if (interrupt_trace) {
        static const char evaluating[] = "[sigint evaluating]\n";
        static const char idle[] = "[sigint idle]\n";
        ssize_t ignored = running ? write(STDERR_FILENO, evaluating, sizeof(evaluating) - 1)
                                  : write(STDERR_FILENO, idle, sizeof(idle) - 1);

        (void)ignored;
    }

    JanetVM *vm = __atomic_load_n(&interrupt_vm, __ATOMIC_SEQ_CST);

    if (vm == NULL || !running) return;

    int before = __atomic_fetch_add(&interrupt_fired, 1, __ATOMIC_SEQ_CST);

    janet_interpreter_interrupt(vm);

    if (interrupt_hard && before >= 1) {
        static const char again[] = "uniterm: interrupted again, so uniterm ended the script\n";
        ssize_t ignored = write(STDERR_FILENO, again, sizeof(again) - 1);

        (void)ignored;
        _exit(UNITERM_JANET_EXIT_INTERRUPTED);
    }
}

/* Ends the window in which a signal interrupts, and balances every interrupt it raised. */
static int interrupt_settle(void) {
    __atomic_store_n(&interrupt_evaluating, 0, __ATOMIC_SEQ_CST);

    int fired = __atomic_exchange_n(&interrupt_fired, 0, __ATOMIC_SEQ_CST);

    JanetVM *vm = __atomic_load_n(&interrupt_vm, __ATOMIC_SEQ_CST);

    for (int index = 0; index < fired && vm != NULL; index++) {
        janet_interpreter_interrupt_handled(vm);
    }

    return fired;
}

/* Starts the window for the calling thread's VM. `hard` makes a second signal end the process. */
static void interrupt_attach(int hard) {
    interrupt_thread = pthread_self();
    interrupt_hard = hard;
    __atomic_store_n(&interrupt_vm, janet_local_vm(), __ATOMIC_SEQ_CST);

    __atomic_store_n(&interrupt_thread_set, 1, __ATOMIC_SEQ_CST);
}

/*
 * Ends the window and leaves the handler installed. A stop request or a SIGINT that arrives late,
 * after the form is over and while the helper is still shutting down, then finds a handler that
 * does nothing. Putting the old disposition back would let it hit the default action and kill the
 * process. The VM thread is the helper's main thread, so it outlives every late signal, and the
 * thread stays recorded for the same reason. The helper process ends right after.
 */
static void interrupt_detach(void) {
    interrupt_settle();
    __atomic_store_n(&interrupt_vm, NULL, __ATOMIC_SEQ_CST);
}

int uniterm_janet_interrupt_pending(void) {
    return __atomic_load_n(&interrupt_vm, __ATOMIC_SEQ_CST) != NULL
           && __atomic_load_n(&interrupt_fired, __ATOMIC_SEQ_CST) > 0;
}

void uniterm_janet_request_interrupt(void) {
    if (__atomic_load_n(&interrupt_thread_set, __ATOMIC_SEQ_CST)) {
        pthread_kill(interrupt_thread, SIGINT);
    }
}

void uniterm_janet_enable_run_sigint(void) {
    run_sigint_requested = 1;
}

void uniterm_janet_repl_trace_sigint(void) {
    interrupt_trace = 1;
}

/* Parses, compiles, and runs each top-level form in order, as `janet_dobytes` does. */
static uniterm_script_status evaluate(JanetTable *env, const char *name, const uint8_t *source,
                                      size_t length, uniterm_script_failure *failure) {
    JanetString where = janet_cstring(name);
    JanetParser *parser = janet_abstract(&janet_parser_type, sizeof(JanetParser));
    size_t index = 0;

    janet_gcroot(janet_wrap_string(where));
    janet_parser_init(parser);
    janet_gcroot(janet_wrap_abstract(parser));

    uniterm_script_status result = UNITERM_SCRIPT_OK;

    while (result == UNITERM_SCRIPT_OK) {
        while (result == UNITERM_SCRIPT_OK && janet_parser_has_more(parser)) {
            Janet form = janet_parser_produce(parser);
            JanetCompileResult compiled = janet_compile(form, env, where);

            if (compiled.status != JANET_COMPILE_OK) {
                int32_t line = (int32_t)parser->line;
                int32_t column = (int32_t)parser->column;

                if (compiled.error_mapping.line > 0 && compiled.error_mapping.column > 0) {
                    line = compiled.error_mapping.line;
                    column = compiled.error_mapping.column;
                }

                fill_failure(failure, line, column, (const char *)compiled.error);
                result = UNITERM_SCRIPT_COMPILE_ERROR;

                break;
            }

            JanetFunction *thunk = janet_thunk(compiled.funcdef);
            JanetFiber *fiber = janet_fiber(thunk, 64, 0, NULL);
            Janet value = janet_wrap_nil();

            fiber->env = env;

            JanetSignal signal = janet_continue(fiber, janet_wrap_nil(), &value);

            if (signal == JANET_SIGNAL_INTERRUPT) {
                result = UNITERM_SCRIPT_INTERRUPTED;
            } else if (signal != JANET_SIGNAL_OK && signal != JANET_SIGNAL_EVENT) {
                int32_t line = 0;
                int32_t column = 0;

                runtime_position(fiber, &line, &column);
                describe_value(value, line, column, failure);
                result = UNITERM_SCRIPT_RUNTIME_ERROR;
            }
        }

        if (result != UNITERM_SCRIPT_OK) break;

        enum JanetParserStatus status = janet_parser_status(parser);

        if (status == JANET_PARSE_DEAD) break;

        if (status == JANET_PARSE_ERROR) {
            fill_failure(failure, (int32_t)parser->line, (int32_t)parser->column,
                         janet_parser_error(parser));
            result = UNITERM_SCRIPT_PARSE_ERROR;

            break;
        }

        if (index >= length) {
            janet_parser_eof(parser);
        } else {
            janet_parser_consume(parser, source[index++]);
        }
    }

    janet_gcunroot(janet_wrap_abstract(parser));
    janet_gcunroot(janet_wrap_string(where));

    return result;
}

static uniterm_script_status run_entry(const uniterm_host *host, const char *name,
                                       const uint8_t *source, size_t length,
                                       const uniterm_package *package, uint32_t sandbox_flags,
                                       const char *const *arguments, size_t argument_count,
                                       uniterm_script_failure *failure);

/* A plain script keeps Janet's own module paths and loaders. */
uniterm_script_status uniterm_janet_run(const uniterm_host *host, const char *name,
                                        const uint8_t *source, size_t length,
                                        uint32_t sandbox_flags, const char *const *arguments,
                                        size_t argument_count, uniterm_script_failure *failure) {
    return run_entry(host, name, source, length, NULL, sandbox_flags, arguments, argument_count,
                     failure);
}

/*
 * `declare-permissions` expands to nothing. The declaration grants nothing at run time, because
 * the app read it before the file ran. The binding exists so that a misspelled form fails as an
 * unbound symbol instead of running as an ordinary call.
 */
static void bind_declaration_form(JanetTable *env) {
    Janet ignored;

    if (janet_dostring(env, "(defmacro declare-permissions [& _] nil)", "uniterm-declare",
                       &ignored) != 0) {
        janet_panic("the declaration form did not install");
    }
}

/*
 * The package loader.
 *
 * One package runs per VM, on the VM's thread, so its files are kept in statics for the run. The
 * resolver and the loader are host functions with names no script would choose, reached through
 * the one module path and the one loader this file installs. A script that calls them directly
 * gets nothing the import could not give it.
 */
static const uniterm_package *active_package;
static JanetTable *package_env;

static int package_index(const char *name) {
    if (active_package == NULL) return -1;

    for (size_t index = 0; index < active_package->count; index++) {
        if (strcmp(active_package->names[index], name) == 0) return (int)index;
    }

    return -1;
}

/*
 * Joins `base`, the importing file's folder, with a relative import path, folding `.` and `..`.
 * Returns 0 and leaves `out` empty when the path climbs out of the package or does not fit.
 */
static int package_join(const char *base, const char *relative, char *out, size_t capacity) {
    char joined[1024];
    int written = snprintf(joined, sizeof(joined), "%s%s%s", base, base[0] ? "/" : "", relative);

    out[0] = '\0';

    if (written < 0 || (size_t)written >= sizeof(joined)) return 0;

    const char *parts[64];
    size_t lengths[64];
    size_t depth = 0;
    const char *cursor = joined;

    while (*cursor) {
        const char *end = strchr(cursor, '/');
        size_t length = end ? (size_t)(end - cursor) : strlen(cursor);

        if (length == 0 || (length == 1 && cursor[0] == '.')) {
        } else if (length == 2 && cursor[0] == '.' && cursor[1] == '.') {
            if (depth == 0) return 0;

            depth--;
        } else {
            if (depth == 64) return 0;

            parts[depth] = cursor;
            lengths[depth] = length;
            depth++;
        }

        if (!end) break;

        cursor = end + 1;
    }

    size_t used = 0;

    for (size_t index = 0; index < depth; index++) {
        if (used + lengths[index] + 2 > capacity) return 0;

        if (index > 0) out[used++] = '/';

        memcpy(out + used, parts[index], lengths[index]);
        used += lengths[index];
    }

    out[used] = '\0';

    return used > 0;
}

/*
 * The one module path. `uniterm` is the bundled module. A path that starts with ./ or ../ is a
 * file of the package, as `<path>.janet` or `<path>/init.janet`. Anything else, such as a bare
 * name Janet would look for on its system path or an absolute path, finds nothing.
 */
static Janet cfun_package_resolve(int32_t argc, Janet *argv) {
    janet_fixarity(argc, 1);

    const char *path = (const char *)janet_getstring(argv, 0);

    if (strcmp(path, "uniterm") == 0) return janet_cstringv("uniterm");

    if (strncmp(path, "./", 2) != 0 && strncmp(path, "../", 3) != 0) return janet_wrap_nil();

    char base[1024] = "";
    Janet current = janet_dyn("current-file");

    if (janet_checktype(current, JANET_STRING)) {
        const char *file = (const char *)janet_unwrap_string(current);
        const char *slash = strrchr(file, '/');

        if (slash != NULL && (size_t)(slash - file) < sizeof(base)) {
            memcpy(base, file, (size_t)(slash - file));
            base[slash - file] = '\0';
        }
    }

    char joined[1024];

    if (!package_join(base, path, joined, sizeof(joined) - 16)) return janet_wrap_nil();

    static const char *const suffixes[] = {".janet", "/init.janet"};
    char candidate[1040];

    for (size_t index = 0; index < 2; index++) {
        snprintf(candidate, sizeof(candidate), "%s%s", joined, suffixes[index]);

        if (package_index(candidate) >= 0) return janet_cstringv(candidate);
    }

    return janet_wrap_nil();
}

/*
 * The one module loader. It runs a package file in a fresh environment whose current file is the
 * file's packaged path, as Janet's own source loader does, and returns that environment. A failure
 * in the module raises in the importing code.
 */
static Janet cfun_package_load(int32_t argc, Janet *argv) {
    janet_arity(argc, 1, -1);

    const char *name = (const char *)janet_getstring(argv, 0);
    int index = package_index(name);

    if (index < 0 || package_env == NULL) janet_panicf("%s is not a file of the package", name);

    JanetTable *env = janet_table(0);

    env->proto = package_env;
    janet_table_put(env, janet_ckeywordv("current-file"), janet_cstringv(name));
    janet_table_put(env, janet_ckeywordv("source"), janet_cstringv(name));

    Janet rooted = janet_wrap_table(env);

    janet_gcroot(rooted);

    const uint8_t *source = active_package->sources[index];
    size_t length = active_package->lengths[index];
    JanetParser *parser = janet_abstract(&janet_parser_type, sizeof(JanetParser));
    Janet parser_value = janet_wrap_abstract(parser);
    JanetString where = janet_cstring(name);
    Janet where_value = janet_wrap_string(where);
    size_t offset = 0;
    JanetSignal failed = JANET_SIGNAL_OK;
    Janet failure = janet_wrap_nil();

    janet_gcroot(parser_value);
    janet_gcroot(where_value);
    janet_parser_init(parser);

    while (failed == JANET_SIGNAL_OK) {
        while (failed == JANET_SIGNAL_OK && janet_parser_has_more(parser)) {
            Janet form = janet_parser_produce(parser);
            JanetCompileResult compiled = janet_compile(form, env, where);

            if (compiled.status != JANET_COMPILE_OK) {
                failure = janet_wrap_string(janet_formatc("%s:%d:%d: compile error: %S", name,
                                                          compiled.error_mapping.line,
                                                          compiled.error_mapping.column,
                                                          compiled.error));
                failed = JANET_SIGNAL_ERROR;

                break;
            }

            JanetFiber *fiber = janet_fiber(janet_thunk(compiled.funcdef), 64, 0, NULL);
            Janet value = janet_wrap_nil();

            fiber->env = env;

            JanetSignal signal = janet_continue(fiber, janet_wrap_nil(), &value);

            if (signal != JANET_SIGNAL_OK && signal != JANET_SIGNAL_EVENT) {
                failed = signal == JANET_SIGNAL_INTERRUPT ? JANET_SIGNAL_INTERRUPT
                                                          : JANET_SIGNAL_ERROR;
                failure = value;
            }
        }

        if (failed != JANET_SIGNAL_OK) break;

        enum JanetParserStatus status = janet_parser_status(parser);

        if (status == JANET_PARSE_DEAD) break;

        if (status == JANET_PARSE_ERROR) {
            failure = janet_wrap_string(janet_formatc("%s:%d:%d: parse error: %s", name,
                                                      (int32_t)parser->line,
                                                      (int32_t)parser->column,
                                                      janet_parser_error(parser)));
            failed = JANET_SIGNAL_ERROR;

            break;
        }

        if (offset >= length) {
            janet_parser_eof(parser);
        } else {
            janet_parser_consume(parser, source[offset++]);
        }
    }

    janet_gcunroot(parser_value);
    janet_gcunroot(where_value);
    janet_gcunroot(rooted);

    if (failed != JANET_SIGNAL_OK) janet_signalv(failed, failure);

    return janet_wrap_table(env);
}

static const JanetReg package_cfuns[] = {
    {"_uniterm/package-resolve", cfun_package_resolve, NULL},
    {"_uniterm/package-load", cfun_package_load, NULL},
    {NULL, NULL, NULL}};

/*
 * Replaces Janet's module paths and loaders with the package's, in the arrays every import reads.
 * Janet's source, native, and image loaders are removed, not only bypassed.
 */
static void install_package_loader(JanetTable *env) {
    janet_cfuns(env, NULL, package_cfuns);

    static const char setup[] =
        "(array/clear module/paths)\n"
        "(array/push module/paths [(fn [path] (_uniterm/package-resolve path)) :uniterm-package])\n"
        "(each loader (keys module/loaders) (put module/loaders loader nil))\n"
        "(put module/loaders :uniterm-package (fn [path & _] (_uniterm/package-load path)))\n";
    Janet ignored;

    if (janet_dostring(env, setup, "uniterm-package-loader", &ignored) != 0) {
        janet_panic("the package loader did not install");
    }
}

uniterm_script_status uniterm_janet_run_package(const uniterm_host *host, const char *entry,
                                                const uniterm_package *package,
                                                uint32_t sandbox_flags,
                                                const char *const *arguments,
                                                size_t argument_count,
                                                uniterm_script_failure *failure) {
    memset(failure, 0, sizeof(*failure));

    active_package = package;

    int index = package_index(entry);

    if (index < 0) {
        active_package = NULL;
        fill_failure(failure, 0, 0, "the entry is not a file of the package");

        return UNITERM_SCRIPT_START_FAILED;
    }

    uniterm_script_status status =
        run_entry(host, entry, package->sources[index], package->lengths[index], package,
                  sandbox_flags, arguments, argument_count, failure);

    active_package = NULL;
    package_env = NULL;

    return status;
}

/*
 * A declared file runs with the package loader and no package files, so an import finds only the
 * bundled uniterm module.
 */
uniterm_script_status uniterm_janet_run_declared(const uniterm_host *host, const char *name,
                                                 const uint8_t *source, size_t length,
                                                 uint32_t sandbox_flags,
                                                 const char *const *arguments,
                                                 size_t argument_count,
                                                 uniterm_script_failure *failure) {
    static const uniterm_package none = {NULL, NULL, NULL, 0};

    active_package = &none;

    uniterm_script_status status = run_entry(host, name, source, length, &none, sandbox_flags,
                                             arguments, argument_count, failure);

    active_package = NULL;
    package_env = NULL;

    return status;
}

/*
 * Every entry into Janet happens under one boundary. A panic in the core environment, the module
 * registration, or the evaluation lands here and comes back as a failure, so a longjmp never
 * leaves this function.
 */
static uniterm_script_status run_entry(const uniterm_host *host, const char *name,
                                       const uint8_t *source, size_t length,
                                       const uniterm_package *package, uint32_t sandbox_flags,
                                       const char *const *arguments, size_t argument_count,
                                       uniterm_script_failure *failure) {
    memset(failure, 0, sizeof(*failure));

    if (janet_init() != 0) {
        fill_failure(failure, 0, 0, "Janet did not start");

        return UNITERM_SCRIPT_START_FAILED;
    }

    volatile uniterm_script_status result = UNITERM_SCRIPT_OK;
    volatile int evaluating = 0;
    volatile int installed = 0;
    JanetTryState state;

    if (janet_try(&state) == JANET_SIGNAL_OK) {
        JanetTable *env = janet_core_env(NULL);

        active_host = host;
        register_module(env);

        JanetArray *args = janet_array((int32_t)argument_count);

        for (size_t index = 0; index < argument_count; index++) {
            janet_array_push(args, janet_cstringv(arguments[index]));
        }

        janet_table_put(env, janet_ckeywordv("args"), janet_wrap_array(args));
        bind_declaration_form(env);

        if (package != NULL) {
            package_env = env;
            janet_table_put(env, janet_ckeywordv("current-file"), janet_cstringv(name));
            install_package_loader(env);
        }

        janet_sandbox(sandbox_flags);

        if (run_sigint_requested) {
            struct sigaction action;

            memset(&action, 0, sizeof(action));
            action.sa_handler = interrupt_on_sigint;
            action.sa_flags = SA_RESTART;
            sigemptyset(&action.sa_mask);
            installed = sigaction(SIGINT, &action, NULL) == 0;

            interrupt_attach(1);

            if (installed) {
                sigset_t set;

                sigemptyset(&set);
                sigaddset(&set, SIGINT);
                pthread_sigmask(SIG_UNBLOCK, &set, NULL);
            }
        }

        evaluating = 1;

        if (installed) __atomic_store_n(&interrupt_evaluating, 1, __ATOMIC_SEQ_CST);

        result = evaluate(env, name, source, length, failure);

        janet_restore(&state);
    } else {
        Janet payload = state.payload;

        janet_restore(&state);
        describe_value(payload, 0, 0, failure);

        result = evaluating ? UNITERM_SCRIPT_RUNTIME_ERROR : UNITERM_SCRIPT_START_FAILED;
    }

    if (installed) interrupt_detach();

    run_sigint_requested = 0;
    active_host = NULL;
    janet_deinit();

    return result;
}

/*
 * The REPL.
 *
 * The loop is this file's own and not Janet's `repl` function, so an interrupt returns to the
 * prompt through code that can be read here. Each form runs in a fiber of its own, as `evaluate`
 * runs a script's, and a signal other than OK ends that form and nothing else.
 */

/*
 * Puts the terminal's signal characters back before a form runs. The line editor restores the
 * settings it found at its read. A terminal that started without ISIG would keep Ctrl-C a plain
 * byte for the whole session. A restore the editor could not finish would do the same.
 */
static void repl_ensure_terminal_signals(void) {
    struct termios settings;

    if (!isatty(STDIN_FILENO) || tcgetattr(STDIN_FILENO, &settings) != 0) return;

    if (settings.c_lflag & ISIG) return;

    settings.c_lflag |= ISIG;
    tcsetattr(STDIN_FILENO, TCSANOW, &settings);
}

void uniterm_janet_block_sigint(void) {
    sigset_t set;

    sigemptyset(&set);
    sigaddset(&set, SIGINT);
    pthread_sigmask(SIG_BLOCK, &set, NULL);
}

void uniterm_janet_repl_seed(const uint8_t *text, size_t length) {
    char *copy = malloc(length + 1);

    if (copy == NULL) return;

    memcpy(copy, text, length);
    copy[length] = '\0';

    uniterm_line_seed(copy);
    free(copy);
}

static void repl_report_running(const uniterm_repl_host *repl, int32_t running) {
    if (repl->running != NULL) repl->running(repl->userdata, running);
}

/*
 * Compiles and runs one form, then prints what Janet's own REPL prints for it. Returns 1 when the
 * form was interrupted, so the caller abandons the rest of the line.
 */
static int repl_run_form(JanetTable *env, Janet form, JanetString where, size_t line,
                          size_t column, const uniterm_repl_host *repl) {
    JanetCompileResult compiled = janet_compile(form, env, where);

    if (compiled.status != JANET_COMPILE_OK) {
        int32_t error_line = (int32_t)line;
        int32_t error_column = (int32_t)column;

        if (compiled.error_mapping.line > 0 && compiled.error_mapping.column > 0) {
            error_line = compiled.error_mapping.line;
            error_column = compiled.error_mapping.column;
        }

        janet_eprintf("%s:%d:%d: compile error: %S\n", (const char *)where, error_line,
                      error_column, compiled.error);

        return 0;
    }

    JanetFunction *thunk = janet_thunk(compiled.funcdef);
    JanetFiber *fiber = janet_fiber(thunk, 64, 0, NULL);
    Janet value = janet_wrap_nil();

    fiber->env = env;
    janet_gcroot(janet_wrap_fiber(fiber));

    repl_report_running(repl, 1);
    __atomic_store_n(&interrupt_evaluating, 1, __ATOMIC_SEQ_CST);

    JanetSignal signal = janet_continue(fiber, janet_wrap_nil(), &value);

    interrupt_settle();
    repl_report_running(repl, 0);

    int interrupted = signal == JANET_SIGNAL_INTERRUPT;

    if (interrupted) {
        janet_eprintf("interrupted\n");
    } else if (signal == JANET_SIGNAL_OK || signal == JANET_SIGNAL_YIELD ||
               signal == JANET_SIGNAL_EVENT) {
        JanetTable *holder = janet_table(1);

        janet_table_put(holder, janet_ckeywordv("value"), value);
        janet_table_put(env, janet_csymbolv("_"), janet_wrap_table(holder));
        janet_printf("%q\n", value);
    } else {
        janet_stacktrace(fiber, value);
    }

    janet_gcunroot(janet_wrap_fiber(fiber));

    return interrupted;
}

/* The prompt Janet's REPL shows: the line, and the delimiters still open. */
static void repl_prompt(JanetParser *parser, char *prompt, size_t capacity) {
    char delimiters[64];

    delimiters[0] = '\0';

    JanetCFunction state_of = janet_unwrap_cfunction(janet_resolve_core("parser/state"));
    Janet arguments[2] = {janet_wrap_abstract(parser), janet_ckeywordv("delimiters")};
    Janet state = state_of(2, arguments);

    if (janet_checktype(state, JANET_STRING)) {
        JanetString text = janet_unwrap_string(state);
        int32_t length = janet_string_length(text);

        if ((size_t)length >= sizeof(delimiters)) length = (int32_t)sizeof(delimiters) - 1;

        memcpy(delimiters, text, (size_t)length);
        delimiters[length] = '\0';
    }

    snprintf(prompt, capacity, "repl:%d:%s> ", (int)parser->line, delimiters);
}

/* Feeds one entered line to the parser, and runs each form it completes. */
static void repl_handle_line(JanetTable *env, JanetParser *parser, JanetBuffer *line,
                             JanetString where, const uniterm_repl_host *repl) {
    int32_t length = line->count;

    if (length > 0 && line->data[length - 1] == '\n') length--;

    if (length > 0 && repl->line != NULL) repl->line(repl->userdata, line->data, (size_t)length);

    for (int32_t index = 0; index < line->count; index++) {
        janet_parser_consume(parser, line->data[index]);

        if (janet_parser_status(parser) == JANET_PARSE_ERROR) {
            janet_eprintf("%s:%d:%d: parse error: %s\n", (const char *)where, (int)parser->line,
                          (int)parser->column, janet_parser_error(parser));
            janet_parser_flush(parser);

            return;
        }

        while (janet_parser_has_more(parser)) {
            size_t form_line = parser->line;
            size_t form_column = parser->column;

            if (repl_run_form(env, janet_parser_produce(parser), where, form_line, form_column,
                              repl)) {
                janet_parser_flush(parser);

                return;
            }
        }
    }
}

static void repl_loop(JanetTable *env, const uniterm_repl_host *repl) {
    JanetBuffer *line = janet_buffer(256);
    JanetParser *parser = janet_abstract(&janet_parser_type, sizeof(JanetParser));
    JanetString where = janet_cstring("repl");

    janet_parser_init(parser);
    janet_gcroot(janet_wrap_buffer(line));
    janet_gcroot(janet_wrap_abstract(parser));
    janet_gcroot(janet_wrap_string(where));

    for (;;) {
        char prompt[96];
        uniterm_line_result result;
        JanetTryState state;

        interrupt_settle();
        fflush(stdout);
        fflush(stderr);

        repl_prompt(parser, prompt, sizeof(prompt));
        result = uniterm_line_read(prompt, line, env);

        if (result == UNITERM_LINE_EOF) break;

        if (result == UNITERM_LINE_CANCEL) {
            janet_parser_flush(parser);

            continue;
        }

        repl_ensure_terminal_signals();

        if (janet_try(&state) == JANET_SIGNAL_OK) {
            repl_handle_line(env, parser, line, where, repl);
            janet_restore(&state);
        } else {
            Janet payload = state.payload;
            uniterm_script_failure described;

            janet_restore(&state);
            interrupt_settle();
            describe_value(payload, 0, 0, &described);
            janet_eprintf("error: %s\n", described.message);
        }
    }

    janet_gcunroot(janet_wrap_string(where));
    janet_gcunroot(janet_wrap_abstract(parser));
    janet_gcunroot(janet_wrap_buffer(line));
}

uniterm_script_status uniterm_janet_repl(const uniterm_host *host, const uniterm_repl_host *repl,
                                         uint32_t sandbox_flags, uniterm_script_failure *failure) {
    memset(failure, 0, sizeof(*failure));

    if (janet_init() != 0) {
        fill_failure(failure, 0, 0, "Janet did not start");

        return UNITERM_SCRIPT_START_FAILED;
    }

    volatile uniterm_script_status result = UNITERM_SCRIPT_OK;
    volatile int installed = 0;
    JanetTryState state;

    if (janet_try(&state) == JANET_SIGNAL_OK) {
        JanetTable *core = janet_core_env(NULL);

        active_host = host;
        register_module(core);

        JanetTable *env = janet_table(0);

        env->proto = core;
        janet_gcroot(janet_wrap_table(env));

        Janet ignored;

        if (janet_dostring(env, "(import uniterm)", "repl", &ignored) != 0) {
            janet_panic("the uniterm module did not load");
        }

        janet_sandbox(sandbox_flags);

        interrupt_attach(0);

        struct sigaction action;
        sigset_t set;

        memset(&action, 0, sizeof(action));
        action.sa_handler = interrupt_on_sigint;
        action.sa_flags = SA_RESTART;
        sigemptyset(&action.sa_mask);
        installed = sigaction(SIGINT, &action, NULL) == 0;

        sigemptyset(&set);
        sigaddset(&set, SIGINT);
        pthread_sigmask(SIG_UNBLOCK, &set, NULL);

        repl_loop(env, repl);
        janet_restore(&state);
    } else {
        Janet payload = state.payload;

        janet_restore(&state);
        describe_value(payload, 0, 0, failure);

        result = UNITERM_SCRIPT_RUNTIME_ERROR;
    }

    interrupt_detach();
    active_host = NULL;
    uniterm_line_close();
    janet_deinit();

    return result;
}

void uniterm_janet_drop_environment(void) {
    char **empty = calloc(1, sizeof(char *));

    if (empty != NULL) *_NSGetEnviron() = empty;
}

size_t uniterm_janet_environment_count(void) {
    char **entry = *_NSGetEnviron();
    size_t count = 0;

    while (entry != NULL && *entry != NULL) {
        count++;
        entry++;
    }

    return count;
}
