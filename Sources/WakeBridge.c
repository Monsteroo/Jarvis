#include "WakeBridge.h"
#include "sherpa-onnx/c-api/c-api.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Two staggered streams, each restarted every JW_AGE samples. Measured on
 * v2.0.1 + gigaspeech 3.3M: a single long-running stream misses the keyword
 * after ~10 s of silence or room noise. With a 3 s offset every keyword up to
 * 3 s long lies entirely inside a fresh stream. */
#define JW_AGE (16000 * 6)
#define JW_OFFSET (16000 * 3)

struct jw_spotter {
    const SherpaOnnxKeywordSpotter *spotter;
    const SherpaOnnxOnlineStream *stream[2];
    int age[2];
};

static void jw_reopen(jw_spotter *s, int k, int age) {
    if (s->stream[k]) SherpaOnnxDestroyOnlineStream(s->stream[k]);
    s->stream[k] = SherpaOnnxCreateKeywordStream(s->spotter);
    s->age[k] = age;
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
    char *encoder = join(model_dir, "encoder-epoch-12-avg-2-chunk-16-left-64.int8.onnx");
    char *decoder = join(model_dir, "decoder-epoch-12-avg-2-chunk-16-left-64.int8.onnx");
    char *joiner = join(model_dir, "joiner-epoch-12-avg-2-chunk-16-left-64.int8.onnx");
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
        config.max_active_paths = 4;
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
                jw_reopen(result, 0, 0);
                jw_reopen(result, 1, JW_OFFSET);
                if (!result->stream[0] || !result->stream[1]) { jw_free(result); result = NULL; }
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
    for (int k = 0; k < 2; k++) if (s->stream[k]) SherpaOnnxDestroyOnlineStream(s->stream[k]);
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
    if (!s || !s->stream[0] || !s->stream[1] || !samples || count <= 0) return 0;
    int fired = 0;
    for (int k = 0; k < 2 && !fired; k++) {
        fired = jw_feed(s, s->stream[k], samples, count);
        s->age[k] += count;
        if (!fired && s->age[k] >= JW_AGE) jw_reopen(s, k, 0);
    }
    if (fired) {
        /* sherpa timestamps are not absolute; callers use the detection time. */
        if (end_seconds) *end_seconds = 0;
        jw_restart(s);
    }
    return fired;
}

void jw_restart(jw_spotter *s) {
    if (!s) return;
    jw_reopen(s, 0, 0);
    jw_reopen(s, 1, JW_OFFSET);
}
