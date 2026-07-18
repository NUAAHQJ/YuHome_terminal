$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$faceDir = Join-Path $repoRoot 'entry/src/main/resources/rawfile/face'
$outDir = Join-Path $repoRoot 'entry/src/main/resources/rawfile/face_ncnn'
$pnnx = Join-Path $env:LOCALAPPDATA 'Programs/Python/Python314/Scripts/pnnx.exe'

if (!(Test-Path $pnnx)) {
  throw "pnnx.exe not found. Install it with: python -m pip install pnnx"
}

if (!(Test-Path $outDir)) {
  New-Item -ItemType Directory $outDir | Out-Null
}

Push-Location $repoRoot
try {
  & $pnnx (Join-Path $faceDir 'w600k_mbf.onnx') 'inputshape=[1,3,112,112]'
  Copy-Item (Join-Path $faceDir 'w600k_mbf.ncnn.param') (Join-Path $outDir 'w600k_mbf.ncnn.param') -Force
  Copy-Item (Join-Path $faceDir 'w600k_mbf.ncnn.bin') (Join-Path $outDir 'w600k_mbf.ncnn.bin') -Force
} finally {
  Pop-Location
}
