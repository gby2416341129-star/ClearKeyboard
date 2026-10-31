#ifndef V21_IME_CORE_H
#define V21_IME_CORE_H
#include <stdint.h>
#include <stddef.h>
#if defined(_WIN32) && defined(V21_HOST)
#define V21_API __declspec(dllexport)
#else
#define V21_API
#endif
#ifdef __cplusplus
extern "C" {
#endif
V21_API uint64_t v21_process_memory_bytes(void);
typedef struct V21Resources V21Resources;
typedef struct V21Request V21Request;
V21_API V21Resources *v21_resources_create(const uint8_t*,size_t,const uint8_t*,size_t,char*,size_t);
V21_API int32_t v21_resources_load_language(V21Resources*,const uint8_t*,size_t,char*,size_t);
V21_API void v21_resources_destroy(V21Resources*);
V21_API uint16_t v21_character_id(const V21Resources*,uint32_t);
/* All maps use original raw UTF8 bytes. Context-last ID is8192(BOS) if unavailable. */
V21_API V21Request *v21_request_allocate(const V21Resources*,const char*,size_t,const char*,size_t,const int32_t*,const int32_t*,int32_t,int32_t,int32_t,char*,size_t);
V21_API int32_t v21_request_prepare(V21Request*);
V21_API const char *v21_runtime_json(V21Request*);
V21_API V21Request *v21_request_create(const V21Resources*,const char*,size_t,const char*,size_t,const int32_t*,const int32_t*,int32_t,int32_t,int32_t,char*,size_t);
V21_API void v21_request_destroy(V21Request*);
V21_API void v21_cancel_request(V21Request*);
V21_API int32_t v21_path_count(const V21Request*);
V21_API int32_t v21_path_length(const V21Request*,int32_t);
V21_API int32_t v21_path_syllable(const V21Request*,int32_t,int32_t);
V21_API int32_t v21_path_start(const V21Request*,int32_t,int32_t);
V21_API int32_t v21_path_end(const V21Request*,int32_t,int32_t);
V21_API double v21_path_log_prior(const V21Request*,int32_t);
V21_API const char *v21_path_completion(const V21Request*,int32_t);
/* compact logits [T,136] in ascending legal-ID order; full_log_z optional diagnostic only. */
V21_API int32_t v21_decode_path(V21Request*,int32_t,const float*,size_t,int32_t,int32_t,const float*,size_t,int32_t);
/* A non-final snapshot exposes only candidates provably above all unprocessed-path bounds. */
V21_API int32_t v21_snapshot(V21Request*,int32_t,int32_t);
/* Finalize only when ALL requested candidates pass the unchanged strict score bound. */
V21_API int32_t v21_finish_if_rank_certified(V21Request*,int32_t);
V21_API int32_t v21_completed_paths(const V21Request*);
V21_API const char *v21_error(const V21Request*);
V21_API int32_t v21_candidate_count(const V21Request*);
V21_API const char *v21_candidate_id(const V21Request*,int32_t);
V21_API const char *v21_candidate_text(const V21Request*,int32_t);
V21_API const char *v21_candidate_reading(const V21Request*,int32_t);
V21_API double v21_candidate_score(const V21Request*,int32_t);
V21_API int32_t v21_candidate_path(const V21Request*,int32_t);
V21_API int32_t v21_candidate_characters(const V21Request*,int32_t);
/* JSON is generated only on explicit diagnostic requests; target is queried AFTER decoding. */
V21_API const char *v21_diagnostic_json(V21Request*,const char*);
#ifdef __cplusplus
}
#endif
#endif
