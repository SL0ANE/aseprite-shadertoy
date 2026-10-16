param([string]$Aseprite = 'D:/Steam/steamapps/common/Aseprite/Aseprite.exe')
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
& (Join-Path $PSScriptRoot 'worker.tests.ps1')
$output = Join-Path $PSScriptRoot ('output/aseprite-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $output -Force | Out-Null
$arguments = @('--batch','--script-param',('"root='+$root+'"'),'--script-param',('"output='+$output+'"'),'--script',('"'+(Join-Path $PSScriptRoot 'aseprite.tests.lua')+'"'))
$process = Start-Process -FilePath $Aseprite -ArgumentList $arguments -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $output 'stdout.txt') -RedirectStandardError (Join-Path $output 'stderr.txt')
if (-not $process.WaitForExit(60000)) { $process.Kill(); throw 'Aseprite integration test timed out' }
$result = Get-Content -LiteralPath (Join-Path $output 'aseprite-result.txt') -Raw
if (-not $result.StartsWith('PASS:')) { throw $result }
Write-Output $result
Write-Output "Artifacts: $output"
& (Join-Path $PSScriptRoot 'lifetime.tests.ps1') -Aseprite $Aseprite
