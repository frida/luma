#ifndef LUMA_CWEBKIT_H
#define LUMA_CWEBKIT_H

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

#endif
