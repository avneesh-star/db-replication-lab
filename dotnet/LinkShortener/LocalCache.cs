using Microsoft.Extensions.Caching.Memory;

namespace LinkShortener;

/// <summary>
/// A small in-process (L1) cache in front of Redis (L2). A hit costs microseconds: no network call, and no
/// load on Redis or Postgres. Each API instance has its own copy, so it is kept small and short-lived.
///
/// Safe here because a link never changes once created: an entry is either correct or expired, so there is
/// nothing to invalidate. (For data that does change, an L1 cache needs short TTLs or a way to broadcast
/// invalidations, and then a stale read becomes possible.)
/// Off by default (Cache:L1:Enabled) so it can be benchmarked on and off.
/// </summary>
public sealed class LocalCache
{
    private readonly MemoryCache? _cache;
    private readonly TimeSpan _ttl;

    public bool Enabled { get; }

    public LocalCache(IConfiguration config)
    {
        Enabled = config.GetValue("Cache:L1:Enabled", false);
        if (!Enabled) return;
        _ttl = TimeSpan.FromSeconds(config.GetValue("Cache:L1:TtlSeconds", 30));
        _cache = new MemoryCache(new MemoryCacheOptions { SizeLimit = config.GetValue("Cache:L1:MaxEntries", 50_000) });
    }

    public Link? Get(string code) => _cache is not null && _cache.TryGetValue(code, out Link? link) ? link : null;

    public void Set(Link link)
    {
        _cache?.Set(link.Code, link, new MemoryCacheEntryOptions { Size = 1, AbsoluteExpirationRelativeToNow = _ttl });
    }
}
