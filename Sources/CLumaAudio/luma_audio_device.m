// The only translation unit that sees miniaudio. Apple's mobile SDKs reach
// the audio session through AVFoundation, which is why this is Objective-C;
// hosts without it compile the same body as C through luma_audio_device.c.
#define MINIAUDIO_IMPLEMENTATION

// Only the device layer is used: the synth generates its own frames, and
// nothing here decodes, encodes, or resamples.
#define MA_NO_DECODING
#define MA_NO_ENCODING
#define MA_NO_GENERATION
#define MA_NO_RESOURCE_MANAGER
#define MA_NO_NODE_GRAPH
#define MA_NO_ENGINE

#include "miniaudio.h"

#include "include/CLumaAudio.h"
#include "luma_synth.h"

#include <stdatomic.h>

#define SAMPLE_RATE 48000

static ma_device g_device;
static bool g_device_ready;
static _Atomic bool g_running;

static void on_audio_frames(ma_device *device, void *output, const void *input, ma_uint32 frame_count);

bool
luma_audio_start(void)
{
    if (atomic_load(&g_running))
        return true;

    ma_device_config config = ma_device_config_init(ma_device_type_playback);
    config.playback.format = ma_format_f32;
    config.playback.channels = 2;
    config.sampleRate = SAMPLE_RATE;
    config.dataCallback = on_audio_frames;

    if (ma_device_init(NULL, &config, &g_device) != MA_SUCCESS)
        return false;
    if (ma_device_start(&g_device) != MA_SUCCESS) {
        ma_device_uninit(&g_device);
        return false;
    }

    g_device_ready = true;
    atomic_store(&g_running, true);
    return true;
}

void
luma_audio_stop(void)
{
    if (!g_device_ready)
        return;
    atomic_store(&g_running, false);
    ma_device_uninit(&g_device);
    g_device_ready = false;
}

bool
luma_audio_is_running(void)
{
    return atomic_load(&g_running);
}

static void
on_audio_frames(ma_device *device, void *output, const void *input, ma_uint32 frame_count)
{
    (void)device;
    (void)input;
    luma_synth_mix((float *)output, (int)frame_count, 2);
}
