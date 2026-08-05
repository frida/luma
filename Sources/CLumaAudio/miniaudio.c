// Only the device layer is used: the synth generates its own frames, and
// nothing here decodes, encodes, or resamples. Compiling the rest of
// miniaudio would cost build time for code Luma never calls.
#define MINIAUDIO_IMPLEMENTATION
#define MA_NO_DECODING
#define MA_NO_ENCODING
#define MA_NO_GENERATION
#define MA_NO_RESOURCE_MANAGER
#define MA_NO_NODE_GRAPH
#define MA_NO_ENGINE

#include "miniaudio.h"
