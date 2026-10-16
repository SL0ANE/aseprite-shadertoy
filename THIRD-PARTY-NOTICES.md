# Third-party notices

## Shaderlens

- Upstream: https://github.com/ytt0/shaderlens
- Pinned commit: `2f81e661422fc634a13efc994b50399161f49f9c`
- License: MIT, copyright (c) 2024 Shaderlens.
- Full text: `licenses/Shaderlens-MIT.txt`.
- Used assemblies: Shaderlens.Render, Shaderlens.Serialization, Shaderlens.Common.
- Upstream source is an unmodified Git submodule; the adapter is separate. No Shaderlens example shaders or UI assets are redistributed.
- Its OpenGL binding identifies https://github.com/ForeverZer0/glfw-net as its source. The corresponding MIT notice is included in `licenses/GLFW.NET-MIT.txt` (copyright 2018 Eric Freed).

## Microsoft .NET

The self-contained worker includes the .NET 8 Windows runtime and Windows Desktop components. MIT license and bundled third-party notices are included in `licenses/NET-LICENSE.txt`, `licenses/NET-THIRD-PARTY-NOTICES.txt`, and `licenses/WindowsDesktop-LICENSE.txt`. System.Text.Json is used by Shaderlens and is covered by the .NET MIT license; its package notices are also included.

## Input shaders and textures

These retain their original authors' licenses. A render library's MIT license does not grant rights to separately supplied shader code or media. Only project-authored examples are included in this extension.
