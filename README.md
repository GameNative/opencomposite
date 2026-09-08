# opencomposite

GameNative's build of [OpenComposite](https://gitlab.com/znixian/OpenOVR) for OpenVR games running under Wine on Quest.

Every release is built by GitHub Actions on a Windows runner from the upstream commit in `UPSTREAM_COMMIT` with the patches in `patches/` applied. The GameNative app downloads `opencomposite_x64.dll` from a pinned release and verifies its SHA-256, so the shipped binary always traces back to a CI run.

## Patches

- `background-support.patch`: on Windows, `VR_Init` with `VRApplication_Background` returns `VRInitError_Init_NoServerForBackgroundApp` instead of aborting. GameNative embeds OpenComposite in each Wine process and has no shared vrserver, so helper processes that use the background app type must not open a competing OpenXR session. Also adds the `<chrono>` include current MSVC needs to compile `XrHMD.cpp`.

## Releasing

1. Change `UPSTREAM_COMMIT` or `patches/` as needed and merge to `main`. Every push builds and uploads the DLL as a workflow artifact.
2. Tag the commit: `git tag v1 && git push origin v1`. The workflow builds again and publishes a GitHub release with the DLL and its `.sha256`.
3. Point the GameNative staging scripts at the release URL and update the pinned hash.

## Building locally

Needs Windows, Visual Studio 2022 with the C++ workload, CMake, Git, and the Vulkan SDK.

```powershell
.\build.ps1 -VulkanSdk C:\VulkanSDK\1.3.296.0
```

Output lands in `build\out\`. MSVC builds are not bit-for-bit reproducible across machines, so a local hash will not match the release hash. Ship the release one.

## License

OpenComposite is GPL-3.0. The binaries in releases are built from the pinned upstream commit plus the patches in this repository, which together are the corresponding source.
