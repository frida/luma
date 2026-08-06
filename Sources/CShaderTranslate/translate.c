#include "include/CShaderTranslate.h"

#include <glslang/Include/glslang_c_interface.h>
#include <glslang/Public/resource_limits_c.h>
#include <spirv_cross/spirv_cross_c.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static char *duplicate(const char *text);
static char *fail(char **error_message, const char *stage, const char *detail);

char *
luma_shader_translate_to_msl(const char *glsl, int stage, const char *entry_point, char **error_message)
{
    glslang_initialize_process();

    glslang_stage_t glslang_stage = stage == LUMA_SHADER_STAGE_VERTEX
        ? GLSLANG_STAGE_VERTEX
        : GLSLANG_STAGE_FRAGMENT;
    SpvExecutionModel execution_model = stage == LUMA_SHADER_STAGE_VERTEX
        ? SpvExecutionModelVertex
        : SpvExecutionModelFragment;

    glslang_input_t input = {
        .language = GLSLANG_SOURCE_GLSL,
        .stage = glslang_stage,
        .client = GLSLANG_CLIENT_VULKAN,
        .client_version = GLSLANG_TARGET_VULKAN_1_0,
        .target_language = GLSLANG_TARGET_SPV,
        .target_language_version = GLSLANG_TARGET_SPV_1_0,
        .code = glsl,
        .default_version = 450,
        .default_profile = GLSLANG_NO_PROFILE,
        .force_default_version_and_profile = 0,
        .forward_compatible = 0,
        .messages = GLSLANG_MSG_DEFAULT_BIT,
        .resource = glslang_default_resource(),
    };

    glslang_shader_t *shader = glslang_shader_create(&input);
    if (!glslang_shader_preprocess(shader, &input)) {
        char *message = fail(error_message, "preprocess", glslang_shader_get_info_log(shader));
        glslang_shader_delete(shader);
        return message;
    }
    if (!glslang_shader_parse(shader, &input)) {
        char *message = fail(error_message, "compile", glslang_shader_get_info_log(shader));
        glslang_shader_delete(shader);
        return message;
    }

    glslang_program_t *program = glslang_program_create();
    glslang_program_add_shader(program, shader);
    if (!glslang_program_link(program, GLSLANG_MSG_SPV_RULES_BIT | GLSLANG_MSG_VULKAN_RULES_BIT)) {
        char *message = fail(error_message, "link", glslang_program_get_info_log(program));
        glslang_program_delete(program);
        glslang_shader_delete(shader);
        return message;
    }

    glslang_program_SPIRV_generate(program, glslang_stage);
    size_t word_count = glslang_program_SPIRV_get_size(program);
    unsigned int *words = malloc(word_count * sizeof(unsigned int));
    glslang_program_SPIRV_get(program, words);
    glslang_program_delete(program);
    glslang_shader_delete(shader);

    spvc_context context = NULL;
    spvc_context_create(&context);

    spvc_parsed_ir ir = NULL;
    if (spvc_context_parse_spirv(context, words, word_count, &ir) != SPVC_SUCCESS) {
        char *message = fail(error_message, "parse", spvc_context_get_last_error_string(context));
        spvc_context_destroy(context);
        free(words);
        return message;
    }

    spvc_compiler compiler = NULL;
    spvc_context_create_compiler(context, SPVC_BACKEND_MSL, ir, SPVC_CAPTURE_MODE_TAKE_OWNERSHIP, &compiler);
    spvc_compiler_rename_entry_point(compiler, "main", entry_point, execution_model);

    // spirv-cross numbers MSL buffers in the order it meets the resources,
    // not by the binding written in the shader, so say which is which. The
    // standard block is buffer 0 and the author's params buffer 1, matching
    // what the renderers bind; vertices sit clear at the top of the range.
    for (unsigned binding = 0; binding != 2; binding++) {
        spvc_msl_resource_binding pin;
        spvc_msl_resource_binding_init(&pin);
        pin.stage = execution_model;
        pin.desc_set = 0;
        pin.binding = binding;
        pin.msl_buffer = binding;
        spvc_compiler_msl_add_resource_binding(compiler, &pin);
    }

    spvc_compiler_options options = NULL;
    spvc_compiler_create_compiler_options(compiler, &options);
    spvc_compiler_install_compiler_options(compiler, options);

    const char *msl = NULL;
    if (spvc_compiler_compile(compiler, &msl) != SPVC_SUCCESS) {
        char *message = fail(error_message, "translate", spvc_context_get_last_error_string(context));
        spvc_context_destroy(context);
        free(words);
        return message;
    }

    char *result = duplicate(msl);
    spvc_context_destroy(context);
    free(words);
    return result;
}

static char *
fail(char **error_message, const char *stage, const char *detail)
{
    size_t size = strlen(stage) + strlen(detail) + 4;
    char *message = malloc(size);
    snprintf(message, size, "%s: %s", stage, detail);
    *error_message = message;
    return NULL;
}

static char *
duplicate(const char *text)
{
    size_t size = strlen(text) + 1;
    char *copy = malloc(size);
    memcpy(copy, text, size);
    return copy;
}
