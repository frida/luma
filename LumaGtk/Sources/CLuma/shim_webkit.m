#include "include/CLuma.h"

#import <WebKit/WebKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <epoxy/gl.h>
#include <gdk/macos/gdkmacos.h>
#include <gtk/gtk.h>

/* WKWebView rendering: capture via takeSnapshotWithConfiguration and
 * paint into GTK's GSK render tree as a GdkGLTexture. WebKit's
 * cross-process compositing means the on-screen IOSurfaces aren't
 * reachable from public APIs; takeSnapshot returns a CPU bitmap that
 * costs a per-frame upload (~20% CPU at native refresh). Acceptable
 * trade-off for the macOS dev build — popovers, sheets and overlay
 * widgets render through GTK normally because the WebView never
 * participates in the on-screen layer composite. */

@interface LumaMonacoDelegate : NSObject <WKNavigationDelegate, WKScriptMessageHandler>
@property (nonatomic, assign) LumaMonacoLoadFinishedCallback loadCallback;
@property (nonatomic, assign) void *loadUserData;
@property (nonatomic, assign) LumaMonacoTextCallback textCallback;
@property (nonatomic, assign) void *textUserData;
@property (nonatomic, assign) LumaMonacoView *owner;
@end

@interface LumaWKWebView : WKWebView
@end

@implementation LumaWKWebView
- (BOOL)acceptsFirstMouse:(NSEvent *)event { (void)event; return YES; }
- (NSView *)hitTest:(NSPoint)point { (void)point; return nil; }
@end

@interface LumaDisplayLinkTarget : NSObject
@property (nonatomic, assign) LumaMonacoView *owner;
- (void)tick;
@end

struct LumaMonacoView {
    GtkWidget *placeholder;
    LumaWKWebView *web_view;
    NSWindow *host_window;
    LumaMonacoDelegate *delegate;

    CADisplayLink *display_link;
    LumaDisplayLinkTarget *display_link_target;
    BOOL snapshot_in_flight;

    GdkGLContext *gl_context;
    GLuint gl_texture;
    int gl_texture_width;
    int gl_texture_height;

    GdkTexture *latest_texture;
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

static void request_snapshot(LumaMonacoView *self);

@implementation LumaDisplayLinkTarget
- (void)tick { request_snapshot(self.owner); }
@end

#define LUMA_TYPE_MONACO_TILE (luma_monaco_tile_get_type())
G_DECLARE_FINAL_TYPE(LumaMonacoTile, luma_monaco_tile, LUMA, MONACO_TILE, GtkWidget)

struct _LumaMonacoTile {
    GtkWidget parent_instance;
};

G_DEFINE_FINAL_TYPE(LumaMonacoTile, luma_monaco_tile, GTK_TYPE_WIDGET)

static void sync_overlay(LumaMonacoView *self);

static void
luma_monaco_tile_snapshot(GtkWidget *widget, GtkSnapshot *snapshot)
{
    LumaMonacoView *owner = g_object_get_data(G_OBJECT(widget), "luma-owner");
    if (owner == NULL || owner->latest_texture == NULL) {
        return;
    }
    int w = gtk_widget_get_width(widget);
    int h = gtk_widget_get_height(widget);
    if (w <= 0 || h <= 0) {
        return;
    }
    graphene_rect_t bounds = GRAPHENE_RECT_INIT(0, 0, w, h);
    gtk_snapshot_append_texture(snapshot, owner->latest_texture, &bounds);
}

static void
luma_monaco_tile_size_allocate(GtkWidget *widget, int width, int height, int baseline)
{
    GTK_WIDGET_CLASS(luma_monaco_tile_parent_class)->size_allocate(widget, width, height, baseline);
    LumaMonacoView *owner = g_object_get_data(G_OBJECT(widget), "luma-owner");
    if (owner != NULL) {
        sync_overlay(owner);
    }
}

static void
luma_monaco_tile_class_init(LumaMonacoTileClass *klass)
{
    GtkWidgetClass *widget_class = GTK_WIDGET_CLASS(klass);
    widget_class->snapshot = luma_monaco_tile_snapshot;
    widget_class->size_allocate = luma_monaco_tile_size_allocate;
}

static void
luma_monaco_tile_init(LumaMonacoTile *self)
{
    gtk_widget_set_hexpand(GTK_WIDGET(self), TRUE);
    gtk_widget_set_vexpand(GTK_WIDGET(self), TRUE);
    gtk_widget_set_focusable(GTK_WIDGET(self), TRUE);
}

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

static gboolean
compute_native_rect(LumaMonacoView *self, NSRect *out)
{
    GtkNative *native = gtk_widget_get_native(self->placeholder);
    if (native == NULL) {
        return FALSE;
    }
    int w = gtk_widget_get_width(self->placeholder);
    int h = gtk_widget_get_height(self->placeholder);
    if (w <= 0 || h <= 0) {
        return FALSE;
    }
    graphene_point_t origin = GRAPHENE_POINT_INIT(0, 0);
    graphene_point_t native_pt;
    if (!gtk_widget_compute_point(self->placeholder, GTK_WIDGET(native), &origin, &native_pt)) {
        return FALSE;
    }
    double surface_dx, surface_dy;
    gtk_native_get_surface_transform(native, &surface_dx, &surface_dy);
    *out = NSMakeRect(native_pt.x + surface_dx, native_pt.y + surface_dy, w, h);
    return TRUE;
}

static GdkTexture *
texture_from_cgimage(LumaMonacoView *self, CGImageRef cgImage)
{
    int width = (int)CGImageGetWidth(cgImage);
    int height = (int)CGImageGetHeight(cgImage);
    if (width == 0 || height == 0 || self->gl_context == NULL) {
        return NULL;
    }

    CGDataProviderRef provider = CGImageGetDataProvider(cgImage);
    if (provider == NULL) {
        return NULL;
    }
    CFDataRef data = CGDataProviderCopyData(provider);
    if (data == NULL) {
        return NULL;
    }
    size_t bpr = CGImageGetBytesPerRow(cgImage);

    gdk_gl_context_make_current(self->gl_context);

    if (self->gl_texture == 0) {
        glGenTextures(1, &self->gl_texture);
        glBindTexture(GL_TEXTURE_2D, self->gl_texture);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    } else {
        glBindTexture(GL_TEXTURE_2D, self->gl_texture);
    }

    glPixelStorei(GL_UNPACK_ROW_LENGTH, (GLint)(bpr / 4));

    if (width != self->gl_texture_width || height != self->gl_texture_height) {
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, width, height, 0,
                     GL_BGRA, GL_UNSIGNED_INT_8_8_8_8_REV,
                     CFDataGetBytePtr(data));
        self->gl_texture_width = width;
        self->gl_texture_height = height;
    } else {
        glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, width, height,
                        GL_BGRA, GL_UNSIGNED_INT_8_8_8_8_REV,
                        CFDataGetBytePtr(data));
    }

    glPixelStorei(GL_UNPACK_ROW_LENGTH, 0);
    glFinish();

    CFRelease(data);

    GdkGLTextureBuilder *builder = gdk_gl_texture_builder_new();
    gdk_gl_texture_builder_set_context(builder, self->gl_context);
    gdk_gl_texture_builder_set_id(builder, self->gl_texture);
    gdk_gl_texture_builder_set_width(builder, width);
    gdk_gl_texture_builder_set_height(builder, height);
    gdk_gl_texture_builder_set_format(builder, GDK_MEMORY_B8G8R8A8_PREMULTIPLIED);
    GdkTexture *texture = gdk_gl_texture_builder_build(builder, NULL, NULL);
    g_object_unref(builder);
    return texture;
}

static void
request_snapshot(LumaMonacoView *self)
{
    if (!self->overlay_installed || self->snapshot_in_flight) {
        return;
    }
    NSRect bounds = self->web_view.bounds;
    if (bounds.size.width <= 0 || bounds.size.height <= 0) {
        return;
    }

    self->snapshot_in_flight = YES;

    WKSnapshotConfiguration *cfg = [[WKSnapshotConfiguration alloc] init];
    cfg.rect = bounds;
    cfg.afterScreenUpdates = NO;

    __block LumaMonacoView *block_self = self;
    [self->web_view takeSnapshotWithConfiguration:cfg completionHandler:^(NSImage *image, NSError *error) {
        block_self->snapshot_in_flight = NO;
        if (image == nil || error != nil) {
            return;
        }
        CGImageRef cgImage = [image CGImageForProposedRect:NULL context:nil hints:nil];
        if (cgImage == NULL) {
            return;
        }
        GdkTexture *texture = texture_from_cgimage(block_self, cgImage);
        if (texture == NULL) {
            return;
        }
        g_clear_object(&block_self->latest_texture);
        block_self->latest_texture = texture;
        if (block_self->placeholder != NULL) {
            gtk_widget_queue_draw(block_self->placeholder);
        }
    }];
}

static void
sync_overlay(LumaMonacoView *self)
{
    if (!self->overlay_installed) {
        return;
    }
    NSRect rect;
    if (!compute_native_rect(self, &rect)) {
        return;
    }
    [self->web_view setFrame:rect];
    request_snapshot(self);
}

static GList *g_monaco_views = NULL;

static gboolean
on_tile_key_pressed(GtkEventControllerKey *controller,
                    guint keyval,
                    guint keycode,
                    GdkModifierType state,
                    gpointer user_data)
{
    (void)controller;
    (void)keyval;
    (void)keycode;
    (void)state;
    LumaMonacoView *self = user_data;

    NSEvent *nsevent = [NSApp currentEvent];
    if (nsevent == nil || nsevent.type != NSEventTypeKeyDown) {
        return GDK_EVENT_PROPAGATE;
    }
    [self->web_view keyDown:nsevent];
    request_snapshot(self);
    return GDK_EVENT_STOP;
}

static gboolean
cursor_over_any_monaco_view(void)
{
    NSPoint screen_pt = [NSEvent mouseLocation];
    for (GList *l = g_monaco_views; l != NULL; l = l->next) {
        LumaMonacoView *view = l->data;
        if (!view->overlay_installed || view->host_window == nil) {
            continue;
        }
        NSPoint window_pt = [view->host_window convertPointFromScreen:screen_pt];
        NSRect rect;
        if (!compute_native_rect(view, &rect)) {
            continue;
        }
        if (NSPointInRect(window_pt, rect)) {
            return TRUE;
        }
    }
    return FALSE;
}

static LumaMonacoView *
find_monaco_view_at(NSWindow *window, NSPoint point_in_window)
{
    for (GList *l = g_monaco_views; l != NULL; l = l->next) {
        LumaMonacoView *view = l->data;
        if (!view->overlay_installed || view->host_window != window) {
            continue;
        }
        NSRect rect;
        if (!compute_native_rect(view, &rect)) {
            continue;
        }
        if (NSPointInRect(point_in_window, rect)) {
            return view;
        }
    }
    return NULL;
}

typedef void (*EventIMP)(id, SEL, NSEvent *);
typedef void (*NoArgIMP)(id, SEL);

static NSCursor *s_arrow_cursor;
static NoArgIMP s_orig_NSCursor_set;

static void
luma_NSCursor_set(id self, SEL _cmd)
{
    if (self == s_arrow_cursor && cursor_over_any_monaco_view()) {
        return;
    }
    s_orig_NSCursor_set(self, _cmd);
}

static EventIMP s_orig_mouseDown;
static EventIMP s_orig_mouseUp;
static EventIMP s_orig_mouseDragged;
static EventIMP s_orig_rightMouseDown;
static EventIMP s_orig_rightMouseUp;
static EventIMP s_orig_rightMouseDragged;
static EventIMP s_orig_otherMouseDown;
static EventIMP s_orig_otherMouseUp;
static EventIMP s_orig_otherMouseDragged;
static EventIMP s_orig_mouseMoved;
static EventIMP s_orig_scrollWheel;
static EventIMP s_orig_cursorUpdate;

static void
forward_or_super_mouse(id self, SEL _cmd, NSEvent *event, EventIMP super_imp, SEL webview_sel, gboolean grab_focus)
{
    LumaMonacoView *view = find_monaco_view_at([self window], event.locationInWindow);
    if (view != NULL) {
        if (grab_focus) {
            gtk_widget_grab_focus(view->placeholder);
            [[self window] makeFirstResponder:view->web_view];
        }
        ((void (*)(id, SEL, NSEvent *))objc_msgSend)(view->web_view, webview_sel, event);
        request_snapshot(view);
        return;
    }
    super_imp(self, _cmd, event);
}

static void
luma_view_mouseDown(id self, SEL _cmd, NSEvent *event)
{
    forward_or_super_mouse(self, _cmd, event, s_orig_mouseDown, @selector(mouseDown:), TRUE);
}

static void
luma_view_mouseUp(id self, SEL _cmd, NSEvent *event)
{
    forward_or_super_mouse(self, _cmd, event, s_orig_mouseUp, @selector(mouseUp:), FALSE);
}

static void
luma_view_mouseDragged(id self, SEL _cmd, NSEvent *event)
{
    forward_or_super_mouse(self, _cmd, event, s_orig_mouseDragged, @selector(mouseDragged:), FALSE);
}

static void
luma_view_rightMouseDown(id self, SEL _cmd, NSEvent *event)
{
    forward_or_super_mouse(self, _cmd, event, s_orig_rightMouseDown, @selector(rightMouseDown:), FALSE);
}

static void
luma_view_rightMouseUp(id self, SEL _cmd, NSEvent *event)
{
    forward_or_super_mouse(self, _cmd, event, s_orig_rightMouseUp, @selector(rightMouseUp:), FALSE);
}

static void
luma_view_rightMouseDragged(id self, SEL _cmd, NSEvent *event)
{
    forward_or_super_mouse(self, _cmd, event, s_orig_rightMouseDragged, @selector(rightMouseDragged:), FALSE);
}

static void
luma_view_otherMouseDown(id self, SEL _cmd, NSEvent *event)
{
    forward_or_super_mouse(self, _cmd, event, s_orig_otherMouseDown, @selector(otherMouseDown:), FALSE);
}

static void
luma_view_otherMouseUp(id self, SEL _cmd, NSEvent *event)
{
    forward_or_super_mouse(self, _cmd, event, s_orig_otherMouseUp, @selector(otherMouseUp:), FALSE);
}

static void
luma_view_otherMouseDragged(id self, SEL _cmd, NSEvent *event)
{
    forward_or_super_mouse(self, _cmd, event, s_orig_otherMouseDragged, @selector(otherMouseDragged:), FALSE);
}

static void
luma_view_mouseMoved(id self, SEL _cmd, NSEvent *event)
{
    if (find_monaco_view_at([self window], event.locationInWindow) != NULL) {
        return;
    }
    s_orig_mouseMoved(self, _cmd, event);
}

static void
luma_view_scrollWheel(id self, SEL _cmd, NSEvent *event)
{
    forward_or_super_mouse(self, _cmd, event, s_orig_scrollWheel, @selector(scrollWheel:), FALSE);
}

static void
luma_view_cursorUpdate(id self, SEL _cmd, NSEvent *event)
{
    if (find_monaco_view_at([self window], event.locationInWindow) != NULL) {
        return;
    }
    s_orig_cursorUpdate(self, _cmd, event);
}

static void
swizzle_method(Class cls, SEL sel, IMP new_impl, EventIMP *out_orig)
{
    Method method = class_getInstanceMethod(cls, sel);
    if (method == NULL) {
        *out_orig = NULL;
        return;
    }
    const char *types = method_getTypeEncoding(method);
    if (class_addMethod(cls, sel, new_impl, types)) {
        *out_orig = (EventIMP)method_getImplementation(method);
    } else {
        Method own = class_getInstanceMethod(cls, sel);
        *out_orig = (EventIMP)method_setImplementation(own, new_impl);
    }
}

static void
install_event_swizzle_once(void)
{
    static gboolean installed = FALSE;
    if (installed) {
        return;
    }
    installed = TRUE;

    Class cls = NSClassFromString(@"GdkMacosView");
    if (cls == Nil) {
        g_warning("luma: GdkMacosView not found; Monaco events will not work");
        return;
    }

    s_arrow_cursor = [NSCursor arrowCursor];
    Method cursor_set = class_getInstanceMethod([NSCursor class], @selector(set));
    if (cursor_set != NULL) {
        s_orig_NSCursor_set = (NoArgIMP)method_setImplementation(cursor_set, (IMP)luma_NSCursor_set);
    }

    swizzle_method(cls, @selector(mouseDown:), (IMP)luma_view_mouseDown, &s_orig_mouseDown);
    swizzle_method(cls, @selector(mouseUp:), (IMP)luma_view_mouseUp, &s_orig_mouseUp);
    swizzle_method(cls, @selector(mouseDragged:), (IMP)luma_view_mouseDragged, &s_orig_mouseDragged);
    swizzle_method(cls, @selector(rightMouseDown:), (IMP)luma_view_rightMouseDown, &s_orig_rightMouseDown);
    swizzle_method(cls, @selector(rightMouseUp:), (IMP)luma_view_rightMouseUp, &s_orig_rightMouseUp);
    swizzle_method(cls, @selector(rightMouseDragged:), (IMP)luma_view_rightMouseDragged, &s_orig_rightMouseDragged);
    swizzle_method(cls, @selector(otherMouseDown:), (IMP)luma_view_otherMouseDown, &s_orig_otherMouseDown);
    swizzle_method(cls, @selector(otherMouseUp:), (IMP)luma_view_otherMouseUp, &s_orig_otherMouseUp);
    swizzle_method(cls, @selector(otherMouseDragged:), (IMP)luma_view_otherMouseDragged, &s_orig_otherMouseDragged);
    swizzle_method(cls, @selector(mouseMoved:), (IMP)luma_view_mouseMoved, &s_orig_mouseMoved);
    swizzle_method(cls, @selector(scrollWheel:), (IMP)luma_view_scrollWheel, &s_orig_scrollWheel);
    swizzle_method(cls, @selector(cursorUpdate:), (IMP)luma_view_cursorUpdate, &s_orig_cursorUpdate);
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

    install_event_swizzle_once();

    self->host_window = parent;
    self->web_view.alphaValue = 1.0;
    self->web_view.translatesAutoresizingMaskIntoConstraints = YES;
    self->web_view.autoresizingMask = NSViewNotSizable;
    self->web_view.layer.zPosition = -1;
    [parent.contentView addSubview:self->web_view];
    self->overlay_installed = TRUE;

    if (self->gl_context == NULL) {
        GtkNative *native = gtk_widget_get_native(self->placeholder);
        GdkSurface *surface = gtk_native_get_surface(native);
        if (surface != NULL) {
            GError *error = NULL;
            self->gl_context = gdk_surface_create_gl_context(surface, &error);
            if (self->gl_context != NULL) {
                if (!gdk_gl_context_realize(self->gl_context, &error)) {
                    g_clear_object(&self->gl_context);
                }
            }
            if (error != NULL) {
                g_warning("luma: GL context setup failed: %s", error->message);
                g_clear_error(&error);
            }
        }
    }

    self->display_link_target = [[LumaDisplayLinkTarget alloc] init];
    self->display_link_target.owner = self;
    self->display_link = [parent.contentView displayLinkWithTarget:self->display_link_target
                                                          selector:@selector(tick)];
    [self->display_link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];

    sync_overlay(self);
}

static void
on_placeholder_realize(GtkWidget *widget, gpointer user_data)
{
    (void)widget;
    install_overlay((LumaMonacoView *)user_data);
}

static void
on_placeholder_unrealize(GtkWidget *widget, gpointer user_data)
{
    (void)widget;
    LumaMonacoView *self = (LumaMonacoView *)user_data;
    if (!self->overlay_installed) {
        return;
    }
    [self->display_link invalidate];
    self->display_link = nil;
    self->display_link_target = nil;
    [self->web_view removeFromSuperview];
    self->host_window = nil;
    self->overlay_installed = FALSE;
}

LumaMonacoView *
luma_monaco_view_new(void)
{
    LumaMonacoView *self = g_new0(LumaMonacoView, 1);

    WKWebViewConfiguration *config = [[WKWebViewConfiguration alloc] init];
    [config.preferences setValue:@YES forKey:@"developerExtrasEnabled"];
    self->web_view = [[LumaWKWebView alloc] initWithFrame:NSZeroRect configuration:config];

    self->delegate = [[LumaMonacoDelegate alloc] init];
    self->delegate.owner = self;
    self->web_view.navigationDelegate = self->delegate;

    self->placeholder = g_object_new(LUMA_TYPE_MONACO_TILE, NULL);
    g_object_set_data(G_OBJECT(self->placeholder), "luma-owner", self);

    GtkEventController *key_controller = gtk_event_controller_key_new();
    gtk_event_controller_set_propagation_phase(key_controller, GTK_PHASE_CAPTURE);
    g_signal_connect(key_controller, "key-pressed", G_CALLBACK(on_tile_key_pressed), self);
    gtk_widget_add_controller(self->placeholder, key_controller);

    g_signal_connect(self->placeholder, "realize", G_CALLBACK(on_placeholder_realize), self);
    g_signal_connect(self->placeholder, "unrealize", G_CALLBACK(on_placeholder_unrealize), self);

    g_monaco_views = g_list_prepend(g_monaco_views, self);

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
luma_monaco_view_grab_focus(LumaMonacoView *view)
{
    gtk_widget_grab_focus(view->placeholder);
    if (view->host_window != nil) {
        [view->host_window makeFirstResponder:view->web_view];
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
