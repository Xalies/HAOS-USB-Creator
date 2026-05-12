using HAOSInstaller.Core.Models;

namespace HAOSInstaller.Core.Services;

public sealed class StubUsbDriveService : IUsbDriveService
{
    public Task<IReadOnlyList<UsbDriveInfo>> GetRemovableDrivesAsync(CancellationToken cancellationToken)
    {
        IReadOnlyList<UsbDriveInfo> drives =
        [
            new UsbDriveInfo(
                DisplayName: "Developer test USB placeholder",
                Model: "Stub removable drive",
                DriveLetter: "T:",
                DevicePath: @"\\.\PhysicalDrive999",
                SizeBytes: 8UL * 1024 * 1024 * 1024,
                IsRemovable: true,
                IsSystemDisk: false)
        ];

        return Task.FromResult(drives);
    }
}
