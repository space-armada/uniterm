#include "uniterm_janet.h"

#include <malloc/malloc.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "janet.h"

/*
 * The allocator wrapper. janetconf.h routes every Janet allocation here. The count is the heap's
 * own size for each block, so a realloc that grows in place is still exact.
 *
 * The count is only read for now. A later cap checks `live_bytes` before it grants a block.
 */
static uint64_t live_bytes;

static void count_add(size_t bytes) {
    __atomic_fetch_add(&live_bytes, (uint64_t)bytes, __ATOMIC_RELAXED);
}

static void count_sub(size_t bytes) {
    __atomic_fetch_sub(&live_bytes, (uint64_t)bytes, __ATOMIC_RELAXED);
}

void *uniterm_janet_malloc(size_t size) {
    void *block = malloc(size);

    if (block != NULL) count_add(malloc_size(block));

    return block;
}

void *uniterm_janet_calloc(size_t count, size_t size) {
    void *block = calloc(count, size);

    if (block != NULL) count_add(malloc_size(block));

    return block;
}

void *uniterm_janet_realloc(void *pointer, size_t size) {
    size_t old_size = pointer != NULL ? malloc_size(pointer) : 0;
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
    CALL_SEND = 6
};

/* The largest ID a script may hold. Every integer below it is exact in a double. */
#define MAX_ID 9007199254740991.0
#define MAX_VALUE_DEPTH 8
#define MAX_VALUE_STRING 4096
#define MAX_VALUE_KEY 32
#define MAX_VALUE_FIELDS 64

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
static int valid_utf8(const uint8_t *bytes, int32_t length) {
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

static void check_text(JanetString text, const char *what, int32_t limit, int forbid_slash) {
    int32_t length = janet_string_length(text);

    if (length == 0) janet_panicf("%s must not be empty", what);

    if (length > limit) janet_panicf("%s is %d bytes, and the most is %d", what, length, limit);

    if (memchr(text, 0, (size_t)length) != NULL) janet_panicf("%s must not hold a NUL byte", what);

    if (forbid_slash && memchr(text, '/', (size_t)length) != NULL) {
        janet_panicf("%s must be a name, not a path", what);
    }

    if (!valid_utf8(text, length)) janet_panicf("%s is not UTF-8", what);
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
} call_options;

static call_options parse_options(int32_t argc, Janet *argv, int32_t first, int allow_axis) {
    call_options options = {janet_wrap_nil(), janet_wrap_nil()};
    int seen_axis = 0;
    int seen_directory = 0;

    if ((argc - first) % 2 != 0) janet_panic("each option needs a value, as in :directory \"/tmp\"");

    for (int32_t index = first; index < argc; index += 2) {
        if (allow_axis && janet_keyeq(argv[index], "axis")) {
            if (seen_axis++) janet_panic("the :axis is given twice");

            options.axis = argv[index + 1];
        } else if (janet_keyeq(argv[index], "directory")) {
            if (seen_directory++) janet_panic("the :directory is given twice");

            options.directory = argv[index + 1];
        } else {
            janet_panic(allow_axis ? "the options are :axis and :directory"
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

    case 4: {
        if (end - *cursor < 4) return 0;

        uint32_t length = 0;

        for (int step = 0; step < 4; step++) length = (length << 8) | *(*cursor)++;

        if (length > MAX_VALUE_STRING || (size_t)(end - *cursor) < length) return 0;
        if (!valid_utf8(*cursor, (int32_t)length)) return 0;

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

/* Runs one call through the host and turns its reply into a Janet value. */
static Janet invoke(JanetBuffer *request) {
    const uniterm_host *host = active_host;

    if (host == NULL || host->call == NULL) janet_panic("this function is not available");

    char error[UNITERM_JANET_ERROR_CAPACITY];
    uint8_t *reply = NULL;
    size_t reply_length = 0;

    error[0] = '\0';

    int32_t status = host->call(host->userdata, request->data, (size_t)request->count, &reply,
                                &reply_length, error, sizeof(error));

    error[sizeof(error) - 1] = '\0';

    if (status != 0) {
        free(reply);
        janet_panicf("%s", error[0] != '\0' ? error : "the host refused the call");
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
    put_pane_reference(request, argv[1]);

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

    return invoke(request);
}

static Janet cfun_open_tab(int32_t argc, Janet *argv) {
    janet_arity(argc, 1, -1);

    call_options options = parse_options(argc, argv, 1, 0);
    JanetBuffer *request = janet_buffer(64);

    put_u16(request, CALL_OPEN_TAB);
    put_pane_reference(request, argv[0]);
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
    put_pane_reference(request, argv[0]);
    put_text(request, name);
    janet_buffer_push_bytes(request, bytes, length);

    return invoke(request);
}

static const JanetReg uniterm_cfuns[] = {
    {"api-version", cfun_api_version,
     "(uniterm/api-version)\n\nThe version of the host API. A change that breaks a script "
     "changes it."},
    {"post-status", cfun_post_status,
     "(uniterm/post-status level text)\n\nPosts a message to the status bar. The level is "
     ":info, :warning, or :error."},
    {"list-windows", cfun_list_windows,
     "(uniterm/list-windows)\n\nReturns the open windows, oldest first, as an array of "
     "{:window id :title text :key bool}."},
    {"list-panes", cfun_list_panes,
     "(uniterm/list-panes window)\n\nReturns the panes of a window as an array of structs with "
     ":window, :pane, :applet, :title, :focused, :tabs, and :directory when the applet reports "
     "one. Returns nil when the window is not open."},
    {"open-pane", cfun_open_pane,
     "(uniterm/open-pane kind pane &named axis directory)\n\nSplits a pane and starts an applet "
     "in the new one. The kind is :terminal, :data-viewer, :map-viewer, :image-viewer, "
     ":text-viewer, or :browser. The axis is :row or :column. The directory is an absolute path, "
     "and defaults to the one the pane reports. Returns the new pane's reference."},
    {"open-tab", cfun_open_tab,
     "(uniterm/open-tab pane &named directory)\n\nOpens a tab in a pane that has tabs and "
     "returns the tab's reference. The directory is an absolute path, and defaults to the one the "
     "pane reports."},
    {"send", cfun_send,
     "(uniterm/send pane name content)\n\nSends content to a viewer pane. The name is a file "
     "name such as \"report.csv\", and its extension picks how the viewer reads the content. "
     "The pane of a terminal refuses it."},
    {NULL, NULL, NULL}};

/*
 * Makes `(import uniterm)` find the module without a file. Janet's import checks the module cache
 * before it looks for a path, so a table placed there is the module.
 */
static void register_module(JanetTable *env) {
    JanetTable *module = janet_table(0);

    janet_cfuns(module, "uniterm", uniterm_cfuns);

    Janet cache_binding = janet_table_get(env, janet_csymbolv("module/cache"));
    Janet cache_value = janet_table_get(janet_unwrap_table(cache_binding), janet_ckeywordv("value"));

    janet_table_put(janet_unwrap_table(cache_value), janet_cstringv("uniterm"),
                    janet_wrap_table(module));
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

            if (signal != JANET_SIGNAL_OK && signal != JANET_SIGNAL_EVENT) {
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

/*
 * Every entry into Janet happens under one boundary. A panic in the core environment, the module
 * registration, or the evaluation lands here and comes back as a failure, so a longjmp never
 * leaves this function.
 */
uniterm_script_status uniterm_janet_run(const uniterm_host *host, const char *name,
                                        const uint8_t *source, size_t length,
                                        uint32_t sandbox_flags, const char *const *arguments,
                                        size_t argument_count, uniterm_script_failure *failure) {
    memset(failure, 0, sizeof(*failure));

    if (janet_init() != 0) {
        fill_failure(failure, 0, 0, "Janet did not start");

        return UNITERM_SCRIPT_START_FAILED;
    }

    volatile uniterm_script_status result = UNITERM_SCRIPT_OK;
    volatile int evaluating = 0;
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
        janet_sandbox(sandbox_flags);

        evaluating = 1;
        result = evaluate(env, name, source, length, failure);

        janet_restore(&state);
    } else {
        Janet payload = state.payload;

        janet_restore(&state);
        describe_value(payload, 0, 0, failure);

        result = evaluating ? UNITERM_SCRIPT_RUNTIME_ERROR : UNITERM_SCRIPT_START_FAILED;
    }

    active_host = NULL;
    janet_deinit();

    return result;
}
