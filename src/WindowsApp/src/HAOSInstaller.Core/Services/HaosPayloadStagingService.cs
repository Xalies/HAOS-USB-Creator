using HAOSInstaller.Core.Models;

namespace HAOSInstaller.Core.Services;

public sealed class HaosPayloadStagingService(ManifestWriter manifestWriter)
{
    public async Task<HaosPayloadStageResult> StageAsync(
        HaosCachedImage cachedImage,
        string stagingDirectory,
        IProgress<ImageWriteProgress> progress,
        CancellationToken cancellationToken)
    {
        var cacheDirectory = Path.Combine(stagingDirectory, DateTimeOffset.UtcNow.ToString("yyyyMMddHHmmss"), "cache");
        Directory.CreateDirectory(cacheDirectory);

        var stagedImagePath = Path.Combine(cacheDirectory, cachedImage.Release.Filename);
        var stagedChecksumPath = Path.Combine(cacheDirectory, $"{cachedImage.Release.Filename}.sha256");

        progress.Report(new ImageWriteProgress("Preparing Home Assistant OS for the USB.", 0));
        await CopyFileAsync(cachedImage.ImagePath, stagedImagePath, cancellationToken);
        await CopyFileAsync(cachedImage.ChecksumPath, stagedChecksumPath, cancellationToken);

        var stagedCachedImage = new HaosCachedImage(cachedImage.Release, stagedImagePath, stagedChecksumPath);
        var manifestPath = await manifestWriter.WriteAsync(stagedCachedImage, cacheDirectory, cancellationToken);

        progress.Report(new ImageWriteProgress("Home Assistant OS is ready to add to the USB.", 100));
        return new HaosPayloadStageResult(cacheDirectory, stagedImagePath, stagedChecksumPath, manifestPath);
    }

    private static async Task CopyFileAsync(string source, string destination, CancellationToken cancellationToken)
    {
        await using var sourceStream = new FileStream(source, FileMode.Open, FileAccess.Read, FileShare.Read, 1024 * 1024, useAsync: true);
        await using var destinationStream = new FileStream(destination, FileMode.Create, FileAccess.Write, FileShare.None, 1024 * 1024, useAsync: true);
        await sourceStream.CopyToAsync(destinationStream, cancellationToken);
        await destinationStream.FlushAsync(cancellationToken);
    }
}
