# Aseprite Shadertoy Renderer

在 Aseprite 输入 FPS 和时长，以当前画布大小渲染 Shadertoy 着色器，输出到新图层的连续 cel。

**渲染使用 [Shaderlens](https://github.com/ytt0/shaderlens)（MIT）**。本项目只维护 Aseprite 界面、后台进程生命周期、输入适配、帧数据通信与导入，不维护另一套着色器编译器或多 pass 渲染器。

## 使用

1. 安装 `dist/aseprite-shadertoy.aseprite-extension`，或把完整插件目录放入 Aseprite 的 extensions 目录，然后重启 Aseprite。当前工作目录已经是插件目录，且已包含构建好的后台程序。
2. 打开 **RGB、Grayscale 或 Indexed** 画布，在 **Edit → FX → Shadertoy…** 打开插件。插件界面、状态提示和自定义错误信息使用英文。
3. 选择 **Local file**，打开 `.frag` / `.glsl` / `.txt`（Shadertoy **Image** 页完整源码）、包含全部 renderpass 的 `.json`，或装有该 JSON 的 `.zip`。
4. 设置 FPS、Duration、Start time、Insert at 和 Layer name，点击 **Render to New Layer**。
5. 渲染在隐藏进程中运行，可取消或关闭窗口。成功后在原画布新建图层，一次撤销可以撤回全部导入。

后台程序是每任务一个进程，完成后退出。取消、关闭插件窗口或卸载插件会撤销任务许可；独立监视线程每 100 ms 检查许可和 Aseprite 宿主句柄，宿主正常退出或被强制结束也会终止渲染进程。即使 Lua 不再响应，心跳超过 60 秒未更新也会退出。这里使用文件通信，没有需要常驻的网络连接。轮询在访问宿主 API 前暂停，防止权限窗口或错误弹窗引起回调重入。

从 `examples/plasma.frag` 开始即可测试。`examples/feedback.json` 展示 Common、Buffer A 反馈与 Image；`examples/canvas-wave.frag` 配合 **Use current canvas as Image.iChannel0** 使当前帧合成图像产生波浪变形。

首次运行时，Aseprite 可能要求允许脚本文件访问及执行外部程序，需要在宿主提示中授权。

## 参数和时间轴

- 尺寸来自点击渲染时的画布。任务绑定原文档；切换标签不会导入到错误文档。
- 帧数为 `floor(FPS × 时长 + 0.5)`；采样时刻为 `起始时间 + 帧索引 / FPS`，索引从 0 开始，不重复末端帧。
- 支持从当前帧开始或追加到时间轴末尾；需要时补充空帧，不覆盖原图层 cel。
- **Aseprite 的帧时长是全局属性**，因此输出区间里其他图层也会采用新的帧时长。选择追加模式可保留原有帧的时长。
- Aseprite 保存整数毫秒；60 FPS 等不能整除 1000 的帧率使用交替帧时长，使累计播放时间接近 `帧数/FPS`。
- **Use current canvas as Image.iChannel0** 使用渲染开始时当前帧的合成快照，并覆盖 Image 原有的通道 0 绑定。它是静态输入，不是源时间轴动画。
- 默认输出不透明；取消勾选后保留 shader 的 alpha（Indexed 按下述色板规则处理）。
- 起始时间只偏移时间 uniform，反馈 Buffer 仍从空状态、`iFrame=0` 开始，不会自动预热模拟。
- 渲染期间可以编辑其他内容；若原画布关闭、改尺寸、改颜色模式或改变时间轴帧数，结果不会自动导入。

## 颜色模式

输出保持当前文档的颜色模式，不转换原画布，也不修改原有色板。

- **RGB**：输出 RGBA cel。
- **Grayscale**：GPU 最终 pass 按 `0.2126R + 0.7152G + 0.0722B` 转为灰度，独立保留 alpha，输出灰度 cel。
- **Indexed**：把当前帧的 Aseprite 色板上传为一张 RGBA 查找纹理。GPU 最终 pass 按预乘 RGBA 距离搜索最近色，输出原色板索引；相同距离优先较小索引，无抖动。CPU 仅翻转行并打包索引字节，不逐像素搜索色板。Common 和反馈 Buffer 仍保持原始精度，量化只发生在最终画面。

Indexed 关闭 **Force opaque output** 时，alpha 小于 0.5 的像素使用文档的透明索引；其余像素匹配非透明色板项，并考虑色板项自身的 alpha。透明索引始终保留，即使该位置的色板颜色本身不透明。开启强制不透明时，仅匹配 alpha=255 且不是透明索引的色板项；没有这样的颜色会提示错误。

画布快照支持三种颜色模式，先由 Aseprite 合成 RGBA，再作为 shader 输入。Indexed 渲染期间若色板或透明索引被修改，导入会停止，避免错误颜色。含有不同逐帧色板的旧动画应按色板区间分别渲染，单次输出区间必须使用当前色板。

## 支持范围

Windows x64、Aseprite 1.3 系列（在 1.3.18.6 验证）、支持 OpenGL 4.5 的显卡驱动。后台是自包含 .NET 8 程序，用户不需安装 .NET、Node、Python 或浏览器。

支持 Image、Common、最多四个 Buffer，多 pass/反馈由 Shaderlens 处理；支持 2D 图片、Cubemap 输入、本地相对纹理路径、Shadertoy `/media/` 和旧 `/presets/` 纹理、nearest/linear/mipmap、clamp/repeat、vflip 与 sRGB。输入可使用 API 的 `ctype/src` 或导出格式的 `type/filepath` 字段。

支持网页导出的根级 `renderpass` JSON，包括不连续的 Buffer A / D 引用。`keyboard` 通道绑定 Shaderlens 的 256×3 键盘纹理，离线导出始终保持所有按键未按下；生成的 Buffer 和 keyboard 不会下载 `filepath` 中的预览图片，也不会因导出器保留的 `vflip` 标记而翻转数据。2D 图片的 `vflip` 仍正常生效。本地 JSON 不需要 API key；如作品使用远程图片纹理，仍需联网取得对应资源。

ZIP 可直接选择，无需手动解压。插件在包内查找包含 `renderpass` 的 JSON，支持嵌套文件夹和相对于 JSON 的纹理路径；无关的元数据 JSON 不作为着色器。ZIP 中只有一个着色器时自动加载；多个着色器时会列出候选名称，提示先解压再选择具体 JSON。包内数据直接读取，不产生解压目录，也不额外启动解压程序。RAR / 7z 请先手动解压。ZIP 上限：4096 个条目、总展开大小 512 MiB、单个 JSON 8 MiB、单个读取资源 64 MiB。

导出自动忽略 Sound pass，不编译其源码，也不读取其输入。画面引用的 `music` / `musicstream` / `mic` 音频通道提供静音纹理（512×2，频谱为 0，波形居中），不会下载、播放或采集音频。依赖音乐节奏的画面会呈现静音状态。

暂不支持视频、摄像头、实时键盘交互、Cubemap 输出 pass、3D/volume 纹理或 VR；鼠标输入固定为未按下。网站的 GLSL ES 与 Shaderlens 的桌面 GLSL 仍有差异，不能保证所有网站作品直接兼容；uniform 的具体语义遵循固定版本的 Shaderlens（例如其 `iDate` 月份为 1–12）。

兼容层会把导出源码中作为标识符使用的 `char` 自动改为不冲突的内部名称，避免桌面 GLSL 保留字错误。Common 和所有视觉 pass 一致处理，保留原始行号、注释及 `charX` 等其他名称；不修改磁盘上的源码或 ZIP。

限制：1–1000 FPS、1–10000 帧、单边最大 8192、原始 RGBA 帧数据合计不超过 512 MiB。大画布的 Buffer 显存和 Aseprite 导入内存会高于原始帧大小。GPU 渲染不阻塞界面；最终导入是一个主线程事务，大任务导入时可能短暂忙碌。

## 内置纹理与 Cubemap

Cubemap 输入上传为真正的 GPU `samplerCube`，支持 `texture`、`textureLod`、`textureGrad` 和旧 `textureCube` 调用。Image 和 Buffer 均可使用，Common 中的 samplerCube 参数正常保留；`iChannelResolution` 为每面的实际尺寸。六面按 +X、−X、+Y、−Y、+Z、−Z 加载，尺寸必须相同且为正方形。

JSON 的路径指向第一面。现代资源 `name.jpg` 对应 `name_1.jpg` 至 `name_5.jpg`；旧资源 `cube00_0.jpg` 对应 `cube00_1.jpg` 至 `cube00_5.jpg`。每面分别应用 vflip；sRGB 在 GPU 采样时转为线性 RGB，alpha 不做颜色空间转换。支持真正的立方体 mipmap 和面边界过滤。画布快照是 2D 图像，不能覆盖 Image 的 Cubemap 通道 0；此时请取消快照选项。

内置资源按以下顺序查找：ZIP 内 → JSON/ZIP 旁边 → 对话框 **Texture assets** 指定的目录 → `SHADERTOY_MEDIA_DIR` → 已下载缓存 → Shadertoy 官方 HTTPS 地址。目录内保留 `media/a/文件名` 或 `presets/文件名` 的结构。Texture assets 可留空，填写后随设置保存。下载成功的图片缓存在 `%LOCALAPPDATA%/AsepriteShadertoy/textures`，之后可离线使用；单个资源上限 64 MiB。

**当前环境访问 Shadertoy 官方纹理地址返回 HTTP 403，因此未验证成功的在线下载。** 解析和 GPU 采样能力已用自制素材测试，但未取得网站原生素材时，相关作品仍不能完整渲染。插件不会把 403 页面当作图片，也不会绕过访问限制；错误会指出缺失路径。未打包第三方内置素材或自动使用许可不明确的镜像，素材许可与插件 MIT 许可分开。

## 网站链接与授权

链接模式通过 `https://www.shadertoy.com/api/v1/shaders/ID?key=...` 获取 JSON，再在本地渲染。配置用户环境变量 `SHADERTOY_API_KEY` 后重启 Aseprite；不把 key 保存到插件设置。作品必须允许官方 API 访问。没有 key 时选择本地源码/JSON 即可。

未使用网页内部抓取接口、登录 cookie 或绕过网站访问控制。官方 API/条款页面在本次检查中返回 403，链接模式未做带 key 的在线端到端验证。API 获取能力不等同于作者授权；第三方 shader 和纹理须分别遵守作者许可，MIT 渲染库不会改变输入作品的许可。附带示例为本项目源码，不打包网站用户作品。

## 构建与测试

开发环境需要 Git、.NET 8 或更新 SDK，以及 Windows 桌面构建支持。

```powershell
git submodule update --init --recursive
./native/build.ps1
./tests/run.ps1 -Aseprite 'D:/Steam/steamapps/common/Aseprite/Aseprite.exe'
./build.ps1
```

`build.ps1` 先构建，然后生成可安装扩展。安装包只含 Lua、示例、后台 exe、说明和许可，不含测试产物、源码依赖目录或开发工具。

测试覆盖实际 GPU 像素方向、时间、透明度、画布快照、Common、多 Buffer 顺序与反馈、错误诊断、输入限制和取消；颜色模式测试覆盖 GPU 灰度转换、色板 LUT、非零透明索引、alpha 阈值、索引 255 和不透明色筛选。真实 Aseprite 测试覆盖后台启动、60 个 cel、累计时长、原图层保留、跨文档导入目标、三种颜色模式的 cel 和快照、色板变更保护及一次撤销/重做。测试产物保存在 `tests/output/`。

`tests/textures.tests.ps1` 使用项目自制图片验证 Cubemap 六方向和面内朝向、vflip、mipmap、双线性过滤、Common/Buffer、索引色输出、iChannelResolution、sRGB、textureGrad、旧 presets 路径、ZIP/独立素材目录、离线缓存及缺失/尺寸错误的面。自动测试不下载第三方美术资源。

`tests/ui.tests.lua` 模拟权限/模态窗口导致的嵌套回调，覆盖启动、错误、取消、关闭、卸载和过期回调；`tests/lifetime.tests.ps1` 使用独立的真实 Aseprite 测试进程，验证取消、关闭窗口回调、卸载、宿主正常退出、强杀宿主、心跳过期及启动期间宿主退出后无渲染进程残留，不结束用户正在使用的 Aseprite。

## 维护边界

- `main.lua`：对话框与命令入口。
- `render_job.lua`：非阻塞启动、Timer 轮询、取消、色板快照及 RGB/灰度/索引色导入事务。
- `native/ShaderWorker/Program.cs` / `Lifetime.cs`：任务协议、进度、宿主进程和许可文件看护。
- `ShaderSource.cs`：读取本地文件/官方 API，验证可接受的输入。
- `ShaderCompatibility.cs`：在内存中适配已知的源码兼容问题（`char` 标识符）。
- `ShaderArchive.cs`：直接读取 ZIP 中的 JSON 和相对路径纹理。
- `TextureAssets.cs`：内置资源路径、六面文件名、本地目录、缓存及官方下载。
- `CubemapBindings.cs` / `NativeTextureResource.cs`：通过 Shaderlens 的编译器/Uniform 扩展接口补充 samplerCube 声明、Cubemap 绑定和 sRGB 纹理格式；编译、绘制、反馈和读回仍由 Shaderlens 执行。
- `ShaderlensRenderer.cs` / `TransportTextureReader.cs`：把输入转换为上游项目对象，调用 `PipelineLoader.LoadPipeline`、`IRenderPipeline.RenderFrame` 和 `GetTexture`，转换传输像素格式。
- `ColorMapping.cs`：交给 Shaderlens 执行的最终灰度/色板映射 shader。
- `native/vendor/shaderlens`：**未修改的 Git 子模块**，固定 `2f81e661422fc634a13efc994b50399161f49f9c`。升级时只更新子模块版本并运行兼容性测试。

进程启动方案借鉴 ultra-bathtub：PowerShell EncodedCommand 避免路径引用问题，`io.popen` 异步启动隐藏 exe，宿主句柄和独立看护线程负责关闭/取消。此插件采用独立临时目录、原子 JSON 状态和像素文件交换（RGBA、灰度+alpha 或索引），不需要端口或 WebSocket。全部帧成功后才提交导入，失败不会创建半成品图层。

## 许可

插件代码与 Shaderlens 均为 MIT。Shaderlens 使用的 GLFW.NET OpenGL 绑定声明、.NET 运行时和第三方声明见 `licenses/` 与 `THIRD-PARTY-NOTICES.md`。
