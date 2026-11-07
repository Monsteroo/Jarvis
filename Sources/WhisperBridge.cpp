#include "WhisperBridge.h"
#include "whisper.h"
#include <atomic>
#include <cmath>
#include <cstring>
#include <string>
#include <fstream>
struct Engine { whisper_context *ctx; std::atomic<bool> cancelled{false}; };
static bool aborted(void *p) { return static_cast<Engine*>(p)->cancelled.load(); }
static void quiet(enum ggml_log_level, const char*, void*) {}
void *jv_create(const char *path) {
    if (!path || !std::ifstream(path).good()) return nullptr;
    whisper_log_set(quiet, nullptr);
    auto params = whisper_context_default_params();
    params.use_gpu = true;
    auto ctx = whisper_init_from_file_with_params(path, params);
    return ctx ? new Engine{ctx} : nullptr;
}
void jv_free(void *p) { if (p) { auto e = static_cast<Engine*>(p); whisper_free(e->ctx); delete e; } }
void jv_reset_cancel(void *p) { if (p) static_cast<Engine*>(p)->cancelled.store(false); }
void jv_cancel(void *p) { if (p) static_cast<Engine*>(p)->cancelled.store(true); }
int jv_transcribe(void *p, const float *audio, int count, const char *language, char *out, int capacity) {
    if (out && capacity > 0) out[0] = 0;
    if (!p || !audio || !out || capacity < 1 || count < 1600 || count > 16000*30 || !language) return -1;
    if (std::strcmp(language,"auto") && whisper_lang_id(language) < 0) return -1;
    double energy=0;
    for (int i=0;i<count;i++) { if (!std::isfinite(audio[i])) return -1; energy += double(audio[i])*audio[i]; }
    if (std::sqrt(energy/count) < 0.001) return 1; // Silence gate, not a speech classifier.
    auto e=static_cast<Engine*>(p);
    if (e->cancelled.load()) return -2;
    auto params=whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
    params.n_threads=4; params.translate=false; params.no_context=true;
    params.language=language; params.print_progress=false; params.print_realtime=false;
    params.print_timestamps=false; params.print_special=false;
    params.greedy.best_of=1; params.temperature_inc=0;
    params.abort_callback=aborted; params.abort_callback_user_data=e;
    int result=whisper_full(e->ctx,params,audio,count);
    if (e->cancelled.load()) return -2;
    if (result != 0) return -3;
    std::string text;
    for (int i=0;i<whisper_full_n_segments(e->ctx);i++) {
        if (whisper_full_get_segment_no_speech_prob(e->ctx,i) < 0.6f)
            text += whisper_full_get_segment_text(e->ctx,i);
    }
    if (text.size() >= static_cast<size_t>(capacity)) return -4;
    std::memcpy(out,text.c_str(),text.size()+1);
    return text.empty() ? 1 : 0;
}
