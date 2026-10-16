using System.Net.Http;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace AsepriteShadertoy;

sealed record Input(int Channel, string Type, string Id, string Source, string Filter, string Wrap, bool VFlip, bool Srgb);
sealed record Pass(string Name, string Type, string Code, string Output, List<Input> Inputs);
sealed record ShaderSource(string Common, List<Pass> Passes, string BaseDirectory, ShaderArchive? Archive = null)
{
    public string TextureDirectory { get; init; } = "";
    internal static readonly HttpClient Http = new(new HttpClientHandler { AllowAutoRedirect = false }) { Timeout = TimeSpan.FromSeconds(45) };
    static string Value(JsonNode? node, string fallback = "") => node?.ToString() ?? fallback;

    public static ShaderSource Load(string source)
    {
        string text, baseDirectory;
        if (Uri.TryCreate(source, UriKind.Absolute, out var uri) && uri.Scheme is "http" or "https")
        {
            if (uri.Scheme != "https" || uri.Host != "www.shadertoy.com" && uri.Host != "shadertoy.com")
                throw new Exception("Only https://www.shadertoy.com/view/ID URLs are supported.");
            var id = Regex.Match(uri.AbsolutePath, @"^/view/([A-Za-z0-9]{6})/?$");
            if (!id.Success) throw new Exception("Invalid Shadertoy URL.");
            var key = Environment.GetEnvironmentVariable("SHADERTOY_API_KEY");
            if (string.IsNullOrWhiteSpace(key)) throw new Exception("URL mode requires the SHADERTOY_API_KEY environment variable. Alternatively, select a local .frag or Shadertoy JSON file.");
            using var response = Http.GetAsync($"https://www.shadertoy.com/api/v1/shaders/{id.Groups[1].Value}?key={Uri.EscapeDataString(key)}").GetAwaiter().GetResult();
            if (!response.IsSuccessStatusCode) throw new Exception($"Shadertoy API returned {(int)response.StatusCode}. Check your API key and whether the shader is available through the API.");
            text = response.Content.ReadAsStringAsync().GetAwaiter().GetResult();
            baseDirectory = "";
        }
        else
        {
            source = Path.GetFullPath(source);
            if (source.EndsWith(".zip", StringComparison.OrdinalIgnoreCase)) return ShaderArchive.Load(source);
            if (Path.GetExtension(source).ToLowerInvariant() is ".rar" or ".7z")
                throw new Exception("Only ZIP archives are supported. Extract this archive and select its shader JSON file.");
            text = File.ReadAllText(source);
            baseDirectory = Path.GetDirectoryName(source)!;
            if (!source.EndsWith(".json", StringComparison.OrdinalIgnoreCase))
                return new("", [new("Image", "image", text, "", [])], baseDirectory);
        }
        return Parse(text, baseDirectory);
    }

    internal static ShaderSource Parse(string text, string baseDirectory, ShaderArchive? archive = null)
    {
        var root = JsonNode.Parse(text) ?? throw new Exception("Empty shader JSON.");
        if (root["Error"] != null) throw new Exception("Shadertoy API: " + root["Error"]);
        var shader = root["Shader"] ?? root;
        var array = shader["renderpass"]?.AsArray() ?? throw new Exception("JSON is missing Shader.renderpass / renderpass.");
        string common = "";
        var passes = new List<Pass>();
        foreach (var node in array)
        {
            var type = Value(node!["type"]);
            // Cel export has no audio track. Ignore the entire sound pass,
            // including its code and inputs, before validation or loading.
            if (type == "sound") continue;
            var code = Value(node["code"]);
            if (type == "common") { common += code + "\n"; continue; }
            if (type is not ("image" or "buffer")) throw new Exception($"Unsupported pass type: {type}. Supported: Image, Common, Buffer A-D.");
            var inputs = new List<Input>();
            foreach (var input in node["inputs"]?.AsArray() ?? [])
            {
                var kind = Value(input!["ctype"], Value(input["type"]));
                if (kind is "music" or "musicstream" or "mic") kind = "audio";
                if (kind is not ("texture" or "cubemap" or "buffer" or "keyboard" or "audio")) throw new Exception($"Unsupported input type: {kind}. Supported: 2D textures, cubemaps, buffers, idle keyboard, and silent audio.");
                var sampler = input["sampler"];
                inputs.Add(new((int?)input["channel"] ?? 0, kind, Value(input["id"]), Value(input["src"], Value(input["filepath"])),
                    Value(sampler?["filter"], "linear") is "nearest" or "point" ? "nearest" : Value(sampler?["filter"], "linear"), Value(sampler?["wrap"], "clamp"), Value(sampler?["vflip"]).Equals("true", StringComparison.OrdinalIgnoreCase), Value(sampler?["srgb"]).Equals("true", StringComparison.OrdinalIgnoreCase)));
            }
            if (inputs.Any(i => i.Channel < 0 || i.Channel > 3) || inputs.Select(i => i.Channel).Distinct().Count() != inputs.Count)
                throw new Exception("Input channels must be unique numbers from 0 to 3.");
            string output = node["outputs"] is JsonArray outputs && outputs.Count > 0 ? Value(outputs[0]?["id"]) : "";
            passes.Add(new(Value(node["name"], type), type, code, output, inputs));
        }
        if (passes.Count(p => p.Type == "image") != 1 || passes.Count(p => p.Type == "buffer") > 4)
            throw new Exception("Exactly one Image pass and at most four Buffer passes are required.");
        // Shadertoy buffers execute A–D before Image, regardless of JSON ordering.
        passes = passes.OrderBy(p => p.Type == "image" ? 1 : 0).ThenBy(p => p.Name, StringComparer.Ordinal).ToList();
        var ids = passes.Where(p => p.Type == "buffer").Select(p => p.Output).ToList();
        if (ids.Any(string.IsNullOrEmpty) || ids.Distinct().Count() != ids.Count ||
            passes.SelectMany(p => p.Inputs).Any(i => i.Type == "buffer" && !ids.Contains(i.Id)))
            throw new Exception("Buffer output IDs are missing, duplicated, or referenced by inputs that have no matching buffer.");
        return new(common, passes, baseDirectory, archive);
    }

    public byte[] TextureBytes(string path) => TextureAssets.Read(this, path);
}
