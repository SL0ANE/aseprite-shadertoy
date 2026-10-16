param([string]$Aseprite='D:/Steam/steamapps/common/Aseprite/Aseprite.exe')
$ErrorActionPreference='Stop'
$root=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$output=Join-Path $PSScriptRoot ('output/lifetime-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $output | Out-Null
function Wait-File($Path) {
    $deadline=[DateTime]::UtcNow.AddSeconds(15)
    while(-not (Test-Path -LiteralPath $Path)) {
        if([DateTime]::UtcNow -gt $deadline) { throw "Timed out: $Path" }
        Start-Sleep -Milliseconds 20
    }
}
foreach($case in @('cancel','close','unload','owner-exit','owner-kill','heartbeat-expired','kill-during-launch')) {
    $dir=Join-Path $output $case
    New-Item -ItemType Directory -Path $dir | Out-Null
    [IO.File]::WriteAllText((Join-Path $dir 'slow.frag'), 'void mainImage(out vec4 c,in vec2 p){vec2 z=p/iResolution.xy; for(int i=0;i<500;i++) z=sin(z.yx*1.1+float(i)*0.001+iTime); c=vec4(z,0,1);}')
    $testHost=Start-Process -FilePath $Aseprite -WindowStyle Hidden -PassThru -ArgumentList @('--batch','--script-param',('"root='+$root+'"'),'--script-param',('"output='+$dir+'"'),'--script',('"'+(Join-Path $PSScriptRoot 'lifetime-host.lua')+'"')) -RedirectStandardOutput "$dir/out.log" -RedirectStandardError "$dir/err.log"
    $null=$testHost.Handle
    $worker=$null
    try {
        Wait-File "$dir/session.path"
        $job=[IO.File]::ReadAllText("$dir/session.path")
        if($case -eq 'kill-during-launch') {
            $testHost.Kill(); $testHost.WaitForExit()
            Wait-File (Join-Path $job 'launch.done')
            Start-Sleep -Milliseconds 500
            $survivors=@(Get-CimInstance Win32_Process -Filter "Name='Aseprite.Shadertoy.exe'" | Where-Object {$_.CommandLine -and $_.CommandLine.Contains($job)})
            if($survivors.Count) { throw 'Worker survived host exit during launch' }
            Write-Output 'PASS: kill-during-launch (no orphan worker)'
            continue
        }
        Wait-File (Join-Path $job 'owned')
        $worker=[Diagnostics.Process]::GetProcessById([int][IO.File]::ReadAllText((Join-Path $job 'owned')))
        $null=$worker.Handle
        if($worker.HasExited) { throw 'Worker finished before lifecycle test' }
        $watch=[Diagnostics.Stopwatch]::StartNew()
        switch($case) {
            'owner-kill' { $testHost.Kill(); $testHost.WaitForExit() }
            'owner-exit' {
                [IO.File]::WriteAllText("$dir/action",'exit')
                if(-not $testHost.WaitForExit(3000) -or $testHost.ExitCode -ne 0) { throw 'Host did not exit normally' }
            }
            'heartbeat-expired' { [IO.File]::SetLastWriteTimeUtc((Join-Path $job 'permit'),[DateTime]::UtcNow.AddSeconds(-61)) }
            default { [IO.File]::WriteAllText("$dir/action",$case); Wait-File "$dir/handled" }
        }
        if(-not $worker.WaitForExit(3000)) { throw "$case left the renderer running" }
        if($worker.ExitCode -ne 3) { throw "$case did not trigger lifetime guard: exit $($worker.ExitCode)" }
        if($case -in @('cancel','close','unload','heartbeat-expired') -and $testHost.HasExited) { throw 'Closing a job must not close Aseprite' }
        Wait-File (Join-Path $job 'launch.done')
        Write-Output ("PASS: {0}, worker exited in {1} ms (code {2})" -f $case,$watch.ElapsedMilliseconds,$worker.ExitCode)
    } finally {
        if(-not $testHost.HasExited) { $testHost.Kill(); $testHost.WaitForExit() }
        if($worker -and -not $worker.HasExited) { $worker.Kill(); $worker.WaitForExit() }
    }
}
Write-Output "Lifetime artifacts: $output"
