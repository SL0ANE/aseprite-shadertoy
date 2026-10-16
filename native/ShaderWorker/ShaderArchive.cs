using System.IO.Compression;
using System.Text;
using System.Text.Json;

namespace AsepriteShadertoy;

// Read data in place: no external unzip process, extracted files, or cleanup race.
sealed record ShaderArchive(string Filename, string ShaderEntry)
{
    const long MaxEntryBytes = 64L * 1024 * 1024;
    const long MaxJsonBytes = 8L * 1024 * 1024;

    public static ShaderSource Load(string filename)
    {
        using var zip = ZipFile.OpenRead(filename);
        var entries = Index(zip);
        var shaders = new List<(string Name, string Text)>();
        long jsonBytes = 0;
        foreach (var (name, entry) in entries)
        {
            if (!name.EndsWith(".json", StringComparison.OrdinalIgnoreCase) ||
                name.Split('/').Any(part => part == "__MACOSX" || part.StartsWith("._"))) continue;
            jsonBytes += entry.Length;
            if (jsonBytes > MaxEntryBytes) throw new Exception("ZIP contains too much JSON data (limit: 64 MiB).");
            var text = Encoding.UTF8.GetString(Read(entry, MaxJsonBytes)).TrimStart('\uFEFF');
            try
            {
                using var document = JsonDocument.Parse(text);
                var root = document.RootElement;
                if (root.ValueKind != JsonValueKind.Object) continue;
                if (root.TryGetProperty("Shader", out var wrapped)) root = wrapped;
                if (root.ValueKind == JsonValueKind.Object && root.TryGetProperty("renderpass", out var passes) &&
                    passes.ValueKind == JsonValueKind.Array) shaders.Add((name, text));
            }
            catch (JsonException) { /* Ignore unrelated JSON files, e.g. export metadata. */ }
        }
        if (shaders.Count == 0) throw new Exception("ZIP contains no Shadertoy JSON with a renderpass array.");
        if (shaders.Count > 1)
            throw new Exception("ZIP contains multiple shaders. Extract it and select one JSON file: " +
                string.Join(", ", shaders.Take(8).Select(s => s.Name)));
        return ShaderSource.Parse(shaders[0].Text, "", new ShaderArchive(filename, shaders[0].Name));
    }

    public byte[]? ReadTexture(string source)
    {
        string? asset = TextureAssets.AssetPath(source);
        bool remote = Uri.TryCreate(source, UriKind.Absolute, out var uri) && uri.Scheme is "http" or "https";
        if (remote && asset == null) return null;
        string path = asset ?? source.Replace('\\', '/');
        bool media = asset != null;
        var folder = ShaderEntry.Contains('/') ? ShaderEntry[..(ShaderEntry.LastIndexOf('/') + 1)] : "";
        var candidates = media
            ? new[] { Normalize(path[1..]), Normalize(folder + path[1..]) }
            : new[] { Normalize(folder + path) };
        if (!media && (path.StartsWith('/') || path.Contains(':')))
            throw new Exception("ZIP textures must use paths relative to the shader JSON.");
        using var zip = ZipFile.OpenRead(Filename);
        var entries = Index(zip);
        foreach (var name in candidates)
            if (entries.TryGetValue(name, out var entry)) return Read(entry, MaxEntryBytes);
        if (media) return null; // Shadertoy /media assets may still be online.
        throw new Exception($"Texture not found inside ZIP: {source} (relative to {ShaderEntry}).");
    }

    static Dictionary<string, ZipArchiveEntry> Index(ZipArchive zip)
    {
        if (zip.Entries.Count > 4096) throw new Exception("ZIP contains too many entries (limit: 4096).");
        long total = 0;
        var entries = new Dictionary<string, ZipArchiveEntry>(StringComparer.OrdinalIgnoreCase);
        foreach (var entry in zip.Entries)
        {
            total += entry.Length;
            if (total > 512L * 1024 * 1024) throw new Exception("ZIP expanded size exceeds 512 MiB.");
            var path = entry.FullName.Replace('\\', '/');
            if (path.StartsWith('/') || path.Contains(':') || path.Split('/').Contains(".."))
                throw new Exception($"Invalid path in ZIP: {entry.FullName}");
            if (path.EndsWith('/')) continue;
            string name = Normalize(path);
            if (!entries.TryAdd(name, entry)) throw new Exception($"Duplicate path in ZIP: {name}");
        }
        return entries;
    }

    static string Normalize(string path)
    {
        var parts = new List<string>();
        foreach (var part in path.Split('/'))
        {
            if (part is "" or ".") continue;
            if (part == "..")
            {
                if (parts.Count == 0) throw new Exception("Texture path escapes the ZIP archive.");
                parts.RemoveAt(parts.Count - 1);
            }
            else parts.Add(part);
        }
        return string.Join('/', parts);
    }

    static byte[] Read(ZipArchiveEntry entry, long limit)
    {
        if (entry.Length > limit) throw new Exception($"ZIP entry is too large: {entry.FullName}");
        using var input = entry.Open();
        using var output = new MemoryStream();
        var buffer = new byte[81920];
        int count;
        while ((count = input.Read(buffer)) > 0)
        {
            if (output.Length + count > limit) throw new Exception($"ZIP entry is too large: {entry.FullName}");
            output.Write(buffer, 0, count);
        }
        return output.ToArray();
    }
}
