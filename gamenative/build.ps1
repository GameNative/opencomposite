param(
    [string]$VulkanSdk = $env:VULKAN_SDK,
    [string]$Version = "dev",
    [ValidateSet("x64", "x86")]
    [string]$Arch = "x64"
)

$ErrorActionPreference = "Stop"
$source = Split-Path -Parent $PSScriptRoot
$work = Join-Path $source "build"
$build = Join-Path $work "cmake-$Arch"
$output = Join-Path $work "out"
$marker = "Ignoring VRApplication_Background: no shared OpenVR server is available"

if ([string]::IsNullOrWhiteSpace($VulkanSdk)) {
    throw "Set VULKAN_SDK or pass -VulkanSdk. OpenComposite needs Vulkan headers and the vulkan-1.lib import library."
}
$vulkanInclude = Join-Path $VulkanSdk "Include"
$libDir = if ($Arch -eq "x64") { "Lib" } else { "Lib32" }
$vulkanLibrary = Join-Path $VulkanSdk "$libDir\vulkan-1.lib"
if (-not (Test-Path -LiteralPath (Join-Path $vulkanInclude "vulkan\vulkan.h") -PathType Leaf)) {
    throw "Vulkan headers were not found under $vulkanInclude"
}
if (-not (Test-Path -LiteralPath $vulkanLibrary -PathType Leaf)) {
    throw "Vulkan import library was not found at $vulkanLibrary"
}
if (-not (Test-Path -LiteralPath (Join-Path $source "libs\openxr-sdk\CMakeLists.txt") -PathType Leaf)) {
    git -C $source submodule update --init --recursive
    if ($LASTEXITCODE -ne 0) { throw "Could not initialize OpenComposite submodules" }
}

New-Item -ItemType Directory -Force -Path $work, $output | Out-Null
$bundledVulkan = Join-Path $source "libs\vulkan"
New-Item -ItemType Directory -Force -Path (Join-Path $bundledVulkan "Include"), (Join-Path $bundledVulkan $libDir) | Out-Null
Copy-Item -Recurse -Force -Path (Join-Path $vulkanInclude "*") -Destination (Join-Path $bundledVulkan "Include")
Copy-Item -Force -LiteralPath $vulkanLibrary -Destination (Join-Path $bundledVulkan "$libDir\vulkan-1.lib")

$shortCommit = (git -C $source rev-parse --short=7 HEAD).Trim()
if ($LASTEXITCODE -ne 0) { throw "Could not read the source commit" }
$platform = if ($Arch -eq "x64") { "x64" } else { "Win32" }
$runtime = if ($Arch -eq "x64") { "MultiThreadedDLL" } else { "MultiThreaded" }
cmake -S $source -B $build -A $platform -DCMAKE_MSVC_RUNTIME_LIBRARY="$runtime" -DOC_VERSION="$shortCommit-gamenative-$Version"
if ($LASTEXITCODE -ne 0) { throw "Could not configure OpenComposite" }
cmake --build $build --config Release --target OCOVR --parallel
if ($LASTEXITCODE -ne 0) { throw "Could not build OpenComposite" }

$clientName = if ($Arch -eq "x64") { "vrclient_x64.dll" } else { "vrclient.dll" }
$machine = if ($Arch -eq "x64") { 0x8664 } else { 0x14c }
$binary = Join-Path $build "bin\Release\$clientName"
if (-not (Test-Path -LiteralPath $binary -PathType Leaf)) { throw "OpenComposite output is missing: $binary" }
$bytes = [System.IO.File]::ReadAllBytes($binary)
$offset = [BitConverter]::ToInt32($bytes, 0x3c)
if ([BitConverter]::ToUInt16($bytes, $offset + 4) -ne $machine) { throw "Output is not $Arch" }
if (-not [System.Text.Encoding]::ASCII.GetString($bytes).Contains($marker)) { throw "Output does not contain the background-app change" }
if ($Arch -eq "x86" -and [System.Text.Encoding]::ASCII.GetString($bytes).ToLowerInvariant().Contains("msvcp140.dll")) { throw "x86 output still imports msvcp140.dll" }

$destination = Join-Path $output "opencomposite_$Arch.dll"
Copy-Item -Force -LiteralPath $binary -Destination $destination
$hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $destination).Hash.ToLowerInvariant()
Set-Content -NoNewline -LiteralPath "$destination.sha256" -Value "$hash  opencomposite_$Arch.dll"
Write-Host "Built $destination"
Write-Host "sha256 $hash"
