#ifndef LUMA_CLUMAAUDIO_H
#define LUMA_CLUMAAUDIO_H

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// The device layer, and nothing else: the voices, patterns and mixing all
// live in Swift, which the callback reaches through luma_synth_mix.

// Opens the default output device and starts the mixer. Answers false if
// the host has no usable device, which is not fatal: playing stays
// callable and simply goes unheard.
bool luma_audio_start(void);
void luma_audio_stop(void);
bool luma_audio_is_running(void);

#ifdef __cplusplus
}
#endif

#endif
