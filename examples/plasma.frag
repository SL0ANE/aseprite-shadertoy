// Paste the contents of a Shadertoy Image tab into a .frag file like this.
void mainImage(out vec4 fragColor, in vec2 fragCoord)
{
    vec2 uv = (fragCoord * 2.0 - iResolution.xy) / iResolution.y;
    float wave = sin(uv.x * 6.0 + iTime) + sin(uv.y * 5.0 - iTime * 1.3);
    wave += sin(length(uv) * 9.0 - iTime * 2.0);
    vec3 col = 0.5 + 0.5 * cos(wave + vec3(0.0, 2.0, 4.0));
    fragColor = vec4(col, 1.0);
}
