#ifndef LUMA_CWEBKIT_H
#define LUMA_CWEBKIT_H

#include <stdbool.h>
#include <stddef.h>

typedef struct LumaMonacoView LumaMonacoView;

typedef void (*LumaMonacoTextCallback)(const char *text_utf8, void *user_data);
typedef void (*LumaMonacoLoadFinishedCallback)(LumaMonacoView *view, void *user_data);

LumaMonacoView *luma_monaco_view_new(void);
void *luma_monaco_view_widget(LumaMonacoView *view);

void luma_monaco_view_load_uri(LumaMonacoView *view, const char *uri);
void luma_monaco_view_evaluate(LumaMonacoView *view, const char *script_utf8);
void luma_monaco_view_set_load_finished(LumaMonacoView *view,
                                         LumaMonacoLoadFinishedCallback callback,
                                         void *user_data);
void luma_monaco_view_set_text_handler(LumaMonacoView *view,
                                        LumaMonacoTextCallback callback,
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

// Simple destructive confirmation alert. The callback receives 1 if the
// destructive button was selected, 0 otherwise (cancel / dismiss).
typedef void (*LumaConfirmCallback)(int confirmed, void *user_data);

void luma_alert_confirm(void *parent_window,
                         const char *message,
                         const char *detail,
                         const char *destructive_label,
                         LumaConfirmCallback callback,
                         void *user_data);

#endif
