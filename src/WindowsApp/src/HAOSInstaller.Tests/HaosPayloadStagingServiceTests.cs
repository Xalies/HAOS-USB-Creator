using HAOSInstaller.Core.Models;
using HAOSInstaller.Core.Services;

namespace HAOSInstaller.Tests;

public sealed class HaosPayloadStagingServiceTests
{
    [Fact]
    public async Task StageAsyncCopiesPayloadChecksumAndManifest()
    {
        var tempDirectory = Path.Combine(Path.GetTempPath(), "HAOSInstaller.Tests", Guid.NewGuid().ToString("N"));
        var sourceDirectory = Path.Combine(tempDirectory, "source");
        var stagingDirectory = Path.Combine(tempDirectory, "staging");
        Directory.CreateDirectory(sourceDirectory);

        try
        {
            var imagePath = Path.Combine(sourceDirectory, "haos_generic-x86-64-17.3.img.xz");
            var checksumPath = Path.Combine(sourceDirectory, "haos_generic-x86-64-17.3.img.xz.sha256");
            await File.WriteAllTextAsync(imagePath, "payload");
            await File.WriteAllTextAsync(checksumPath, "abc  haos_generic-x86-64-17.3.img.xz");

            var release = new HaosReleaseInfo(
                "17.3",
                "haos_generic-x86-64-17.3.img.xz",
                new Uri("https://example.test/haos_generic-x86-64-17.3.img.xz"),
                "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                7,
                DateTimeOffset.UtcNow);

            var service = new HaosPayloadStagingService(new ManifestWriter());
            var result = await service.StageAsync(
                new HaosCachedImage(release, imagePath, checksumPath),
                stagingDirectory,
                new Progress<ImageWriteProgress>(),
                CancellationToken.None);

            Assert.True(File.Exists(result.ImagePath));
            Assert.True(File.Exists(result.ChecksumPath));
            Assert.True(File.Exists(result.ManifestPath));
            Assert.Contains(Path.Combine("cache", release.Filename), result.ImagePath);
        }
        finally
        {
            if (Directory.Exists(tempDirectory))
            {
                Directory.Delete(tempDirectory, recursive: true);
            }
        }
    }
}
