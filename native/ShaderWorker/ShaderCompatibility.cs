using System.Text.RegularExpressions;

namespace AsepriteShadertoy;

static class ShaderCompatibility
{
    // Some exported shaders use "char" as an identifier. Desktop GLSL reserves
    // it. Rename the complete token consistently across Common and every pass;
    // preserve comments, quoted preprocessor text, longer names and line numbers.
    static readonly Regex Tokens = new("//[^\\r\\n]*|/\\*[\\s\\S]*?\\*/|\"(?:\\\\.|[^\"\\\\])*\"|[A-Za-z_][A-Za-z0-9_]*");

    public static ShaderSource Adapt(ShaderSource source)
    {
        var codes = source.Passes.Select(p => p.Code).Prepend(source.Common);
        var identifiers = codes.SelectMany(code => Tokens.Matches(code).Cast<Match>())
            .Select(m => m.Value).ToHashSet(StringComparer.Ordinal);
        if (!identifiers.Contains("char")) return source;
        var replacement = "asepriteCompatChar";
        for (int suffix = 1; identifiers.Contains(replacement); suffix++) replacement = "asepriteCompatChar" + suffix;
        string Rewrite(string code) => Tokens.Replace(code, m => m.Value == "char" ? replacement : m.Value);
        return source with { Common = Rewrite(source.Common), Passes = source.Passes.Select(p => p with { Code = Rewrite(p.Code) }).ToList() };
    }
}
