# Builds the A2B Race release files into a2b-race/dist/:
#   a2brace_d3k1d.zip          the client mod (also works on its own in single-player: solo races)
#   A2BRace-Server-<ver>.zip   BeamMP server pack: Resources/Client + Resources/Server/A2BRace
param([string]$Version = "0.1.1")
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$dist = Join-Path $root 'dist'
$stage = Join-Path $root '.stage'
Remove-Item -Recurse -Force $stage -ErrorAction SilentlyContinue
Get-ChildItem $dist -File -ErrorAction SilentlyContinue | Remove-Item -Force
New-Item -ItemType Directory -Force $dist, $stage | Out-Null

# Zip a folder's contents with forward-slash entry names (Compress-Archive in Windows
# PowerShell writes backslashes, which unpack as literal file names on Linux).
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
function New-Zip([string]$folder, [string]$zipPath) {
  if (Test-Path $zipPath) { Remove-Item -Force $zipPath }
  $zip = [System.IO.Compression.ZipFile]::Open($zipPath, 'Create')
  try {
    Get-ChildItem -Recurse -File $folder | ForEach-Object {
      $rel = $_.FullName.Substring($folder.TrimEnd('\').Length + 1).Replace('\', '/')
      [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $_.FullName, $rel, 'Optimal')
    }
  } finally { $zip.Dispose() }
}

Write-Host "== client mod zip"
$modZip = Join-Path $dist 'a2brace_d3k1d.zip'
New-Zip "$root\mod" $modZip

Write-Host "== server pack"
$srv = Join-Path $stage 'server'
New-Item -ItemType Directory -Force "$srv\Resources\Client", "$srv\Resources\Server\A2BRace\lib" | Out-Null
Copy-Item $modZip "$srv\Resources\Client\"
Copy-Item "$root\beammp-server\A2BRace\main.lua" "$srv\Resources\Server\A2BRace\"
# The server runs the very same rules file as the client's solo mode.
Copy-Item "$root\mod\lua\ge\extensions\a2brace\core.lua" "$srv\Resources\Server\A2BRace\lib\core.lua"
Copy-Item "$root\README.md" "$srv\A2BRace-README.md"
New-Zip $srv "$dist\A2BRace-Server-$Version.zip"
Remove-Item -Recurse -Force $stage

Write-Host "== checksums"
Get-ChildItem $dist -File -Filter *.zip | ForEach-Object { "{0}  {1}" -f (Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLower(), $_.Name } | Set-Content "$dist\SHA256SUMS.txt" -Encoding ascii

Get-ChildItem $dist | Format-Table Name, @{n = 'KB'; e = { [math]::Round($_.Length / 1KB, 1) } } -AutoSize
