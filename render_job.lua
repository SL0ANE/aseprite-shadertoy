-- One isolated directory per render. Only complete results are imported.
local M = {}
local pending, reaper, reaping = {}, nil, false
local function read(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local bytes = f:read("*a"); f:close(); return bytes
end
local function write(path, bytes)
  local f = assert(io.open(path, "wb")); assert(f:write(bytes)); f:close()
end
local function quote(value) return "'" .. value:gsub("'", "''") .. "'" end
local function encodedCommand(value)
  local utf16 = {}
  for _, cp in utf8.codes(value) do
    if cp > 0xffff then
      cp = cp - 0x10000
      utf16[#utf16+1] = string.pack("<I2I2", 0xd800 + (cp >> 10), 0xdc00 + (cp & 1023))
    else utf16[#utf16+1] = string.pack("<I2", cp) end
  end
  local bytes, result = table.concat(utf16), {}
  local alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
  for i = 1, #bytes, 3 do
    local a,b,c = bytes:byte(i,i+2)
    local bits = (a << 16) | ((b or 0) << 8) | (c or 0)
    for shift = 18, 0, -6 do
      local n = ((bits >> shift) & 63) + 1
      result[#result+1] = alphabet:sub(n,n)
    end
    if not c then result[#result] = "=" end
    if not b then result[#result-1] = "=" end
  end
  return table.concat(result)
end
M.encodedCommand = encodedCommand

local files = {"request.json", "snapshot.rgba", "permit", "owned", "exited", "launch.done", "launch.error",
  "status.json", "status.json.tmp", "result.json", "result.json.tmp", "frames.rgba", "frames.rgba.part",
  "frames.graya", "frames.graya.part", "frames.indexed", "frames.indexed.part"}
local function cleanup(job)
  for _, name in ipairs(files) do pcall(os.remove, app.fs.joinPath(job.directory, name)) end
  pcall(app.fs.removeDirectory, job.directory)
end
local function retire(job)
  if job.retired then return end
  job.retired = true
  pcall(os.remove, app.fs.joinPath(job.directory, "permit"))
  pending[#pending+1] = job
  if reaper then return end
  reaper = Timer{interval=0.25, ontick=function()
    if reaping or not reaper then return end
    reaping = true
    local current = reaper
    current:stop()
    for i = #pending, 1, -1 do
      local item = pending[i]
      local done = app.fs.isFile(app.fs.joinPath(item.directory, "launch.done"))
      if done then item.doneAt = item.doneAt or os.time() end
      -- Wait for the launcher's finally marker plus a grace interval before pclose.
      if item.doneAt and os.time() - item.doneAt >= 1 then
        if item.pipe then pcall(function() item.pipe:close() end); item.pipe = nil end
        local exited = app.fs.isFile(app.fs.joinPath(item.directory, "exited"))
        if exited or not app.fs.isFile(app.fs.joinPath(item.directory, "owned")) then
          cleanup(item); table.remove(pending, i)
        end
      end
    end
    reaping = false
    if reaper ~= current then return end
    if #pending == 0 then reaper = nil else current:start() end
  end}
  reaper:start()
end

local function paletteFrame(palette)
  local frame = palette.frame
  return type(frame) == "number" and frame or frame.frameNumber
end
local function paletteAt(sprite, frame)
  local selected = sprite.palettes[1]
  for i = 1, #sprite.palettes do
    local palette = sprite.palettes[i]
    if paletteFrame(palette) <= frame and paletteFrame(palette) >= paletteFrame(selected) then selected = palette end
  end
  return selected
end
local function paletteData(palette)
  assert(palette and #palette >= 1 and #palette <= 256, "Indexed output requires 1-256 palette colors.")
  local colors, bytes = {}, {}
  for i = 0, #palette - 1 do
    local c = palette:getColor(i)
    colors[#colors+1] = {c.red, c.green, c.blue, c.alpha}
    bytes[#bytes+1] = string.char(c.red, c.green, c.blue, c.alpha)
  end
  return colors, table.concat(bytes)
end
local function paletteStamp(sprite)
  local parts = {tostring(sprite.transparentColor)}
  for i = 1, #sprite.palettes do
    local palette = sprite.palettes[i]
    local _, bytes = paletteData(palette)
    parts[#parts+1] = tostring(paletteFrame(palette)) .. ":" .. #bytes .. ":" .. bytes
  end
  return table.concat(parts, "|")
end

function M.validate(sprite, data)
  assert(sprite, "Open a sprite first.")
  assert(sprite.colorMode == ColorMode.RGB or sprite.colorMode == ColorMode.GRAY or sprite.colorMode == ColorMode.INDEXED, "Unsupported sprite color mode.")
  local fps, seconds, start = tonumber(data.fps), tonumber(data.seconds), tonumber(data.startTime)
  assert(fps and fps == fps and fps >= 1 and fps <= 1000, "FPS must be between 1 and 1000.")
  assert(seconds and seconds == seconds and seconds > 0 and seconds <= 3600, "Duration must be greater than 0 and at most 3600 seconds.")
  assert(start and start == start and start >= 0 and start <= 86400, "Start time must be between 0 and 86400 seconds.")
  local count = math.floor(fps * seconds + 0.5)
  assert(count >= 1 and count <= 10000, "Frame count must be 1-10000 (rounded FPS x duration).")
  assert(sprite.width <= 8192 and sprite.height <= 8192, "Canvas size cannot exceed 8192 x 8192.")
  assert(sprite.width * sprite.height * 4 * count <= 512 * 1024 * 1024, "Output exceeds 512 MiB. Reduce canvas size, FPS, or duration.")
  assert(type(data.source) == "string" and data.source ~= "", "Select a shader file or enter a Shadertoy URL.")
  local request = {width=sprite.width, height=sprite.height, fps=fps, seconds=seconds, startTime=start,
    source=data.source, textureDirectory=data.textureDirectory or "", opaque=data.opaque ~= false,
    outputMode=sprite.colorMode == ColorMode.INDEXED and "indexed" or sprite.colorMode == ColorMode.GRAY and "gray" or "rgb"}
  if request.outputMode == "indexed" then
    local first = data.first or 1
    local palette = paletteAt(sprite, data.snapshotFrame or first)
    local colors, bytes = paletteData(palette)
    request.palette, request.transparentIndex = colors, sprite.transparentColor
    local opaqueColor = false
    for i, c in ipairs(colors) do if i-1 ~= request.transparentIndex and c[4] == 255 then opaqueColor = true end end
    assert(not request.opaque or opaqueColor, "Force opaque output requires an opaque, non-transparent palette entry.")
    -- Avoid changing existing per-frame palettes or importing wrongly colored indexes.
    local _, firstBytes = paletteData(paletteAt(sprite, first))
    assert(firstBytes == bytes, "The output range must use the current palette. Select a matching frame and render again.")
    for i = 1, #sprite.palettes do
      local p = sprite.palettes[i]
      if paletteFrame(p) > first and paletteFrame(p) < first + count then
        local _, otherBytes = paletteData(p)
        assert(otherBytes == bytes, "The output range contains different palettes. Render each palette range separately.")
      end
    end
  end
  return request, count
end

function M.start(pluginPath, sprite, data)
  assert(app.os.name == "Windows", "The bundled renderer supports Windows x64 only.")
  local request, count = M.validate(sprite, data)
  local executable = app.fs.joinPath(pluginPath, "bin", "win-x64", "Aseprite.Shadertoy.exe")
  assert(app.fs.isFile(executable), "Renderer not found. Run native/build.ps1 or install the complete extension.")
  local job = {sprite=sprite, width=sprite.width, height=sprite.height, count=count, fps=request.fps,
    first=data.first, layerName=data.layerName, originalFrames=#sprite.frames, started=os.time(), lastProgress=os.time()}
  job.colorMode, job.outputMode = sprite.colorMode, request.outputMode
  job.bytesPerPixel = request.outputMode == "indexed" and 1 or request.outputMode == "gray" and 2 or 4
  job.frameFile = request.outputMode == "indexed" and "frames.indexed" or request.outputMode == "gray" and "frames.graya" or "frames.rgba"
  if request.outputMode == "indexed" then job.paletteStamp = paletteStamp(sprite) end
  job.directory = app.fs.joinPath(app.fs.tempPath, "aseprite-shadertoy-" .. tostring(Uuid()))
  app.fs.makeDirectory(job.directory)
  local ok, err = pcall(function()
    if data.snapshot then
      -- drawSprite resolves indexed palettes and grayscale to an RGBA snapshot.
      local image = Image(sprite.width, sprite.height, ColorMode.RGB)
      image:drawSprite(sprite, data.snapshotFrame)
      request.snapshot = app.fs.joinPath(job.directory, "snapshot.rgba")
      write(request.snapshot, image.bytes)
    end
    write(app.fs.joinPath(job.directory, "request.json"), json.encode(request))
    write(app.fs.joinPath(job.directory, "permit"), "1")
    local dir = quote(job.directory)
    local script = "$ErrorActionPreference='Stop'; $d=" .. dir .. "; try { if(Test-Path -LiteralPath (Join-Path $d 'permit')) { "
      .. "$p=Start-Process -WindowStyle Hidden -PassThru -FilePath " .. quote(executable)
      .. " -ArgumentList " .. quote('--job "' .. job.directory .. '"') .. "; "
      .. "$limit=[DateTime]::UtcNow.AddSeconds(20); while(-not $p.HasExited -and -not (Test-Path -LiteralPath (Join-Path $d 'owned')) -and [DateTime]::UtcNow -lt $limit){Start-Sleep -Milliseconds 20}; "
      .. "if(-not $p.HasExited -and -not (Test-Path -LiteralPath (Join-Path $d 'owned'))){$p.Kill(); throw 'Worker startup timed out'} "
      .. "} } catch { [IO.File]::WriteAllText((Join-Path $d 'launch.error'),$_.Exception.Message) } "
      .. "finally { [IO.File]::WriteAllText((Join-Path $d 'launch.done'),'1') }"
    job.pipe = assert(io.popen("powershell.exe -NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -EncodedCommand " .. encodedCommand(script), "r"))
  end)
  if not ok then
    if job.pipe then retire(job) else cleanup(job) end
    error(err)
  end
  return job
end

function M.poll(job)
  assert(not job.retired, "Task cancelled.")
  local path = function(name) return app.fs.joinPath(job.directory, name) end
  if job.lastHeartbeat ~= os.time() then write(path("permit"), "1"); job.lastHeartbeat = os.time() end
  local errorText = read(path("launch.error"))
  if errorText then error(errorText) end
  local bytes = read(path("result.json"))
  if bytes then
    local result = json.decode(bytes)
    assert(result.ok, result.error or "Rendering failed.")
    assert(result.frames == job.count and result.width == job.width and result.height == job.height, "Rendered dimensions or frame count do not match the request.")
    assert(result.outputMode == job.outputMode and result.bytesPerPixel == job.bytesPerPixel, "Rendered color mode does not match the request. Update the complete extension.")
    job.device = result.renderer
    return true, job.count
  end
  if app.fs.isFile(path("exited")) and not app.fs.isFile(path("result.json")) then error("Renderer exited early. Please try again.") end
  if os.time() - job.started > 30 and not app.fs.isFile(path("owned")) then error("Renderer startup timed out.") end
  local status = read(path("status.json"))
  local completed = status and json.decode(status).completed or 0
  if completed ~= job.completed then job.completed = completed; job.lastProgress = os.time() end
  assert(os.time() - job.lastProgress < 180, "No rendering progress for 180 seconds. Task stopped.")
  return false, completed
end

function M.import(job)
  assert(not job.retired, "Task cancelled. Import is not allowed.")
  local sprite = job.sprite
  local open = false
  for _, current in ipairs(app.sprites) do if current == sprite then open = true end end
  assert(open, "The original sprite was closed. Cannot import.")
  assert(sprite.width == job.width and sprite.height == job.height and sprite.colorMode == (job.colorMode or ColorMode.RGB),
    "Canvas size or color mode changed during rendering. Render again.")
  if job.paletteStamp then assert(paletteStamp(sprite) == job.paletteStamp, "Palette or transparent index changed during rendering. Render again.") end
  assert(not job.originalFrames or #sprite.frames == job.originalFrames, "Timeline frame count changed during rendering. Render again.")
  assert(job.first >= 1 and job.first <= #sprite.frames + 1, "The original timeline changed. Render again.")
  local frameBytes = job.width * job.height * (job.bytesPerPixel or 4)
  local f = assert(io.open(app.fs.joinPath(job.directory, job.frameFile or "frames.rgba"), "rb"))
  local layer
  local previousSprite = app.activeSprite
  app.activeSprite = sprite
  local ok, err = pcall(function()
    -- io.open can display a permission prompt, during which the user may cancel.
    assert(not job.retired, "Task cancelled. Import is not allowed.")
    if job.paletteStamp then assert(paletteStamp(sprite) == job.paletteStamp, "Palette or transparent index changed during rendering. Render again.") end
    assert(f:seek("end") == frameBytes * job.count, "Rendered frame data is incomplete.")
    f:seek("set", 0)
    -- One transaction provides one undo and rollback on any failed cel import.
    app.transaction("Import Shadertoy animation", function()
      while #sprite.frames < job.first + job.count - 1 do sprite:newEmptyFrame(#sprite.frames + 1) end
      layer = sprite:newLayer()
      layer.name = job.layerName ~= "" and job.layerName or "Shadertoy"
      for index = 0, job.count - 1 do
        local bytes = assert(f:read(frameBytes))
        assert(#bytes == frameBytes, "Failed to read frame data.")
        local image = Image(sprite.spec)
        image.bytes = bytes
        local frame = job.first + index
        -- Aseprite stores integer milliseconds. Distribute rounding error so
        -- 60 FPS uses 17/16/17 ms instead of accumulating 17 ms per frame.
        local a = math.floor(index * 1000 / job.fps + 0.5)
        local b = math.floor((index + 1) * 1000 / job.fps + 0.5)
        sprite.frames[frame].duration = (b - a) / 1000
        sprite:newCel(layer, frame, image, Point(0, 0))
      end
    end)
  end)
  f:close()
  if not ok then app.activeSprite = previousSprite; error(err) end
  app.activeSprite = sprite; app.activeLayer = layer; app.activeFrame = sprite.frames[job.first]
  app.refresh()
  return layer
end

M.release = retire
function M.shutdown()
  for _, job in ipairs(pending) do pcall(os.remove, app.fs.joinPath(job.directory, "permit")) end
  if reaper then reaper:stop(); reaper = nil end
  -- Launch scripts are bounded; only plugin unload can wait for their exit.
  for _, job in ipairs(pending) do
    if job.pipe then pcall(function() job.pipe:close() end) end
    if app.fs.isFile(app.fs.joinPath(job.directory, "exited")) then cleanup(job) end
  end
  pending = {}
end
return M
