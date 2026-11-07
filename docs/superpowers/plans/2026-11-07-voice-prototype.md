# Voice prototype implementation plan

Approved scope: first stage of docs/research/jarvis-implementation.md. macOS14.5, ARM64, local audio only, no OS actions or server. User authorized execution, no additional design approval required.

- [ ] Build pinned whisper.cpp v1.8.3 static libraries with Metal; download multilingual base/small weights into ignored .runtime. Record hashes.
- [ ] Native Swift/AppKit window and global hold-to-talk shortcut. AVAudioEngine microphone only while held; permission request manually granted; stop on release/cancel/sleep/timeout. RAM-only audio.
- [ ] Resident C bridge to Whisper on serial queue; 16kHz mono float input; output text and inference timing; reject silence; cancellation abort callback. Test boundary behavior before implementation.
- [ ] File benchmark executable using same bridge. Compare base/small on upstream sample, explicitly not user accuracy/SLA. Prepare 50 multilingual prompts for manual recording without storing audio by default.
- [ ] Build app bundle, verify signature/linkage, tests, benchmark. Review code and fix findings. Launch UI without starting capture. Document manual microphone step, measurement limitations, cleanup.

Interfaces: bridge exports jv_create(path), jv_free(ctx), jv_transcribe(ctx,float*,count,language,char*,capacity), jv_cancel(ctx). C functions return error codes, no shell or network. UI links bridge directly, keeps context resident; all inference and freeing serialized. Native bundle model path resolves project .runtime/models. Benchmark input uses AVAudioFile and AVAudioConverter.
