param([switch]$SkipNativeBuild)
$ErrorActionPreference = 'Stop'
if (-not $SkipNativeBuild) { & (Join-Path $PSScriptRoot 'native/build.ps1') }
$worker = Join-Path $PSScriptRoot 'bin/win-x64/Aseprite.Shadertoy.exe'
if (-not (Test-Path -LiteralPath $worker)) { throw 'Build the native worker first' }
$dist = Join-Path $PSScriptRoot 'dist'
New-Item -ItemType Directory -Force -Path $dist | Out-Null
$archivePath = Join-Path $dist 'aseprite-shadertoy.aseprite-extension'
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$stream = [IO.File]::Open($archivePath,[IO.FileMode]::Create)
try {
    $archive = [IO.Compression.ZipArchive]::new($stream,[IO.Compression.ZipArchiveMode]::Create)
    try {
        $names = @('package.json','main.lua','render_job.lua','README.md','LICENSE','THIRD-PARTY-NOTICES.md','bin/win-x64/Aseprite.Shadertoy.exe')
        foreach ($folder in @('examples','licenses')) {
            $names += Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot $folder) -File | ForEach-Object { $folder+'/'+$_.Name }
        }
        foreach ($name in $names) {
            [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive,(Join-Path $PSScriptRoot $name),$name,[IO.Compression.CompressionLevel]::Optimal) | Out-Null
        }
    } finally { $archive.Dispose() }
} finally { $stream.Dispose() }
Write-Output $archivePath
