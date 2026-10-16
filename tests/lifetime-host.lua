-- Disposable real Aseprite process; controller can kill it without touching the user's UI.
local root, output = assert(app.params.root), assert(app.params.output)
local function write(name,value)
  local f=assert(io.open(app.fs.joinPath(output,name),"wb")); f:write(value); f:close()
end
local worker=dofile(app.fs.joinPath(root,"render_job.lua"))
local originalStart=worker.start
worker.start=function(...)
  local job=originalStart(...)
  write("session.path",job.directory)
  return job
end
local timers, view, command = {}, nil, nil
local env=setmetatable({dofile=function() return worker end,
  Timer=function(spec)
    function spec:start() self.running=true end
    function spec:stop() self.running=false end
    timers[#timers+1]=spec; return spec
  end,
  Dialog=function(spec)
    local d={data={kind="Local file",file=app.fs.joinPath(output,"slow.frag"),fps=1000,seconds=10,startTime=0,
      where="Current frame",layerName="lifetime",opaque=true},bounds={x=0,y=0,width=500,height=500},callbacks={}}
    for _,name in ipairs({"combobox","file","entry","number","check","label","button"}) do
      d[name]=function(self,options) if options.id then self.callbacks[options.id]=options end; return self end
    end
    for _,name in ipairs({"newrow","separator","show","modify"}) do d[name]=function(self) return self end end
    function d:close() spec.onclose() end
    view=d; return d
  end,
},{__index=_G})
local sprite=Sprite(64,64,ColorMode.RGB)
assert(loadfile(app.fs.joinPath(root,"main.lua"),"t",env))()
env.init({path=root,preferences={},newCommand=function(_,spec) command=spec.onclick end})
command(); view.callbacks.render.onclick(); timers[1].ontick()
write("launched","1")
local deadline=os.time()+40
local handled=false
while os.time()<deadline do
  local f=io.open(app.fs.joinPath(output,"action"),"rb")
  local action=f and f:read("*a"); if f then f:close() end
  if action=="exit" then return end -- deliberately no Lua cleanup
  if (action=="cancel" or action=="close" or action=="unload") and not handled then
    if action=="cancel" then view.callbacks.cancel.onclick()
    elseif action=="close" then view:close()
    elseif action=="unload" then env.exit() end
    handled=true; write("handled","1")
  end
end
error("Lifetime controller timed out")
