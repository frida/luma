#include "include/CLuma.h"

#include "generated/welcome_backdrop_fragment.h"

void *
luma_welcome_backdrop_new(void)
{
    void *widget = luma_shader_effect_new(welcome_backdrop_fragment_src);
    luma_welcome_backdrop_set_dark(widget, false);
    return widget;
}

void
luma_welcome_backdrop_set_dark(void *widget, bool dark)
{
    luma_shader_effect_set_scheme(widget, dark ? 0.0f : 1.0f);
    if (dark)
        luma_shader_effect_set_clear_color(widget, 0.075f, 0.050f, 0.065f);
    else
        luma_shader_effect_set_clear_color(widget, 0.994f, 0.991f, 0.986f);
}
