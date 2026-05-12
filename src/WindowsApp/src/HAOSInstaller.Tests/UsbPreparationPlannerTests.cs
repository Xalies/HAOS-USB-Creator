using HAOSInstaller.Core.Models;
using HAOSInstaller.Core.Services;

namespace HAOSInstaller.Tests;

public sealed class UsbPreparationPlannerTests
{
    [Fact]
    public async Task CreatePlanRequiresBootImageToExist()
    {
        var target = new UsbDriveInfo("USB", "USB", "E:", @"\\.\PhysicalDrive9", 1024, true, false);
        var installer = new HaosInstallerBootImage(
            Path.Combine(Path.GetTempPath(), "missing-haos-installer.img"),
            null,
            null,
            null,
            0,
            ChecksumVerified: false,
            "raw-usb-image");

        await Task.CompletedTask;

        Assert.Throws<FileNotFoundException>(() => new UsbPreparationPlanner().CreatePlan(
            target,
            installer,
            stagedPayload: null,
            cacheDestinationRoot: "cache",
            isDeveloperTarget: false));
    }

    [Fact]
    public async Task BuildSummaryShowsOnlyUserActionableReviewDetails()
    {
        var tempDirectory = Path.Combine(Path.GetTempPath(), "HAOSInstaller.Tests", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(tempDirectory);

        try
        {
            var installerPath = Path.Combine(tempDirectory, "haos-installer.img");
            var payloadPath = Path.Combine(tempDirectory, "haos_generic-x86-64-17.3.img.xz");
            var checksumPath = Path.Combine(tempDirectory, "haos_generic-x86-64-17.3.img.xz.sha256");
            var manifestPath = Path.Combine(tempDirectory, "manifest.json");

            await File.WriteAllTextAsync(installerPath, "installer");
            await File.WriteAllTextAsync(payloadPath, "payload");
            await File.WriteAllTextAsync(checksumPath, "hash payload");
            await File.WriteAllTextAsync(manifestPath, "{}");

            var target = new UsbDriveInfo("USB", "USB", "E:", @"\\.\PhysicalDrive9", 1024, true, false);
            var installer = new HaosInstallerBootImage(installerPath, null, null, null, 9, ChecksumVerified: true, "raw-usb-image");
            var stagedPayload = new HaosPayloadStageResult(tempDirectory, payloadPath, checksumPath, manifestPath);

            var plan = new UsbPreparationPlanner().CreatePlan(
                target,
                installer,
                stagedPayload,
                cacheDestinationRoot: Path.Combine(tempDirectory, "usb-cache"),
                isDeveloperTarget: false);

            var summary = UsbPreparationPlanner.BuildSummary(plan);

            Assert.Contains(@"\\.\PhysicalDrive9", summary);
            Assert.Contains("Model: USB", summary);
            Assert.Contains("HAOS payload: cached and ready", summary);
            Assert.DoesNotContain("Mode:", summary);
            Assert.DoesNotContain("Physical USB write", summary);
            Assert.DoesNotContain("HAOS Installer boot image:", summary);
            Assert.DoesNotContain("raw-usb-image", summary);
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
