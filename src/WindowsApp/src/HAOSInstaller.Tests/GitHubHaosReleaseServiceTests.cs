using System.Net;
using HAOSInstaller.Core.Services;

namespace HAOSInstaller.Tests;

public sealed class GitHubHaosReleaseServiceTests
{
    [Fact]
    public async Task FindsGenericX86ImageAndDigest()
    {
        const string json = """
        {
          "tag_name": "17.3",
          "published_at": "2026-05-06T08:35:28Z",
          "assets": [
            {
              "name": "haos_generic-aarch64-17.3.img.xz",
              "browser_download_url": "https://example.test/aarch64.img.xz",
              "size": 1,
              "digest": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
            },
            {
              "name": "haos_generic-x86-64-17.3.img.xz",
              "browser_download_url": "https://example.test/x86.img.xz",
              "size": 1234,
              "digest": "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
            }
          ]
        }
        """;

        using var httpClient = new HttpClient(new StaticJsonHandler(json));
        var service = new GitHubHaosReleaseService(httpClient);

        var release = await service.GetLatestGenericX86_64Async(CancellationToken.None);

        Assert.Equal("17.3", release.Version);
        Assert.Equal("haos_generic-x86-64-17.3.img.xz", release.Filename);
        Assert.Equal(1234, release.FileSizeBytes);
        Assert.Equal("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", release.Sha256);
    }

    private sealed class StaticJsonHandler(string json) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            var response = new HttpResponseMessage(HttpStatusCode.OK)
            {
                Content = new StringContent(json)
            };

            return Task.FromResult(response);
        }
    }
}
