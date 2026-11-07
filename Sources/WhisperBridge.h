#pragma once
#ifdef __cplusplus
extern "C" {
#endif
void *jv_create(const char *path);
void jv_free(void *ctx);
void jv_cancel(void *ctx);
void jv_reset_cancel(void *ctx);
int jv_transcribe(void *ctx, const float *audio, int count, const char *language, char *out, int capacity);
#ifdef __cplusplus
}
#endif
