#ifndef UNITERM_JANET_H
#define UNITERM_JANET_H

#include <stddef.h>
#include <stdint.h>

/*
 * What Swift sees of Janet. This header never includes janet.h, so no Janet type or macro reaches
 * Swift. Janet raises errors with longjmp. Every Janet call therefore happens in this target, and
 * a longjmp never crosses a Swift frame.
 */

#define UNITERM_JANET_API_VERSION 1

/* The most bytes a host function's error message may carry, with its terminator. */
#define UNITERM_JANET_ERROR_CAPACITY 256

/* The most bytes of status text a script may post. */
#define UNITERM_JANET_MAX_STATUS_BYTES 2048

/*
 * The limits the wire shares. ScriptProtocol in ScriptWire holds the same numbers, and a script
 * that sends the most bytes proves they agree.
 */
#define UNITERM_JANET_MAX_KIND_BYTES 32
#define UNITERM_JANET_MAX_DIRECTORY_BYTES 1024
#define UNITERM_JANET_MAX_FILE_NAME_BYTES 255
#define UNITERM_JANET_MAX_SEND_BYTES (1024 * 1024)

/* Levels as scripts name them: :info, :warning, :error. */
#define UNITERM_STATUS_INFO 0
#define UNITERM_STATUS_WARNING 1
#define UNITERM_STATUS_ERROR 2

/*
 * The host's side of the `uniterm` module. Each callback is called on the thread that runs the
 * script, with arguments already checked. It returns 0 on success. On failure it writes a message
 * into `error` and returns nonzero, and the shim raises it to the script as a Janet error. A
 * callback must not unwind or trap.
 *
 * `call` runs every function but post-status. The shim writes the call in the wire's encoding and
 * passes the bytes. The callback hands back the reply's bytes in memory from malloc, which the
 * shim frees, or none when the function returns nothing. The shim builds the Janet values, so no
 * Janet error can unwind a Swift frame.
 */
typedef struct uniterm_host {
    void *userdata;
    int32_t (*post_status)(void *userdata, int32_t level, const uint8_t *text, size_t length,
                           char *error, size_t capacity);
    int32_t (*call)(void *userdata, const uint8_t *request, size_t length, uint8_t **reply,
                    size_t *reply_length, char *error, size_t capacity);
} uniterm_host;

typedef enum uniterm_script_status {
    UNITERM_SCRIPT_OK = 0,
    UNITERM_SCRIPT_PARSE_ERROR = 1,
    UNITERM_SCRIPT_COMPILE_ERROR = 2,
    UNITERM_SCRIPT_RUNTIME_ERROR = 3,
    UNITERM_SCRIPT_START_FAILED = 4
} uniterm_script_status;

typedef struct uniterm_script_failure {
    int32_t line;
    int32_t column;
    char message[1024];
} uniterm_script_failure;

/*
 * The capabilities a script has by default: none. Each bit is a Janet sandbox flag. A caller that
 * grants a capability clears its bit.
 */
extern const uint32_t uniterm_janet_default_sandbox;

/*
 * Runs one script in a fresh VM on the calling thread, then tears the VM down. The thread must
 * not run another VM at the same time. `name` is the script's name in errors. On any status other
 * than OK, `failure` holds the line, column, and message. Line and column are zero when Janet
 * gave none.
 */
uniterm_script_status uniterm_janet_run(const uniterm_host *host, const char *name,
                                        const uint8_t *source, size_t length,
                                        uint32_t sandbox_flags, uniterm_script_failure *failure);

/* The bytes the VM holds now, as counted by the allocator wrapper. */
uint64_t uniterm_janet_live_bytes(void);

/* The Janet release this build embeds, such as "1.43.0". */
const char *uniterm_janet_version(void);

#endif
