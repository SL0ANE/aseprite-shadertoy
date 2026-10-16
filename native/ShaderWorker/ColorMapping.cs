namespace AsepriteShadertoy;

// A final Shaderlens pass maps the rendered Image without quantizing feedback buffers.
static class ColorMapping
{
    public static string Source(Request request)
    {
        var prefix = "void mainImage(out vec4 result, in vec2 p) {\n" +
            "vec4 c=texelFetch(iChannel0,ivec2(p),0);\n" +
            "c=vec4(isnan(c.x)||isinf(c.x)?0.:c.x,isnan(c.y)||isinf(c.y)?0.:c.y,isnan(c.z)||isinf(c.z)?0.:c.z,isnan(c.w)||isinf(c.w)?0.:c.w);\n" +
            "c=clamp(c,0.,1.);\n" + (request.Opaque ? "c.a=1.;\n" : "");
        if (request.OutputMode == "gray")
            return prefix + "result=vec4(dot(c.rgb,vec3(0.2126,0.7152,0.0722)),0.,0.,c.a);}\n";
        return prefix + $$"""
            const int transparentIndex={{request.TransparentIndex}};
            if (c.a < 0.5) { result=vec4(float(transparentIndex)/255.,0.,0.,1.); return; }
            float bestDistance=1e30;
            int best=transparentIndex;
            for(int i=0;i<{{request.Palette.Length}};i++) {
                if(i==transparentIndex) continue;
                vec4 color=texelFetch(iChannel1,ivec2(i,0),0);
                if(color.a {{(request.Opaque ? "< 1." : "<= 0.")}}) continue;
                vec4 delta=vec4(c.rgb*c.a-color.rgb*color.a,c.a-color.a);
                float distance=dot(delta,delta);
                if(distance<bestDistance) { bestDistance=distance; best=i; }
            }
            result=vec4(float(best)/255.,0.,0.,1.);
            }
            """;
    }
}
