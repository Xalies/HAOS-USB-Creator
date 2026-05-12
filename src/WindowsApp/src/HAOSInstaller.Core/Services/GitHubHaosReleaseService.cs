using System.Net.Http.Headers;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;
using HAOSInstaller.Core.Models;

namespace HAOSInstaller.Core.Services;

public sealed partial class GitHubHaosReleaseService(HttpClient httpClient) : IHaosReleaseService
{
    private static readonly Uri LatestReleaseUri = new("https://api.github.com/repos/home-assistant/operating-system/releases/latest");

    public async Task<HaosReleaseInfo> GetLatestGenericX86_64Async(CancellationToken cancellationToken)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, LatestReleaseUri);
        request.Headers.UserAgent.Add(new ProductInfoHeaderValue("HAOSInstaller", "0.1"));
        request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/vnd.github+json"));

        using var response = await httpClient.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, cancellationToken);
        response.EnsureSuccessStatusCode();

        await using var stream = await response.Content.ReadAsStreamAsync(cancellationToken);
        var release = await JsonSerializer.DeserializeAsync<GitHubReleaseDto>(
            stream,
            JsonOptions,
            cancellationToken);

        if (release is null)
        {
            throw new InvalidOperationException("GitHub returned an empty release response.");
        }

        var asset = release.Assets
            .FirstOrDefault(asset => GenericX86ImageRegex().IsMatch(asset.Name));

        if (asset is null)
        {
            throw new InvalidOperationException("Latest HAOS release did not include a generic x86-64 .img.xz asset.");
        }

        var match = GenericX86ImageRegex().Match(asset.Name);
        var version = match.Groups["version"].Value;
        var sha256 = ParseSha256(asset.Digest);

        return new HaosReleaseInfo(
            Version: string.IsNullOrWhiteSpace(version) ? release.TagName : version,
            Filename: asset.Name,
            DownloadUrl: new Uri(asset.BrowserDownloadUrl),
            Sha256: sha256,
            FileSizeBytes: asset.Size,
            PublishedAtUtc: release.PublishedAt);
    }

    private static string? ParseSha256(string? digest)
    {
        const string prefix = "sha256:";
        if (digest is null || !digest.StartsWith(prefix, StringComparison.OrdinalIgnoreCase))
        {
            return null;
        }

        var value = digest[prefix.Length..].Trim();
        return value.Length == 64 ? value.ToLowerInvariant() : null;
    }

    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web);

    [GeneratedRegex("^haos_generic-x86-64-(?<version>.+)\\.img\\.xz$", RegexOptions.IgnoreCase)]
    private static partial Regex GenericX86ImageRegex();

    private sealed record GitHubReleaseDto(
        [property: JsonPropertyName("tag_name")] string TagName,
        [property: JsonPropertyName("published_at")] DateTimeOffset PublishedAt,
        [property: JsonPropertyName("assets")] GitHubAssetDto[] Assets);

    private sealed record GitHubAssetDto(
        [property: JsonPropertyName("name")] string Name,
        [property: JsonPropertyName("browser_download_url")] string BrowserDownloadUrl,
        [property: JsonPropertyName("size")] long Size,
        [property: JsonPropertyName("digest")] string? Digest);
}
