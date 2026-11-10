// Smoke test of the sherpa-onnx keyword spotter through WakeBridge.
// Usage: wake-bridge-test MODEL_DIR KEYWORDS_FILE THRESHOLD SCORE WAV...
// Prints one line per file: name, fired count, keyword end time reported by
// sherpa, file duration, and the stream position (s) at which it fired.
#include "WakeBridge.h"
#include "sherpa-onnx/c-api/c-api.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(int argc, char **argv) {
    // Without a model the wrapper must fail cleanly, not crash.
    if (jw_create("/nonexistent", "\xe2\x96\x81JA R VI S @JARVIS\n", 0.25f, 1.0f, 1, 1) != NULL) {
        fprintf(stderr, "expected NULL for missing model\n");
        return 1;
    }
    if (argc < 6) { printf("wake-bridge-test: missing-model check passed; no model given\n"); return 0; }
    FILE *f = fopen(argv[2], "rb");
    if (!f) return 2;
    char keywords[4096] = {0};
    fread(keywords, 1, sizeof(keywords) - 1, f);
    fclose(f);
    jw_spotter *s = jw_create(argv[1], keywords, (float)atof(argv[3]), (float)atof(argv[4]), 1, 1);
    if (!s) { fprintf(stderr, "spotter creation failed\n"); return 3; }
    for (int i = 5; i < argc; i++) {
        const SherpaOnnxWave *wave = SherpaOnnxReadWave(argv[i]);
        if (!wave) { fprintf(stderr, "cannot read %s\n", argv[i]); return 4; }
        jw_restart(s);
        int fired = 0; float end = -1; float at = -1;
        // Feed in 20 ms chunks like the live pipeline.
        for (int pos = 0; pos < wave->num_samples; pos += 320) {
            int n = wave->num_samples - pos < 320 ? wave->num_samples - pos : 320;
            float e = 0;
            if (jw_accept(s, wave->samples + pos, n, &e)) { fired++; if (end < 0) { end = e; at = (pos + n) / 16000.0f; } }
        }
        // Trailing silence flushes the final frames.
        float tail[8000] = {0};
        float e = 0;
        if (jw_accept(s, tail, 8000, &e)) { fired++; if (end < 0) end = e; }
        const char *name = strrchr(argv[i], '/');
        printf("%s %d %.2f %.2f %.2f\n", name ? name + 1 : argv[i], fired, end, wave->num_samples / 16000.0, at);
        SherpaOnnxFreeWave(wave);
    }
    jw_free(s);
    return 0;
}
