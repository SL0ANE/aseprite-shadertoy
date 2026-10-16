using Shaderlens;
using Shaderlens.Render;
using Shaderlens.Render.Project;
using Shaderlens.Render.Resources;
using Shaderlens.Render.Uniforms;
using Shaderlens.Serialization.Text;
using Shaderlens.Storage;
using Shaderlens.Threading;
using static OpenGL.Gl;

namespace AsepriteShadertoy;

sealed record CubemapInput(Input Sampler, byte[][] Faces);

// Decorate upstream interfaces, without modifying the pinned Shaderlens source.
// Only sampler declarations and native texture bindings differ from stock 2D.
sealed class CubemapBindings(IThreadAccess access, IShaderCompiler compiler, Dictionary<string, List<CubemapInput>> passes)
    : IShaderCompiler, IUniform, IDisposable
{
    readonly Dictionary<uint, List<CubemapInput>> programs = [];
    readonly List<NativeTextureResource> textures = [];

    public IRenderResource Compile(string displayName, IProgramSource source, IProjectResources resources, IShaderCache shaderCache, IProjectLoadLogger logger)
    {
        var inputs = source.Fragment?.SourceLines.Select(l => l.Source.Key.AbsolutePath).Distinct()
            .Where(p => p != null && passes.ContainsKey(p)).SelectMany(p => passes[p]).ToList() ?? [];
        if (inputs.Count > 0)
        {
            var lines = new SourceLines(source.Fragment!.SourceLines.Select(line =>
            {
                string text = line.Line;
                foreach (var cube in inputs)
                    if (text == $"uniform sampler2D iChannel{cube.Sampler.Channel};") text = $"uniform samplerCube iChannel{cube.Sampler.Channel};";
                return new SourceLine(line.Source, text, line.Index);
            }));
            source = new CubeProgram(source, new CubeStage(lines));
        }
        var program = compiler.Compile(displayName, source, resources, shaderCache, logger);
        programs[program.Id] = inputs;
        return program;
    }

    public IUniformBinding CreateBinding(uint programId)
    {
        access.Verify();
        var bindings = new List<IUniformBinding>();
        foreach (var input in programs.GetValueOrDefault(programId) ?? [])
        {
            var texture = new NativeTextureResource(access, input.Faces, input.Sampler.Srgb, input.Sampler);
            textures.Add(texture);
            int channel = input.Sampler.Channel;
            // Stock bindings occupy at most units 0-4 (viewer plus 4 channels).
            int unit = 8 + channel;
            bindings.Add(new CubeBinding(access, texture, unit,
                glGetUniformLocation(programId, $"iChannel{channel}"), glGetUniformLocation(programId, $"iChannelResolution[{channel}]")));
        }
        return new UniformBindingCollection(bindings.ToArray());
    }
    public void AddViewElement(IUniformsViewBuilder builder) { }
    public void Dispose() { foreach (var texture in textures) texture.Dispose(); textures.Clear(); }

    sealed class CubeBinding(IThreadAccess access, NativeTextureResource texture, int unit, int samplerLocation, int resolutionLocation) : IUniformBinding
    {
        public void BindValue(IRenderContext context, IFramebufferResource framebuffer)
        {
            access.Verify();
            glActiveTexture(GL_TEXTURE0 + unit); glBindTexture(GL_TEXTURE_CUBE_MAP, texture.Id);
            glUniform1i(samplerLocation, unit);
            // Runs after stock channel uniforms, including when only resolution is used.
            glUniform3f(resolutionLocation, texture.Width, texture.Height, 1);
        }
    }
    sealed class CubeStage(SourceLines lines) : IProgramStageSource
    {
        public SourceLines SourceLines { get; } = lines;
        public string Source { get; } = lines.JoinLines();
        public string ResourceKey { get; } = Sha256HashSource.Instance.GetHash(lines.JoinLines());
    }
    sealed class CubeProgram(IProgramSource original, IProgramStageSource fragment) : IProgramSource
    {
        public string ResourceKey { get; } = Sha256HashSource.Instance.GetHash(original.ResourceKey + fragment.ResourceKey);
        public IProgramStageSource? Vertex => original.Vertex;
        public IProgramStageSource? Fragment => fragment;
        public IProgramStageSource? Compute => original.Compute;
    }
}
