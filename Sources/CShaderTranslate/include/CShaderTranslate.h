#ifndef LUMA_CSHADERTRANSLATE_H
#define LUMA_CSHADERTRANSLATE_H

#ifdef __cplusplus
extern "C" {
#endif

// Translates a fragment shader authored in GLSL into Metal Shading Language,
// so an effect written in a snippet reaches a Metal host without a build step.
// GTK needs none of this: OpenGL takes the GLSL as it stands.
//
// Answers a malloc'd MSL string the caller frees, or NULL. On failure a
// malloc'd message is written to *error_message, which the caller frees too,
// so a mistyped shader can be reported where it was written.
#define LUMA_SHADER_STAGE_VERTEX 0
#define LUMA_SHADER_STAGE_FRAGMENT 1

char *luma_shader_translate_to_msl(const char *glsl,
                                   int stage,
                                   const char *entry_point,
                                   char **error_message);

#ifdef __cplusplus
}
#endif

#endif
