#ifndef CLEAR_QWEN_H
#define CLEAR_QWEN_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct CKQwen CKQwen;
typedef int (*CKQwenCancelled)(void *);
CKQwen *ck_qwen_create(const char *model_path, const char *phonetic_path);
void ck_qwen_destroy(CKQwen *engine);
const char *ck_qwen_error(void);
// All calls on an engine are serialized by its Swift owner. Cancellation may
// be queried from the CPU worker during both prompt and token evaluation.
int ck_qwen_query(CKQwen *engine, const char *raw, const char *context,
                  uint32_t fuzzy_pairs, int corrections, int character_only,
                  int limit, CKQwenCancelled cancelled, void *opaque);
const char *ck_qwen_text(CKQwen *engine, int index);
const char *ck_qwen_reading(CKQwen *engine, int index);
int ck_qwen_consumed(CKQwen *engine, int index);
double ck_qwen_score(CKQwen *engine, int index);
#ifdef __cplusplus
}
#endif
#endif
