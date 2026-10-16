using System.Runtime.InteropServices;
using Shaderlens.Render.Resources;
using Shaderlens.Threading;
using static OpenGL.Gl;

namespace AsepriteShadertoy;

// Adds texture formats missing from Shaderlens' stock 2D byte reader.
// Shaderlens still owns compilation, pass execution, feedback and readback.
sealed class NativeTextureResource : ITextureResource
{
    readonly IThreadAccess access;
    bool disposed;
    public uint Id { get; }
    public int Width { get; }
    public int Height { get; }
    public int Target { get; }

    public NativeTextureResource(IThreadAccess access, IReadOnlyList<byte[]> packedFaces, bool srgb, Input? sampler = null)
    {
        this.access = access; access.Verify();
        bool cube = packedFaces.Count == 6;
        if (!cube && packedFaces.Count != 1) throw new Exception("A cubemap requires six faces.");
        Width = BitConverter.ToInt32(packedFaces[0], 0); Height = BitConverter.ToInt32(packedFaces[0], 4);
        if (cube && Width != Height) throw new Exception("Cubemap faces must be square.");
        foreach (var face in packedFaces)
            if (BitConverter.ToInt32(face, 0) != Width || BitConverter.ToInt32(face, 4) != Height || face.Length != checked(8 + Width * Height * 4))
                throw new Exception("Cubemap faces must have identical dimensions.");
        Target = cube ? GL_TEXTURE_CUBE_MAP : GL_TEXTURE_2D;
        if (Width > glGetInteger(cube ? GL_MAX_CUBE_MAP_TEXTURE_SIZE : GL_MAX_TEXTURE_SIZE)) throw new Exception("Texture exceeds the GPU size limit.");
        Id = glGenTexture();
        try
        {
            glBindTexture(Target, Id);
            for (int face = 0; face < packedFaces.Count; face++)
            {
                var handle = GCHandle.Alloc(packedFaces[face], GCHandleType.Pinned);
                try { glTexImage2D(cube ? GL_TEXTURE_CUBE_MAP_POSITIVE_X + face : Target, 0, srgb ? GL_SRGB8_ALPHA8 : GL_RGBA8,
                    Width, Height, 0, GL_RGBA, GL_UNSIGNED_BYTE, handle.AddrOfPinnedObject() + 8); }
                finally { handle.Free(); }
            }
            bool nearest = sampler?.Filter == "nearest";
            int wrap = sampler?.Wrap == "repeat" ? GL_REPEAT : GL_CLAMP_TO_EDGE;
            glTexParameteri(Target, GL_TEXTURE_WRAP_S, wrap); glTexParameteri(Target, GL_TEXTURE_WRAP_T, wrap);
            if (cube) glTexParameteri(Target, GL_TEXTURE_WRAP_R, wrap);
            glTexParameteri(Target, GL_TEXTURE_MAG_FILTER, nearest ? GL_NEAREST : GL_LINEAR);
            glTexParameteri(Target, GL_TEXTURE_MIN_FILTER, sampler?.Filter == "mipmap" ? GL_LINEAR_MIPMAP_LINEAR : nearest ? GL_NEAREST : GL_LINEAR);
            glGenerateMipmap(Target);
            if (cube) glEnable(GL_TEXTURE_CUBE_MAP_SEAMLESS);
            if (GetError() != GL_NO_ERROR) throw new Exception("GPU texture upload failed.");
        }
        catch { glDeleteTexture(Id); throw; }
        finally { glBindTexture(Target, 0); }
    }
    public void Dispose() { access.Verify(); if (!disposed) { glDeleteTexture(Id); disposed = true; } }
}
