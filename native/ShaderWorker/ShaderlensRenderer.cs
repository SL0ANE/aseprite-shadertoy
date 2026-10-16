using System.Text;
using System.Text.RegularExpressions;
using Shaderlens;
using Shaderlens.Render;
using Shaderlens.Render.Project;
using Shaderlens.Render.Resources;
using Shaderlens.Render.Uniforms;
using Shaderlens.Serialization;
using Shaderlens.Serialization.Project;
using Shaderlens.Serialization.Text;
using Shaderlens.Storage;
using Shaderlens.Threading;

namespace AsepriteShadertoy;

// Adapter only: shader compilation, uniforms, textures, feedback buffers,
// pass scheduling, drawing and GPU readback belong to Shaderlens (MIT).
// Keep the pinned vendor submodule unmodified; do not add a second renderer.
sealed class Renderer : IDisposable
{
    readonly Request request;
    readonly BackgroundRenderWindow window;
    readonly RenderThread thread;
    readonly float[] pixels;
    readonly byte[] rgba;
    readonly DateTime date = DateTime.Now;
    readonly int imagePassIndex;
    ProjectResources? resources;
    IRenderPipeline pipeline = null!;
    KeyboardTextureResource? keyboard;
    QuadVertexArrayResource? vertices;
    CubemapBindings? cubemaps;
    Exception? threadError;
    public string Device => "Shaderlens (MIT) / " + thread.RenderInformation;

    public Renderer(Request request, ShaderSource source)
    {
        this.request = request;
        pixels = new float[request.Width * request.Height * 4];
        rgba = new byte[request.Width * request.Height * request.BytesPerPixel];
        imagePassIndex = source.Passes.Count - 1 + (request.OutputMode == "rgb" ? 0 : 1);
        var cubeInputs = new Dictionary<string, List<CubemapInput>>(StringComparer.OrdinalIgnoreCase);
        var project = CreateProject(source, request, cubeInputs);
        window = new BackgroundRenderWindow();
        thread = new RenderThread(window.Handle, new FrameIndexSource(), FrameRateCounter.Empty, "Shaderlens export");
        thread.OnException += (_, error) => threadError = error;
        try
        {
            thread.Start();
            if (threadError != null) throw threadError;
            thread.Dispatch(() =>
            {
                resources = new ProjectResources(thread.Access);
                keyboard = new KeyboardTextureResource(thread.Access);
                vertices = new QuadVertexArrayResource(thread.Access);
                var header = Lines("Compatibility header", "#version 430 core\n#define texture2D texture\n#define textureCube texture\n#define textureCubeLod textureLod\n#define iGlobalTime iTime\n");
                var factory = new ProgramSourceFactory(Sha256HashSource.Instance, header, header, header);
                cubemaps = new CubemapBindings(thread.Access, new ShaderCompiler(thread.Access, ShaderStatusParser.Instance), cubeInputs);
                var loader = new PipelineLoader(thread.Access, factory, cubemaps,
                    CSharpTransformer.Instance, new TransportTextureReader(thread.Access), keyboard,
                    new MouseStateSource(thread.Access, MousePositionSource.Empty), new EmptyViewer(), vertices);
                var log = new CompileLog();
                try { pipeline = loader.LoadPipeline(project, cubemaps, resources, new EmptyShaderCache(), new FileSystem(), log); }
                catch (Exception error) { throw new Exception(log.Errors.Length > 0 ? log.Errors.ToString() : error.Message, error); }
                pipeline.SetViewerPass(ViewerPassSelection.None);
                pipeline.SetViewerBufferIndex(imagePassIndex, 0);
                pipeline.SetViewportSize(request.Width, request.Height);
                pipeline.ClearState();
            });
        }
        catch { Dispose(); throw; }
    }

    public byte[] Render(int frame)
    {
        if (threadError != null) throw threadError;
        thread.Dispatch(() =>
        {
            pipeline.RenderFrame(new FrameIndex
            {
                Index = frame,
                Time = (long)Math.Round((request.StartTime + frame / request.Fps) * TimeSpan.TicksPerSecond),
                Delta = (long)Math.Round(TimeSpan.TicksPerSecond / request.Fps),
                DateTime = date.AddSeconds(frame / request.Fps)
            });
            pipeline.GetTexture(imagePassIndex, 0, pixels);
        });
        // Color selection happened on the GPU. CPU only flips rows and packs bytes.
        for (int y = 0; y < request.Height; y++)
            for (int x = 0; x < request.Width; x++)
            {
                int src = ((request.Height - y - 1) * request.Width + x) * 4;
                int dest = (y * request.Width + x) * request.BytesPerPixel;
                rgba[dest] = ToByte(pixels[src]);
                if (request.OutputMode == "indexed") continue;
                byte alpha = request.Opaque ? (byte)255 : ToByte(pixels[src + 3]);
                if (request.OutputMode == "gray") rgba[dest + 1] = alpha;
                else { rgba[dest + 1] = ToByte(pixels[src + 1]); rgba[dest + 2] = ToByte(pixels[src + 2]); rgba[dest + 3] = alpha; }
            }
        return rgba;
    }

    static byte ToByte(float value) => !float.IsFinite(value) ? (byte)0 :
        (byte)Math.Clamp((int)MathF.Round(Math.Clamp(value, 0, 1) * 255), 0, 255);

    static SourceLines Lines(string name, string code) => new(new FileResource<string>(new FileResourceKey(name), code));
    static ProjectProgramSource Code(string name, string code) => new([new FileResource<string>(
        new FileResourceKey(Path.GetFullPath(name + ".glsl"), DateTime.MinValue, true),
        Regex.Replace(code, @"(?m)^\s*#version[^\r\n]*", ""))]);

    static IProjectSource CreateProject(ShaderSource source, Request request, Dictionary<string, List<CubemapInput>> cubeInputs)
    {
        source = ShaderCompatibility.Adapt(source);
        var ids = source.Passes.Where(p => p.Type == "buffer").Select((p, i) => (p.Output, Key: "Buffer" + (char)('A' + i)))
            .ToDictionary(p => p.Output, p => p.Key);
        var buffers = new Dictionary<string, IProjectPass>();
        IProjectPass image = null!;
        foreach (var pass in source.Passes)
        {
            string key = pass.Type == "image" ? (request.OutputMode == "rgb" ? "Image" : "BufferZOutput") : ids[pass.Output];
            var actions = new List<Action<IChannelBindingBuilder>>();
            foreach (var input in pass.Inputs)
            {
                if (pass.Type == "image" && input.Channel == 0 && request.Snapshot != "")
                {
                    if (input.Type == "cubemap") throw new Exception("A canvas snapshot cannot replace a cubemap. Disable Use current canvas as Image.iChannel0.");
                    continue;
                }
                if (input.Type == "audio")
                {
                    // Shadertoy audio data: 512 FFT bins, then 512 unsigned
                    // waveform samples. Silence is FFT=0 and waveform=128.
                    var silent = new byte[512 * 2 * 4];
                    for (int x = 0; x < 1024; x++)
                    {
                        silent[x * 4] = x < 512 ? (byte)0 : (byte)128;
                        silent[x * 4 + 3] = 255;
                    }
                    var packed = TransportTextureReader.Pack(512, 2, silent, false);
                    var resource = new FileResource<byte[]>(new FileResourceKey(Path.GetFullPath($"{key}-{input.Channel}-silent.rgba"), DateTime.MinValue, true), packed);
                    var sampler = new BindingParametersSource(TextureFilterMode.Linear, MipmapFilterMode.None, ClampFilterMode.ClampToEdge, ClampFilterMode.ClampToEdge, false);
                    actions.Add(builder => builder.SetTextureBinding(input.Channel, resource, sampler));
                    continue;
                }
                if (input.Type == "keyboard")
                {
                    // Shadertoy keyboard is generated data, not the exported preview image.
                    // Offline export leaves all keys up; Shaderlens owns its 256x3 texture.
                    actions.Add(builder => builder.SetKeyboardBinding(input.Channel));
                    continue;
                }
                if (input.Filter is not ("linear" or "nearest" or "mipmap") || input.Wrap is not ("clamp" or "repeat"))
                    throw new Exception($"{pass.Name}: Unsupported sampler settings {input.Filter}/{input.Wrap}.");
                if (input.Type == "cubemap")
                {
                    var faces = Enumerable.Range(0, 6).Select(face => TransportTextureReader.DecodeImage(source.TextureBytes(TextureAssets.CubeFace(input.Source, face)), input.VFlip)).ToArray();
                    string path = Path.GetFullPath(key + ".glsl");
                    if (!cubeInputs.TryGetValue(path, out var list)) cubeInputs[path] = list = [];
                    list.Add(new CubemapInput(input, faces));
                    continue;
                }
                var wrap = input.Wrap == "repeat" ? ClampFilterMode.Repeat : ClampFilterMode.ClampToEdge;
                var parameters = new BindingParametersSource(input.Filter == "nearest" ? TextureFilterMode.Nearest : TextureFilterMode.Linear,
                    input.Filter == "mipmap" ? MipmapFilterMode.Linear : MipmapFilterMode.None, wrap, wrap, false);
                if (input.Type == "buffer")
                {
                    // Exporters retain image-upload flags on generated inputs too.
                    // Framebuffer data is already in GL coordinates; do not flip it.
                    actions.Add(builder => builder.SetPassFramebufferBinding(input.Channel, ids[input.Id], 0, parameters));
                }
                else
                {
                    var bytes = TransportTextureReader.DecodeImage(source.TextureBytes(input.Source), input.VFlip, input.Srgb);
                    var resource = new FileResource<byte[]>(new FileResourceKey(Path.GetFullPath($"{key}-{input.Channel}.rgba"), DateTime.MinValue, true), bytes);
                    actions.Add(builder => builder.SetTextureBinding(input.Channel, resource, parameters));
                }
            }
            if (pass.Type == "image" && request.Snapshot != "")
            {
                var packed = TransportTextureReader.Pack(request.Width, request.Height, File.ReadAllBytes(request.Snapshot), true);
                var resource = new FileResource<byte[]>(new FileResourceKey(request.Snapshot, DateTime.MinValue, true), packed);
                var sampler = new BindingParametersSource(TextureFilterMode.Linear, MipmapFilterMode.None, ClampFilterMode.ClampToEdge, ClampFilterMode.ClampToEdge, false);
                actions.Add(builder => builder.SetTextureBinding(0, resource, sampler));
            }
            var program = new ProjectProgram(ProjectProgramType.Fragment, pass.Name, Code(key, pass.Code), new ExplicitChannels(actions), true, null, null);
            var translated = new ProjectPass(key, 1, program, null, null, false);
            if (pass.Type == "image" && request.OutputMode == "rgb") image = translated; else buffers[key] = translated;
        }
        if (request.OutputMode != "rgb")
        {
            var sampler = new BindingParametersSource(TextureFilterMode.Nearest, MipmapFilterMode.None, ClampFilterMode.ClampToEdge, ClampFilterMode.ClampToEdge, false);
            var actions = new List<Action<IChannelBindingBuilder>> { b => b.SetPassFramebufferBinding(0, "BufferZOutput", 0, sampler) };
            if (request.OutputMode == "indexed")
            {
                var packed = TransportTextureReader.Pack(request.Palette.Length, 1, request.Palette.SelectMany(c => c).Select(v => (byte)v).ToArray(), false);
                var lut = new FileResource<byte[]>(new FileResourceKey(Path.GetFullPath("aseprite-palette.rgba"), DateTime.MinValue, true), packed);
                actions.Add(b => b.SetTextureBinding(1, lut, sampler));
            }
            var mapping = new ProjectProgram(ProjectProgramType.Fragment, "Aseprite color mapping", Code("ColorMapping", ColorMapping.Source(request)), new ExplicitChannels(actions), false, null, null);
            image = new ProjectPass("Image", 1, mapping, null, null, false);
        }
        return new ProjectSource(true, "Shadertoy", null, null, null, null, Code("Common", source.Common), [],
            new PassCollection<IProjectPass>(image, buffers), false, new RenderSize(request.Width, request.Height), false);
    }

    // Disable Shaderlens' automatic wiring for unspecified channels.
    sealed class ExplicitChannels(List<Action<IChannelBindingBuilder>> actions) : IChannelBindingSource
    {
        public bool IsEmpty => false;
        public void AddBinding(IChannelBindingBuilder builder) { foreach (var action in actions) action(builder); }
    }
    sealed class EmptyViewer : IViewerSourceLines
    {
        public SourceLines Clear => Lines("Unused viewer", "void mainImage(out vec4 c,in vec2 p){c=vec4(0);}");
        public SourceLines ValuesOverlay => Clear;
    }
    sealed class CompileLog : IProjectLoadLogger
    {
        public readonly StringBuilder Errors = new();
        string state = "";
        public void SetState(string header, string? content = null) => state = header + " " + content;
        public void AddFailure(string message, IFileResource<string>? source = null, int? lineIndex = null) =>
            Errors.AppendLine($"{state}: {source?.Key.ToString()}:{lineIndex + 1} {message}");
        public void LoadStarted() { }
        public void LoadCompleted(bool succeeded) { }
        public void Dispose() { }
    }

    public void Dispose()
    {
        if (threadError == null)
            thread.Dispatch(() => { cubemaps?.Dispose(); resources?.Dispose(); keyboard?.Dispose(); vertices?.Dispose(); });
        thread.Stop(); thread.Dispose(); window.Dispose();
    }
}
