#include "include/CLuma.h"

#import <WebKit/WebKit.h>
#include <gdk/macos/gdkmacos.h>
#include <gtk/gtk.h>

@interface LumaMonacoDelegate : NSObject <WKNavigationDelegate, WKScriptMessageHandler>
@property (nonatomic, assign) LumaMonacoLoadFinishedCallback loadCallback;
@property (nonatomic, assign) void *loadUserData;
@property (nonatomic, assign) LumaMonacoTextCallback textCallback;
@property (nonatomic, assign) void *textUserData;
@property (nonatomic, assign) LumaMonacoView *owner;
@end

@interface LumaEditorPanel : NSPanel
@end

@implementation LumaEditorPanel
- (BOOL)canBecomeKeyWindow { return YES; }
@end

struct LumaMonacoView {
    GtkWidget *placeholder;
    WKWebView *web_view;
    NSPanel *overlay_panel;
    LumaMonacoDelegate *delegate;
    gboolean overlay_installed;
};

@implementation LumaMonacoDelegate

- (void)webView:(WKWebView *)webView
    didFinishNavigation:(WKNavigation *)navigation
{
    (void)webView;
    (void)navigation;
    if (self.loadCallback) {
        self.loadCallback(self.owner, self.loadUserData);
    }
}

- (void)userContentController:(WKUserContentController *)controller
    didReceiveScriptMessage:(WKScriptMessage *)message
{
    (void)controller;
    if (!self.textCallback) {
        return;
    }
    NSString *body = message.body;
    if (![body isKindOfClass:[NSString class]]) {
        return;
    }
    self.textCallback(body.UTF8String, self.textUserData);
}

@end

static void sync_overlay_frame(LumaMonacoView *self);

static NSWindow *
find_parent_window(LumaMonacoView *self)
{
    GtkNative *native = gtk_widget_get_native(self->placeholder);
    if (native == NULL) {
        return nil;
    }
    GdkSurface *surface = gtk_native_get_surface(native);
    if (surface == NULL || !GDK_IS_MACOS_SURFACE(surface)) {
        return nil;
    }

    return (__bridge NSWindow *)gdk_macos_surface_get_native_window(GDK_MACOS_SURFACE(surface));
}

static void
install_overlay(LumaMonacoView *self)
{
    if (self->overlay_installed) {
        return;
    }

    NSWindow *parent = find_parent_window(self);
    if (parent == nil) {
        return;
    }

    self->overlay_panel = [[LumaEditorPanel alloc]
        initWithContentRect:NSZeroRect
                  styleMask:NSWindowStyleMaskBorderless
                    backing:NSBackingStoreBuffered
                      defer:NO];
    self->overlay_panel.opaque = NO;
    self->overlay_panel.backgroundColor = [NSColor clearColor];
    self->overlay_panel.hasShadow = NO;
    self->overlay_panel.level = NSNormalWindowLevel;
    self->overlay_panel.ignoresMouseEvents = NO;
    self->overlay_panel.contentView = self->web_view;

    [parent addChildWindow:self->overlay_panel ordered:NSWindowAbove];
    self->overlay_installed = TRUE;

    sync_overlay_frame(self);
}

static void
sync_overlay_frame(LumaMonacoView *self)
{
    if (!self->overlay_installed) {
        return;
    }

    NSWindow *parent = find_parent_window(self);
    if (parent == nil) {
        return;
    }

    GtkNative *native = gtk_widget_get_native(self->placeholder);
    if (native == NULL) {
        return;
    }

    graphene_point_t origin = GRAPHENE_POINT_INIT(0, 0);
    graphene_point_t root_pt;
    if (!gtk_widget_compute_point(self->placeholder, GTK_WIDGET(native), &origin, &root_pt)) {
        return;
    }

    int w = gtk_widget_get_width(self->placeholder);
    int h = gtk_widget_get_height(self->placeholder);
    if (w <= 0 || h <= 0) {
        return;
    }

    double surface_dx, surface_dy;
    gtk_native_get_surface_transform(native, &surface_dx, &surface_dy);

    CGFloat sx = root_pt.x + surface_dx;
    CGFloat sy = root_pt.y + surface_dy;

    NSRect contentRect = parent.contentView.bounds;
    CGFloat contentH = contentRect.size.height;

    NSRect localRect = NSMakeRect(sx, contentH - sy - h, w, h);
    NSRect screenRect = [parent convertRectToScreen:localRect];
    [self->overlay_panel setFrame:screenRect display:YES];
}

static void
on_placeholder_realize(GtkWidget *widget, gpointer user_data)
{
    (void)widget;
    install_overlay((LumaMonacoView *)user_data);
}

static void
on_placeholder_resize(GtkWidget *widget, int width, int height, gpointer user_data)
{
    (void)widget;
    (void)width;
    (void)height;
    sync_overlay_frame((LumaMonacoView *)user_data);
}

static void
on_placeholder_unrealize(GtkWidget *widget, gpointer user_data)
{
    (void)widget;
    LumaMonacoView *self = (LumaMonacoView *)user_data;
    if (self->overlay_installed) {
        NSWindow *parent = find_parent_window(self);
        if (parent != nil) {
            [parent removeChildWindow:self->overlay_panel];
        }
        [self->overlay_panel orderOut:nil];
        self->overlay_panel = nil;
        self->overlay_installed = FALSE;
    }
}

LumaMonacoView *
luma_monaco_view_new(void)
{
    LumaMonacoView *self = g_new0(LumaMonacoView, 1);

    WKWebViewConfiguration *config = [[WKWebViewConfiguration alloc] init];
    [config.preferences setValue:@YES forKey:@"developerExtrasEnabled"];
    self->web_view = [[WKWebView alloc] initWithFrame:NSZeroRect configuration:config];

    self->delegate = [[LumaMonacoDelegate alloc] init];
    self->delegate.owner = self;
    self->web_view.navigationDelegate = self->delegate;

    self->placeholder = gtk_drawing_area_new();

    g_signal_connect(self->placeholder, "realize", G_CALLBACK(on_placeholder_realize), self);
    g_signal_connect(self->placeholder, "resize", G_CALLBACK(on_placeholder_resize), self);
    g_signal_connect(self->placeholder, "unrealize", G_CALLBACK(on_placeholder_unrealize), self);

    return self;
}

void *
luma_monaco_view_widget(LumaMonacoView *view)
{
    return (void *)view->placeholder;
}

void
luma_monaco_view_load_uri(LumaMonacoView *view, const char *uri)
{
    NSString *urlString = [NSString stringWithUTF8String:uri];
    NSURL *url = [NSURL URLWithString:urlString];
    if (url != nil) {
        if ([url isFileURL]) {
            NSURL *dirURL = [url URLByDeletingLastPathComponent];
            [view->web_view loadFileURL:url allowingReadAccessToURL:dirURL];
        } else {
            [view->web_view loadRequest:[NSURLRequest requestWithURL:url]];
        }
    }
}

void
luma_monaco_view_evaluate(LumaMonacoView *view, const char *script_utf8)
{
    NSString *script = [NSString stringWithUTF8String:script_utf8];
    [view->web_view evaluateJavaScript:script completionHandler:nil];
}

void
luma_monaco_view_set_load_finished(LumaMonacoView *view,
                                    LumaMonacoLoadFinishedCallback callback,
                                    void *user_data)
{
    view->delegate.loadCallback = callback;
    view->delegate.loadUserData = user_data;
}

void
luma_monaco_view_set_text_handler(LumaMonacoView *view,
                                   LumaMonacoTextCallback callback,
                                   void *user_data)
{
    view->delegate.textCallback = callback;
    view->delegate.textUserData = user_data;

    [view->web_view.configuration.userContentController
        addScriptMessageHandler:view->delegate
                           name:@"updateText"];
}
