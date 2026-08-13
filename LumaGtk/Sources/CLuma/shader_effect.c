#include "include/CLuma.h"

#include <gtk/gtk.h>
#include <epoxy/gl.h>
#include <math.h>

#define LUMA_SHADER_EFFECT_DATA_KEY "luma-shader-effect"

// Seconds for a reported arrival to fall to 1/e.
#define PULSE_HALF_LIFE_SECONDS 0.4f
#define ACTIVITY_HALF_LIFE_SECONDS 1.2f

typedef struct {
    char *fragment_src;
    GLuint program;
    GLuint vao;
    GLuint vbo;
    GLint loc_resolution;
    GLint loc_time;
    GLint loc_scheme;
    GLint loc_activity;
    GLint loc_pulse;
    gint64 start_us;
    guint tick_id;
    float scheme;
    float activity;
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
static GLuint link_program(const char *fragment_src, gboolean gles);
static GLuint compile_shader(GLenum kind, const char **sources, int source_count);

void *
luma_shader_effect_new(const char *fragment_src)
{
    LumaShaderEffect *self = g_new0(LumaShaderEffect, 1);
    self->fragment_src = g_strdup(fragment_src);
    self->scheme = 1.0f;

    GtkWidget *area = gtk_gl_area_new();
    gtk_gl_area_set_has_depth_buffer(GTK_GL_AREA(area), FALSE);
    gtk_gl_area_set_has_stencil_buffer(GTK_GL_AREA(area), FALSE);
    gtk_gl_area_set_auto_render(GTK_GL_AREA(area), TRUE);

    g_object_set_data_full(G_OBJECT(area), LUMA_SHADER_EFFECT_DATA_KEY, self, effect_free);

    g_signal_connect(area, "realize", G_CALLBACK(on_realize), NULL);
    g_signal_connect(area, "unrealize", G_CALLBACK(on_unrealize), NULL);
    g_signal_connect(area, "render", G_CALLBACK(on_render), NULL);

    self->tick_id = gtk_widget_add_tick_callback(area, on_tick, NULL, NULL);
    return area;
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

    GdkGLContext *context = gtk_gl_area_get_context(area);
    gboolean gles = gdk_gl_context_get_api(context) == GDK_GL_API_GLES;
    self->program = link_program(self->fragment_src, gles);
    if (self->program == 0)
        return;
    self->loc_resolution = glGetUniformLocation(self->program, "u_resolution");
    self->loc_time = glGetUniformLocation(self->program, "u_time");
    self->loc_scheme = glGetUniformLocation(self->program, "u_scheme");
    self->loc_activity = glGetUniformLocation(self->program, "u_activity");
    self->loc_pulse = glGetUniformLocation(self->program, "u_pulse");

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
    if (self->program == 0)
        return FALSE;

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

    glClearColor(self->clear_color[0], self->clear_color[1], self->clear_color[2], 1.0f);
    glClear(GL_COLOR_BUFFER_BIT);

    glUseProgram(self->program);
    glUniform2f(self->loc_resolution, fb_w, fb_h);
    glUniform1f(self->loc_time, elapsed);
    glUniform1f(self->loc_scheme, self->scheme);
    glUniform1f(self->loc_activity, self->activity);
    glUniform1f(self->loc_pulse, pulse);
    glBindVertexArray(self->vao);
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
    glBindVertexArray(0);
    glUseProgram(0);
    return TRUE;
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
    g_free(self->fragment_src);
    g_free(self);
}

static LumaShaderEffect *
effect_for(GtkWidget *widget)
{
    return g_object_get_data(G_OBJECT(widget), LUMA_SHADER_EFFECT_DATA_KEY);
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
    "uniform float u_pulse;\n";

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
