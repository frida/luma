#include "include/CLuma.h"

#include <gtk/gtk.h>
#include <epoxy/gl.h>
#include <stdint.h>
#include <stdlib.h>

#define LUMA_BACKDROP_DATA_KEY "luma-welcome-backdrop"

typedef struct {
    GLuint program;
    GLuint vao;
    GLuint vbo;
    GLint loc_resolution;
    GLint loc_time;
    GLint loc_scheme;
    gint64 start_us;
    guint tick_id;
    gboolean dark;
} LumaWelcomeBackdrop;

static const char *backdrop_vertex_src =
    "in vec2 a_pos;\n"
    "out vec2 v_uv;\n"
    "void main() {\n"
    "    v_uv = a_pos * 0.5 + 0.5;\n"
    "    gl_Position = vec4(a_pos, 0.0, 1.0);\n"
    "}\n";

static const char *backdrop_fragment_src =
    "in vec2 v_uv;\n"
    "out vec4 frag_color;\n"
    "uniform vec2 u_resolution;\n"
    "uniform float u_time;\n"
    "uniform float u_scheme;\n"
    "float plasmaField(vec2 p, float t) {\n"
    "    float v = sin(p.x * 3.0 + t * 0.55);\n"
    "    v += sin(p.y * 2.7 - t * 0.42);\n"
    "    v += sin((p.x + p.y) * 1.9 + t * 0.38);\n"
    "    vec2 c = vec2(sin(t * 0.27), cos(t * 0.31)) * 1.4;\n"
    "    v += sin(length(p * 1.6 - c) * 4.2 - t * 0.65);\n"
    "    return v * 0.25;\n"
    "}\n"
    "void main() {\n"
    "    float aspect = u_resolution.x / max(u_resolution.y, 1.0);\n"
    "    vec2 p = v_uv * 2.0 - 1.0;\n"
    "    p.x *= aspect;\n"
    "    float v = plasmaField(p, u_time);\n"
    "    float n = v * 0.5 + 0.5;\n"
    "    const vec3 LIGHT_A = vec3(0.965, 0.935, 0.905);\n"
    "    const vec3 LIGHT_B = vec3(0.085, 0.110, 0.130);\n"
    "    const vec3 LIGHT_D = vec3(0.00, 0.10, 0.22);\n"
    "    const vec3 DARK_A  = vec3(0.180, 0.105, 0.135);\n"
    "    const vec3 DARK_B  = vec3(0.520, 0.230, 0.205);\n"
    "    const vec3 DARK_D  = vec3(0.00, 0.14, 0.30);\n"
    "    vec3 lightColor = LIGHT_A + LIGHT_B * cos(6.28318 * (n + LIGHT_D));\n"
    "    vec3 darkColor  = DARK_A  + DARK_B  * cos(6.28318 * (n + DARK_D));\n"
    "    float band = sin(v * 9.0 + u_time * 0.6);\n"
    "    float contour = smoothstep(0.86, 1.0, band);\n"
    "    lightColor -= contour * 0.020;\n"
    "    darkColor  += contour * vec3(0.060, 0.022, 0.018);\n"
    "    float ripple = sin(p.x * 1.8 - p.y * 1.2 + u_time * 0.9) * 0.5 + 0.5;\n"
    "    lightColor = mix(lightColor, lightColor * 0.985, ripple * 0.20);\n"
    "    darkColor  = mix(darkColor,  darkColor  * 1.080, ripple * 0.22);\n"
    "    float grain = fract(sin(dot(v_uv * u_resolution, vec2(12.9898, 78.233))) * 43758.5453);\n"
    "    lightColor += (grain - 0.5) * 0.008;\n"
    "    darkColor  += (grain - 0.5) * 0.014;\n"
    "    float vignette = smoothstep(1.70, 0.45, length(p * vec2(0.85, 1.0)));\n"
    "    lightColor *= mix(0.96, 1.0, vignette);\n"
    "    darkColor  *= mix(0.55, 1.0, vignette);\n"
    "    vec3 color = mix(darkColor, lightColor, u_scheme);\n"
    "    frag_color = vec4(color, 1.0);\n"
    "}\n";

static GLuint
compile_shader(GLenum kind, const char *preamble, const char *src)
{
    GLuint shader = glCreateShader(kind);
    const char *sources[] = { preamble, src };
    glShaderSource(shader, G_N_ELEMENTS(sources), sources, NULL);
    glCompileShader(shader);
    GLint ok = 0;
    glGetShaderiv(shader, GL_COMPILE_STATUS, &ok);
    if (!ok) {
        char log[1024];
        glGetShaderInfoLog(shader, sizeof log, NULL, log);
        g_warning("luma welcome backdrop: shader compile failed: %s", log);
        glDeleteShader(shader);
        return 0;
    }
    return shader;
}

static GLuint
link_program(gboolean gles)
{
    const char *preamble = gles
        ? "#version 300 es\nprecision highp float;\n"
        : "#version 150 core\n";
    GLuint vs = compile_shader(GL_VERTEX_SHADER, preamble, backdrop_vertex_src);
    GLuint fs = compile_shader(GL_FRAGMENT_SHADER, preamble, backdrop_fragment_src);
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
        g_warning("luma welcome backdrop: program link failed: %s", log);
        glDeleteProgram(program);
        return 0;
    }
    return program;
}

static LumaWelcomeBackdrop *
ctx_for(GtkWidget *widget)
{
    return g_object_get_data(G_OBJECT(widget), LUMA_BACKDROP_DATA_KEY);
}

static void
on_realize(GtkGLArea *area, gpointer user_data)
{
    (void)user_data;
    LumaWelcomeBackdrop *self = ctx_for(GTK_WIDGET(area));
    if (self == NULL)
        return;
    gtk_gl_area_make_current(area);
    if (gtk_gl_area_get_error(area) != NULL)
        return;

    GdkGLContext *context = gtk_gl_area_get_context(area);
    gboolean gles = gdk_gl_context_get_api(context) == GDK_GL_API_GLES;
    self->program = link_program(gles);
    if (self->program == 0)
        return;
    self->loc_resolution = glGetUniformLocation(self->program, "u_resolution");
    self->loc_time = glGetUniformLocation(self->program, "u_time");
    self->loc_scheme = glGetUniformLocation(self->program, "u_scheme");

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
}

static void
on_unrealize(GtkGLArea *area, gpointer user_data)
{
    (void)user_data;
    LumaWelcomeBackdrop *self = ctx_for(GTK_WIDGET(area));
    if (self == NULL)
        return;
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
    LumaWelcomeBackdrop *self = ctx_for(GTK_WIDGET(area));
    if (self == NULL || self->program == 0)
        return FALSE;

    int width = gtk_widget_get_width(GTK_WIDGET(area));
    int height = gtk_widget_get_height(GTK_WIDGET(area));
    int scale = gtk_widget_get_scale_factor(GTK_WIDGET(area));
    float fb_w = (float)(width * scale);
    float fb_h = (float)(height * scale);

    float t = (float)((g_get_monotonic_time() - self->start_us) / 1000000.0);

    if (self->dark)
        glClearColor(0.075f, 0.050f, 0.065f, 1.0f);
    else
        glClearColor(0.994f, 0.991f, 0.986f, 1.0f);
    glClear(GL_COLOR_BUFFER_BIT);

    glUseProgram(self->program);
    glUniform2f(self->loc_resolution, fb_w, fb_h);
    glUniform1f(self->loc_time, t);
    glUniform1f(self->loc_scheme, self->dark ? 0.0f : 1.0f);
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

void *
luma_welcome_backdrop_new(void)
{
    LumaWelcomeBackdrop *self = g_new0(LumaWelcomeBackdrop, 1);
    self->dark = FALSE;

    GtkWidget *area = gtk_gl_area_new();
    gtk_gl_area_set_has_depth_buffer(GTK_GL_AREA(area), FALSE);
    gtk_gl_area_set_has_stencil_buffer(GTK_GL_AREA(area), FALSE);
    gtk_gl_area_set_auto_render(GTK_GL_AREA(area), TRUE);

    g_object_set_data_full(G_OBJECT(area), LUMA_BACKDROP_DATA_KEY, self, g_free);

    g_signal_connect(area, "realize", G_CALLBACK(on_realize), NULL);
    g_signal_connect(area, "unrealize", G_CALLBACK(on_unrealize), NULL);
    g_signal_connect(area, "render", G_CALLBACK(on_render), NULL);

    self->tick_id = gtk_widget_add_tick_callback(area, on_tick, NULL, NULL);
    return area;
}

void
luma_welcome_backdrop_set_dark(void *widget, bool dark)
{
    if (widget == NULL)
        return;
    LumaWelcomeBackdrop *self = ctx_for(GTK_WIDGET(widget));
    if (self == NULL)
        return;
    self->dark = dark ? TRUE : FALSE;
    gtk_gl_area_queue_render(GTK_GL_AREA(widget));
}
