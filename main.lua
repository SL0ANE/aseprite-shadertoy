local worker, pluginRef, dialog, session
local function stopJob()
  -- Detach before calling host APIs: permission/modal dialogs can pump events.
  local old = session
  session = nil
  if not old then return end
  old.cancelled = true
  local timer, job = old.timer, old.job
  old.timer, old.job = nil, nil
  if timer then timer:stop() end
  if job then worker.release(job) end
end
local controls = {"kind", "file", "url", "textureDirectory", "fps", "seconds", "startTime", "where", "layerName", "snapshot", "opaque", "render"}
local function busy(value)
  if not dialog then return end
  for _, id in ipairs(controls) do dialog:modify{id=id, enabled=not value} end
  dialog:modify{id="cancel", enabled=value}
end
local function showError(error)
  print("[Shadertoy] " .. tostring(error))
  app.alert{title="Shadertoy", text=tostring(error)}
end
local function openDialog()
  if dialog then dialog:show{wait=false}; return end
  if not app.activeSprite then app.alert("Open a sprite first."); return end
  local prefs = pluginRef.preferences
  dialog = Dialog{title="Shadertoy", resizeable=true, onclose=function() dialog = nil; stopJob() end}
  local function estimate()
    local data = dialog.data
    local count = math.floor((tonumber(data.fps) or 0) * (tonumber(data.seconds) or 0) + 0.5)
    local sprite = app.activeSprite
    dialog:modify{id="estimate", text=string.format("%s | %d frames", sprite and (sprite.width .. " × " .. sprite.height) or "No sprite", count)}
  end
  dialog:combobox{id="kind", label="Source", options={"Local file", "Shadertoy URL"}, onchange=function()
    local localFile = dialog.data.kind == "Local file"
    dialog:modify{id="file", visible=localFile}; dialog:modify{id="url", visible=not localFile}
  end}
  dialog:file{id="file", label="Shader", title="Select shader source, Shadertoy JSON, or ZIP", open=true, entry=true,
    filename=prefs.file or app.fs.joinPath(pluginRef.path,"examples","plasma.frag"), filetypes={"frag","glsl","json","zip","txt"}}
  dialog:entry{id="url", label="URL", text=prefs.url or "", visible=false}
  dialog:entry{id="textureDirectory", label="Texture assets", text=prefs.textureDirectory or ""}
  dialog:number{id="fps", label="FPS", text=tostring(prefs.fps or 30), decimals=3, onchange=estimate}
  dialog:number{id="seconds", label="Duration (s)", text=tostring(prefs.seconds or 2), decimals=3, onchange=estimate}
  dialog:number{id="startTime", label="Start time (s)", text=tostring(prefs.startTime or 0), decimals=3}
  dialog:combobox{id="where", label="Insert at", options={"Current frame", "End of timeline"}}
  dialog:entry{id="layerName", label="Layer name", text=prefs.layerName or "Shadertoy"}
  dialog:check{id="snapshot", text="Use current canvas as Image.iChannel0", selected=false}
  dialog:newrow()
  dialog:check{id="opaque", text="Force opaque output", selected=prefs.opaque ~= false}
  dialog:label{id="estimate", label="Output", text=""}
  dialog:newrow()
  dialog:label{text="FPS changes frame duration for all layers in the output range."}
  dialog:newrow()
  dialog:label{text="URL mode requires SHADERTOY_API_KEY."}
  dialog:separator{}
  dialog:label{id="status", label="Status", text="Ready"}
  dialog:button{id="render", text="Render to New Layer", onclick=function()
    if session then return end
    local view = dialog
    local data, sprite = dialog.data, app.activeSprite
    data.source = data.kind == "Local file" and data.file or data.url
    data.first = sprite and (data.where == "End of timeline" and #sprite.frames + 1 or app.activeFrame.frameNumber) or 1
    data.snapshotFrame = app.activeFrame and app.activeFrame.frameNumber or 1
    local ok, err = pcall(function()
      worker.validate(sprite, data)
      local run = {view=view}
      session = run
      busy(true); dialog:modify{id="status", text="Starting renderer..."}
      -- Defer launch until after the dialog's busy state is painted.
      run.timer = Timer{interval=0.1, ontick=function()
        if session ~= run or run.inTick then return end
        run.inTick = true
        -- Stop BEFORE any file/execute permission prompt, alert or import.
        -- Those host APIs can run a nested event loop and re-enter ontick.
        run.timer:stop()
        local success, problem = pcall(function()
          if not run.job then
            local job = worker.start(pluginRef.path, sprite, data)
            if session ~= run then worker.release(job); return end
            run.job = job
            for _, key in ipairs({"file","url","textureDirectory","fps","seconds","startTime","layerName","opaque"}) do prefs[key] = data[key] end
            return
          end
          local complete, rendered = worker.poll(run.job)
          if session ~= run then return end
          view:modify{id="status", text=string.format("Rendering %d / %d", rendered, run.job.count)}
          if complete then
            local count = run.job.count
            view:modify{id="status", text="Importing cels..."}
            worker.import(run.job)
            if session ~= run then return end
            stopJob(); busy(false)
            view:modify{id="status", text="Done: " .. count .. " frames (one undo)"}
          end
        end)
        run.inTick = false
        if session ~= run then return end
        if not success then
          stopJob(); busy(false)
          view:modify{id="status", text="Failed. No frames imported."}
          showError(problem)
        else
          run.timer:start()
        end
      end}
      run.timer:start()
    end)
    if not ok then stopJob(); busy(false); showError(err) end
  end}
  dialog:button{id="cancel", text="Cancel", enabled=false, onclick=function()
    stopJob(); busy(false); if dialog then dialog:modify{id="status", text="Cancelled"} end
  end}
  dialog:button{text="Close", onclick=function() dialog:close() end}
  estimate()
  dialog:show{wait=false}
  local bounds = dialog.bounds
  if bounds.width > 720 then
    bounds.x = bounds.x + math.floor((bounds.width - 720) / 2)
    bounds.width = 720
    dialog.bounds = bounds
  end
end
function init(plugin)
  pluginRef = plugin
  worker = dofile(app.fs.joinPath(plugin.path, "render_job.lua"))
  plugin:newCommand{id="ShadertoyRender", title="Shadertoy…", group="edit_fx",
    onclick=openDialog, onenabled=function() return app.activeSprite ~= nil end}
end
function exit(plugin)
  if dialog then dialog:close() end
  stopJob()
  if worker then worker.shutdown() end
end
