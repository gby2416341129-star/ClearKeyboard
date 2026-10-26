#ifndef CLEAR_QWEN_H
#define CLEAR_QWEN_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct CKQwen CKQwen;
typedef struct CKQwenPreview CKQwenPreview;
enum { CK_QWEN_MORE = 1, CK_QWEN_REFINING = 2 };
typedef int (*CKQwenCancelled)(void *);
typedef void (*CKQwenUpdated)(void *, CKQwen *, int, int);
CKQwen *ck_qwen_create(const char *model_path, const char *phonetic_path);
void ck_qwen_destroy(CKQwen *engine);
const char *ck_qwen_error(void);
// Filters immutable Qwen scores, independent of the inference lock. The caller
// owns this snapshot; it never aliases the active decoder's candidate storage.
CKQwenPreview *ck_qwen_preview(CKQwen *engine, const char *raw, const char *context,
                              uint32_t fuzzy_pairs, int corrections, int limit,
                              CKQwenCancelled cancelled, void *opaque);
void ck_qwen_preview_destroy(CKQwenPreview *page);
int ck_qwen_preview_count(const CKQwenPreview *page);
const char *ck_qwen_preview_text(const CKQwenPreview *page, int index);
const char *ck_qwen_preview_reading(const CKQwenPreview *page, int index);
int ck_qwen_preview_consumed(const CKQwenPreview *page, int index);
double ck_qwen_preview_score(const CKQwenPreview *page, int index);
// All calls on an engine are serialized by its Swift owner. Cancellation may
// be queried from the CPU worker during both prompt and token evaluation.
int ck_qwen_query(CKQwen *engine, const char *raw, const char *context,
                  uint32_t fuzzy_pairs, int corrections, int character_only,
                  int limit, CKQwenCancelled cancelled, CKQwenUpdated updated, void *opaque);
int ck_qwen_has_more(CKQwen *engine);
const char *ck_qwen_text(CKQwen *engine, int index);
const char *ck_qwen_reading(CKQwen *engine, int index);
int ck_qwen_consumed(CKQwen *engine, int index);
double ck_qwen_score(CKQwen *engine, int index);
#ifdef __cplusplus
}
#endif
#endif
