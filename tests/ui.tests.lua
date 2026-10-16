-- Run in Aseprite batch Lua, but simulate modal event-loop re-entry explicitly.
local root = assert(app.params.root)
local function scenario(mode)
  local timers, views, calls = {}, {}, {start=0, poll=0, import=0, release=0, alert=0}
  local command, env, active
  local api = {}
  local function nested()
    local t = timers[1]
    assert(not t.running, "Polling timer must stop before entering host/worker APIs")
    t.ontick() -- simulate an already queued tick in a nested modal loop
  end
  function api.validate() end
  function api.start()
    calls.start = calls.start + 1
    nested()
    if mode == "launch-error" then error("permission denied") end
    if mode == "close-during-launch" then active:close() end
    return {count=2,device="test"}
  end
  function api.poll()
    calls.poll = calls.poll + 1
    nested()
    if mode == "poll-error" then error("read denied") end
    return true,2
  end
  function api.import() calls.import = calls.import + 1; nested() end
  function api.release() calls.release = calls.release + 1; nested() end
  function api.shutdown() calls.shutdown = true end
  env = setmetatable({
    dofile=function() return api end,
    app={fs=app.fs,activeSprite={width=8,height=4,frames={1}},activeFrame={frameNumber=1},
      alert=function() calls.alert=calls.alert+1; nested() end},
    Timer=function(spec)
      function spec:start() self.running=true end
      function spec:stop() self.running=false; self.ontick() end
      timers[#timers+1]=spec
      return spec
    end,
    Dialog=function(spec)
      local d={data={kind="Local file",fps=30,seconds=1,startTime=0,file="test.frag",where="Current frame",layerName="test"},
        bounds={x=0,y=0,width=500,height=500},callbacks={}}
      for _,name in ipairs({"combobox","file","entry","number","check","label","button"}) do
        d[name]=function(self,options) if options.id then self.callbacks[options.id]=options end; return self end
      end
      for _,name in ipairs({"newrow","separator","show","modify"}) do d[name]=function(self) return self end end
      function d:close() spec.onclose() end
      views[#views+1]=d; active=d; return d
    end,
  }, {__index=_G})
  assert(loadfile(app.fs.joinPath(root,"main.lua"),"t",env))()
  env.init({path=root,preferences={},newCommand=function(_,spec) command=spec.onclick end})
  command(); active.callbacks.render.onclick()
  assert(#timers==1 and timers[1].running)
  timers[1].ontick()
  if mode == "close-during-launch" or mode == "launch-error" then
    assert(not timers[1].running)
  elseif mode == "cancel" then
    active.callbacks.cancel.onclick()
  elseif mode == "close" then
    active:close()
  elseif mode == "unload" then
    env.exit()
  else
    assert(timers[1].running)
    timers[1].ontick()
  end
  assert(not timers[1].running,"Finished/cancelled timer still running")
  timers[1].ontick() -- stale callbacks cannot start another process
  assert(calls.start==1,"Re-entered process launch")
  assert(calls.import==(mode=="success" and 1 or 0),"Unexpected/duplicate import")
  assert(calls.release==(mode=="launch-error" and 0 or 1),"Job not released exactly once")
  assert(calls.alert==((mode=="launch-error" or mode=="poll-error") and 1 or 0),"Repeated error dialog")
  -- Closing/reopening must isolate the old timer from a fresh session.
  if mode=="close-during-launch" then
    command(); active.callbacks.render.onclick(); timers[1].ontick()
    assert(calls.start==1 and timers[2].running,"Stale tick affected new dialog")
  end
  env.exit()
end
for _,mode in ipairs({"success","launch-error","poll-error","cancel","close","close-during-launch","unload"}) do scenario(mode) end
print("PASS: modal re-entry, stop re-entry, launch/read errors, cancel, close, unload, stale callbacks")
