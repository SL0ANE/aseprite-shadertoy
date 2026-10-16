using System.Net.Http;
using System.Security.Cryptography;
using System.Text;

namespace AsepriteShadertoy;

// Asset resolution only. No cookies, scraping, or alternative asset mirrors.
static class TextureAssets
{
    const int MaxBytes = 64 * 1024 * 1024;
    public static string? AssetPath(string source)
    {
        if (Uri.TryCreate(source, UriKind.Absolute, out var uri) && uri.Scheme is "http" or "https")
        {
            if (uri.Scheme != "https" || uri.Host is not ("www.shadertoy.com" or "shadertoy.com") || uri.Port != 443 || uri.UserInfo != "")
                throw new Exception("Remote textures must use Shadertoy HTTPS asset URLs. Use local files for other textures.");
            source = Uri.UnescapeDataString(uri.AbsolutePath);
        }
        if (!source.StartsWith("/media/", StringComparison.Ordinal) && !source.StartsWith("/presets/", StringComparison.Ordinal)) return null;
        if (source.Contains('\\') || source.Contains(':') || source.Contains('?') || source.Contains('#') || source.Split('/').Any(p => p is "." or ".."))
            throw new Exception("Invalid Shadertoy asset path.");
        return source;
    }

    public static string CubeFace(string source, int face)
    {
        if (face == 0) return source;
        int tail = source.IndexOfAny(['?', '#']);
        string path = tail < 0 ? source : source[..tail], query = tail < 0 ? "" : source[tail..];
        int dot = path.LastIndexOf('.');
        if (dot <= path.LastIndexOfAny(['/', '\\'])) throw new Exception("Cubemap source must name its first image face.");
        string stem = path[..dot];
        // Older /presets/cube00_0.jpg and modern /media/a/hash.jpg exports.
        if (stem.EndsWith("_0", StringComparison.Ordinal)) stem = stem[..^2];
        return stem + "_" + face + path[dot..] + query;
    }

    public static byte[] Read(ShaderSource shader, string source)
    {
        string? asset = AssetPath(source);
        if (shader.Archive != null)
        {
            var packed = shader.Archive.ReadTexture(source);
            if (packed != null) return packed;
        }
        if (asset == null)
        {
            if (Uri.TryCreate(source, UriKind.Absolute, out var uri) && uri.Scheme is "http" or "https")
                throw new Exception("Remote textures must use Shadertoy /media/ or /presets/ URLs.");
            if (shader.BaseDirectory == "") throw new Exception("Invalid texture URL in online shader.");
            return ReadFile(Path.GetFullPath(source, shader.BaseDirectory));
        }

        string relative = asset.TrimStart('/').Replace('/', Path.DirectorySeparatorChar);
        string folder = shader.Archive != null ? Path.GetDirectoryName(shader.Archive.Filename)! : shader.BaseDirectory;
        string? mediaRoot = Environment.GetEnvironmentVariable("SHADERTOY_MEDIA_DIR");
        foreach (string root in new[] { folder, shader.TextureDirectory, mediaRoot ?? "" }.Where(p => !string.IsNullOrWhiteSpace(p)))
        {
            string local = Path.Combine(root, relative);
            if (File.Exists(local)) return ReadFile(local);
        }
        string cache = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "AsepriteShadertoy", "textures");
        string hash = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(asset)));
        string cached = Path.Combine(cache, hash + ".asset");
        if (File.Exists(cached))
        {
            byte[] bytes = ReadFile(cached);
            if (IsImage(bytes)) return bytes;
        }
        try
        {
            using var response = ShaderSource.Http.GetAsync("https://www.shadertoy.com" + asset, HttpCompletionOption.ResponseHeadersRead).GetAwaiter().GetResult();
            if (!response.IsSuccessStatusCode) throw new Exception($"HTTP {(int)response.StatusCode}");
            if (response.Content.Headers.ContentLength > MaxBytes) throw new Exception("Texture exceeds 64 MiB.");
            using var input = response.Content.ReadAsStream();
            using var output = new MemoryStream();
            byte[] buffer = new byte[81920];
            int count;
            while ((count = input.Read(buffer)) > 0)
            {
                if (output.Length + count > MaxBytes) throw new Exception("Texture exceeds 64 MiB.");
                output.Write(buffer, 0, count);
            }
            byte[] bytes = output.ToArray();
            if (!IsImage(bytes)) throw new Exception("Server did not return an image.");
            // Cache only decoded images; cache failure must not block rendering.
            try
            {
                Directory.CreateDirectory(cache);
                string temp = cached + "." + Environment.ProcessId + ".tmp";
                try { File.WriteAllBytes(temp, bytes); File.Move(temp, cached, true); }
                finally { if (File.Exists(temp)) File.Delete(temp); }
            }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
            return bytes;
        }
        catch (Exception error)
        {
            throw new Exception($"Cannot load Shadertoy texture {asset}: {error.Message} Put {relative} beside the shader/ZIP, inside its ZIP, or in the Texture assets folder.", error);
        }
    }

    static byte[] ReadFile(string path)
    {
        if (new FileInfo(path).Length > MaxBytes) throw new Exception("Texture exceeds 64 MiB: " + path);
        return File.ReadAllBytes(path);
    }
    static bool IsImage(byte[] bytes)
    {
        try { using var stream = new MemoryStream(bytes); using var bitmap = new System.Drawing.Bitmap(stream); return bitmap.Width <= 8192 && bitmap.Height <= 8192; }
        catch { return false; }
    }
}
