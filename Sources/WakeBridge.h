#pragma once
#ifdef __cplusplus
extern "C" {
#endif

/// Narrow wrapper over the sherpa-onnx keyword spotter C API. Config structs
/// stay in C so Swift never depends on their layout.
typedef struct jw_spotter jw_spotter;

/// `model_dir` contains encoder.onnx, decoder.onnx, joiner.onnx (streaming
/// zipformer transducer, int8) and tokens.txt.
/// `keywords` uses the sherpa keyword-file format (BPE tokens + @label).
/// Returns NULL on failure.
jw_spotter *jw_create(const char *model_dir, const char *keywords,
                      float threshold, float score, int trailing_blanks, int threads);
void jw_free(jw_spotter *spotter);

/// Feeds 16 kHz mono float samples and decodes what is ready.
/// Returns 1 when the keyword fired, shortly after the spoken word ends.
/// `end_seconds` is set to 0: sherpa's token timestamps are not absolute and
/// are not used. The stream restarts after a hit.
int jw_accept(jw_spotter *spotter, const float *samples, int count, float *end_seconds);

/// Starts a fresh stream (used when listening resumes).
void jw_restart(jw_spotter *spotter);

#ifdef __cplusplus
}
#endif
