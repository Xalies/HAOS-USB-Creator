using HAOSInstaller.Core.Models;
using HAOSInstaller.Core.Safety;

namespace HAOSInstaller.Tests;

public sealed class DiskWriteGuardTests
{
    private static readonly UsbDriveInfo RemovableDrive = new(
        "USB",
        "Test USB",
        "E:",
        @"\\.\PhysicalDrive9",
        8UL * 1024 * 1024 * 1024,
        IsRemovable: true,
        IsSystemDisk: false);

    [Fact]
    public void PhysicalUsbWriteRequiresExplicitConfirmation()
    {
        var approval = new DiskWriteGuard().Evaluate(RemovableDrive, DiskWriteMode.PhysicalUsb, destructiveWriteConfirmed: false);

        Assert.False(approval.IsApproved);
    }

    [Fact]
    public void PhysicalUsbWriteRejectsFixedDisk()
    {
        var fixedDisk = RemovableDrive with { IsRemovable = false };

        var approval = new DiskWriteGuard().Evaluate(fixedDisk, DiskWriteMode.PhysicalUsb, destructiveWriteConfirmed: true);

        Assert.False(approval.IsApproved);
    }

    [Fact]
    public void DryRunAllowsInspectionWithoutConfirmation()
    {
        var approval = new DiskWriteGuard().Evaluate(RemovableDrive, DiskWriteMode.DryRun, destructiveWriteConfirmed: false);

        Assert.True(approval.IsApproved);
    }

    [Fact]
    public void PhysicalUsbWriteRejectsLargeUsbByDefault()
    {
        var largeUsb = RemovableDrive with { SizeBytes = 1024UL * 1024 * 1024 * 1024 };

        var approval = new DiskWriteGuard().Evaluate(largeUsb, DiskWriteMode.PhysicalUsb, destructiveWriteConfirmed: true);

        Assert.False(approval.IsApproved);
    }
}
