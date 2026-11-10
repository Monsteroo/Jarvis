#include "WakeBridge.h"
#include "sherpa-onnx/c-api/c-api.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* One stream. Measured on v2.0.1 + streaming zipformer en-2023-06-26 int8:
 * the keyword still fires after 600 s of room-like noise and after 60 s of
 * silence, so the two staggered streams the 3.3M gigaspeech model needed are
 * gone (they doubled CPU). The stream is still renewed every JW_AGE samples as
 * a precaution against unmeasured multi-hour drift; a keyword spoken across
 * that boundary (≈1.5 s in 600 s) can be missed. */
#define JW_AGE (16000 * 600)

struct jw_spotter {
    const SherpaOnnxKeywordSpotter *spotter;
    const SherpaOnnxOnlineStream *stream;
    int age;
};

static void jw_reopen(jw_spotter *s) {
    if (s->stream) SherpaOnnxDestroyOnlineStream(s->stream);
    s->stream = SherpaOnnxCreateKeywordStream(s->spotter);
    s->age = 0;
}

static char *join(const char *dir, const char *name) {
    size_t n = strlen(dir) + strlen(name) + 2;
    char *path = malloc(n);
    if (path) snprintf(path, n, "%s/%s", dir, name);
    return path;
}

jw_spotter *jw_create(const char *model_dir, const char *keywords,
                      float threshold, float score, int trailing_blanks, int threads) {
    if (!model_dir || !keywords) return NULL;
    char *encoder = join(model_dir, "encoder.onnx");
    char *decoder = join(model_dir, "decoder.onnx");
    char *joiner = join(model_dir, "joiner.onnx");
    char *tokens = join(model_dir, "tokens.txt");
    jw_spotter *result = NULL;
    if (encoder && decoder && joiner && tokens) {
        SherpaOnnxKeywordSpotterConfig config;
        memset(&config, 0, sizeof(config));
        config.feat_config.sample_rate = 16000;
        config.feat_config.feature_dim = 80;
        config.model_config.transducer.encoder = encoder;
        config.model_config.transducer.decoder = decoder;
        config.model_config.transducer.joiner = joiner;
        config.model_config.tokens = tokens;
        config.model_config.num_threads = threads > 0 ? threads : 1;
        config.model_config.provider = "cpu";
        config.model_config.debug = 0;
        /* 8 paths: 12/13 real-voice hits vs 10/13 with 4, same CPU (measured). */
        config.max_active_paths = 8;
        config.num_trailing_blanks = trailing_blanks;
        config.keywords_score = score;
        config.keywords_threshold = threshold;
        config.keywords_buf = keywords;
        config.keywords_buf_size = (int32_t)strlen(keywords);
        const SherpaOnnxKeywordSpotter *spotter = SherpaOnnxCreateKeywordSpotter(&config);
        if (spotter) {
            result = calloc(1, sizeof(jw_spotter));
            if (result) {
                result->spotter = spotter;
                jw_reopen(result);
                if (!result->stream) { jw_free(result); result = NULL; }
            } else {
                SherpaOnnxDestroyKeywordSpotter(spotter);
            }
        }
    }
    free(encoder); free(decoder); free(joiner); free(tokens);
    return result;
}

void jw_free(jw_spotter *s) {
    if (!s) return;
    if (s->stream) SherpaOnnxDestroyOnlineStream(s->stream);
    if (s->spotter) SherpaOnnxDestroyKeywordSpotter(s->spotter);
    free(s);
}

static int jw_feed(jw_spotter *s, const SherpaOnnxOnlineStream *stream, const float *samples, int count) {
    SherpaOnnxOnlineStreamAcceptWaveform(stream, 16000, samples, count);
    int fired = 0;
    while (!fired && SherpaOnnxIsKeywordStreamReady(s->spotter, stream)) {
        SherpaOnnxDecodeKeywordStream(s->spotter, stream);
        const SherpaOnnxKeywordResult *r = SherpaOnnxGetKeywordResult(s->spotter, stream);
        if (r && r->keyword && r->keyword[0] != '\0') fired = 1;
        if (r) SherpaOnnxDestroyKeywordResult(r);
    }
    return fired;
}

int jw_accept(jw_spotter *s, const float *samples, int count, float *end_seconds) {
    if (!s || !s->stream || !samples || count <= 0) return 0;
    int fired = jw_feed(s, s->stream, samples, count);
    s->age += count;
    if (!fired && s->age >= JW_AGE) jw_reopen(s);
    if (fired) {
        /* sherpa timestamps are not absolute; callers use the detection time. */
        if (end_seconds) *end_seconds = 0;
        jw_restart(s);
    }
    return fired;
}

void jw_restart(jw_spotter *s) {
    if (!s) return;
    jw_reopen(s);
}
