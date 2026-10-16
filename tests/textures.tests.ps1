# Project-authored fixtures only; tests do not fetch or redistribute Shadertoy art.
$assetDir=Join-Path $output ('texture-fixtures-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $assetDir | Out-Null
$faces=@()
for($face=0;$face -lt 6;$face++) {
    $path=Join-Path $assetDir $(if($face -eq 0){'cube.png'}else{"cube_$face.png"})
    $bitmap=[Drawing.Bitmap]::new(2,2)
    try {
        for($y=0;$y -lt 2;$y++){for($x=0;$x -lt 2;$x++){$bitmap.SetPixel($x,$y,[Drawing.Color]::FromArgb(255,($face+1)*30,$x*200,$y*200))}}
        $bitmap.Save($path,[Drawing.Imaging.ImageFormat]::Png)
    }finally{$bitmap.Dispose()}
    $faces+=,$path
}
$cubeCode=@'
vec3 direction(int i){
if(i==0)return vec3(1,.5,.5);if(i==1)return vec3(-1,.5,-.5);
if(i==2)return vec3(-.5,1,-.5);if(i==3)return vec3(-.5,-1,.5);
if(i==4)return vec3(-.5,.5,1);return vec3(.5,.5,-1);}
void mainImage(out vec4 c,in vec2 p){c=texture(iChannel0,direction(int(p.x)));}
'@
$cubeInput=@{channel=0;type='cubemap';filepath='cube.png';sampler=@{filter='nearest';wrap='clamp';vflip='false';srgb='false'}}
$cubeShader=@{renderpass=@(@{name='Image';type='image';inputs=@($cubeInput);code=$cubeCode})}
$cubeJson=Join-Path $assetDir 'cube.json'
Write-Text $cubeJson ($cubeShader|ConvertTo-Json -Depth 12)
$cube=Render 'cube-six-directions' $cubeJson @{width=6;height=1}
for($i=0;$i -lt 6;$i++) {Assert ($cube.Bytes[$i*4] -eq ($i+1)*30 -and $cube.Bytes[$i*4+1] -eq 0 -and $cube.Bytes[$i*4+2] -eq 0) "Cube face $i direction/orientation"}
$snapshotCube=Render 'cube-snapshot-incompatible' $cubeJson @{snapshot=$snapshot} $true
Assert ($snapshotCube.error -match 'snapshot cannot replace a cubemap') 'Snapshot/cube type diagnostic'
$cubeInput.sampler.vflip='true'
Write-Text $cubeJson ($cubeShader|ConvertTo-Json -Depth 12)
$flipped=Render 'cube-vflip' $cubeJson @{width=6;height=1}
for($i=0;$i -lt 6;$i++) {Assert ($flipped.Bytes[$i*4+2] -eq 200) "Cube vflip face $i"}
$cubeInput.sampler.vflip='false';$cubeInput.sampler.filter='mipmap'
$cubeShader.renderpass[0].code=$cubeCode.Replace('texture(iChannel0,direction(int(p.x)))','textureLod(iChannel0,direction(int(p.x)),1.)')
Write-Text $cubeJson ($cubeShader|ConvertTo-Json -Depth 12)
$mipmap=Render 'cube-mipmap' $cubeJson @{width=6;height=1}
for($i=0;$i -lt 6;$i++) {Assert ([Math]::Abs($mipmap.Bytes[$i*4+1]-100) -le 1 -and [Math]::Abs($mipmap.Bytes[$i*4+2]-100) -le 1) "Cube mipmap face $i"}
$cubeInput.sampler.filter='linear'
$cubeShader.renderpass[0].code=$cubeCode.Replace('direction(int(p.x))','vec3(1,0,0)')
Write-Text $cubeJson ($cubeShader|ConvertTo-Json -Depth 12)
$linear=Render 'cube-linear' $cubeJson @{width=6;height=1}
Assert ([Math]::Abs($linear.Bytes[1]-100) -le 1 -and [Math]::Abs($linear.Bytes[2]-100) -le 1) 'Cube bilinear filtering'
# Older preset filenames, assets in a nested ZIP, samplerCube in Common, legacy textureCube.
$cubeInput.filepath='/presets/cube00_0.png';$cubeInput.sampler.filter='point'
$cubeShader.renderpass[0].code=$cubeCode.Replace('texture(iChannel0,direction(int(p.x)))','sampleCube(iChannel0,direction(int(p.x)))')
$cubeShader.renderpass=@(@{type='common';name='Common';code='vec4 sampleCube(samplerCube s,vec3 d){return textureCube(s,d);}'},$cubeShader.renderpass[0])
$entries=@{'nested/shader.json'=$utf8.GetBytes(($cubeShader|ConvertTo-Json -Depth 12))}
for($i=0;$i -lt 6;$i++){$entries["nested/presets/cube00_$i.png"]=[IO.File]::ReadAllBytes($faces[$i])}
$cubeZip=New-TestZip 'cubemap-presets' $entries
$zippedCube=Render 'cube-presets-zip-common' $cubeZip @{width=6;height=1}
Assert ([Convert]::ToBase64String($zippedCube.Bytes) -eq [Convert]::ToBase64String($cube.Bytes)) 'ZIP cube face naming or Common sampler mismatch'
# Non-image pass and mixed 2D/cube samplers; final palette mapping must stay sampler2D.
$cubeShader.renderpass[1].name='Buffer A';$cubeShader.renderpass[1].type='buffer';$cubeShader.renderpass[1].outputs=@(@{id='A'})
$cubeInput.filepath='cube.png'
$cubeShader.renderpass+=@{name='Image';type='image';inputs=@(@{channel=0;type='buffer';id='A'});code='void mainImage(out vec4 c,in vec2 p){c=texelFetch(iChannel0,ivec2(p),0);if(iChannelResolution[0].x!=6.)c=vec4(1);}'}
Write-Text $cubeJson ($cubeShader|ConvertTo-Json -Depth 12)
$bufferCube=Render 'cube-buffer-to-image' $cubeJson @{width=6;height=1}
Assert ([Convert]::ToBase64String($bufferCube.Bytes) -eq [Convert]::ToBase64String($cube.Bytes)) 'Cubemap in Buffer, 2D buffer in Image'
$palette=@(,@(0,0,0,0)) + @(1..6|ForEach-Object{,@(($_*30),0,0,255)})
$indexedCube=Render 'cube-indexed' $cubeJson @{width=6;height=1;outputMode='indexed';palette=$palette;transparentIndex=0;opaque=$true}
Assert (($indexedCube.Bytes[0..5] -join ',') -eq '1,2,3,4,5,6') 'Cubemap with final indexed pass'
$cubeShader.renderpass[1].code='void mainImage(out vec4 c,in vec2 p){c=vec4(iChannelResolution[0]/vec3(2,2,1),1);}'
Write-Text $cubeJson ($cubeShader|ConvertTo-Json -Depth 12)
$resolution=Render 'cube-resolution-only' $cubeJson @{width=6;height=1}
Assert (($resolution.Bytes[0..3] -join ',') -eq '255,255,255,255') 'Cubemap resolution when sampler optimized out'
# sRGB converts RGB before filtering, while alpha remains linear.
$srgbFile=Join-Path $assetDir 'srgb.png'
$bitmap=[Drawing.Bitmap]::new(2,2)
try {for($y=0;$y -lt 2;$y++){for($x=0;$x -lt 2;$x++){$bitmap.SetPixel($x,$y,[Drawing.Color]::FromArgb(200,128,128,128))}};$bitmap.Save($srgbFile,[Drawing.Imaging.ImageFormat]::Png)}finally{$bitmap.Dispose()}
$srgbShader=@{renderpass=@(@{name='Image';type='image';inputs=@(@{channel=0;ctype='texture';src='srgb.png';sampler=@{srgb=$true;filter='nearest'}});code='void mainImage(out vec4 c,in vec2 p){c=texture(iChannel0,vec2(.5));}'})}
$srgbJson=Join-Path $assetDir 'srgb.json'
Write-Text $srgbJson ($srgbShader|ConvertTo-Json -Depth 12)
$srgb=Render 'texture-srgb' $srgbJson
Assert ([Math]::Abs($srgb.Bytes[0]-55) -le 1 -and $srgb.Bytes[3] -eq 200) '2D sRGB/alpha decode'
$srgbShader.renderpass[0].inputs[0].ctype='cubemap'
for($i=1;$i -lt 6;$i++){Copy-Item -LiteralPath $srgbFile -Destination (Join-Path $assetDir "srgb_$i.png")}
$srgbShader.renderpass[0].code='void mainImage(out vec4 c,in vec2 p){c=textureGrad(iChannel0,vec3(1,0,0),vec3(0),vec3(0));}'
Write-Text $srgbJson ($srgbShader|ConvertTo-Json -Depth 12)
$srgbCube=Render 'cube-srgb-grad' $srgbJson
Assert ([Math]::Abs($srgbCube.Bytes[0]-55) -le 1 -and $srgbCube.Bytes[3] -eq 200) 'Cubemap sRGB/alpha and textureGrad'
# A Shadertoy /media URL can resolve from assets adjacent to loose JSON or ZIP.
$mediaDir=Join-Path $assetDir 'media/a'
New-Item -ItemType Directory -Path $mediaDir -Force|Out-Null
Copy-Item -LiteralPath $srgbFile -Destination (Join-Path $mediaDir 'fixture.png')
$srgbShader.renderpass[0].inputs[0].ctype='texture';$srgbShader.renderpass[0].inputs[0].src='https://www.shadertoy.com/media/a/fixture.png'
$srgbShader.renderpass[0].code='void mainImage(out vec4 c,in vec2 p){c=texture(iChannel0,vec2(.5));}'
Write-Text $srgbJson ($srgbShader|ConvertTo-Json -Depth 12)
$media=Render 'media-adjacent-json' $srgbJson
Assert ($media.Bytes[0] -eq $srgb.Bytes[0]) 'Adjacent media URL resolution'
$mediaZip=New-TestZip 'media-archive' @{'shader.json'=[IO.File]::ReadAllBytes($srgbJson);'media/a/fixture.png'=[IO.File]::ReadAllBytes($srgbFile)}
$zipMedia=Render 'media-inside-zip' $mediaZip
Assert ($zipMedia.Bytes[0] -eq $srgb.Bytes[0]) 'Media embedded in ZIP'
$oldMediaRoot=$env:SHADERTOY_MEDIA_DIR
try {
    $env:SHADERTOY_MEDIA_DIR=$assetDir
    $externalZip=New-TestZip 'external-media' @{'shader.json'=[IO.File]::ReadAllBytes($srgbJson)}
    $external=Render 'media-shared-root' $externalZip
    Assert ($external.Bytes[0] -eq $srgb.Bytes[0]) 'Shared media folder'
} finally { $env:SHADERTOY_MEDIA_DIR=$oldMediaRoot }
$customFolder=Render 'media-explicit-folder' $externalZip @{textureDirectory=$assetDir}
Assert ($customFolder.Bytes[0] -eq $srgb.Bytes[0]) 'Explicit texture folder'
# An already downloaded asset renders offline from cache; fixture has a unique path.
$cacheAsset='/media/a/aseprite-test-'+[guid]::NewGuid().ToString('N')+'.png'
$cache=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'AsepriteShadertoy/textures'
New-Item -ItemType Directory -Path $cache -Force|Out-Null
$sha=[Security.Cryptography.SHA256]::Create()
try{$hash=([BitConverter]::ToString($sha.ComputeHash($utf8.GetBytes($cacheAsset)))).Replace('-','')}finally{$sha.Dispose()}
$cacheFile=Join-Path $cache ($hash+'.asset')
try {
    Copy-Item -LiteralPath $srgbFile -Destination $cacheFile
    $srgbShader.renderpass[0].inputs[0].src=$cacheAsset
    Write-Text $srgbJson ($srgbShader|ConvertTo-Json -Depth 12)
    $cached=Render 'media-offline-cache' $srgbJson
    Assert ($cached.Bytes[0] -eq $srgb.Bytes[0]) 'Offline cached asset'
} finally {Remove-Item -LiteralPath $cacheFile}
$cubeShader.renderpass[1].code=$cubeCode
$cubeInput.filepath='missing.png'
Write-Text $cubeJson ($cubeShader|ConvertTo-Json -Depth 12)
$missing=Render 'cube-missing-face' $cubeJson @{} $true
Assert ($missing.error -match 'missing.png') 'Missing cube face diagnostic'
$cubeInput.filepath='srgb.png'
$bitmap=[Drawing.Bitmap]::new(1,2)
try{$bitmap.Save((Join-Path $assetDir 'srgb_5.png'),[Drawing.Imaging.ImageFormat]::Png)}finally{$bitmap.Dispose()}
Write-Text $cubeJson ($cubeShader|ConvertTo-Json -Depth 12)
$mismatched=Render 'cube-mismatched-face' $cubeJson @{} $true
Assert ($mismatched.error -match 'identical dimensions') 'Mismatched cube faces diagnostic'
Write-Output 'PASS: cubemap six axes/orientation, flip, mipmaps, linear sampling, Common, Buffer, indexed, channel resolution, sRGB, textureGrad, preset/media paths, ZIP/shared assets, invalid faces.'
