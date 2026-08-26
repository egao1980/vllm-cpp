# Build mudler/vllm.cpp shared C ABI (vllm.dll) into lib/windows-amd64/.
# Published windows/amd64 overlay is CPU (MSVC /MT). CUDA Windows is not a
# vllm.cpp release target; if it ever is, it becomes THIS overlay (os-arch only).
# Env: VLLM_CPP_REF, DEST_DIR, JOBS
$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$Root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$Ref = if ($env:VLLM_CPP_REF) { $env:VLLM_CPP_REF } else { "master" }
$Jobs = if ($env:JOBS) { [int]$env:JOBS } else { [Environment]::ProcessorCount }
$SrcUrl = "https://github.com/mudler/vllm.cpp.git"
$Out = if ($env:DEST_DIR) { $env:DEST_DIR } else { Join-Path $Root "lib\windows-amd64" }
$Src = Join-Path $Root "build\vllm.cpp"
$Build = Join-Path $Root "build\windows-amd64-cpu"
$Inject = Join-Path $Root "scripts\windows-msvc-wholearchive.cmake"

New-Item -ItemType Directory -Force -Path (Join-Path $Root "build") | Out-Null
if (Test-Path (Join-Path $Src ".git")) {
    git -C $Src fetch --depth 1 origin $Ref
    if ($LASTEXITCODE -ne 0) { throw "git fetch failed: $LASTEXITCODE" }
    git -C $Src checkout --force FETCH_HEAD
    if ($LASTEXITCODE -ne 0) { throw "git checkout failed: $LASTEXITCODE" }
} else {
    if (Test-Path $Src) { Remove-Item -Recurse -Force $Src }
    git clone --depth 1 --branch $Ref $SrcUrl $Src
    if ($LASTEXITCODE -ne 0) {
        git clone --depth 1 $SrcUrl $Src
        if ($LASTEXITCODE -ne 0) { throw "git clone failed: $LASTEXITCODE" }
        git -C $Src checkout --force $Ref
        if ($LASTEXITCODE -ne 0) { throw "git checkout $Ref failed: $LASTEXITCODE" }
    }
}

Write-Host "==> cmake vllm.cpp $Ref flavor=cpu (MSVC /MT) -> $Out"
$cmakeArgs = @(
    "-S", $Src,
    "-B", $Build,
    "-G", "Visual Studio 17 2022",
    "-A", "x64",
    "-DCMAKE_PROJECT_INCLUDE=$Inject",
    "-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded",
    "-DBUILD_SHARED_LIBS=ON",
    "-DVLLM_CPP_BUILD_TESTS=OFF",
    "-DVLLM_CPP_BUILD_EXAMPLES=OFF",
    "-DVLLM_CPP_SERVER=OFF",
    "-DVLLM_CPP_CUDA=OFF",
    "-DVLLM_CPP_HIP=OFF",
    "-DVLLM_CPP_METAL=OFF",
    "-DVLLM_CPP_MLX=OFF",
    "-DVLLM_CPP_VULKAN=OFF",
    "-DVLLM_CPP_TRITON=OFF"
)
& cmake @cmakeArgs
if ($LASTEXITCODE -ne 0) { throw "cmake configure failed: $LASTEXITCODE" }

& cmake --build $Build --config Release --target vllm_shared --parallel $Jobs
if ($LASTEXITCODE -ne 0) { throw "cmake build failed: $LASTEXITCODE" }

$dll = $null
foreach ($cand in @(
        (Join-Path $Build "Release\vllm.dll"),
        (Join-Path $Build "vllm_shared\Release\vllm.dll"),
        (Join-Path $Build "Release\libvllm.dll")
    )) {
    if (Test-Path $cand) { $dll = $cand; break }
}
if (-not $dll) {
    $dll = Get-ChildItem -Path $Build -Recurse -File -Filter "vllm.dll" |
        Where-Object { $_.FullName -notmatch '[\\/](?:_deps|third_party|CMakeFiles)[\\/]' } |
        Select-Object -First 1 -ExpandProperty FullName
}
if (-not $dll) {
    Get-ChildItem -Path $Build -Recurse -File -Filter "*vllm*" | Select-Object -First 50 FullName
    throw "vllm.dll not found under $Build"
}

if (Test-Path $Out) { Remove-Item -Recurse -Force $Out }
New-Item -ItemType Directory -Force -Path $Out | Out-Null
Copy-Item -Force $dll (Join-Path $Out "vllm.dll")

Write-Host "staged:"
Get-ChildItem $Out | Format-Table Name, Length
