$reservedProbe=Join-Path $output 'reserved-char.frag'
Write-Text $reservedProbe @'
// char must not change longer names such as charX.
/* int char = bad syntax in a comment; */
void mainImage(out vec4 c,in vec2 p){int char=int(p.x);int charX=2;int asepriteCompatChar=3;int asepriteCompatChar1=4;c=vec4(float(char+charX+asepriteCompatChar+asepriteCompatChar1)/16.,0,0,1);}
'@
$reserved=Render 'reserved-char-local-collision' $reservedProbe
Assert ([Math]::Abs($reserved.Bytes[0]-143) -le 1 -and $reserved.Bytes[28] -eq 255) 'Reserved identifier rename changed local variable semantics'
$reservedJson=Join-Path $output 'reserved-char-common.json'
$reservedShader=@{renderpass=@(
    @{name='Common';type='common';code="#define FETCH(item) ((item).char)`n#define ADD(char) ((char)+0.25)`nstruct Glyph{float char;};`nfloat char(float x){return ADD(x);}"},
    @{name='Buffer A';type='buffer';outputs=@(@{id='A'});code='void mainImage(out vec4 c,in vec2 p){Glyph g;g.char=char(0.25);c=vec4(FETCH(g),0,0,1);}'},
    @{name='Image';type='image';inputs=@(@{channel=0;type='buffer';id='A'});code='void mainImage(out vec4 c,in vec2 p){float asepriteCompatChar=0.25;c=texelFetch(iChannel0,ivec2(p),0)+vec4(asepriteCompatChar,0,0,0);}'})}
Write-Text $reservedJson ($reservedShader | ConvertTo-Json -Depth 12)
foreach($mode in @('rgb','gray','indexed')) {
    $args=@{outputMode=$mode;opaque=$true}
    if($mode -eq 'indexed') {$args.palette=@(@(0,0,0,0),@(191,0,0,255));$args.transparentIndex=0}
    $mapped=Render ('reserved-char-common-'+$mode) $reservedJson $args
    $expected=@{rgb=191;gray=41;indexed=1}[$mode]
    Assert ([Math]::Abs($mapped.Bytes[0]-$expected) -le 1) "Common, macros and members compatibility in $mode"
}
Write-Output 'PASS: reserved char identifiers, collision avoidance, Common and Buffer references, macro parameters, struct members, RGB/gray/indexed rendering.'
