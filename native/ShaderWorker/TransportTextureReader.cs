using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using Shaderlens.Render;
using Shaderlens.Render.Resources;
using Shaderlens.Threading;

namespace AsepriteShadertoy;

// Image codec / transport adapter. Stock 2D upload uses Shaderlens;
// the sRGB texture format is supplied by NativeTextureResource.
sealed class TransportTextureReader(IThreadAccess access) : ITextureReaderFactory, ITextureReader
{
    public ITextureReader Create(string extension) => this;
    public ITextureResource Read(Stream source)
    {
        using var reader = new BinaryReader(source);
        int width = reader.ReadInt32(), height = reader.ReadInt32();
        bool srgb = width < 0;
        width = Math.Abs(width);
        var rgba = reader.ReadBytes(checked(width * height * 4));
        if (rgba.Length != width * height * 4) throw new Exception("Texture data is incomplete.");
        return srgb ? new NativeTextureResource(access, [Pack(width, height, rgba, false)], true) :
            new BufferTextureResource(access, width, height, rgba, 0x1401); // GL_UNSIGNED_BYTE
    }

    internal static byte[] Pack(int width, int height, byte[] rgba, bool flip)
    {
        if (rgba.Length != checked(width * height * 4)) throw new Exception("Texture dimensions do not match.");
        using var stream = new MemoryStream();
        using var writer = new BinaryWriter(stream);
        writer.Write(width); writer.Write(height);
        for (int row = 0; row < height; row++) writer.Write(rgba, (flip ? height - row - 1 : row) * width * 4, width * 4);
        return stream.ToArray();
    }

    internal static byte[] DecodeImage(byte[] encoded, bool flip, bool srgb = false)
    {
        using var stream = new MemoryStream(encoded);
        using var image = new Bitmap(stream);
        if (image.Width > 8192 || image.Height > 8192) throw new Exception("Texture size cannot exceed 8192 x 8192.");
        using var bitmap = new Bitmap(image.Width, image.Height, PixelFormat.Format32bppArgb);
        using (var g = Graphics.FromImage(bitmap))
        { g.CompositingMode = System.Drawing.Drawing2D.CompositingMode.SourceCopy; g.DrawImageUnscaled(image, 0, 0); }
        var data = bitmap.LockBits(new Rectangle(0, 0, bitmap.Width, bitmap.Height), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
        var rgba = new byte[bitmap.Width * bitmap.Height * 4];
        try { for (int row = 0; row < bitmap.Height; row++) Marshal.Copy(data.Scan0 + row * data.Stride, rgba, row * bitmap.Width * 4, bitmap.Width * 4); }
        finally { bitmap.UnlockBits(data); }
        for (int i = 0; i < rgba.Length; i += 4) (rgba[i], rgba[i + 2]) = (rgba[i + 2], rgba[i]);
        var packed = Pack(bitmap.Width, bitmap.Height, rgba, flip);
        if (srgb) BitConverter.GetBytes(-bitmap.Width).CopyTo(packed, 0);
        return packed;
    }
}
