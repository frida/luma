#ifndef LUMA_SYNTH_H
#define LUMA_SYNTH_H

// Mixes the active voices, draining any queued commands first. Called by the
// device's audio callback, and directly when rendering without a device.
void luma_synth_mix(float *frames, int frame_count, int channels);

#endif
