using System.Security.Cryptography;
using HAOSInstaller.Core.Services;

namespace HAOSInstaller.Tests;

public sealed class HaosInstallerBootImageServiceTests
{
    [Fact]
    public async Task LoadAsyncVerifiesSidecarChecksumWhenPresent()
    {
        var tempDirectory = Path.Combine(Path.GetTempPath(), "HAOSInstaller.Tests", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(tempDirectory);

        try
        {
            var imagePath = Path.Combine(tempDirectory, "haos-installer.img");
            await File.WriteAllTextAsync(imagePath, "installer");
            var hash = Convert.ToHexString(SHA256.HashData(await File.ReadAllBytesAsync(imagePath))).ToLowerInvariant();
            await File.WriteAllTextAsync($"{imagePath}.sha256", $"{hash}  haos-installer.img");

            var bootImage = await new HaosInstallerBootImageService(new Sha256Verifier())
                .LoadAsync(imagePath, new Progress<ImageWriteProgress>(), CancellationToken.None);

            Assert.True(bootImage.ChecksumVerified);
            Assert.Equal(hash, bootImage.Sha256);
            Assert.Equal(imagePath, bootImage.ImagePath);
            Assert.Equal("raw-usb-image", bootImage.Format);
        }
        finally
        {
            if (Directory.Exists(tempDirectory))
            {
                Directory.Delete(tempDirectory, recursive: true);
            }
        }
    }

    [Fact]
    public async Task LoadAsyncReadsBootImageManifestWhenPresent()
    {
        var tempDirectory = Path.Combine(Path.GetTempPath(), "HAOSInstaller.Tests", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(tempDirectory);

        try
        {
            var imagePath = Path.Combine(tempDirectory, "haos-installer-x86_64.img");
            await File.WriteAllTextAsync(imagePath, "raw usb image");
            var manifestPath = $"{imagePath}.manifest.json";
            await File.WriteAllTextAsync(manifestPath, """
            {
              "schemaVersion": 1,
              "artifactType": "haos_installer_boot",
              "format": "raw-usb-image",
              "filename": "haos-installer-x86_64.img",
              "sha256": null,
              "fileSizeBytes": 13,
              "builtAtUtc": "2026-05-10T00:00:00Z",
              "builder": "test"
            }
            """);

            var bootImage = await new HaosInstallerBootImageService(new Sha256Verifier())
                .LoadAsync(imagePath, null, CancellationToken.None);

            Assert.Equal(manifestPath, bootImage.ManifestPath);
            Assert.Equal("raw-usb-image", bootImage.Format);
        }
        finally
        {
            if (Directory.Exists(tempDirectory))
            {
                Directory.Delete(tempDirectory, recursive: true);
            }
        }
    }

    [Fact]
    public async Task TryFindLatestAsyncIgnoresTemporaryIsoAndUsesRawUsbImage()
    {
        var tempDirectory = Path.Combine(Path.GetTempPath(), "HAOSInstaller.Tests", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(tempDirectory);

        try
        {
            var ignoredPath = Path.Combine(tempDirectory, "ubuntu-live.iso");
            var temporaryIsoPath = Path.Combine(tempDirectory, "haos-installer-x86_64.iso");
            var rawUsbPath = Path.Combine(tempDirectory, "haos-installer-x86_64.img");
            await File.WriteAllTextAsync(ignoredPath, "ignored");
            await File.WriteAllTextAsync(temporaryIsoPath, "temporary iso");
            await File.WriteAllTextAsync(rawUsbPath, "raw usb image");
            File.SetLastWriteTimeUtc(ignoredPath, DateTime.UtcNow.AddHours(2));
            File.SetLastWriteTimeUtc(temporaryIsoPath, DateTime.UtcNow.AddHours(1));
            File.SetLastWriteTimeUtc(rawUsbPath, DateTime.UtcNow);

            var bootImage = await new HaosInstallerBootImageService(new Sha256Verifier())
                .TryFindLatestAsync([tempDirectory], null, CancellationToken.None);

            Assert.NotNull(bootImage);
            Assert.Equal(rawUsbPath, bootImage.ImagePath);
            Assert.Equal("raw-usb-image", bootImage.Format);
        }
        finally
        {
            if (Directory.Exists(tempDirectory))
            {
                Directory.Delete(tempDirectory, recursive: true);
            }
        }
    }

    [Fact]
    public async Task ValidateBundledBootImageAsyncRequiresManifestAndVerifiedChecksum()
    {
        var tempDirectory = Path.Combine(Path.GetTempPath(), "HAOSInstaller.Tests", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(tempDirectory);

        try
        {
            var imagePath = Path.Combine(tempDirectory, "haos-installer-x86_64.img");
            await File.WriteAllTextAsync(imagePath, "raw usb image");
            var hash = Convert.ToHexString(SHA256.HashData(await File.ReadAllBytesAsync(imagePath))).ToLowerInvariant();
            await File.WriteAllTextAsync($"{imagePath}.sha256", $"{hash}  haos-installer-x86_64.img");
            await File.WriteAllTextAsync($"{imagePath}.manifest.json", """
            {
              "schemaVersion": 1,
              "artifactType": "haos_installer_boot",
              "format": "raw-usb-image",
              "filename": "haos-installer-x86_64.img",
              "sha256": null,
              "fileSizeBytes": 13,
              "builtAtUtc": "2026-05-10T00:00:00Z",
              "builder": "test"
            }
            """);

            await new HaosInstallerBootImageService(new Sha256Verifier())
                .ValidateBundledBootImageAsync(tempDirectory, null, CancellationToken.None);
        }
        finally
        {
            if (Directory.Exists(tempDirectory))
            {
                Directory.Delete(tempDirectory, recursive: true);
            }
        }
    }
}
