local root, output = app.params.root, app.params.output
local worker = dofile(app.fs.joinPath(root,"render_job.lua"))
local function write(path,text) local f=assert(io.open(path,"wb")); f:write(text); f:close() end
local function wait(job)
  local deadline=os.time()+20
  repeat
    if worker.poll(job) then return end
    local nextPoll=os.clock()+0.05; while os.clock()<nextPoll do end
  until os.time()>=deadline
  error("Color mode render timed out")
end
local source=app.fs.joinPath(output,"colors.frag")
write(source,'void mainImage(out vec4 c,in vec2 p){int x=int(p.x);c=vec4(x==0?vec3(1,0,0):x==1?vec3(0,1,0):vec3(0,0,1),p.y<1.?0.:1.);}')
local copy=app.fs.joinPath(output,"copy.frag")
write(copy,'void mainImage(out vec4 c,in vec2 p){c=texelFetch(iChannel0,ivec2(p),0);}')
for _,mode in ipairs({ColorMode.GRAY,ColorMode.INDEXED}) do
  local indexed=mode==ColorMode.INDEXED
  local sprite=Sprite(3,2,mode)
  if indexed then
    local palette=Palette(4)
    palette:setColor(0,Color{r=255,g=0,b=0,a=255})
    palette:setColor(1,Color{r=255,g=0,b=0,a=255})
    palette:setColor(2,Color{r=0,g=255,b=0,a=255})
    palette:setColor(3,Color{r=0,g=0,b=255,a=255})
    sprite:setPalette(palette); sprite.transparentColor=1
    sprite.cels[1].image:clear(1)
  end
  local original=sprite.cels[1].image.bytes
  local data={source=source,fps=10,seconds=0.3,startTime=0,opaque=false,first=1,layerName="Mapped",snapshot=false,snapshotFrame=1}
  local job=worker.start(root,sprite,data); wait(job)
  local layer=worker.import(job); worker.release(job)
  assert(sprite.colorMode==mode and #layer.cels==3 and #sprite.frames==3,"Native color mode cels")
  local image=layer:cel(1).image
  assert(image.colorMode==mode,"Image mode mismatch")
  assert(#image.bytes==3*2*(indexed and 1 or 2),"Odd-width packed image data")
  if indexed then
    assert(image.bytes==string.char(0,2,3,1,1,1),"Indexed pixels or transparent index mismatch")
    assert(sprite.transparentColor==1 and #sprite.palettes[1]==4,"Palette changed")
    assert(sprite.palettes[1]:getColor(1).red==255,"Reserved palette color modified")
  else
    assert(image.bytes==string.char(54,255,182,255,18,255,54,0,182,0,18,0),"Gray pixels mismatch")
  end
  assert(sprite.layers[1]:cel(1).image.bytes==original,"Original cel changed")
  app.command.Undo(); assert(#sprite.layers==1 and #sprite.frames==1,"Color mode undo")
  app.command.Redo(); assert(#sprite.layers==2 and #sprite.frames==3,"Color mode redo")
  sprite:saveAs(app.fs.joinPath(output,indexed and "indexed.aseprite" or "gray.aseprite"))
  -- Snapshot resolves the document palette/grayscale before GPU input, then maps back.
  data.source=copy; data.snapshot=true
  local snapshotJob=worker.start(root,sprite,data); wait(snapshotJob)
  local snapshotLayer=worker.import(snapshotJob); worker.release(snapshotJob)
  local captured=snapshotLayer:cel(1).image
  for x=0,2 do assert(captured:getPixel(x,0)==layer:cel(1).image:getPixel(x,0),"Snapshot visible color roundtrip") end
  for x=0,2 do
    local pixel=captured:getPixel(x,1)
    assert(indexed and pixel==1 or not indexed and app.pixelColor.grayaA(pixel)==0,"Snapshot transparency")
  end
  if indexed then
    local guardJob=worker.start(root,sprite,data); wait(guardJob)
    local layers=#sprite.layers
    sprite.palettes[1]:setColor(2,Color{r=20,g=30,b=40})
    local ok,err=pcall(worker.import,guardJob)
    assert(not ok and tostring(err):find("Palette or transparent index changed"),"Stale palette guard")
    assert(#sprite.layers==layers,"Stale palette created a layer")
    worker.release(guardJob)
  end
  sprite:close()
end
worker.shutdown()
