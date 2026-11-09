#include "uniterm_janet.h"

#include <malloc/malloc.h>
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

static const JanetReg uniterm_cfuns[] = {
    {"api-version", cfun_api_version,
     "(uniterm/api-version)\n\nThe version of the host API. A change that breaks a script "
     "changes it."},
    {"post-status", cfun_post_status,
     "(uniterm/post-status level text)\n\nPosts a message to the status bar. The level is "
     ":info, :warning, or :error."},
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
                                        uint32_t sandbox_flags, uniterm_script_failure *failure) {
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
