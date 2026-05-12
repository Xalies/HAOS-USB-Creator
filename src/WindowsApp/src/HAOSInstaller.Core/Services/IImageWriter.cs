using HAOSInstaller.Core.Models;

namespace HAOSInstaller.Core.Services;

public interface IImageWriter
{
    Task WriteAsync(ImageWriteRequest request, IProgress<ImageWriteProgress> progress, CancellationToken cancellationToken);
}

public sealed record ImageWriteProgress(string Message, double? Percent = null);
