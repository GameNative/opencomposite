param(
    [string]$VulkanSdk = $env:VULKAN_SDK,
    [string]$WorkDirectory = (Join-Path $PSScriptRoot "build"),
    [string]$Version = "dev",
    [ValidateSet("x64", "x86")]
    [string]$Arch = "x64"
)

$ErrorActionPreference = "Stop"
$commit = (Get-Content -LiteralPath (Join-Path $PSScriptRoot "UPSTREAM_COMMIT")).Trim()
$patch = Join-Path $PSScriptRoot "patches\background-support.patch"
$interfacePatch = Join-Path $PSScriptRoot "patches\openvr-2.15.6-interfaces.patch"
$openvrHeaderCommit = "0924064316de3effbcd1acf1e309182a2deb1c05"
$openvrHeaderSha256 = "1e6ed57199896cc1f7c5484e50fa18955e97be15be690beb28d998c877ead7fd"
$marker = "Ignoring VRApplication_Background: no shared OpenVR server is available"
$source = Join-Path $WorkDirectory "source"
$build = Join-Path $WorkDirectory "cmake-$Arch"
$output = Join-Path $WorkDirectory "out"

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

New-Item -ItemType Directory -Force -Path $WorkDirectory, $output | Out-Null
if (-not (Test-Path -LiteralPath (Join-Path $source ".git") -PathType Container)) {
    git clone https://gitlab.com/znixian/OpenOVR.git $source
    if ($LASTEXITCODE -ne 0) { throw "Could not clone OpenComposite" }
}
git -C $source fetch origin $commit
if ($LASTEXITCODE -ne 0) { throw "Could not fetch OpenComposite commit $commit" }
git -C $source checkout --detach --force $commit
if ($LASTEXITCODE -ne 0) { throw "Could not check out OpenComposite commit $commit" }
git -C $source submodule update --init --recursive
if ($LASTEXITCODE -ne 0) { throw "Could not initialize OpenComposite submodules" }
git -C $source reset --hard $commit
git -C $source clean -dffx
git -C $source apply --check $patch
if ($LASTEXITCODE -ne 0) { throw "The patch no longer applies to $commit" }
git -C $source apply $patch
if ($LASTEXITCODE -ne 0) { throw "Could not apply the patch" }
git -C $source apply $interfacePatch
if ($LASTEXITCODE -ne 0) { throw "Could not apply the OpenVR 2.15.6 interface patch" }
git -C $source apply (Join-Path $PSScriptRoot "patches\debug-input-log.patch")
if ($LASTEXITCODE -ne 0) { throw "Could not apply the debug input log patch" }
$openvrHeader = Join-Path $source "OpenVRHeaders\openvr-2.15.6.h"
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/ValveSoftware/openvr/$openvrHeaderCommit/headers/openvr.h" -OutFile $openvrHeader
if ((Get-FileHash -Algorithm SHA256 -LiteralPath $openvrHeader).Hash.ToLowerInvariant() -ne $openvrHeaderSha256) { throw "OpenVR 2.15.6 header checksum mismatch" }

$bundledVulkan = Join-Path $source "libs\vulkan"
New-Item -ItemType Directory -Force -Path (Join-Path $bundledVulkan "Include"), (Join-Path $bundledVulkan $libDir) | Out-Null
Copy-Item -Recurse -Force -Path (Join-Path $vulkanInclude "*") -Destination (Join-Path $bundledVulkan "Include")
Copy-Item -Force -LiteralPath $vulkanLibrary -Destination (Join-Path $bundledVulkan "$libDir\vulkan-1.lib")

$shortCommit = $commit.Substring(0, 7)
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
if (-not [System.Text.Encoding]::ASCII.GetString($bytes).Contains($marker)) { throw "Output does not contain the background-app patch" }
if ($Arch -eq "x86" -and [System.Text.Encoding]::ASCII.GetString($bytes).ToLowerInvariant().Contains("msvcp140.dll")) { throw "x86 output still imports msvcp140.dll" }

$destination = Join-Path $output "opencomposite_$Arch.dll"
Copy-Item -Force -LiteralPath $binary -Destination $destination
$hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $destination).Hash.ToLowerInvariant()
Set-Content -NoNewline -LiteralPath "$destination.sha256" -Value "$hash  opencomposite_$Arch.dll"
Write-Host "Built $destination"
Write-Host "sha256 $hash"
