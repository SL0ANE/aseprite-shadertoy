param([string]$Worker = (Join-Path $PSScriptRoot '../bin/win-x64/Aseprite.Shadertoy.exe'))
$ErrorActionPreference = 'Stop'
$output = Join-Path $PSScriptRoot 'output'
New-Item -ItemType Directory -Force -Path $output | Out-Null
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$utf8 = [Text.UTF8Encoding]::new($false)
function Write-Text($Path, $Text) { [IO.File]::WriteAllText($Path, $Text, $utf8) }
function Assert($Condition, $Message) { if (-not $Condition) { throw $Message } }
function Render($Name, $Source, $Extra = @{}, $ExpectError = $false) {
    $dir = Join-Path $output ($Name + '-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $dir | Out-Null
    $request = @{ width=8; height=4; fps=10; seconds=0.3; startTime=0; source=$Source; opaque=$false }
    foreach ($key in $Extra.Keys) { $request[$key] = $Extra[$key] }
    Write-Text (Join-Path $dir 'request.json') ($request | ConvertTo-Json -Depth 12)
    Write-Text (Join-Path $dir 'permit') '1'
    $p = Start-Process -FilePath $Worker -ArgumentList @('--job', ('"' + $dir + '"'), '--standalone') -WindowStyle Hidden -PassThru
    if (-not $p.WaitForExit(45000)) { $p.Kill(); throw "$Name timed out" }
    $result = Get-Content -LiteralPath (Join-Path $dir 'result.json') -Raw | ConvertFrom-Json
    if ($ExpectError) { Assert (-not $result.ok) "$Name should fail"; return $result }
    Assert $result.ok "$Name failed: $($result.error)"
    $mode = if ($request.outputMode) { $request.outputMode } else { 'rgb' }
    $format = @{rgb=@('rgba',4);gray=@('graya',2);indexed=@('indexed',1)}[$mode]
    Assert ($result.outputMode -eq $mode -and $result.bytesPerPixel -eq $format[1]) "$Name output format"
    $bytes = [IO.File]::ReadAllBytes((Join-Path $dir ('frames.'+$format[0])))
    Assert ($bytes.Length -eq $request.width*$request.height*$format[1]*$result.frames) "$Name byte count"
    return @{ Result=$result; Bytes=$bytes; Directory=$dir }
}
$probe = Join-Path $output 'probe.frag'
Write-Text $probe 'void mainImage(out vec4 c,in vec2 p){c=vec4(p.x/iResolution.x,p.y/iResolution.y,float(iFrame)/10.0,0.25+iTime);}'
$r = Render 'orientation-time-alpha' $probe
Assert ($r.Result.renderer -match '^Shaderlens \(MIT\)') 'Rendering must use the MIT Shaderlens dependency'
Assert ($r.Result.frames -eq 3) 'Frame count'
Assert ([Math]::Abs($r.Bytes[0]-16) -le 1 -and [Math]::Abs($r.Bytes[1]-223) -le 1) 'Top-left orientation'
Assert ([Math]::Abs($r.Bytes[3]-64) -le 1) 'Alpha preservation'
Assert ([Math]::Abs($r.Bytes[128+2]-26) -le 1 -and [Math]::Abs($r.Bytes[128+3]-89) -le 1) 'iFrame/iTime stepping'
$opaque = Render 'opaque-start-time' $probe @{ opaque=$true; startTime=2 }
Assert ($opaque.Bytes[3] -eq 255) 'Forced opaque'
$buffers = Join-Path $output 'buffers.json'
$shader = @{ renderpass=@(
    @{name='Common';type='common';code='float stepSize(){return 0.1;}';},
    @{name='Image';type='image';inputs=@(@{channel=0;ctype='buffer';id='B'});code='void mainImage(out vec4 c,in vec2 p){c=texture(iChannel0,p/iResolution.xy);}'},
    @{name='Buffer B';type='buffer';outputs=@(@{id='B'});inputs=@(@{channel=0;ctype='buffer';id='A'});code='void mainImage(out vec4 c,in vec2 p){c=texture(iChannel0,p/iResolution.xy)+vec4(stepSize(),0,0,0);}'},
    @{name='Buffer A';type='buffer';outputs=@(@{id='A'});inputs=@(@{channel=0;ctype='buffer';id='B'});code='void mainImage(out vec4 c,in vec2 p){c=texture(iChannel0,p/iResolution.xy)+vec4(stepSize(),0,0,0);}'}) }
Write-Text $buffers ($shader | ConvertTo-Json -Depth 12)
$feedback = Render 'buffer-order-feedback' $buffers
foreach ($i in 0..2) { Assert ([Math]::Abs($feedback.Bytes[$i*128] - (51*($i+1))) -le 1) "Buffer feedback frame $i" }
$snapshot = Join-Path $output 'snapshot.rgba'
$snapshotBytes = [byte[]]::new(128)
for ($i=0; $i -lt 32; $i++) { $snapshotBytes[$i*4]=[byte]($i*7); $snapshotBytes[$i*4+3]=255 }
[IO.File]::WriteAllBytes($snapshot,$snapshotBytes)
$copy = Join-Path $output 'copy.frag'
Write-Text $copy 'void mainImage(out vec4 c,in vec2 p){c=texelFetch(iChannel0,ivec2(p),0);}'
$copied = Render 'snapshot-roundtrip' $copy @{ snapshot=$snapshot }
for ($i=0; $i -lt 128; $i++) { Assert ($copied.Bytes[$i] -eq $snapshotBytes[$i]) "Snapshot pixel $i" }
$clockProbe = Join-Path $output 'clock.frag'
Write-Text $clockProbe 'void mainImage(out vec4 c,in vec2 p){c=vec4(iTime/4.0,iTimeDelta,iFrameRate/100.0,1);}'
$clock = Render 'fixed-clock' $clockProbe @{startTime=2}
Assert ([Math]::Abs($clock.Bytes[0]-128) -le 1) 'Initial iTime offset'
Assert ([Math]::Abs($clock.Bytes[1]-26) -le 1 -and [Math]::Abs($clock.Bytes[2]-26) -le 1) 'iTimeDelta and iFrameRate'
# Exercise the local texture codec, sampler and vflip through the library API.
Add-Type -AssemblyName System.Drawing
$texturePath = Join-Path $output 'texture.png'
$bitmap = [Drawing.Bitmap]::new(2,2)
try {
    $bitmap.SetPixel(0,0,[Drawing.Color]::Red); $bitmap.SetPixel(1,0,[Drawing.Color]::Lime)
    $bitmap.SetPixel(0,1,[Drawing.Color]::Blue); $bitmap.SetPixel(1,1,[Drawing.Color]::White)
    $bitmap.Save($texturePath,[Drawing.Imaging.ImageFormat]::Png)
} finally { $bitmap.Dispose() }
$textureSource = Join-Path $output 'texture.json'
$textureShader = @{renderpass=@(@{name='Image';type='image';inputs=@(@{channel=0;type='texture';filepath='texture.png';sampler=@{filter='nearest';wrap='clamp';vflip='true'}});code='void mainImage(out vec4 c,in vec2 p){c=texture(iChannel0,p/iResolution.xy);}'})}
Write-Text $textureSource ($textureShader | ConvertTo-Json -Depth 12)
$textureRender = Render 'texture-codec' $textureSource @{width=2;height=2}
Assert ($textureRender.Bytes[0] -eq 255 -and $textureRender.Bytes[2] -eq 0 -and $textureRender.Bytes[10] -eq 255) 'Texture orientation or sampling'
# Website exports keep vflip/preview filepath fields on generated buffers and keyboard.
# Check a sparse A/D graph and an asymmetric image so a wrong flip cannot pass unnoticed.
$exportSource = Join-Path $output 'website-export.json'
$exported = @{ver='0.1';renderpass=@(
    @{name='Image';type='image';outputs=@(@{id='screen'});inputs=@(@{channel=0;type='buffer';id='D';filepath='/media/previz/buffer03.png';sampler=@{vflip='true'}});code='void mainImage(out vec4 c,in vec2 p){c=texelFetch(iChannel0,ivec2(p),0);}'},
    @{name='Buffer D';type='buffer';outputs=@(@{id='D'});inputs=@(@{channel=2;type='buffer';id='A';sampler=@{vflip='true'}});code='void mainImage(out vec4 c,in vec2 p){c=texelFetch(iChannel2,ivec2(p),0);}'},
    @{name='Buffer A';type='buffer';outputs=@(@{id='A'});inputs=@(@{channel=3;type='keyboard';filepath='/presets/tex00.jpg';sampler=@{vflip='true'}});code='void mainImage(out vec4 c,in vec2 p){float k=0.;for(int y=0;y<3;y++)for(int x=0;x<256;x++)k+=texelFetch(iChannel3,ivec2(x,y),0).r;c=vec4(p.y/iResolution.y,k,float(textureSize(iChannel3,0)==ivec2(256,3)),1.);}'}
)}
Write-Text $exportSource ($exported | ConvertTo-Json -Depth 12)
$exportResult=Render 'website-export-keyboard-sparse-buffers' $exportSource
Assert ([Math]::Abs($exportResult.Bytes[0]-223) -le 1 -and [Math]::Abs($exportResult.Bytes[96]-32) -le 1) 'Generated buffers must retain GL pixel orientation'
Assert ($exportResult.Bytes[1] -eq 0 -and $exportResult.Bytes[2] -eq 255) 'Keyboard must be a 256x3 texture with all keys up'
function New-TestZip($Name, $Entries) {
    $path=Join-Path $output ($Name+'-'+[guid]::NewGuid().ToString('N')+'.ZIP')
    $archive=[IO.Compression.ZipFile]::Open($path,[IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach($name in $Entries.Keys) {
            $stream=$archive.CreateEntry($name).Open()
            try { $content=$Entries[$name]; $stream.Write($content,0,$content.Length) } finally { $stream.Dispose() }
        }
    } finally { $archive.Dispose() }
    return $path
}
$flatZip=New-TestZip 'flat-shader' @{'shader.json'=[IO.File]::ReadAllBytes($exportSource);'readme.txt'=$utf8.GetBytes('Readme')}
$flatResult=Render 'zip-flat' $flatZip
Assert ([Convert]::ToBase64String($flatResult.Bytes) -ceq [Convert]::ToBase64String($exportResult.Bytes)) 'ZIP shader differs from loose JSON'
$nestedJson=$textureShader | ConvertTo-Json -Depth 12
$nestedJson=$nestedJson.Replace('texture.png','../assets/texture.png')
$nestedZip=New-TestZip 'nested-texture' @{'作品/shaders/main.json'=$utf8.GetBytes($nestedJson);'作品/assets/texture.png'=[IO.File]::ReadAllBytes($texturePath);'metadata.json'=$utf8.GetBytes('{"name":"metadata"}')}
$nestedResult=Render 'zip-nested-texture' $nestedZip @{width=2;height=2}
Assert ([Convert]::ToBase64String($nestedResult.Bytes) -ceq [Convert]::ToBase64String($textureRender.Bytes)) 'ZIP relative texture differs from loose texture'
$multipleZip=New-TestZip 'multiple-shaders' @{'a.json'=[IO.File]::ReadAllBytes($exportSource);'b.json'=[IO.File]::ReadAllBytes($exportSource)}
$multipleResult=Render 'zip-multiple' $multipleZip @{} $true
Assert ($multipleResult.error -match 'multiple shaders') 'Ambiguous ZIP must not silently choose a shader'
$emptyZip=New-TestZip 'no-shader' @{'metadata.json'=$utf8.GetBytes('{}')}
$emptyResult=Render 'zip-no-shader' $emptyZip @{} $true
Assert ($emptyResult.error -match 'no Shadertoy JSON') 'Missing JSON diagnostic'
$badPathZip=New-TestZip 'bad-path' @{'../escape.json'=[IO.File]::ReadAllBytes($exportSource)}
$badPathResult=Render 'zip-bad-path' $badPathZip @{} $true
Assert ($badPathResult.error -match 'Invalid path') 'ZIP path validation'
$missingTextureZip=New-TestZip 'missing-texture' @{'shader.json'=[IO.File]::ReadAllBytes($textureSource)}
$missingTextureResult=Render 'zip-missing-texture' $missingTextureZip @{} $true
Assert ($missingTextureResult.error -match 'Texture not found inside ZIP') 'Missing ZIP texture diagnostic'
$bad = Join-Path $output 'bad.frag'
Write-Text $bad 'void mainImage(out vec4 c,in vec2 p){invalid syntax;}'
$failure = Render 'compile-error' $bad @{} $true
Assert ($failure.error -match 'Image') 'Compile diagnostics include pass name'
$invalid = Render 'invalid-size' $probe @{width=0} $true
$example = Render 'example-plasma' (Join-Path $root 'examples/plasma.frag')
$soundSource=Join-Path $output 'sound-ignored.json'
$withSound=@{renderpass=@(
    @{type='sound';name='Sound';code='INVALID SOUND CODE MUST NOT COMPILE';inputs=@(@{type='unsupported';src='https://invalid.example/audio'})},
    @{type='image';name='Image';code=[IO.File]::ReadAllText((Join-Path $root 'examples/plasma.frag'))}
)}
Write-Text $soundSource ($withSound | ConvertTo-Json -Depth 12)
$ignoredSound=Render 'sound-pass-ignored' $soundSource
Assert ([Convert]::ToBase64String($ignoredSound.Bytes) -ceq [Convert]::ToBase64String($example.Bytes)) 'Sound pass must not affect visual frames'
foreach($audioKind in @('music','musicstream','mic')) {
    $audioSource=Join-Path $output ($audioKind+'.json')
    $audioShader=@{renderpass=@(@{name='Image';type='image';inputs=@(@{channel=0;ctype=$audioKind;src='https://invalid.example/audio';sampler=@{srgb='true';vflip='true'}});code='void mainImage(out vec4 c,in vec2 p){float f=0.;float w=0.;for(int x=0;x<512;x++){f+=texelFetch(iChannel0,ivec2(x,0),0).r;w+=texelFetch(iChannel0,ivec2(x,1),0).r;}c=vec4(f,w/512.,float(textureSize(iChannel0,0)==ivec2(512,2)),1.);}'})}
    Write-Text $audioSource ($audioShader | ConvertTo-Json -Depth 12)
    $silence=Render ('silent-'+$audioKind) $audioSource
    Assert ($silence.Bytes[0] -eq 0 -and $silence.Bytes[1] -eq 128 -and $silence.Bytes[2] -eq 255) "Incorrect silent audio texture: $audioKind"
}
$exampleFeedback = Render 'example-feedback' (Join-Path $root 'examples/feedback.json')
. (Join-Path $PSScriptRoot 'compatibility.tests.ps1')
. (Join-Path $PSScriptRoot 'textures.tests.ps1')
. (Join-Path $PSScriptRoot 'color-modes.tests.ps1')
# Cancellation while a long job is running must terminate the independent process.
$cancelDir = Join-Path $output ('cancel-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $cancelDir | Out-Null
Write-Text (Join-Path $cancelDir 'permit') '1'
Write-Text (Join-Path $cancelDir 'request.json') (@{width=1024;height=1024;fps=100;seconds=1;source=$probe} | ConvertTo-Json)
$cancel = Start-Process -FilePath $Worker -ArgumentList @('--job',('"'+$cancelDir+'"'),'--standalone') -WindowStyle Hidden -PassThru
$deadline = [DateTime]::UtcNow.AddSeconds(10)
while (-not (Test-Path (Join-Path $cancelDir 'owned')) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 20 }
Assert (-not $cancel.HasExited) 'Cancellation job should still be running'
Remove-Item -LiteralPath (Join-Path $cancelDir 'permit')
Assert ($cancel.WaitForExit(5000)) 'Worker did not exit after cancellation'
Write-Output "PASS: GPU orientation, time, alpha, snapshot, Common, Buffer ordering/feedback, website-export JSON, ZIP and relative textures, idle keyboard, diagnostics, validation, examples, cancellation."
Write-Output $r.Result.renderer
