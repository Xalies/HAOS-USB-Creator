using System.Text.Json;
using HAOSInstaller.Core.Models;

namespace HAOSInstaller.Core.Services;

public sealed class ManifestWriter
{
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web)
    {
        WriteIndented = true
    };

    public async Task<string> WriteAsync(HaosCachedImage cachedImage, string cacheDirectory, CancellationToken cancellationToken)
    {
        if (string.IsNullOrWhiteSpace(cachedImage.Release.Sha256))
        {
            throw new InvalidOperationException("Cannot write cache manifest without verified SHA-256.");
        }

        var manifest = new HaosImageManifest
        {
            Version = cachedImage.Release.Version,
            Filename = cachedImage.Release.Filename,
            Sha256 = cachedImage.Release.Sha256,
            SourceUrl = cachedImage.Release.DownloadUrl.ToString(),
            DownloadedAtUtc = DateTimeOffset.UtcNow,
            FileSizeBytes = new FileInfo(cachedImage.ImagePath).Length
        };

        var manifestPath = Path.Combine(cacheDirectory, "manifest.json");
        await using var stream = new FileStream(manifestPath, FileMode.Create, FileAccess.Write, FileShare.Read, 16 * 1024, useAsync: true);
        await JsonSerializer.SerializeAsync(stream, manifest, JsonOptions, cancellationToken);
        return manifestPath;
    }
}
