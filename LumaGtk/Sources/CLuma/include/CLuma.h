#ifndef LUMA_CLUMA_H
#define LUMA_CLUMA_H

#include <epoxy/gl.h>
#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

void *luma_text_buffer_create_style_tag(void *gtk_text_buffer,
                                         const char *name,
                                         const char *foreground,
                                         bool bold,
                                         bool italic);
void *luma_text_buffer_create_underline_tag(void *gtk_text_buffer,
                                             const char *name,
                                             const char *color,
                                             bool error);

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

// --- Pointer capture --------------------------------------------------------

// Where the pointer sits on screen, in the coordinates luma_pointer_place
// takes back. Returns false where the platform keeps the pointer's
// whereabouts to itself (Wayland), in which case it cannot be placed either.
bool luma_pointer_location(double *x, double *y);
void luma_pointer_place(double x, double y);

void luma_widget_set_cursor_name(void *widget, const char *name);

// GdkPaintable backed by librsvg that re-rasterizes the SVG into
// each snapshot's backing pixels at its logical-size aspect ratio.
// Returns NULL on load failure; transfer-full.
void *luma_svg_paintable_new_from_path(const char *path, int logical_width, int logical_height);

#ifdef __cplusplus
}
#endif

#endif
