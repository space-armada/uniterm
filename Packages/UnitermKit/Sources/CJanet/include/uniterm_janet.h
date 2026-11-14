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
    UNITERM_SCRIPT_START_FAILED = 4,
    UNITERM_SCRIPT_INTERRUPTED = 5
} uniterm_script_status;

/* The most memory Janet may hold in one helper, in bytes. 1 GiB. */
#define UNITERM_JANET_DEFAULT_MEMORY_CAP ((uint64_t)1 << 30)

/*
 * The status a helper exits with when its allocator refuses a block for passing the cap. It is
 * outside sysexits.h, which names nothing for this.
 */
#define UNITERM_JANET_EXIT_MEMORY_LIMIT 79

/* The status of a run that Ctrl-C stopped, as a shell reports a process that died of SIGINT. */
#define UNITERM_JANET_EXIT_INTERRUPTED 130

/*
 * Sets the most bytes the allocator wrapper lets Janet hold. An allocation that would pass it
 * writes a message to standard error, sends the notice below when one is set, and ends the process
 * with UNITERM_JANET_EXIT_MEMORY_LIMIT. It never returns null, since Janet's out-of-memory path is
 * not safe to unwind. Call it before the VM starts.
 */
void uniterm_janet_set_memory_cap(uint64_t bytes);

/* The cap now in force. */
uint64_t uniterm_janet_memory_cap(void);

/*
 * Sets a function the allocator calls, on the VM thread, just before it ends the process for the
 * cap. The REPL helper uses it to send the app a notice through the connection's own locked send,
 * so the notice never interleaves with a pong from the watchdog thread. It must not allocate
 * through Janet. The failure path itself formats nothing and uses no stdio, so output a script
 * printed but did not flush may be lost.
 */
void uniterm_janet_set_memory_limit_hook(void (*hook)(void *userdata), void *userdata);

/*
 * Makes the next uniterm_janet_run stop on SIGINT. The first SIGINT while the script runs stops
 * it, and a second ends the process at once, so a script stuck in a C call that the interrupt
 * never reaches still ends. Call it before the run.
 *
 * The handler stays installed after the run and does nothing once the run is over, so a late
 * signal never reaches the default action. The run unblocks SIGINT on its own thread only. A
 * caller that blocked it on every other thread, with uniterm_janet_block_sigint, keeps the
 * handler on one thread.
 */
void uniterm_janet_enable_run_sigint(void);

/*
 * Asks the running script or REPL form to stop, as a SIGINT does. Any thread may call it. It
 * signals the VM's own thread, so it takes the same gated path as Ctrl-C: it does nothing when no
 * form is running, and it leaves no interrupt behind for the next one.
 */
void uniterm_janet_request_interrupt(void);

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
 * Looks up a capability by the name Janet's `sandbox` accepts, such as "fs-read". On success it
 * stores the capability's bits in `flags` and returns 0. It returns -1 for a name Janet does not
 * accept, and for "all", which forbids everything and is never something to grant.
 */
int uniterm_janet_capability_flags(const char *name, uint32_t *flags);

/*
 * Runs one script in a fresh VM on the calling thread, then tears the VM down. The thread must
 * not run another VM at the same time. `name` is the script's name in errors. The script reads
 * `arguments` through `(dyn :args)`, as it would under Janet's own command. On any status other
 * than OK, `failure` holds the line, column, and message. Line and column are zero when Janet
 * gave none.
 */
uniterm_script_status uniterm_janet_run(const uniterm_host *host, const char *name,
                                        const uint8_t *source, size_t length,
                                        uint32_t sandbox_flags, const char *const *arguments,
                                        size_t argument_count, uniterm_script_failure *failure);

/*
 * What the REPL reports to its host. Both callbacks run on the thread that runs the REPL, and must
 * not unwind or trap. `line` gets each non-blank line the user enters, without its newline, before
 * the line is evaluated. `running` gets 1 when a form starts to evaluate and 0 when it ends.
 */
typedef struct uniterm_repl_host {
    void *userdata;
    void (*line)(void *userdata, const uint8_t *text, size_t length);
    void (*running)(void *userdata, int32_t running);
} uniterm_repl_host;

/*
 * Blocks SIGINT on the calling thread. The VM's thread calls it before it starts any other thread,
 * so every other thread inherits the block and the signal can only reach the VM's own. The REPL
 * and the run each unblock it again on the VM thread, once their handler is installed.
 */
void uniterm_janet_block_sigint(void);

/*
 * Makes the REPL's SIGINT handler write `[sigint evaluating]` or `[sigint idle]` to stderr each
 * time the signal arrives. It tells a signal that never arrives from one that arrives and fails to
 * stop the form. Debug builds only. Call it before the REPL starts.
 */
void uniterm_janet_repl_trace_sigint(void);

/*
 * Puts a line into the line editor's recall history as the newest entry, on the calling thread. It
 * is recall only, and is never evaluated. Call it in order from oldest to newest, before the REPL
 * starts. The editor keeps the newest 100.
 */
void uniterm_janet_repl_seed(const uint8_t *text, size_t length);

/*
 * Runs the REPL on the calling thread until the input ends, then tears the VM down. It reads with
 * Janet's own line editor, evaluates each form in the user's environment, and prints results as
 * Janet's REPL does. An error in a form is printed and the prompt returns, with the environment's
 * definitions intact. SIGINT stops a running form and returns to the prompt, and clears the line at
 * an idle prompt. The `uniterm` module is already imported.
 */
uniterm_script_status uniterm_janet_repl(const uniterm_host *host, const uniterm_repl_host *repl,
                                         uint32_t sandbox_flags, uniterm_script_failure *failure);

/*
 * Replaces the process's environment with an empty one. Call it on the helper's main thread, before
 * any other thread starts. The old block is left unreferenced, since a library may still point
 * into it.
 */
void uniterm_janet_drop_environment(void);

/* How many variables the process's environment holds now. */
size_t uniterm_janet_environment_count(void);

/* The bytes the VM holds now, as counted by the allocator wrapper. */
uint64_t uniterm_janet_live_bytes(void);

/* The Janet release this build embeds, such as "1.43.0". */
const char *uniterm_janet_version(void);

#endif
