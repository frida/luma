#include "include/CLuma.h"

#include <gtk/gtk.h>
#include <epoxy/gl.h>
#include <math.h>
#include <string.h>

#define LUMA_SHADER_EFFECT_DATA_KEY "luma-shader-effect"

// Seconds for a reported arrival to fall to 1/e.
#define PULSE_HALF_LIFE_SECONDS 0.4f
#define ACTIVITY_HALF_LIFE_SECONDS 1.2f
#define MAX_ATTRIBUTES 8
#define MAX_DRAWABLES 64
#define MAX_PARAMS 16

typedef struct {
    char *name;
    int components;
} LumaAttribute;

// A uniform the author named. OpenGL takes them loose, so each is set by
// the name it was given.
typedef struct {
    char *name;
    float values[16];
    int components;
    GLint location;
    // Set when the value is moving on its own: worked out here each frame
    // rather than pushed from the image.
    gboolean driven;
    int driver_kind;
    float from[16];
    float to[16];
    float seconds;
    gint64 started_at;
} LumaParam;

// One thing the widget draws, with its own stages, vertices and place. A
// scene is however many of these the author made.
typedef struct {
    int handle;
    gboolean visible;
    gboolean changed;
    char *vertex_src;
    char *fragment_src;
    LumaAttribute attributes[MAX_ATTRIBUTES];
    int attribute_count;
    float *vertices;
    int vertex_count;
    int primitive;
    float mvp[16];
    LumaParam params[MAX_PARAMS];
    int param_count;
    GLuint program;
    GLuint vao;
    GLuint vbo;
    GLint loc_resolution;
    GLint loc_time;
    GLint loc_scheme;
    GLint loc_activity;
    GLint loc_pulse;
    GLint loc_data_count;
    GLint loc_data;
    GLint loc_mvp;
} LumaDrawable;

typedef struct {
    // The screen-filling effect, when the widget is showing one of those.
    char *fragment_src;
    GLuint program;
    GLuint vao;
    GLuint vbo;
    GLint loc_resolution;
    GLint loc_time;
    GLint loc_scheme;
    GLint loc_activity;
    GLint loc_pulse;
    GLint loc_data_count;
    GLint loc_data;
    GLint loc_mvp;

    LumaDrawable drawables[MAX_DRAWABLES];
    int next_handle;

    gint64 start_us;
    guint tick_id;
    float scheme;
    float activity;
    float data[64];
    int data_count;
    float mvp[16];
    gint64 pulsed_at_us;
    gint64 rendered_at_us;
    float clear_color[3];
} LumaShaderEffect;

static void on_realize(GtkGLArea *area, gpointer user_data);
static void on_unrealize(GtkGLArea *area, gpointer user_data);
static gboolean on_render(GtkGLArea *area, GdkGLContext *context, gpointer user_data);
static gboolean on_tick(GtkWidget *widget, GdkFrameClock *clock, gpointer user_data);
static void effect_free(gpointer data);
static LumaShaderEffect *effect_for(GtkWidget *widget);
static LumaDrawable *drawable_for(LumaShaderEffect *self, int handle);
static void feed_uniforms(LumaShaderEffect *self, GLint resolution, GLint time, GLint scheme,
                          GLint activity, GLint pulse, GLint data_count, GLint data, GLint mvp,
                          const float *transform, float width, float height,
                          float elapsed, float pulse_value);
static void rebuild_drawable(LumaDrawable *drawable);
static GLuint link_program(const char *fragment_src, gboolean gles);
static GLuint link_authored_program(LumaDrawable *drawable);
static GLuint compile_shader(GLenum kind, const char **sources, int source_count);
static GLenum gl_primitive(int primitive);
static void identity(float *matrix);

void *
luma_shader_effect_new(const char *fragment_src)
{
    LumaShaderEffect *self = g_new0(LumaShaderEffect, 1);
    self->fragment_src = fragment_src != NULL ? g_strdup(fragment_src) : NULL;
    self->scheme = 1.0f;
    self->next_handle = 1;
    identity(self->mvp);

    GtkWidget *area = gtk_gl_area_new();
    // Geometry with any depth to it needs this, and a screen-filling effect
    // is no worse off for having it.
    gtk_gl_area_set_has_depth_buffer(GTK_GL_AREA(area), TRUE);
    gtk_gl_area_set_has_stencil_buffer(GTK_GL_AREA(area), FALSE);
    gtk_gl_area_set_auto_render(GTK_GL_AREA(area), TRUE);

    g_object_set_data_full(G_OBJECT(area), LUMA_SHADER_EFFECT_DATA_KEY, self, effect_free);

    g_signal_connect(area, "realize", G_CALLBACK(on_realize), NULL);
    g_signal_connect(area, "unrealize", G_CALLBACK(on_unrealize), NULL);
    g_signal_connect(area, "render", G_CALLBACK(on_render), NULL);

    self->tick_id = gtk_widget_add_tick_callback(area, on_tick, NULL, NULL);
    return area;
}

int
luma_shader_effect_add_drawable(void *widget)
{
    LumaShaderEffect *self = effect_for(GTK_WIDGET(widget));
    for (int index = 0; index != MAX_DRAWABLES; index++) {
        LumaDrawable *drawable = &self->drawables[index];
        if (drawable->handle != 0)
            continue;

        drawable->handle = self->next_handle++;
        drawable->visible = TRUE;
        identity(drawable->mvp);
        return drawable->handle;
    }
    return 0;
}

void
luma_shader_effect_drawable_set_program(void *widget, int handle,
                                        const char *vertex_src, const char *fragment_src)
{
    LumaDrawable *drawable = drawable_for(effect_for(GTK_WIDGET(widget)), handle);
    if (drawable == NULL)
        return;

    g_clear_pointer(&drawable->vertex_src, g_free);
    g_clear_pointer(&drawable->fragment_src, g_free);
    drawable->vertex_src = g_strdup(vertex_src);
    drawable->fragment_src = g_strdup(fragment_src);
    for (int index = 0; index != drawable->attribute_count; index++)
        g_clear_pointer(&drawable->attributes[index].name, g_free);
    drawable->attribute_count = 0;
    drawable->changed = TRUE;
}

void
luma_shader_effect_drawable_add_attribute(void *widget, int handle, const char *name, int components)
{
    LumaDrawable *drawable = drawable_for(effect_for(GTK_WIDGET(widget)), handle);
    if (drawable == NULL || drawable->attribute_count == MAX_ATTRIBUTES)
        return;

    LumaAttribute *attribute = &drawable->attributes[drawable->attribute_count++];
    attribute->name = g_strdup(name);
    attribute->components = components;
    drawable->changed = TRUE;
}

void
luma_shader_effect_drawable_set_vertices(void *widget, int handle,
                                         const float *values, int count, int primitive)
{
    LumaDrawable *drawable = drawable_for(effect_for(GTK_WIDGET(widget)), handle);
    if (drawable == NULL)
        return;

    g_clear_pointer(&drawable->vertices, g_free);
    drawable->vertices = g_memdup2(values, count * sizeof(float));
    drawable->vertex_count = count;
    drawable->primitive = primitive;
    drawable->changed = TRUE;
}

void
luma_shader_effect_drawable_set_uniform(void *widget, int handle,
                                        const char *name, const float *values, int count)
{
    LumaDrawable *drawable = drawable_for(effect_for(GTK_WIDGET(widget)), handle);
    if (drawable == NULL)
        return;
    if (count > 16)
        count = 16;

    for (int index = 0; index != drawable->param_count; index++) {
        LumaParam *param = &drawable->params[index];
        if (strcmp(param->name, name) != 0)
            continue;
        memcpy(param->values, values, count * sizeof(float));
        param->components = count;
        return;
    }

    if (drawable->param_count == MAX_PARAMS)
        return;

    LumaParam *param = &drawable->params[drawable->param_count++];
    param->name = g_strdup(name);
    memcpy(param->values, values, count * sizeof(float));
    param->components = count;
    param->location = -1;
    drawable->changed = TRUE;
}

void
luma_shader_effect_drawable_drive_uniform(void *widget, int handle, const char *name,
                                          int kind, const float *from, const float *to,
                                          int count, float seconds)
{
    LumaShaderEffect *self = effect_for(GTK_WIDGET(widget));
    LumaDrawable *drawable = drawable_for(self, handle);
    if (drawable == NULL)
        return;
    if (count > 16)
        count = 16;

    LumaParam *param = NULL;
    for (int index = 0; index != drawable->param_count; index++) {
        if (strcmp(drawable->params[index].name, name) == 0) {
            param = &drawable->params[index];
            break;
        }
    }
    if (param == NULL) {
        if (drawable->param_count == MAX_PARAMS)
            return;
        param = &drawable->params[drawable->param_count++];
        param->name = g_strdup(name);
        param->location = -1;
        drawable->changed = TRUE;
    }

    param->components = count;
    param->driven = TRUE;
    param->driver_kind = kind;
    param->seconds = seconds;
    param->started_at = g_get_monotonic_time();
    memcpy(param->from, from, count * sizeof(float));
    memcpy(param->to, to, count * sizeof(float));
    memcpy(param->values, from, count * sizeof(float));
}

void
luma_shader_effect_drawable_set_transform(void *widget, int handle, const float *values)
{
    LumaDrawable *drawable = drawable_for(effect_for(GTK_WIDGET(widget)), handle);
    if (drawable != NULL)
        memcpy(drawable->mvp, values, 16 * sizeof(float));
}

void
luma_shader_effect_drawable_set_visible(void *widget, int handle, bool visible)
{
    LumaDrawable *drawable = drawable_for(effect_for(GTK_WIDGET(widget)), handle);
    if (drawable != NULL)
        drawable->visible = visible ? TRUE : FALSE;
}

void
luma_shader_effect_remove_drawable(void *widget, int handle)
{
    LumaDrawable *drawable = drawable_for(effect_for(GTK_WIDGET(widget)), handle);
    if (drawable == NULL)
        return;

    for (int index = 0; index != drawable->attribute_count; index++)
        g_free(drawable->attributes[index].name);
    g_free(drawable->vertices);
    g_free(drawable->vertex_src);
    g_free(drawable->fragment_src);
    if (drawable->program != 0)
        glDeleteProgram(drawable->program);
    if (drawable->vbo != 0)
        glDeleteBuffers(1, &drawable->vbo);
    if (drawable->vao != 0)
        glDeleteVertexArrays(1, &drawable->vao);
    memset(drawable, 0, sizeof *drawable);
}

void
luma_shader_effect_set_scheme(void *widget, float scheme)
{
    effect_for(GTK_WIDGET(widget))->scheme = scheme;
}

void
luma_shader_effect_report_activity(void *widget, float activity)
{
    LumaShaderEffect *self = effect_for(GTK_WIDGET(widget));
    self->activity = activity;
    self->pulsed_at_us = g_get_monotonic_time();
}

void
luma_shader_effect_set_data(void *widget, const float *values, int count)
{
    LumaShaderEffect *self = effect_for(GTK_WIDGET(widget));
    if (count > 64)
        count = 64;
    memcpy(self->data, values, count * sizeof(float));
    memset(self->data + count, 0, (64 - count) * sizeof(float));
    self->data_count = count;
}

void
luma_shader_effect_set_transform(void *widget, const float *values)
{
    memcpy(effect_for(GTK_WIDGET(widget))->mvp, values, 16 * sizeof(float));
}

void
luma_shader_effect_set_clear_color(void *widget, float red, float green, float blue)
{
    LumaShaderEffect *self = effect_for(GTK_WIDGET(widget));
    self->clear_color[0] = red;
    self->clear_color[1] = green;
    self->clear_color[2] = blue;
}

static void
on_realize(GtkGLArea *area, gpointer user_data)
{
    (void)user_data;
    LumaShaderEffect *self = effect_for(GTK_WIDGET(area));
    gtk_gl_area_make_current(area);
    if (gtk_gl_area_get_error(area) != NULL)
        return;

    // A widget made for a scene has no screen-filling source to link.
    if (self->fragment_src == NULL) {
        self->start_us = g_get_monotonic_time();
        self->rendered_at_us = self->start_us;
        return;
    }

    GdkGLContext *context = gtk_gl_area_get_context(area);
    gboolean gles = gdk_gl_context_get_api(context) == GDK_GL_API_GLES;
    self->program = link_program(self->fragment_src, gles);
    self->loc_resolution = glGetUniformLocation(self->program, "u_resolution");
    self->loc_time = glGetUniformLocation(self->program, "u_time");
    self->loc_scheme = glGetUniformLocation(self->program, "u_scheme");
    self->loc_activity = glGetUniformLocation(self->program, "u_activity");
    self->loc_pulse = glGetUniformLocation(self->program, "u_pulse");
    self->loc_data_count = glGetUniformLocation(self->program, "u_data_count");
    self->loc_data = glGetUniformLocation(self->program, "u_data");
    self->loc_mvp = glGetUniformLocation(self->program, "u_mvp");

    static const float quad[] = {
        -1.0f, -1.0f,
         1.0f, -1.0f,
        -1.0f,  1.0f,
         1.0f,  1.0f,
    };

    glGenVertexArrays(1, &self->vao);
    glBindVertexArray(self->vao);
    glGenBuffers(1, &self->vbo);
    glBindBuffer(GL_ARRAY_BUFFER, self->vbo);
    glBufferData(GL_ARRAY_BUFFER, sizeof quad, quad, GL_STATIC_DRAW);
    glEnableVertexAttribArray(0);
    glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 0, NULL);
    glBindVertexArray(0);

    self->start_us = g_get_monotonic_time();
    self->rendered_at_us = self->start_us;
}

static void
on_unrealize(GtkGLArea *area, gpointer user_data)
{
    (void)user_data;
    LumaShaderEffect *self = effect_for(GTK_WIDGET(area));
    gtk_gl_area_make_current(area);
    if (self->vbo != 0) { glDeleteBuffers(1, &self->vbo); self->vbo = 0; }
    if (self->vao != 0) { glDeleteVertexArrays(1, &self->vao); self->vao = 0; }
    if (self->program != 0) { glDeleteProgram(self->program); self->program = 0; }
}

static gboolean
on_render(GtkGLArea *area, GdkGLContext *context, gpointer user_data)
{
    (void)context;
    (void)user_data;
    LumaShaderEffect *self = effect_for(GTK_WIDGET(area));

    int width = gtk_widget_get_width(GTK_WIDGET(area));
    int height = gtk_widget_get_height(GTK_WIDGET(area));
    int scale = gtk_widget_get_scale_factor(GTK_WIDGET(area));
    float fb_w = (float)(width * scale);
    float fb_h = (float)(height * scale);

    gint64 now_us = g_get_monotonic_time();
    float elapsed = (float)((now_us - self->start_us) / 1000000.0);
    float since_pulse = (float)((now_us - self->pulsed_at_us) / 1000000.0);
    float pulse = self->pulsed_at_us == 0 ? 0.0f : expf(-since_pulse / PULSE_HALF_LIFE_SECONDS);
    float since_render = (float)((now_us - self->rendered_at_us) / 1000000.0);
    self->rendered_at_us = now_us;
    self->activity *= expf(-since_render / ACTIVITY_HALF_LIFE_SECONDS);

    int drawn = 0;
    for (int index = 0; index != MAX_DRAWABLES; index++) {
        if (self->drawables[index].handle != 0 && self->drawables[index].visible)
            drawn++;
    }

    glClearColor(self->clear_color[0], self->clear_color[1], self->clear_color[2], 1.0f);
    if (drawn > 0) {
        glEnable(GL_DEPTH_TEST);
        glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
    } else {
        glDisable(GL_DEPTH_TEST);
        glClear(GL_COLOR_BUFFER_BIT);
    }

    if (drawn > 0) {
        for (int index = 0; index != MAX_DRAWABLES; index++) {
            LumaDrawable *drawable = &self->drawables[index];
            if (drawable->handle == 0 || !drawable->visible)
                continue;
            if (drawable->changed)
                rebuild_drawable(drawable);
            if (drawable->program == 0 || drawable->vertices == NULL)
                continue;

            int stride = 0;
            for (int at = 0; at != drawable->attribute_count; at++)
                stride += drawable->attributes[at].components;
            if (stride == 0)
                continue;

            glUseProgram(drawable->program);
            for (int at = 0; at != drawable->param_count; at++) {
                LumaParam *param = &drawable->params[at];
                if (param->location < 0)
                    continue;
                if (param->driven) {
                    float since = (float)((now_us - param->started_at) / 1000000.0);
                    float fraction;
                    if (param->driver_kind == 1) {
                        float period = param->seconds <= 0.0f ? 1.0f : param->seconds;
                        fraction = 0.5f - 0.5f * cosf(2.0f * (float)M_PI * since / period);
                    } else {
                        fraction = param->seconds <= 0.0f
                            ? 1.0f
                            : fminf(fmaxf(since / param->seconds, 0.0f), 1.0f);
                    }
                    for (int c = 0; c != param->components; c++)
                        param->values[c] = param->from[c] + (param->to[c] - param->from[c]) * fraction;
                }
                switch (param->components) {
                    case 1: glUniform1fv(param->location, 1, param->values); break;
                    case 2: glUniform2fv(param->location, 1, param->values); break;
                    case 3: glUniform3fv(param->location, 1, param->values); break;
                    case 16: glUniformMatrix4fv(param->location, 1, GL_FALSE, param->values); break;
                    default: glUniform4fv(param->location, 1, param->values); break;
                }
            }
            feed_uniforms(self, drawable->loc_resolution, drawable->loc_time, drawable->loc_scheme,
                          drawable->loc_activity, drawable->loc_pulse, drawable->loc_data_count,
                          drawable->loc_data, drawable->loc_mvp, drawable->mvp,
                          fb_w, fb_h, elapsed, pulse);
            glBindVertexArray(drawable->vao);
            glDrawArrays(gl_primitive(drawable->primitive), 0, drawable->vertex_count / stride);
            glBindVertexArray(0);
        }
        glUseProgram(0);
        return TRUE;
    }

    if (self->program == 0)
        return FALSE;

    glUseProgram(self->program);
    feed_uniforms(self, self->loc_resolution, self->loc_time, self->loc_scheme,
                  self->loc_activity, self->loc_pulse, self->loc_data_count,
                  self->loc_data, self->loc_mvp, self->mvp, fb_w, fb_h, elapsed, pulse);
    glBindVertexArray(self->vao);
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
    glBindVertexArray(0);
    glUseProgram(0);
    return TRUE;
}

static void
feed_uniforms(LumaShaderEffect *self, GLint resolution, GLint time, GLint scheme,
              GLint activity, GLint pulse, GLint data_count, GLint data, GLint mvp,
              const float *transform, float width, float height,
              float elapsed, float pulse_value)
{
    glUniform2f(resolution, width, height);
    glUniform1f(time, elapsed);
    glUniform1f(scheme, self->scheme);
    glUniform1f(activity, self->activity);
    glUniform1f(pulse, pulse_value);
    glUniform1f(data_count, (float)self->data_count);
    glUniform4fv(data, 16, self->data);
    glUniformMatrix4fv(mvp, 1, GL_FALSE, transform);
}

// Lays the author's own attributes out over their vertices, binding each by
// the name they gave it, so their shader needs no layout qualifier that the
// GLSL version here would refuse.
static void
rebuild_drawable(LumaDrawable *drawable)
{
    drawable->changed = FALSE;
    if (drawable->vertex_src == NULL || drawable->vertices == NULL)
        return;

    if (drawable->program != 0)
        glDeleteProgram(drawable->program);
    drawable->program = link_authored_program(drawable);
    if (drawable->program == 0)
        return;

    drawable->loc_resolution = glGetUniformLocation(drawable->program, "u_resolution");
    drawable->loc_time = glGetUniformLocation(drawable->program, "u_time");
    drawable->loc_scheme = glGetUniformLocation(drawable->program, "u_scheme");
    drawable->loc_activity = glGetUniformLocation(drawable->program, "u_activity");
    drawable->loc_pulse = glGetUniformLocation(drawable->program, "u_pulse");
    drawable->loc_data_count = glGetUniformLocation(drawable->program, "u_data_count");
    drawable->loc_data = glGetUniformLocation(drawable->program, "u_data");
    drawable->loc_mvp = glGetUniformLocation(drawable->program, "u_mvp");
    for (int index = 0; index != drawable->param_count; index++) {
        LumaParam *param = &drawable->params[index];
        param->location = glGetUniformLocation(drawable->program, param->name);
    }

    if (drawable->vao == 0)
        glGenVertexArrays(1, &drawable->vao);
    if (drawable->vbo == 0)
        glGenBuffers(1, &drawable->vbo);

    glBindVertexArray(drawable->vao);
    glBindBuffer(GL_ARRAY_BUFFER, drawable->vbo);
    glBufferData(GL_ARRAY_BUFFER, drawable->vertex_count * sizeof(float),
                 drawable->vertices, GL_STATIC_DRAW);

    int stride = 0;
    for (int index = 0; index != drawable->attribute_count; index++)
        stride += drawable->attributes[index].components;

    size_t offset = 0;
    for (int index = 0; index != drawable->attribute_count; index++) {
        const LumaAttribute *attribute = &drawable->attributes[index];
        glEnableVertexAttribArray(index);
        glVertexAttribPointer(index, attribute->components, GL_FLOAT, GL_FALSE,
                              stride * sizeof(float), (const void *)(offset * sizeof(float)));
        offset += attribute->components;
    }
    glBindVertexArray(0);
}

static GLuint
link_authored_program(LumaDrawable *drawable)
{
    const char *vertex_sources[] = { drawable->vertex_src };
    const char *fragment_sources[] = { drawable->fragment_src };

    GLuint vs = compile_shader(GL_VERTEX_SHADER, vertex_sources, 1);
    GLuint fs = compile_shader(GL_FRAGMENT_SHADER, fragment_sources, 1);
    if (vs == 0 || fs == 0) {
        if (vs != 0) glDeleteShader(vs);
        if (fs != 0) glDeleteShader(fs);
        return 0;
    }

    GLuint program = glCreateProgram();
    glAttachShader(program, vs);
    glAttachShader(program, fs);
    for (int index = 0; index != drawable->attribute_count; index++)
        glBindAttribLocation(program, index, drawable->attributes[index].name);
    glLinkProgram(program);
    glDetachShader(program, vs);
    glDetachShader(program, fs);
    glDeleteShader(vs);
    glDeleteShader(fs);

    GLint ok = 0;
    glGetProgramiv(program, GL_LINK_STATUS, &ok);
    if (!ok) {
        char log[1024];
        glGetProgramInfoLog(program, sizeof log, NULL, log);
        g_warning("luma shader effect: program link failed: %s", log);
        glDeleteProgram(program);
        return 0;
    }
    return program;
}

static gboolean
on_tick(GtkWidget *widget, GdkFrameClock *clock, gpointer user_data)
{
    (void)clock;
    (void)user_data;
    gtk_gl_area_queue_render(GTK_GL_AREA(widget));
    return G_SOURCE_CONTINUE;
}

static void
effect_free(gpointer data)
{
    LumaShaderEffect *self = data;
    for (int index = 0; index != MAX_DRAWABLES; index++) {
        LumaDrawable *drawable = &self->drawables[index];
        for (int at = 0; at != drawable->attribute_count; at++)
            g_free(drawable->attributes[at].name);
        for (int at = 0; at != drawable->param_count; at++)
            g_free(drawable->params[at].name);
        g_free(drawable->vertices);
        g_free(drawable->vertex_src);
        g_free(drawable->fragment_src);
    }
    g_free(self->fragment_src);
    g_free(self);
}

static LumaShaderEffect *
effect_for(GtkWidget *widget)
{
    return g_object_get_data(G_OBJECT(widget), LUMA_SHADER_EFFECT_DATA_KEY);
}

static LumaDrawable *
drawable_for(LumaShaderEffect *self, int handle)
{
    for (int index = 0; index != MAX_DRAWABLES; index++) {
        if (self->drawables[index].handle == handle)
            return &self->drawables[index];
    }
    return NULL;
}

static GLenum
gl_primitive(int primitive)
{
    switch (primitive) {
        case 0: return GL_POINTS;
        case 1: return GL_LINES;
        case 2: return GL_LINE_STRIP;
        case 4: return GL_TRIANGLE_STRIP;
        default: return GL_TRIANGLES;
    }
}

static void
identity(float *matrix)
{
    memset(matrix, 0, 16 * sizeof(float));
    for (int index = 0; index != 4; index++)
        matrix[index * 5] = 1.0f;
}

static const char *shader_effect_vertex_src =
    "in vec2 a_pos;\n"
    "out vec2 v_uv;\n"
    "void main() {\n"
    "    v_uv = a_pos * 0.5 + 0.5;\n"
    "    gl_Position = vec4(a_pos, 0.0, 1.0);\n"
    "}\n";

static const char *shader_effect_fragment_preamble =
    "in vec2 v_uv;\n"
    "out vec4 frag_color;\n"
    "uniform vec2 u_resolution;\n"
    "uniform float u_time;\n"
    "uniform float u_scheme;\n"
    "uniform float u_activity;\n"
    "uniform float u_pulse;\n"
    "uniform float u_data_count;\n"
    "uniform vec4 u_data[16];\n"
    "uniform mat4 u_mvp;\n"
    "float dataAt(int i) { return u_data[i >> 2][i & 3]; }\n";

static GLuint
link_program(const char *fragment_src, gboolean gles)
{
    const char *version = gles
        ? "#version 300 es\nprecision highp float;\n"
        : "#version 150 core\n";
    const char *vertex_sources[] = { version, shader_effect_vertex_src };
    const char *fragment_sources[] = { version, shader_effect_fragment_preamble, fragment_src };

    GLuint vs = compile_shader(GL_VERTEX_SHADER, vertex_sources, G_N_ELEMENTS(vertex_sources));
    GLuint fs = compile_shader(GL_FRAGMENT_SHADER, fragment_sources, G_N_ELEMENTS(fragment_sources));
    if (vs == 0 || fs == 0) {
        if (vs != 0) glDeleteShader(vs);
        if (fs != 0) glDeleteShader(fs);
        return 0;
    }

    GLuint program = glCreateProgram();
    glAttachShader(program, vs);
    glAttachShader(program, fs);
    glBindAttribLocation(program, 0, "a_pos");
    glLinkProgram(program);
    glDetachShader(program, vs);
    glDetachShader(program, fs);
    glDeleteShader(vs);
    glDeleteShader(fs);

    GLint ok = 0;
    glGetProgramiv(program, GL_LINK_STATUS, &ok);
    if (!ok) {
        char log[1024];
        glGetProgramInfoLog(program, sizeof log, NULL, log);
        g_warning("luma shader effect: program link failed: %s", log);
        glDeleteProgram(program);
        return 0;
    }
    return program;
}

static GLuint
compile_shader(GLenum kind, const char **sources, int source_count)
{
    GLuint shader = glCreateShader(kind);
    glShaderSource(shader, source_count, sources, NULL);
    glCompileShader(shader);
    GLint ok = 0;
    glGetShaderiv(shader, GL_COMPILE_STATUS, &ok);
    if (!ok) {
        char log[1024];
        glGetShaderInfoLog(shader, sizeof log, NULL, log);
        g_warning("luma shader effect: shader compile failed: %s", log);
        glDeleteShader(shader);
        return 0;
    }
    return shader;
}
