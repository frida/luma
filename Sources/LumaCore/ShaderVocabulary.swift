/// What every shader may read, whichever stage it is and wherever it is
/// headed. Kept apart from the translator so it can be exercised without a
/// shader toolchain: the preambles are generated text, and generated text is
/// worth testing.
public enum ShaderVocabulary {
    public static let header = "#version 450"

    /// The uniforms every shader may read, whichever stage it is.
    public static let uniformBlock = """
        layout(binding = 0) uniform ShaderEffectUniforms {
            vec2 u_resolution;
            float u_time;
            float u_scheme;
            float u_activity;
            float u_pulse;
            float u_data_count;
            // Physical pixels to a logical one, so a shader that wants to
            // land on whole pixels can. One on an ordinary display.
            float u_scale;
            // Values the caller fed the canvas, up to 64 of them, packed four
            // to a vec4. Read them through dataAt.
            vec4 u_data[16];
            // Where the author's vertices land: orthographic for a flat
            // drawing, perspective for one with depth. Identity until set.
            mat4 u_mvp;
        };
        float dataAt(int i) { return u_data[i >> 2][i & 3]; }
        """
}
