#include "include/CLuma.h"

// Stub WebView2 implementation for Windows.
// TODO: Implement using Microsoft WebView2 SDK.

LumaMonacoView *luma_monaco_view_new(void) { return NULL; }
void *luma_monaco_view_widget(LumaMonacoView *view) { (void)view; return NULL; }
void luma_monaco_view_load_uri(LumaMonacoView *view, const char *uri) { (void)view; (void)uri; }
void luma_monaco_view_evaluate(LumaMonacoView *view, const char *script_utf8) { (void)view; (void)script_utf8; }
void luma_monaco_view_set_load_finished(LumaMonacoView *view,
                                         LumaMonacoLoadFinishedCallback callback,
                                         void *user_data) { (void)view; (void)callback; (void)user_data; }
void luma_monaco_view_set_text_handler(LumaMonacoView *view,
                                        LumaMonacoTextCallback callback,
                                        void *user_data) { (void)view; (void)callback; (void)user_data; }
