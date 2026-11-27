using System.Text.Json;
using StackExchange.Redis;

namespace LinkShortener;

/// <summary>
/// Cache-aside cache for links, kept in Redis.
///
/// Design rules:
///   * Redis is an optimisation, never a dependency. Every Redis call is wrapped so that a failure
///     is treated as a cache miss and the request is served from the database.
///   * A tiny circuit breaker stops the API paying the Redis timeout on every request while Redis
///     is down: after a failure the cache is skipped for a few seconds, then probed again.
///   * Entries expire (TTL) so a stale value cannot live forever. Links are immutable once created,
///     so there is no invalidation problem: an entry is either correct or absent.
///   * Switched on and off with Cache:Enabled, so the same build can be benchmarked both ways.
/// </summary>
public sealed class LinkCache
{
    private static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web);
    private static readonly TimeSpan CircuitOpenFor = TimeSpan.FromSeconds(5);

    private readonly Lazy<ConnectionMultiplexer>? _mux;
    private readonly TimeSpan _ttl;
    private readonly ILogger<LinkCache> _log;
    private long _skipUntilTicks;           // Environment.TickCount64 value until which Redis is skipped

    public bool Enabled { get; }

    public LinkCache(IConfiguration config, ILogger<LinkCache> log)
    {
        _log = log;
        Enabled = config.GetValue("Cache:Enabled", false);
        _ttl = TimeSpan.FromSeconds(config.GetValue("Cache:TtlSeconds", 300));
        var conn = config.GetConnectionString("Redis");
        if (!Enabled || string.IsNullOrWhiteSpace(conn))
        {
            Enabled = false;
            return;
        }
        // AbortOnConnectFail=false lets the app start, and keep working, while Redis is unreachable.
        _mux = new Lazy<ConnectionMultiplexer>(() => ConnectionMultiplexer.Connect(conn));
    }

    private IDatabase? Db()
    {
        if (!Enabled || Environment.TickCount64 < Interlocked.Read(ref _skipUntilTicks)) return null;
        try { return _mux!.Value.GetDatabase(); }
        catch (Exception e) { Trip(e); return null; }
    }

    private void Trip(Exception e)
    {
        if (Environment.TickCount64 >= Interlocked.Read(ref _skipUntilTicks))
            _log.LogWarning("Redis unavailable ({Error}); serving from the database for {Seconds} s", e.Message.Split('\n')[0], CircuitOpenFor.TotalSeconds);
        Interlocked.Exchange(ref _skipUntilTicks, Environment.TickCount64 + (long)CircuitOpenFor.TotalMilliseconds);
    }

    private static string Key(string code) => $"link:{code}";

    /// <summary>Returns the cached link, or null on a miss or any Redis problem.</summary>
    public async Task<Link?> GetAsync(string code)
    {
        var db = Db();
        if (db is null) return null;
        try
        {
            var value = await db.StringGetAsync(Key(code));
            return value.IsNullOrEmpty ? null : JsonSerializer.Deserialize<Link>((string)value!, Json);
        }
        catch (Exception e) { Trip(e); return null; }
    }

    /// <summary>Stores a link without waiting for Redis to acknowledge (the response must not wait on the cache).</summary>
    public void Set(Link link)
    {
        var db = Db();
        if (db is null) return;
        try { db.StringSet(Key(link.Code), JsonSerializer.Serialize(link, Json), _ttl, flags: CommandFlags.FireAndForget); }
        catch (Exception e) { Trip(e); }
    }

    /// <summary>For /health/db: is Redis reachable right now?</summary>
    public async Task<object> ProbeAsync()
    {
        if (!Enabled) return new { enabled = false };
        try
        {
            var ping = await _mux!.Value.GetDatabase().PingAsync();
            return new { enabled = true, ok = true, pingMs = Math.Round(ping.TotalMilliseconds, 2) };
        }
        catch (Exception e)
        {
            var msg = e.Message.Split('\n')[0];
            return new { enabled = true, ok = false, error = msg.Length > 120 ? msg[..120] + "..." : msg };
        }
    }
}
