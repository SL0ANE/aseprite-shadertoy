// Enable "current canvas -> Image.iChannel0" in the dialog.
void mainImage(out vec4 fragColor, in vec2 fragCoord)
{
    vec2 uv = fragCoord / iResolution.xy;
    uv.x += sin(uv.y * 20.0 + iTime * 3.0) * 0.025;
    fragColor = texture(iChannel0, uv);
}
