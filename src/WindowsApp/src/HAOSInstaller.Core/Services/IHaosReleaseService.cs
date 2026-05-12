using HAOSInstaller.Core.Models;

namespace HAOSInstaller.Core.Services;

public interface IHaosReleaseService
{
    Task<HaosReleaseInfo> GetLatestGenericX86_64Async(CancellationToken cancellationToken);
}
