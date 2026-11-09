/*
 * Janet's own line editor, as the REPL uses it.
 *
 * Unbuilt/shell.c is the editor's source from the same release as the amalgamation. It is vendored
 * unchanged, since janet.pin hashes it. Its `main` is renamed out of the way here, and the file is
 * included whole so this translation unit can reach the editor's static history and completion
 * state. The rest of the target sees only the functions in uniterm_line.h.
 */

#define main uniterm_line_editor_unused_main
#include "Unbuilt/shell.c"
#undef main

#include "uniterm_line.h"

void uniterm_line_seed(const char *text) {
    char *copy = sdup(text);

    if (copy == NULL) return;

    if (gbl_history_count < JANET_HISTORY_MAX) {
        gbl_history_count++;
    } else {
        janet_free(gbl_history[JANET_HISTORY_MAX - 1]);
    }

    for (int index = gbl_history_count - 1; index > 0; index--) {
        gbl_history[index] = gbl_history[index - 1];
    }

    gbl_history[0] = copy;
}

uniterm_line_result uniterm_line_read(const char *prompt, JanetBuffer *buffer, JanetTable *env) {
    gbl_cancel_current_repl_form = 0;
    gbl_complete_env = env;

    janet_line_get(prompt, buffer);

    gbl_complete_env = NULL;

    if (gbl_cancel_current_repl_form) {
        gbl_cancel_current_repl_form = 0;

        return UNITERM_LINE_CANCEL;
    }

    return buffer->count == 0 ? UNITERM_LINE_EOF : UNITERM_LINE_OK;
}

void uniterm_line_close(void) {
    janet_line_deinit();
}
