#ifndef LUMA_SYNTH_H
#define LUMA_SYNTH_H

// Implemented in Swift. Mixes the active voices, advancing each channel's
// pattern, and is called from the device's audio callback.
void luma_synth_mix(float *frames, int frame_count, int channels);

#endif
