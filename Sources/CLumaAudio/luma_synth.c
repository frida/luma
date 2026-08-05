#include "include/CLumaAudio.h"

#include "miniaudio.h"

#include <math.h>
#include <stdatomic.h>
#include <string.h>

#define VOICE_COUNT 16
#define COMMAND_CAPACITY 256
#define SAMPLE_RATE 48000
#define TWO_PI 6.283185307179586f

typedef enum {
    COMMAND_NOTE_ON,
    COMMAND_NOTE_OFF,
    COMMAND_PATCH,
} CommandKind;

typedef struct {
    int kind;
    int voice;
    float frequency;
    float velocity;
    LumaSynthPatch patch;
} Command;

typedef enum {
    STAGE_IDLE,
    STAGE_ATTACK,
    STAGE_DECAY,
    STAGE_SUSTAIN,
    STAGE_RELEASE,
} EnvelopeStage;

typedef struct {
    int stage;
    float frequency;
    float velocity;
    float phase;
    float detuned_phase;
    float envelope;
    float lowpass;
    float bandpass;
    LumaSynthPatch patch;
} Voice;

// Written only by the control thread, read only by the audio thread.
static _Atomic unsigned int g_command_head;
static _Atomic unsigned int g_command_tail;
static Command g_commands[COMMAND_CAPACITY];
static _Atomic unsigned int g_next_voice;
static _Atomic bool g_running;

// Touched only by the audio thread once started.
static Voice g_voices[VOICE_COUNT];
static LumaSynthPatch g_patch;
static float g_level = 0.6f;
static unsigned int g_noise_seed = 22222;

static ma_device g_device;
static bool g_device_ready;

static void push_command(Command command);
static void on_audio_frames(ma_device *device, void *output, const void *input, ma_uint32 frame_count);
static void mix(float *frames, int frame_count, int channels);
static void drain_commands(void);
static float render_voice(Voice *voice);

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

void
luma_audio_set_level(float level)
{
    g_level = level;
}

void
luma_audio_set_patch(const LumaSynthPatch *patch)
{
    Command command = { .kind = COMMAND_PATCH, .patch = *patch };
    push_command(command);
}

int
luma_audio_note_on(float frequency_hz, float velocity)
{
    int voice = (int)(atomic_fetch_add(&g_next_voice, 1) % VOICE_COUNT);
    Command command = {
        .kind = COMMAND_NOTE_ON,
        .voice = voice,
        .frequency = frequency_hz,
        .velocity = velocity,
    };
    push_command(command);
    return voice;
}

void
luma_audio_note_off(int voice)
{
    Command command = { .kind = COMMAND_NOTE_OFF, .voice = voice };
    push_command(command);
}

void
luma_audio_render_offline(float *frames, int frame_count, int channels)
{
    mix(frames, frame_count, channels);
}

// Drops the command when the ring is full rather than blocking the caller;
// a lost blip is cheaper than a stalled UI thread.
static void
push_command(Command command)
{
    unsigned int head = atomic_load_explicit(&g_command_head, memory_order_relaxed);
    unsigned int tail = atomic_load_explicit(&g_command_tail, memory_order_acquire);
    if (head - tail >= COMMAND_CAPACITY)
        return;

    g_commands[head % COMMAND_CAPACITY] = command;
    atomic_store_explicit(&g_command_head, head + 1, memory_order_release);
}

static void
on_audio_frames(ma_device *device, void *output, const void *input, ma_uint32 frame_count)
{
    (void)device;
    (void)input;
    mix((float *)output, (int)frame_count, 2);
}

static void
mix(float *frames, int frame_count, int channels)
{
    drain_commands();

    for (int frame = 0; frame != frame_count; frame++) {
        float sample = 0.0f;
        for (int index = 0; index != VOICE_COUNT; index++) {
            Voice *voice = &g_voices[index];
            if (voice->stage != STAGE_IDLE)
                sample += render_voice(voice);
        }
        sample *= g_level;
        if (sample > 1.0f)
            sample = 1.0f;
        if (sample < -1.0f)
            sample = -1.0f;

        for (int channel = 0; channel != channels; channel++)
            frames[frame * channels + channel] = sample;
    }
}

static void
drain_commands(void)
{
    unsigned int head = atomic_load_explicit(&g_command_head, memory_order_acquire);
    unsigned int tail = atomic_load_explicit(&g_command_tail, memory_order_relaxed);

    for (; tail != head; tail++) {
        const Command *command = &g_commands[tail % COMMAND_CAPACITY];
        switch (command->kind) {
            case COMMAND_PATCH:
                g_patch = command->patch;
                break;
            case COMMAND_NOTE_ON: {
                Voice *voice = &g_voices[command->voice];
                voice->stage = STAGE_ATTACK;
                voice->frequency = command->frequency;
                voice->velocity = command->velocity;
                voice->phase = 0.0f;
                voice->detuned_phase = 0.0f;
                voice->envelope = 0.0f;
                voice->lowpass = 0.0f;
                voice->bandpass = 0.0f;
                voice->patch = g_patch;
                break;
            }
            case COMMAND_NOTE_OFF:
                g_voices[command->voice].stage = STAGE_RELEASE;
                break;
        }
    }

    atomic_store_explicit(&g_command_tail, tail, memory_order_release);
}

static float oscillator(int waveform, float phase);
static void advance_envelope(Voice *voice);
static float filtered(Voice *voice, float sample);

static float
render_voice(Voice *voice)
{
    const LumaSynthPatch *patch = &voice->patch;

    float sample = oscillator(patch->waveform, voice->phase);
    voice->phase += voice->frequency / SAMPLE_RATE;
    voice->phase -= (float)(int)voice->phase;

    if (patch->detune_semitones != 0.0f) {
        float detuned = voice->frequency * powf(2.0f, patch->detune_semitones / 12.0f);
        sample = (sample + oscillator(patch->waveform, voice->detuned_phase)) * 0.5f;
        voice->detuned_phase += detuned / SAMPLE_RATE;
        voice->detuned_phase -= (float)(int)voice->detuned_phase;
    }

    advance_envelope(voice);
    return filtered(voice, sample) * voice->envelope * voice->velocity * patch->gain;
}

static float
oscillator(int waveform, float phase)
{
    switch (waveform) {
        case LUMA_WAVEFORM_TRIANGLE:
            return 4.0f * fabsf(phase - 0.5f) - 1.0f;
        case LUMA_WAVEFORM_SAW:
            return 2.0f * phase - 1.0f;
        case LUMA_WAVEFORM_SQUARE:
            return phase < 0.5f ? 1.0f : -1.0f;
        case LUMA_WAVEFORM_NOISE:
            g_noise_seed = g_noise_seed * 1664525u + 1013904223u;
            return (float)(g_noise_seed >> 8) / 8388608.0f - 1.0f;
        default:
            return sinf(TWO_PI * phase);
    }
}

static void
advance_envelope(Voice *voice)
{
    const LumaSynthPatch *patch = &voice->patch;

    switch (voice->stage) {
        case STAGE_ATTACK:
            voice->envelope += 1.0f / fmaxf(patch->attack_seconds * SAMPLE_RATE, 1.0f);
            if (voice->envelope >= 1.0f) {
                voice->envelope = 1.0f;
                voice->stage = STAGE_DECAY;
            }
            break;
        case STAGE_DECAY:
            voice->envelope -= (1.0f - patch->sustain_level) / fmaxf(patch->decay_seconds * SAMPLE_RATE, 1.0f);
            if (voice->envelope <= patch->sustain_level) {
                voice->envelope = patch->sustain_level;
                voice->stage = patch->sustain_level <= 0.0f ? STAGE_IDLE : STAGE_SUSTAIN;
            }
            break;
        case STAGE_RELEASE:
            voice->envelope -= patch->sustain_level / fmaxf(patch->release_seconds * SAMPLE_RATE, 1.0f);
            if (voice->envelope <= 0.0f) {
                voice->envelope = 0.0f;
                voice->stage = STAGE_IDLE;
            }
            break;
    }
}

// Chamberlin state variable, taking the lowpass tap.
static float
filtered(Voice *voice, float sample)
{
    const LumaSynthPatch *patch = &voice->patch;
    if (patch->cutoff_hz <= 0.0f)
        return sample;

    float f = 2.0f * sinf((float)M_PI * fminf(patch->cutoff_hz, SAMPLE_RATE * 0.45f) / SAMPLE_RATE);
    float q = 1.0f - fminf(patch->resonance, 0.98f);

    float highpass = sample - voice->lowpass - q * voice->bandpass;
    voice->bandpass += f * highpass;
    voice->lowpass += f * voice->bandpass;
    return voice->lowpass;
}
