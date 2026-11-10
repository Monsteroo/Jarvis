#include "WhisperBridge.h"
#include <cassert>
#include <cmath>
int main(int argc, char **argv) {
  char out[16] = "old";
  float audio[4000] = {};
  assert(jv_transcribe(nullptr,audio,4000,"uk",out,16) == -1);
  assert(out[0] == 0);
  assert(jv_transcribe(nullptr,audio,4000,"uk",nullptr,0) == -1);
  jv_cancel(nullptr); jv_free(nullptr);
  assert(jv_create("/does/not/exist.bin") == nullptr);
  if (argc > 1) {
    void *ctx=jv_create(argv[1]); assert(ctx);
    assert(jv_transcribe(ctx,audio,4000,"uk",out,16)==1);
    assert(jv_transcribe(ctx,audio,4000,"ru",out,16)==-1);
    assert(jv_transcribe(ctx,audio,4000,"auto",out,16)==-1);
    audio[0]=NAN;
    assert(jv_transcribe(ctx,audio,4000,"uk",out,16)==-1);
    audio[0]=0;
    assert(jv_transcribe(ctx,audio,4000,"zz",out,16)==-1);
    assert(jv_transcribe(ctx,audio,1,"uk",out,16)==-1);
    for (auto &sample : audio) sample=0.1f;
    jv_cancel(ctx);
    assert(jv_transcribe(ctx,audio,4000,"uk",out,16)==-2);
    jv_reset_cancel(ctx);
    for (auto &sample : audio) sample=0;
    assert(jv_transcribe(ctx,audio,4000,"uk",out,16)==1);
    jv_free(ctx);
  }
}
