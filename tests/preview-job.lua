-- Import a completed worker job for visual inspection without changing user documents.
local root, directory = assert(app.params.root), assert(app.params.job)
local function read(name)
  local f=assert(io.open(app.fs.joinPath(directory,name),"rb")); local text=f:read("*a"); f:close(); return text
end
local request, result = json.decode(read("request.json")), json.decode(read("result.json"))
assert(result.ok,result.error)
local sprite=Sprite(request.width,request.height,ColorMode.RGB)
local worker=dofile(app.fs.joinPath(root,"render_job.lua"))
local layer=worker.import{sprite=sprite,directory=directory,width=request.width,height=request.height,
  count=result.frames,fps=request.fps,first=1,layerName="Shadertoy",originalFrames=1}
assert(#layer.cels==result.frames)
sprite:saveAs(app.fs.joinPath(directory,"preview.aseprite"))
layer:cel(1).image:saveAs(app.fs.joinPath(directory,"first.png"))
layer:cel(result.frames).image:saveAs(app.fs.joinPath(directory,"last.png"))
sprite:close()
