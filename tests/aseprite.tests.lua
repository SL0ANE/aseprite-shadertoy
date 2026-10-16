local root = app.params.root
local output = app.params.output
local worker = dofile(app.fs.joinPath(root, "render_job.lua"))
local function write(path, text) local f=assert(io.open(path,"wb")); f:write(text); f:close() end
local function run()
  dofile(app.fs.joinPath(root,"tests","ui.tests.lua"))
  assert(loadfile(app.fs.joinPath(root,"main.lua")))
  local sprite = Sprite(8,4,ColorMode.RGB)
  sprite.layers[1].name = "Original"
  sprite.cels[1].image:drawPixel(0,0,app.pixelColor.rgba(10,20,30,255))
  local data = {source=app.fs.joinPath(root,"examples","plasma.frag"), fps=60, seconds=1, startTime=0,
    opaque=true, first=1, layerName="Shader result", snapshot=false}
  local job = worker.start(root,sprite,data)
  local deadline = os.time()+45
  local done = false
  while os.time() < deadline do
    done = worker.poll(job)
    if done then break end
    local nextPoll = os.clock()+0.05
    while os.clock()<nextPoll do end -- batch has no GUI timer/event pump
  end
  assert(done,"Worker failed to complete")
  -- Switching the selected document must not redirect the import/undo transaction.
  local other = Sprite(2,2,ColorMode.RGB)
  local layer = worker.import(job)
  assert(#sprite.frames==60 and #layer.cels==60 and #sprite.layers==2)
  assert(#other.frames==1 and #other.layers==1)
  assert(layer.name=="Shader result")
  local total=0
  for _,frame in ipairs(sprite.frames) do total=total+frame.duration end
  assert(math.abs(total-1)<0.00001,"60 FPS cumulative duration must be exactly 1s")
  assert(layer:cel(1).image.bytes ~= layer:cel(30).image.bytes,"Animation must change")
  assert(sprite.layers[1]:cel(1).image:getPixel(0,0)==app.pixelColor.rgba(10,20,30,255),"Existing cel modified")
  sprite:saveAs(app.fs.joinPath(output,"rendered.aseprite"))
  layer:cel(1).image:saveAs(app.fs.joinPath(output,"first-frame.png"))
  app.command.Undo()
  assert(#sprite.frames==1 and #sprite.layers==1,"Import must undo in one step")
  app.command.Redo()
  assert(#sprite.frames==60 and #sprite.layers==2,"Redo failed")
  worker.release(job)
  assert(not pcall(worker.import,job),"Cancelled/released jobs must not import")
  -- Validate input limits without starting a process.
  data.fps=0; assert(not pcall(worker.validate,sprite,data)); data.fps=60
  dofile(app.fs.joinPath(root,"tests","color-modes.tests.lua"))
  other:close(); sprite:close()
  worker.shutdown()
end
local ok,err=xpcall(run,debug.traceback)
write(app.fs.joinPath(output,"aseprite-result.txt"),ok and "PASS: UI re-entry/cancel/close/unload, native launch, GPU render, 60 cels, timing, target document, original content, RGB/gray/indexed cels and snapshots, palette guard, undo/redo, validation" or tostring(err))
if not ok then worker.shutdown(); error(err) end
