#ifndef V19_IME_CORE_H
#define V19_IME_CORE_H
#include <stdint.h>
#include <stddef.h>
#if defined(_WIN32) && defined(V19_HOST_TEST)
#define V19_API __declspec(dllexport)
#else
#define V19_API
#endif
#ifdef __cplusplus
extern "C" {
#endif
typedef struct V19Resources V19Resources;
typedef struct V19Request V19Request;
/* Resources are immutable, reusable, and must outlive every request using them. */
V19_API V19Resources *v19_resources_create(const uint8_t *bytes,size_t count,char *error,size_t error_capacity);
V19_API void v19_resources_destroy(V19Resources *resources);
V19_API const char *v19_source_fingerprint(const V19Resources *resources);
V19_API uint16_t v19_character_id(const V19Resources *resources,uint32_t unicode_scalar);
/* Normalization and original-coordinate maps are supplied by the included Swift layer.
   start/end arrays each have normalized_count elements, in ORIGINAL UTF-8 bytes. */
V19_API V19Request *v19_request_create(const V19Resources *resources,const char *original,size_t original_count,const char *normalized,size_t normalized_count,const int32_t *original_start,const int32_t *original_end,char *error,size_t error_capacity);
V19_API void v19_request_destroy(V19Request *request);
V19_API int32_t v19_path_count(const V19Request *request);
V19_API int32_t v19_path_length(const V19Request *request,int32_t path);
V19_API int32_t v19_path_syllable(const V19Request *request,int32_t path,int32_t position);
V19_API int32_t v19_path_normalized_start(const V19Request *request,int32_t path,int32_t position);
V19_API int32_t v19_path_normalized_end(const V19Request *request,int32_t path,int32_t position);
/* logits are source-model FP32 [1,64,8192]. Strides and element_count are in FLOATS. */
V19_API int32_t v19_decode_path(V19Request *request,int32_t path,const float *logits,size_t element_count,int32_t position_stride,int32_t character_stride);
/* Applies the original stable global sort, text deduplication, and Top8 cap. */
V19_API int32_t v19_finish(V19Request *request,int32_t requested_count);
V19_API const char *v19_request_error(const V19Request *request);
V19_API int32_t v19_candidate_count(const V19Request *request);
V19_API const char *v19_candidate_id(const V19Request *request,int32_t candidate);
V19_API const char *v19_candidate_text(const V19Request *request,int32_t candidate);
V19_API const char *v19_candidate_reading(const V19Request *request,int32_t candidate);
V19_API double v19_candidate_score(const V19Request *request,int32_t candidate);
V19_API int32_t v19_candidate_character_count(const V19Request *request,int32_t candidate);
V19_API int32_t v19_alignment_raw_start(const V19Request *request,int32_t candidate,int32_t character);
V19_API int32_t v19_alignment_raw_end(const V19Request *request,int32_t candidate,int32_t character);
V19_API int32_t v19_alignment_normalized_start(const V19Request *request,int32_t candidate,int32_t character);
V19_API int32_t v19_alignment_normalized_end(const V19Request *request,int32_t candidate,int32_t character);
V19_API const char *v19_alignment_syllable(const V19Request *request,int32_t candidate,int32_t character);
#ifdef __cplusplus
}
#endif
#endif
