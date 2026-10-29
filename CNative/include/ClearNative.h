#ifndef CLEAR_NATIVE_H
#define CLEAR_NATIVE_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct CKNative CKNative;
typedef struct CKNativePage CKNativePage;
typedef int (*CKNativeCancelled)(void *);
CKNative *ck_native_create(const char *index_path);
void ck_native_destroy(CKNative *engine);
const char *ck_native_error(void);
CKNativePage *ck_native_decode(CKNative *,const char *,const char *,uint32_t,int,int,int,CKNativeCancelled,void *);
void ck_native_page_destroy(CKNativePage *);
int ck_native_page_count(const CKNativePage *);
int ck_native_page_more(const CKNativePage *);
const char *ck_native_text(const CKNativePage *,int);
const char *ck_native_reading(const CKNativePage *,int);
int ck_native_consumed(const CKNativePage *,int);
int ck_native_scalar_end(const CKNativePage *,int);
double ck_native_score(const CKNativePage *,int);
float ck_native_frequency(const CKNativePage *,int);
float ck_native_edit_cost(const CKNativePage *,int);
int ck_native_base_rank(const CKNativePage *,int);
int ck_native_match_type(const CKNativePage *,int);
int ck_native_segment_count(const CKNativePage *,int);
int ck_native_segment_end(const CKNativePage *,int,int);
#ifdef __cplusplus
}
#endif
#endif
