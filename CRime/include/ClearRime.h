#ifndef CLEAR_RIME_H
#define CLEAR_RIME_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
int cr_initialize(const char *shared_directory, const char *user_directory);
uintptr_t cr_session(void);
void cr_destroy(uintptr_t session);
int cr_query(uintptr_t session, const char *input);
int cr_candidate(uintptr_t session, int index, char *text, size_t capacity,
                 char *reading, size_t reading_capacity);
const char *cr_version(void);
#ifdef __cplusplus
}
#endif
#endif
