$colorProbe=Join-Path $output 'color-modes.frag'
Write-Text $colorProbe 'void mainImage(out vec4 c,in vec2 p){int x=int(p.x);c=vec4(x==0?vec3(1,0,0):x==1?vec3(0,1,0):vec3(0,0,1),p.y<1.?0.25:1.);}'
$gray=Render 'gray-colors-alpha' $colorProbe @{width=3;height=2;outputMode='gray'}
Assert (($gray.Bytes[0..11] -join ',') -eq '54,255,182,255,18,255,54,64,182,64,18,64') 'Grayscale luminance, alpha and odd-width orientation'
$grayOpaque=Render 'gray-opaque' $colorProbe @{width=3;height=2;outputMode='gray';opaque=$true}
Assert ($grayOpaque.Bytes[7] -eq 255) 'Grayscale force opaque'
# Index 1 is reserved even though its stored palette color duplicates opaque red.
$palette=@(@(255,0,0,255),@(255,0,0,255),@(0,255,0,255),@(0,0,255,255))
$indexed=Render 'indexed-palette-alpha' $colorProbe @{width=3;height=2;outputMode='indexed';palette=$palette;transparentIndex=1}
Assert (($indexed.Bytes[0..5] -join ',') -eq '0,2,3,1,1,1') 'Palette lookup, nonzero transparent index and orientation'
$indexedOpaque=Render 'indexed-opaque' $colorProbe @{width=3;height=2;outputMode='indexed';palette=$palette;transparentIndex=1;opaque=$true}
Assert (($indexedOpaque.Bytes[0..5] -join ',') -eq '0,2,3,0,2,3') 'Indexed force opaque'
$tieProbe=Join-Path $output 'index-tie.frag'
Write-Text $tieProbe 'void mainImage(out vec4 c,in vec2 p){c=vec4(1,0,0,int(p.x)==0?0.49:0.5);}'
$tie=Render 'indexed-threshold-tie' $tieProbe @{width=2;height=1;outputMode='indexed';transparentIndex=0;palette=@(@(0,0,0,0),@(255,0,0,128),@(255,0,0,128),@(255,0,0,255))}
Assert (($tie.Bytes[0..1] -join ',') -eq '0,1') 'Alpha threshold and duplicate color tie'
$tieOpaque=Render 'indexed-skip-partial' $tieProbe @{width=2;height=1;outputMode='indexed';opaque=$true;transparentIndex=0;palette=@(@(0,0,0,0),@(255,0,0,128),@(255,0,0,128),@(255,0,0,255))}
Assert ($tieOpaque.Bytes[0] -eq 3) 'Opaque lookup must skip partially transparent palette entries'
$fullPalette=@(0..255 | ForEach-Object { ,@($_,$_, $_,255) })
$whiteProbe=Join-Path $output 'white.frag'
Write-Text $whiteProbe 'void mainImage(out vec4 c,in vec2 p){c=vec4(1);}'
$full=Render 'indexed-255' $whiteProbe @{outputMode='indexed';palette=$fullPalette;transparentIndex=0}
Assert ($full.Bytes[0] -eq 255) 'Index 255 roundtrip'
$mappedFeedback=Render 'indexed-feedback' $buffers @{outputMode='indexed';opaque=$true;transparentIndex=0;palette=@(@(0,0,0,0),@(51,0,0,255),@(102,0,0,255),@(153,0,0,255))}
foreach($i in 0..2) { Assert ($mappedFeedback.Bytes[$i*32] -eq $i+1) "Unquantized feedback with final palette mapping frame $i" }
$invalidPalette=Render 'indexed-no-opaque' $whiteProbe @{outputMode='indexed';opaque=$true;transparentIndex=0;palette=@(@(0,0,0,0),@(255,0,0,128))} $true
Assert ($invalidPalette.error -match 'opaque') 'Missing opaque palette color diagnostic'
Write-Output 'PASS: GPU grayscale, indexed palette LUT, transparent index, alpha threshold, palette ties, opaque filtering, index 255, unquantized feedback.'
