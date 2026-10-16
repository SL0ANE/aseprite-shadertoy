using System.Text.Json;

namespace AsepriteShadertoy;

sealed record Request
{
    public int Width { get; init; }
    public int Height { get; init; }
    public double Fps { get; init; }
    public double Seconds { get; init; }
    public double StartTime { get; init; }
    public string Source { get; init; } = "";
    public string Snapshot { get; init; } = "";
    public string TextureDirectory { get; init; } = "";
    public bool Opaque { get; init; } = true;
    public string OutputMode { get; init; } = "rgb";
    public int[][] Palette { get; init; } = [];
    public int TransparentIndex { get; init; }
    public int BytesPerPixel => OutputMode == "indexed" ? 1 : OutputMode == "gray" ? 2 : 4;
    public string FrameFile => OutputMode == "indexed" ? "frames.indexed" : OutputMode == "gray" ? "frames.graya" : "frames.rgba";
    public int Frames => (int)Math.Round(Fps * Seconds, MidpointRounding.AwayFromZero);
    public void Validate()
    {
        if (!string.IsNullOrWhiteSpace(TextureDirectory) && !Directory.Exists(TextureDirectory)) throw new Exception("Texture assets folder does not exist: " + TextureDirectory);
        if (OutputMode is not ("rgb" or "gray" or "indexed")) throw new Exception("Invalid output color mode.");
        if (OutputMode == "indexed")
        {
            if (Palette == null || Palette.Length < 1 || Palette.Length > 256 || Palette.Any(c => c == null || c.Length != 4 || c.Any(v => v < 0 || v > 255)) || TransparentIndex < 0 || TransparentIndex > 255)
                throw new Exception("Indexed output requires a palette of 1-256 RGBA colors and a transparent index from 0 to 255.");
            if (Opaque && !Palette.Where((c, i) => i != TransparentIndex).Any(c => c[3] == 255))
                throw new Exception("Force opaque output requires at least one opaque, non-transparent palette entry.");
        }
        if (Width < 1 || Height < 1 || Width > 8192 || Height > 8192 ||
            !double.IsFinite(Fps) || Fps < 1 || Fps > 1000 ||
            !double.IsFinite(Seconds) || Seconds <= 0 || Seconds > 3600 ||
            !double.IsFinite(StartTime) || StartTime < 0 || StartTime > 86400 ||
            Frames > 10000 || Frames < 1 || (long)Width * Height * 4 * Frames > 512L * 1024 * 1024)
            throw new Exception("Parameters out of range: 1-1000 FPS, 1-10000 frames, up to 8192 x 8192, at most 512 MiB of RGBA data.");
    }
}

static class Program
{
    internal static readonly JsonSerializerOptions Json = new() { PropertyNameCaseInsensitive = true, PropertyNamingPolicy = JsonNamingPolicy.CamelCase };
    internal static void Atomic(string path, object value)
    {
        File.WriteAllText(path + ".tmp", JsonSerializer.Serialize(value, Json));
        // Lua's standard file reads on Windows do not share FILE_SHARE_DELETE.
        // A status reader can briefly hold the previous file across this rename.
        for (int attempt = 0; ; attempt++)
        {
            try { File.Move(path + ".tmp", path, true); break; }
            catch (IOException) when (attempt < 100) { Thread.Sleep(10); }
            catch (UnauthorizedAccessException) when (attempt < 100) { Thread.Sleep(10); }
        }
    }

    [STAThread]
    static int Main(string[] args)
    {
        if (args.Length < 2 || args[0] != "--job") return 2;
        var directory = Path.GetFullPath(args[1]);
        try
        {
            using var lifetime = new Lifetime(directory, args.Contains("--standalone"));
            File.WriteAllText(Path.Combine(directory, "owned"), Environment.ProcessId.ToString());
            var request = JsonSerializer.Deserialize<Request>(File.ReadAllText(Path.Combine(directory, "request.json")), Json)!;
            request.Validate();
            Atomic(Path.Combine(directory, "status.json"), new { phase = "loading", completed = 0 });
            var shader = ShaderSource.Load(request.Source) with { TextureDirectory = request.TextureDirectory };
            using var renderer = new Renderer(request, shader);
            using (var output = new FileStream(Path.Combine(directory, request.FrameFile + ".part"), FileMode.Create, FileAccess.Write))
            {
                for (int frame = 0; frame < request.Frames; frame++)
                {
                    output.Write(renderer.Render(frame));
                    if (frame % 5 == 0 || frame == request.Frames - 1)
                        Atomic(Path.Combine(directory, "status.json"), new { phase = "rendering", completed = frame + 1 });
                }
            }
            File.Move(Path.Combine(directory, request.FrameFile + ".part"), Path.Combine(directory, request.FrameFile), true);
            Atomic(Path.Combine(directory, "result.json"), new { ok = true, frames = request.Frames, width = request.Width, height = request.Height,
                outputMode = request.OutputMode, bytesPerPixel = request.BytesPerPixel, renderer = renderer.Device });
            return 0;
        }
        catch (Exception error)
        {
            try { Atomic(Path.Combine(directory, "result.json"), new { ok = false, error = error.Message }); } catch { }
            return 1;
        }
        finally { try { File.WriteAllText(Path.Combine(directory, "exited"), "1"); } catch { } }
    }
}
