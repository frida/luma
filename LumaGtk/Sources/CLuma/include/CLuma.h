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

// Welcome window animated GPU backdrop. Returns a new GtkGLArea
// (as a GtkWidget*) that renders rising coral/plum motes over a
// frida.re-style cream or plum field. The widget owns its OpenGL
// resources via realize/unrealize and self-drives redraws.
void *luma_welcome_backdrop_new(void);

// Toggle the backdrop palette between dark plum (true) and light
// cream (false).
void luma_welcome_backdrop_set_dark(void *widget, bool dark);

// GdkPaintable backed by librsvg that re-rasterizes the SVG into
// each snapshot's backing pixels at its logical-size aspect ratio.
// Returns NULL on load failure; transfer-full.
void *luma_svg_paintable_new_from_path(const char *path, int logical_width, int logical_height);

#ifdef __cplusplus
}
#endif

#endif
