$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$nngDir = Join-Path $root 'entry/src/main/cpp/third_party/nanomq/nng'
$patchFile = Join-Path $root 'patches/nanonnng-handshake-lock.patch'

Push-Location $root
try {
    git submodule update --init --recursive

    git -C $nngDir apply --check $patchFile 2>$null
    if ($LASTEXITCODE -eq 0) {
        git -C $nngDir apply $patchFile
        Write-Host 'Applied NanoNNG TLS handshake lock patch.' -ForegroundColor Green
    } else {
        git -C $nngDir apply --reverse --check $patchFile 2>$null
        if ($LASTEXITCODE -eq 0) {
            Write-Host 'NanoNNG TLS handshake lock patch is already applied.' -ForegroundColor Green
        } else {
            throw 'NanoNNG source does not match the expected patch base.'
        }
    }
} finally {
    Pop-Location
}
