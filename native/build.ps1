$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
git -C $root submodule update --init --recursive
if ($LASTEXITCODE -ne 0) { throw 'Shaderlens checkout failed' }
dotnet publish (Join-Path $PSScriptRoot 'ShaderWorker/ShaderWorker.csproj') -c Release -r win-x64 --self-contained true -p:EnableVersion=false -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -p:EnableCompressionInSingleFile=true -o (Join-Path $root 'bin/win-x64')
if ($LASTEXITCODE -ne 0) { throw 'Shader worker build failed' }
