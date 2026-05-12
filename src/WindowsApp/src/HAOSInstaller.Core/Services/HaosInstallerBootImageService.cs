using System.Text.Json;
using HAOSInstaller.Core.Models;

namespace HAOSInstaller.Core.Services;

public sealed class HaosInstallerBootImageService(Sha256Verifier verifier)
{
    private static readonly string[] SupportedPatterns =
    [
        "haos-installer*.img",
        "haos-installer*.usb"
    ];

    public async Task<HaosInstallerBootImage?> TryFindLatestAsync(
        IEnumerable<string> searchDirectories,
        IProgress<ImageWriteProgress>? progress,
        CancellationToken cancellationToken)
    {
        var candidates = searchDirectories
            .Where(Directory.Exists)
            .SelectMany(directory => SupportedPatterns.SelectMany(pattern =>
                Directory.EnumerateFiles(directory, pattern, SearchOption.TopDirectoryOnly)))
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .Select(path => new FileInfo(path))
            .OrderByDescending(file => PreferredFormatScore(file.Extension))
            .ThenByDescending(file => file.LastWriteTimeUtc)
            .ToArray();

        if (candidates.Length == 0)
        {
            return null;
        }

        return await LoadAsync(candidates[0].FullName, progress, cancellationToken);
    }

    public async Task<HaosInstallerBootImage> LoadAsync(
        string imagePath,
        IProgress<ImageWriteProgress>? progress,
        CancellationToken cancellationToken)
    {
        if (!File.Exists(imagePath))
        {
            throw new FileNotFoundException("HAOS Installer boot image was not found.", imagePath);
        }

        var checksumPath = FindChecksumPath(imagePath);
        var manifestPath = FindManifestPath(imagePath);
        var manifest = manifestPath is null
            ? null
            : await ReadManifestAsync(manifestPath, cancellationToken);
        string? expectedSha256 = null;
        var checksumVerified = false;

        if (checksumPath is not null)
        {
            expectedSha256 = await ReadExpectedSha256Async(checksumPath, cancellationToken);
            if (!string.IsNullOrWhiteSpace(expectedSha256))
            {
                await verifier.VerifyFileHashAsync(imagePath, expectedSha256, progress, cancellationToken);
                checksumVerified = true;
            }
        }

        var info = new FileInfo(imagePath);
        return new HaosInstallerBootImage(
            info.FullName,
            checksumPath,
            manifestPath,
            expectedSha256,
            info.Length,
            checksumVerified,
            manifest?.Format ?? FormatFromExtension(info.Extension));
    }

    private static int PreferredFormatScore(string extension)
    {
        return extension.ToLowerInvariant() switch
        {
            ".img" => 3,
            ".usb" => 2,
            _ => 0
        };
    }

    private static string FormatFromExtension(string extension)
    {
        return extension.ToLowerInvariant() switch
        {
            ".img" => "raw-usb-image",
            ".usb" => "usb-layout-image",
            _ => "unknown"
        };
    }

    private static string? FindChecksumPath(string imagePath)
    {
        var direct = $"{imagePath}.sha256";
        if (File.Exists(direct))
        {
            return direct;
        }

        var sibling = Path.Combine(Path.GetDirectoryName(imagePath) ?? string.Empty, $"{Path.GetFileName(imagePath)}.sha256");
        return File.Exists(sibling) ? sibling : null;
    }

    private static string? FindManifestPath(string imagePath)
    {
        var direct = $"{imagePath}.manifest.json";
        if (File.Exists(direct))
        {
            return direct;
        }

        var sibling = Path.Combine(Path.GetDirectoryName(imagePath) ?? string.Empty, "haos-installer-boot-image.json");
        return File.Exists(sibling) ? sibling : null;
    }

    private static async Task<HaosInstallerBootImageManifest?> ReadManifestAsync(
        string manifestPath,
        CancellationToken cancellationToken)
    {
        await using var stream = File.OpenRead(manifestPath);
        var manifest = await JsonSerializer.DeserializeAsync<HaosInstallerBootImageManifest>(
            stream,
            new JsonSerializerOptions(JsonSerializerDefaults.Web),
            cancellationToken);

        if (manifest is null || manifest.SchemaVersion != 1 || manifest.ArtifactType != "haos_installer_boot")
        {
            return null;
        }

        return manifest;
    }

    public async Task ValidateBundledBootImageAsync(
        string bundledBootImageDirectory,
        IProgress<ImageWriteProgress>? progress,
        CancellationToken cancellationToken)
    {
        var bootImage = await TryFindLatestAsync([bundledBootImageDirectory], progress, cancellationToken)
            ?? throw new FileNotFoundException("Bundled HAOS Installer boot image was not found.", bundledBootImageDirectory);

        if (bootImage.ManifestPath is null)
        {
            throw new InvalidOperationException("Bundled HAOS Installer boot image manifest is missing.");
        }

        if (!bootImage.ChecksumVerified)
        {
            throw new InvalidOperationException("Bundled HAOS Installer boot image checksum could not be verified.");
        }

        progress?.Report(new ImageWriteProgress($"Bundled HAOS Installer boot image validated: {bootImage.ImagePath}", 100));
    }

    private static async Task<string?> ReadExpectedSha256Async(string checksumPath, CancellationToken cancellationToken)
    {
        var text = await File.ReadAllTextAsync(checksumPath, cancellationToken);
        var firstToken = text
            .Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries)
            .FirstOrDefault();

        return firstToken is { Length: 64 } && firstToken.All(Uri.IsHexDigit)
            ? firstToken.ToLowerInvariant()
            : null;
    }
}
