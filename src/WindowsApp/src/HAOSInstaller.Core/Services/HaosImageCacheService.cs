using HAOSInstaller.Core.Models;

namespace HAOSInstaller.Core.Services;

public sealed class HaosImageCacheService(HttpClient httpClient, Sha256Verifier verifier)
{
    private const int BufferSize = 1024 * 1024;

    public async Task<HaosCachedImage> DownloadAndVerifyAsync(
        HaosReleaseInfo release,
        string cacheDirectory,
        IProgress<ImageWriteProgress> progress,
        CancellationToken cancellationToken)
    {
        Directory.CreateDirectory(cacheDirectory);

        var imagePath = Path.Combine(cacheDirectory, release.Filename);
        var checksumPath = Path.Combine(cacheDirectory, $"{release.Filename}.sha256");
        var tempPath = $"{imagePath}.download";

        if (File.Exists(imagePath) && !string.IsNullOrWhiteSpace(release.Sha256))
        {
            progress.Report(new ImageWriteProgress("Existing Home Assistant OS image found. Checking it now.", 0));
            await verifier.VerifyFileHashAsync(imagePath, release.Sha256, progress, cancellationToken);
            await File.WriteAllTextAsync(checksumPath, $"{release.Sha256}  {release.Filename}{Environment.NewLine}", cancellationToken);
            progress.Report(new ImageWriteProgress("Existing Home Assistant OS image is ready.", 100));
            return new HaosCachedImage(release, imagePath, checksumPath);
        }

        progress.Report(new ImageWriteProgress($"Downloading {release.Filename}.", 0));

        using var response = await httpClient.GetAsync(release.DownloadUrl, HttpCompletionOption.ResponseHeadersRead, cancellationToken);
        response.EnsureSuccessStatusCode();

        var totalBytes = response.Content.Headers.ContentLength ?? release.FileSizeBytes;
        {
            await using var remote = await response.Content.ReadAsStreamAsync(cancellationToken);
            await using var local = new FileStream(tempPath, FileMode.Create, FileAccess.Write, FileShare.Read, BufferSize, useAsync: true);

            var buffer = new byte[BufferSize];
            long downloaded = 0;
            int read;

            while ((read = await remote.ReadAsync(buffer, cancellationToken)) > 0)
            {
                await local.WriteAsync(buffer.AsMemory(0, read), cancellationToken);
                downloaded += read;

                double? percent = totalBytes > 0 ? downloaded * 100d / totalBytes : null;
                progress.Report(new ImageWriteProgress($"Downloaded {downloaded:N0} of {totalBytes:N0} bytes.", percent));
            }

            await local.FlushAsync(cancellationToken);
        }

        if (File.Exists(imagePath))
        {
            File.Delete(imagePath);
        }

        File.Move(tempPath, imagePath);

        if (string.IsNullOrWhiteSpace(release.Sha256))
        {
            throw new InvalidOperationException("Release metadata did not include a SHA-256 digest; refusing to cache unverified image for MVP.");
        }

        await verifier.VerifyFileHashAsync(imagePath, release.Sha256, progress, cancellationToken);
        await File.WriteAllTextAsync(checksumPath, $"{release.Sha256}  {release.Filename}{Environment.NewLine}", cancellationToken);
        progress.Report(new ImageWriteProgress("Home Assistant OS image downloaded and verified.", 100));

        return new HaosCachedImage(release, imagePath, checksumPath);
    }
}

public sealed record HaosCachedImage(HaosReleaseInfo Release, string ImagePath, string ChecksumPath);
