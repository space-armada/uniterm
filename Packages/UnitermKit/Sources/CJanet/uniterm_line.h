#ifndef UNITERM_LINE_H
#define UNITERM_LINE_H

#include "janet.h"

/*
 * The REPL's use of Janet's own line editor. The editor's source is vendored unchanged and
 * included whole by uniterm_janet_line.c, so its static state is reachable only from that file.
 * This header is private to the target.
 */

typedef enum uniterm_line_result {
    UNITERM_LINE_OK = 0,
    UNITERM_LINE_CANCEL = 1,
    UNITERM_LINE_EOF = 2
} uniterm_line_result;

/*
 * Puts `text` into the editor's recall history as the newest entry. The editor keeps the newest
 * 100 entries, so an older one falls off. The text is never evaluated.
 */
void uniterm_line_seed(const char *text);

/*
 * Reads one line with editing, history, and completion against `env`. On OK the buffer holds the
 * line and its newline. CANCEL means the user dropped the form being typed. EOF means Ctrl-D at
 * an empty line, or the end of the input.
 */
uniterm_line_result uniterm_line_read(const char *prompt, JanetBuffer *buffer, JanetTable *env);

/* Restores the terminal and frees the editor's history. */
void uniterm_line_close(void);

#endif
