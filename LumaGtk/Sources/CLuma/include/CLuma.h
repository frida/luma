#ifndef LUMA_CLUMA_H
#define LUMA_CLUMA_H

#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct LumaMonacoView LumaMonacoView;

typedef void (*LumaMonacoTextCallback)(const char *text_utf8, void *user_data);
typedef void (*LumaMonacoLoadFinishedCallback)(LumaMonacoView *view, void *user_data);
// Return true to consume the accelerator; false to fall back to the GTK action
// bound to it. keyval/modifiers are GDK values (GdkModifierType).
typedef bool (*LumaMonacoAcceleratorCallback)(unsigned int keyval, int modifiers, void *user_data);

LumaMonacoView *luma_monaco_view_new(void);
void *luma_monaco_view_widget(LumaMonacoView *view);

void luma_monaco_view_load_uri(LumaMonacoView *view, const char *uri);
void luma_monaco_view_grab_focus(LumaMonacoView *view);
void luma_monaco_view_evaluate(LumaMonacoView *view, const char *script_utf8);
void luma_monaco_view_set_load_finished(LumaMonacoView *view,
                                         LumaMonacoLoadFinishedCallback callback,
                                         void *user_data);
void luma_monaco_view_set_text_handler(LumaMonacoView *view,
                                        LumaMonacoTextCallback callback,
                                        void *user_data);
void luma_monaco_view_set_accelerator_handler(LumaMonacoView *view,
                                              LumaMonacoAcceleratorCallback callback,
                                              void *user_data);

// --- File menu / actions ----------------------------------------------------

typedef void (*LumaActionCallback)(void *user_data);

void luma_action_install(void *gobject_application,
                          const char *name,
                          LumaActionCallback callback,
                          void *user_data);

void luma_app_set_accels(void *gobject_application,
                          const char *detailed_action,
                          const char *primary_accel);

void *luma_menu_new(void);
void luma_menu_append(void *menu, const char *label, const char *detailed_action);
void luma_menu_append_submenu(void *menu, const char *label, void *submenu);
void luma_menu_append_section(void *menu, void *section);
void luma_menu_remove_all(void *menu);
void luma_menu_unref(void *menu);

void luma_menu_button_set_menu(void *menu_button, void *menu_model);

// File dialogs (GtkFileDialog wrappers).
typedef void (*LumaPathCallback)(const char *path, void *user_data);

void luma_file_dialog_open(void *parent_window,
                            const char *title,
                            LumaPathCallback callback,
                            void *user_data);
void luma_file_dialog_save(void *parent_window,
                            const char *title,
                            const char *initial_name,
                            LumaPathCallback callback,
                            void *user_data);
void luma_folder_dialog_select(void *parent_window,
                                const char *title,
                                LumaPathCallback callback,
                                void *user_data);

// GApplication::open signal wrapper.
typedef void (*LumaOpenFilesCallback)(const char *path, void *user_data);
void luma_app_set_open_handler(void *gobject_application,
                                LumaOpenFilesCallback callback,
                                void *user_data);

// Image normalization: decode `in_bytes`/`in_size` via GdkPixbuf,
// scale to at most `max_dimension` on the longest side (preserving
// aspect ratio), and re-encode as JPEG at quality ~85. On success
// writes a malloc'd buffer to `*out_bytes` and its length to
// `*out_size`; caller owns the buffer and must free() it. Returns
// true on success, false on any decode/scale/encode failure.
bool luma_image_normalize(const unsigned char *in_bytes,
                           size_t in_size,
                           int max_dimension,
                           unsigned char **out_bytes,
                           size_t *out_size,
                           int *out_width,
                           int *out_height);

bool luma_image_normalize_to_png(const unsigned char *in_bytes,
                                  size_t in_size,
                                  int max_dimension,
                                  unsigned char **out_bytes,
                                  size_t *out_size,
                                  int *out_width,
                                  int *out_height);

// Fullscreen fragment effect. Returns a new GtkGLArea (as a
// GtkWidget*) that draws fragment_src over a screen-filling quad and
// self-drives redraws off the frame clock. The widget owns its OpenGL
// resources via realize/unrealize. The source is appended to a
// preamble declaring v_uv, frag_color, u_resolution, u_time,
// u_scheme, u_activity, u_pulse and the u_data channel, so it carries
// only its own helpers and main().
void *luma_shader_effect_new(const char *fragment_src);

// Feed u_scheme, by convention 1 for light and 0 for dark.
void luma_shader_effect_set_scheme(void *widget, float scheme);

// Report that events arrived at the given 0..1 rate. Feeds u_activity,
// and spikes u_pulse. The widget decays both, so a caller only calls
// when there is news.
void luma_shader_effect_report_activity(void *widget, float activity);

// Draw the author's own vertices rather than a screen-filling quad. Both
// sources are complete GLSL: the host writes the declarations that match
// the attributes named here. Primitive is points, lines, line strip,
// triangles or triangle strip, 0 through 4.
void luma_shader_effect_set_program(void *widget, const char *vertex_src, const char *fragment_src);
void luma_shader_effect_add_attribute(void *widget, const char *name, int components);
void luma_shader_effect_set_vertices(void *widget, const float *values, int count, int primitive);

// Feed u_data and u_data_count: up to 64 values the effect reads through
// dataAt(), which is how a caller pictures something it has measured.
void luma_shader_effect_set_data(void *widget, const float *values, int count);

// Colour shown until the effect's program has linked.
void luma_shader_effect_set_clear_color(void *widget, float red, float green, float blue);

// GdkPaintable backed by librsvg that re-rasterizes the SVG into
// each snapshot's backing pixels at its logical-size aspect ratio.
// Returns NULL on load failure; transfer-full.
void *luma_svg_paintable_new_from_path(const char *path, int logical_width, int logical_height);

#ifdef __cplusplus
}
#endif

#endif
