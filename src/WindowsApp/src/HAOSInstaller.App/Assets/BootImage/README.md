# Bundled Boot Image

The Windows app expects the HAOS AIO Linux boot image to be placed here before publishing.

Expected files:

- `haos-installer-x86_64.img`
- `haos-installer-x86_64.img.sha256`
- `haos-installer-x86_64.img.manifest.json`

These generated files are intentionally ignored by git because the raw image is large. Build them locally with:

```powershell
powershell -ExecutionPolicy Bypass -File .\src\InstallerLinux\build\build-installer-image.ps1 -OutDir .\artifacts\installer-linux
```

Then copy the generated files into this folder before publishing the Windows app.
