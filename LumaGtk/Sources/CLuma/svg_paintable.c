#include "include/CLuma.h"

#include <gtk/gtk.h>
#include <librsvg/rsvg.h>

#define LUMA_TYPE_SVG_PAINTABLE (luma_svg_paintable_get_type())

typedef struct {
    GObject parent_instance;
    RsvgHandle *handle;
    int logical_width;
    int logical_height;
} LumaSvgPaintable;

typedef struct {
    GObjectClass parent_class;
} LumaSvgPaintableClass;

static void luma_svg_paintable_iface_init(GdkPaintableInterface *iface);

G_DEFINE_TYPE_WITH_CODE(LumaSvgPaintable, luma_svg_paintable, G_TYPE_OBJECT,
    G_IMPLEMENT_INTERFACE(GDK_TYPE_PAINTABLE, luma_svg_paintable_iface_init))

void *
luma_svg_paintable_new_from_path(const char *path, int logical_width, int logical_height)
{
    GFile *file = g_file_new_for_path(path);
    RsvgHandle *handle = rsvg_handle_new_from_gfile_sync(file, RSVG_HANDLE_FLAGS_NONE, NULL, NULL);
    g_object_unref(file);
    if (handle == NULL)
        return NULL;

    LumaSvgPaintable *self = g_object_new(LUMA_TYPE_SVG_PAINTABLE, NULL);
    self->handle = handle;
    self->logical_width = logical_width;
    self->logical_height = logical_height;
    return self;
}

static void
luma_svg_paintable_snapshot(GdkPaintable *paintable, GdkSnapshot *snapshot, double width, double height)
{
    LumaSvgPaintable *self = (LumaSvgPaintable *) paintable;
    graphene_rect_t bounds = GRAPHENE_RECT_INIT(0.0f, 0.0f, (float) width, (float) height);
    cairo_t *cr = gtk_snapshot_append_cairo(GTK_SNAPSHOT(snapshot), &bounds);
    RsvgRectangle viewport = { 0.0, 0.0, width, height };
    rsvg_handle_render_document(self->handle, cr, &viewport, NULL);
    cairo_destroy(cr);
}

static int
luma_svg_paintable_intrinsic_width(GdkPaintable *paintable)
{
    return ((LumaSvgPaintable *) paintable)->logical_width;
}

static int
luma_svg_paintable_intrinsic_height(GdkPaintable *paintable)
{
    return ((LumaSvgPaintable *) paintable)->logical_height;
}

static double
luma_svg_paintable_intrinsic_aspect_ratio(GdkPaintable *paintable)
{
    LumaSvgPaintable *self = (LumaSvgPaintable *) paintable;
    return (double) self->logical_width / (double) self->logical_height;
}

static void
luma_svg_paintable_iface_init(GdkPaintableInterface *iface)
{
    iface->snapshot = luma_svg_paintable_snapshot;
    iface->get_intrinsic_width = luma_svg_paintable_intrinsic_width;
    iface->get_intrinsic_height = luma_svg_paintable_intrinsic_height;
    iface->get_intrinsic_aspect_ratio = luma_svg_paintable_intrinsic_aspect_ratio;
}

static void
luma_svg_paintable_finalize(GObject *object)
{
    LumaSvgPaintable *self = (LumaSvgPaintable *) object;
    g_clear_object(&self->handle);
    G_OBJECT_CLASS(luma_svg_paintable_parent_class)->finalize(object);
}

static void
luma_svg_paintable_class_init(LumaSvgPaintableClass *klass)
{
    G_OBJECT_CLASS(klass)->finalize = luma_svg_paintable_finalize;
}

static void
luma_svg_paintable_init(LumaSvgPaintable *self)
{
}
