#ifndef UNITERM_JANET_H
#define UNITERM_JANET_H

#include <stddef.h>
#include <stdint.h>

/*
 * What Swift sees of Janet. This header never includes janet.h, so no Janet type or macro reaches
 * Swift. Janet raises errors with longjmp. Every Janet call therefore happens in this target, and
 * a longjmp never crosses a Swift frame.
 */

/* The scripting API's version. It stays 0 until uniterm's maintainers declare it version 1. */
#define UNITERM_JANET_API_VERSION 0

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
#define UNITERM_JANET_MAX_COMMAND_NAME_BYTES 64
#define UNITERM_JANET_MAX_COMMAND_ARGUMENT_BYTES (32 * 1024)
#define UNITERM_JANET_MAX_LAYOUT_BYTES (32 * 1024)
#define UNITERM_JANET_MAX_CLIPBOARD_BYTES (32 * 1024)
#define UNITERM_JANET_MAX_FORM_BYTES (32 * 1024)

/*
 * A call callback returns this plus a failure kind when the app answered with a failure, so a
 * function that raises a structured error can name the kind. Any other nonzero status is a
 * failure on the helper's side.
 */
#define UNITERM_JANET_APP_FAILURE_BASE 16

/*
 * A call callback returns this when a wait for a form was cut short by an interrupt. The host has
 * already discarded the form's handle and read both replies. The shim returns nil to the script,
 * and the interrupt stops the script at its next instruction. No other call returns it.
 */
#define UNITERM_JANET_CALL_INTERRUPTED 2

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

/*
 * Whether an interrupt is waiting to stop the running script or REPL form. The host's wait for a
 * reply polls it, since a signal alone does not wake a thread that waits on a condition. It is
 * false when nothing is running.
 */
int uniterm_janet_interrupt_pending(void);

/*
 * Makes the next run collect garbage just before it defines the module's helpers, so a test can
 * prove the module and the helpers' scope survive a collection there.
 */
void uniterm_janet_set_helper_gc_stress(int enabled);

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
 * The files of a verified controller package, by their packaged paths. The caller keeps the
 * memory alive for the run.
 */
typedef struct uniterm_package {
    const char *const *names;
    const uint8_t *const *sources;
    const size_t *lengths;
    size_t count;
} uniterm_package;

/*
 * Runs a controller package's Janet entry, `entry`, as uniterm_janet_run runs a script, with a
 * fixed module loader in place of Janet's own.
 *
 * Before any of the package's code runs, the loader replaces every module path and every module
 * loader. An import then finds only the bundled uniterm module and the package's own files, held
 * in memory, never a file on disk. A relative import resolves against the importing file's place
 * in the package. Native modules and images have no loader at all, so neither loads from anywhere.
 * The sandbox is applied after the loader is in place and before the entry runs.
 */
uniterm_script_status uniterm_janet_run_package(const uniterm_host *host, const char *entry,
                                                const uniterm_package *package,
                                                uint32_t sandbox_flags,
                                                const char *const *arguments,
                                                size_t argument_count,
                                                uniterm_script_failure *failure);

/*
 * Runs a declared script file as uniterm_janet_run runs a script, with a fixed module loader that
 * resolves only the bundled uniterm module. No import finds a file, relative or absolute, and
 * native modules and images have no loader at all. `name` is the file's name in errors.
 */
uniterm_script_status uniterm_janet_run_declared(const uniterm_host *host, const char *name,
                                                 const uint8_t *source, size_t length,
                                                 uint32_t sandbox_flags,
                                                 const char *const *arguments,
                                                 size_t argument_count,
                                                 uniterm_script_failure *failure);

/* The most bytes of JSON a declaration may convert to. ScriptProtocol holds the same number. */
#define UNITERM_JANET_MAX_DECLARATION_BYTES (32 * 1024)

/* The most bytes of a declaration refusal, with its terminator. */
#define UNITERM_JANET_DECLARATION_MESSAGE_CAPACITY 512

typedef enum uniterm_declaration_status {
    /* The file's first form is not a declaration. The file is not declared. */
    UNITERM_DECLARATION_NONE = 0,

    /* The first form is a valid declaration, converted to JSON in `json`. */
    UNITERM_DECLARATION_FOUND = 1,

    /* The file has a declaration problem. `message` says which. */
    UNITERM_DECLARATION_INVALID = 2
} uniterm_declaration_status;

typedef struct uniterm_declaration {
    /* From malloc, owned by the caller, and only for FOUND. Release it with the function below. */
    char *json;
    size_t json_length;
    char message[UNITERM_JANET_DECLARATION_MESSAGE_CAPACITY];
} uniterm_declaration;

/*
 * Reads a script file's first form with Janet's own parser, in a VM of its own, and evaluates
 * nothing. When the form is `(declare-permissions ...)`, it checks that nothing else in the file
 * declares, converts the declaration to JSON, and returns FOUND. The JSON is
 * {"header": {...}, "permissions": [{...}, ...]}, with the header absent when the file names none.
 * A keyword and a string both become a JSON string, after the declaration's field types are
 * checked. Only literal data is accepted: keywords, strings, whole numbers, bracketed lists, and
 * structs.
 *
 * The reader refuses what Janet's parser would merge or drop, which no later step could see: a
 * struct that repeats a key, and a nil key or value. It can only refuse. A file that does not
 * parse reads as NONE, since the run reports the parse error. The call starts and ends a VM on the
 * calling thread, so no other VM may be running there.
 */
uniterm_declaration_status uniterm_janet_read_declaration(const uint8_t *source, size_t length,
                                                          uniterm_declaration *declaration);

void uniterm_janet_free_declaration(uniterm_declaration *declaration);

/*
 * The names of the functions the `uniterm` module offers, without a prefix, one for each index from
 * zero. Returns NULL past the last. The script lint reads them to tell a function uniterm offers
 * from a name that only looks like one.
 */
const char *uniterm_janet_module_function(size_t index);

typedef enum uniterm_form_kind {
    UNITERM_FORM_SYMBOL = 0,
    UNITERM_FORM_KEYWORD = 1,
    UNITERM_FORM_STRING = 2,
    /* A number, nil, a boolean, or a buffer. `text` is empty. */
    UNITERM_FORM_ATOM = 3,
    /* `(...)`. The children are the elements. */
    UNITERM_FORM_PAREN = 4,
    /* `[...]`, which reads as a bracketed tuple. */
    UNITERM_FORM_BRACKET = 5,
    /* `@[...]`. */
    UNITERM_FORM_ARRAY = 6,
    /* `{...}` or `@{...}`. The children alternate key and value. */
    UNITERM_FORM_STRUCT = 7,
    UNITERM_FORM_TABLE = 8
} uniterm_form_kind;

/* One form of a parsed file. The nodes of a file are in pre-order, each followed by its subtree. */
typedef struct uniterm_form_node {
    int32_t kind;

    /* The number of direct children, which a struct or table counts as keys plus values. */
    int32_t children;

    /* Where the form starts, 1-based. A form with no recorded start gets where its parent starts. */
    int32_t line;
    int32_t column;

    /* The symbol, keyword, or string bytes, as an offset and length into the file's text. */
    size_t text_offset;
    size_t text_length;
} uniterm_form_node;

typedef struct uniterm_forms {
    /* Both from malloc, owned by the caller, and released with the function below. */
    uniterm_form_node *nodes;
    size_t node_count;
    char *text;
    size_t text_length;

    /* Nonempty when the file does not parse. `error_line` and `error_column` are 1-based. */
    char message[UNITERM_JANET_DECLARATION_MESSAGE_CAPACITY];
    int32_t error_line;
    int32_t error_column;

    /* The number of top-level forms, which are the first nodes of the list's roots. */
    size_t root_count;
} uniterm_forms;

typedef enum uniterm_forms_status {
    UNITERM_FORMS_OK = 0,
    /* The file did not parse, or is nested too deeply. `message` says which. */
    UNITERM_FORMS_ERROR = 1
} uniterm_forms_status;

/*
 * Parses a script file with Janet's own parser, in a VM of its own, and evaluates nothing. It
 * returns the file's top-level forms as data. A struct's entries come in the parser's order, with
 * duplicate keys merged and nil entries dropped as the run would see them. Nesting past 512 levels
 * is an error. The call starts and ends a VM on the calling thread, so no other VM may be running
 * there.
 */
uniterm_forms_status uniterm_janet_parse_forms(const uint8_t *source, size_t length,
                                               uniterm_forms *forms);

void uniterm_janet_free_forms(uniterm_forms *forms);

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
