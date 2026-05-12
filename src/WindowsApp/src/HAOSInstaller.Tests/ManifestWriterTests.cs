using System.Text.Json;
using HAOSInstaller.Core.Models;
using HAOSInstaller.Core.Services;

namespace HAOSInstaller.Tests;

public sealed class ManifestWriterTests
{
    [Fact]
    public async Task WritesCacheManifest()
    {
        var tempDirectory = Path.Combine(Path.GetTempPath(), "HAOSInstaller.Tests", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(tempDirectory);

        try
        {
            var imagePath = Path.Combine(tempDirectory, "haos_generic-x86-64-17.3.img.xz");
            await File.WriteAllTextAsync(imagePath, "dummy");

            var release = new HaosReleaseInfo(
                "17.3",
                "haos_generic-x86-64-17.3.img.xz",
                new Uri("https://example.test/haos.img.xz"),
                "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
                5,
                DateTimeOffset.Parse("2026-05-06T08:35:28Z"));

            var cachedImage = new HaosCachedImage(release, imagePath, Path.Combine(tempDirectory, "checksum.sha256"));

            var manifestPath = await new ManifestWriter().WriteAsync(cachedImage, tempDirectory, CancellationToken.None);
            using var document = JsonDocument.Parse(await File.ReadAllTextAsync(manifestPath));

            Assert.Equal(1, document.RootElement.GetProperty("schemaVersion").GetInt32());
            Assert.Equal("haos_generic-x86-64", document.RootElement.GetProperty("imageType").GetString());
            Assert.Equal("17.3", document.RootElement.GetProperty("version").GetString());
            Assert.Equal(release.Sha256, document.RootElement.GetProperty("sha256").GetString());
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
