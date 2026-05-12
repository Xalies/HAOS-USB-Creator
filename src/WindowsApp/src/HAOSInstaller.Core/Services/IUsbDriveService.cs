using HAOSInstaller.Core.Models;

namespace HAOSInstaller.Core.Services;

public interface IUsbDriveService
{
    Task<IReadOnlyList<UsbDriveInfo>> GetRemovableDrivesAsync(CancellationToken cancellationToken);
}
