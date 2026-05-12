using HAOSInstaller.Core.Models;
using HAOSInstaller.Core.Safety;
using HAOSInstaller.Core.Services;

namespace HAOSInstaller.Tests;

public sealed class SafeImageWriterTests
{
    [Fact]
    public async Task DeveloperFileTargetCopiesSourceImageWhenConfirmed()
    {
        var tempDirectory = Path.Combine(Path.GetTempPath(), "HAOSInstaller.Tests", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(tempDirectory);

        try
        {
            var sourcePath = Path.Combine(tempDirectory, "source.img");
            var outputPath = Path.Combine(tempDirectory, "target.img");
            await File.WriteAllBytesAsync(sourcePath, [1, 2, 3, 4, 5]);

            var writer = new SafeImageWriter(new DiskWriteGuard());
            var request = new ImageWriteRequest(
                new UsbDriveInfo("Developer file target", "File", null, outputPath, 0, true, false),
                sourcePath,
                DiskWriteMode.DeveloperFileTarget,
                DestructiveWriteConfirmed: true,
                outputPath);

            await writer.WriteAsync(request, new Progress<ImageWriteProgress>(), CancellationToken.None);

            Assert.True(File.Exists(outputPath));
            Assert.Equal(await File.ReadAllBytesAsync(sourcePath), await File.ReadAllBytesAsync(outputPath));
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
    public async Task PhysicalUsbWriteRequiresAdministratorPrivileges()
    {
        var tempDirectory = Path.Combine(Path.GetTempPath(), "HAOSInstaller.Tests", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(tempDirectory);
        var sourcePath = Path.Combine(tempDirectory, "source.img");
        await File.WriteAllBytesAsync(sourcePath, [1, 2, 3, 4, 5]);

        var writer = new SafeImageWriter(new DiskWriteGuard());
        var request = new ImageWriteRequest(
            new UsbDriveInfo("USB", "USB", "E:", @"\\.\PhysicalDrive9", 8UL * 1024 * 1024 * 1024, true, false),
            sourcePath,
            DiskWriteMode.PhysicalUsb,
            DestructiveWriteConfirmed: true);

        try
        {
            if (!IsRunningAsAdministrator())
            {
                await Assert.ThrowsAsync<InvalidOperationException>(
                    () => writer.WriteAsync(request, new Progress<ImageWriteProgress>(), CancellationToken.None));
            }
        }
        finally
        {
            Directory.Delete(tempDirectory, recursive: true);
        }
    }

    private static bool IsRunningAsAdministrator()
    {
        if (!OperatingSystem.IsWindows())
        {
            return false;
        }

        using var identity = System.Security.Principal.WindowsIdentity.GetCurrent();
        return new System.Security.Principal.WindowsPrincipal(identity)
            .IsInRole(System.Security.Principal.WindowsBuiltInRole.Administrator);
    }
}
