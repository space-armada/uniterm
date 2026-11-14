
/* uniterm settings. scripts/vendor-janet.sh appends this block to the upstream file. */

/* Every VM allocation goes through a counting wrapper in CJanet's shim. The macros are function
 * like, so the `(janet_malloc)` declarations in janet.h stay plain function names. */
#include <stddef.h>
void *uniterm_janet_malloc(size_t size);
void *uniterm_janet_realloc(void *pointer, size_t size);
void *uniterm_janet_calloc(size_t count, size_t size);
void uniterm_janet_free(void *pointer);

#define janet_malloc(X) uniterm_janet_malloc((X))
#define janet_realloc(X, Y) uniterm_janet_realloc((X), (Y))
#define janet_calloc(X, Y) uniterm_janet_calloc((X), (Y))
#define janet_free(X) uniterm_janet_free((X))

/* The helper never loads native modules. */
#define JANET_NO_DYNAMIC_MODULES
