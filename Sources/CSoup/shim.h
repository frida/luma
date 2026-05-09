#ifndef LUMA_CSOUP_SHIM_H
#define LUMA_CSOUP_SHIM_H

#include <libsoup/soup.h>

static inline SoupServer *luma_soup_server_new_default(void) {
    return soup_server_new(NULL);
}

#endif
