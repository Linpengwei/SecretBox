using System.Net.Http.Json;
using System.Text.Json;

namespace SecretBox.Core;

// Explicit adapter for the existing server contract; never logs bodies, queries
// or server error bodies, which can contain credentials. Not a sync engine.
public sealed class SecretBoxApi(HttpClient client)
{
    public async Task<bool> HealthAsync(CancellationToken cancellation = default)
    {
        using var response = await client.GetAsync("health", cancellation);
        return response.IsSuccessStatusCode;
    }
    public async Task<List<VaultItem>> SearchAsync(string query, CancellationToken cancellation = default)
    {
        using var response = await client.PostAsJsonAsync("api/search", new { query, limit = 20 }, VaultJson.Options, cancellation);
        EnsureSuccess(response);
        var body = await response.Content.ReadFromJsonAsync<SearchResult>(VaultJson.Options, cancellation);
        return body?.Results ?? [];
    }
    public async Task<VaultItem> SaveAsync(VaultItem item, bool update, CancellationToken cancellation = default)
    {
        MetadataGuard.Validate(item);
        // Never send capture text. TOTP is a dedicated secret-class payload.
        var payload = new
        {
            item.ItemType, item.TemplateType, item.Name, item.PrimarySecret, item.Notes,
            item.Tags, item.Fields, item.Totp, item.Permissions,
            pasted_text = "", remove_totp = update && item.Totp is null
        };
        using var request = new HttpRequestMessage(update ? HttpMethod.Put : HttpMethod.Post,
            update ? $"api/records/{Uri.EscapeDataString(item.Id)}" : "api/records")
        { Content = JsonContent.Create(payload, options: VaultJson.Options) };
        using var response = await client.SendAsync(request, cancellation);
        EnsureSuccess(response);
        return await response.Content.ReadFromJsonAsync<VaultItem>(VaultJson.Options, cancellation) ?? throw new JsonException("服务端返回空记录。");
    }
    private static void EnsureSuccess(HttpResponseMessage response)
    { if (!response.IsSuccessStatusCode) throw new HttpRequestException($"服务端请求失败（{(int)response.StatusCode}）。"); }
    private sealed class SearchResult { public List<VaultItem> Results { get; set; } = []; }
}
