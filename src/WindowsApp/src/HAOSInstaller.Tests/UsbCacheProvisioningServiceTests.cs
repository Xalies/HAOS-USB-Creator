using HAOSInstaller.Core.Models;
using HAOSInstaller.Core.Services;

namespace HAOSInstaller.Tests;

public sealed class UsbCacheProvisioningServiceTests
{
    [Fact]
    public async Task ProvisionAsyncCopiesStagedPayloadIntoUsbCacheFolder()
    {
        var tempDirectory = Path.Combine(Path.GetTempPath(), "HAOSInstaller.Tests", Guid.NewGuid().ToString("N"));
        var stagedDirectory = Path.Combine(tempDirectory, "staged");
        var usbRoot = Path.Combine(tempDirectory, "usb");
        Directory.CreateDirectory(stagedDirectory);

        try
        {
            var imagePath = Path.Combine(stagedDirectory, "haos_generic-x86-64-17.3.img.xz");
            var checksumPath = Path.Combine(stagedDirectory, "haos_generic-x86-64-17.3.img.xz.sha256");
            var manifestPath = Path.Combine(stagedDirectory, "manifest.json");

            await File.WriteAllTextAsync(imagePath, "payload");
            await File.WriteAllTextAsync(checksumPath, "hash  haos_generic-x86-64-17.3.img.xz");
            await File.WriteAllTextAsync(manifestPath, "{}");

            var stagedPayload = new HaosPayloadStageResult(stagedDirectory, imagePath, checksumPath, manifestPath);
            var result = await new UsbCacheProvisioningService().ProvisionAsync(
                stagedPayload,
                usbRoot,
                new Progress<ImageWriteProgress>(),
                CancellationToken.None);

            Assert.True(File.Exists(result.ImagePath));
            Assert.True(File.Exists(result.ChecksumPath));
            Assert.True(File.Exists(result.ManifestPath));
            Assert.Equal(Path.Combine(usbRoot, "cache"), result.CacheDirectory);
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
    public async Task WriteInstallerConfigAsyncWritesUnattendedChoice()
    {
        var tempDirectory = Path.Combine(Path.GetTempPath(), "HAOSInstaller.Tests", Guid.NewGuid().ToString("N"));

        try
        {
            await new UsbCacheProvisioningService().WriteInstallerConfigAsync(
                tempDirectory,
                unattendedInstallEnabled: true,
                legacyBiosBootEnabled: true,
                sshPassword: "test-password",
                CancellationToken.None);

            var configPath = Path.Combine(tempDirectory, "cache", "installer-config.json");
            var configJson = await File.ReadAllTextAsync(configPath);

            Assert.Contains("\"enabled\": true", configJson);
            Assert.Contains("\"mode\": \"first-available-single-disk\"", configJson);
            Assert.Contains("\"runOnce\": true", configJson);
            Assert.Contains("\"ssh\"", configJson);
            Assert.Contains("\"password\": \"test-password\"", configJson);
            Assert.Contains("\"legacyBiosBoot\"", configJson);
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
