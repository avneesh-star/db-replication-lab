using System.Security.Cryptography;
using Npgsql;

namespace LinkShortener;

public sealed record Link(string Code, string Url, DateTime CreatedAt);

public sealed record CreateResult(Link Link, bool Created, string? Conflict = null);

public sealed record ReadResult(Link? Link, string ServedBy, int Attempts);

public sealed class LinkRepository(Db db, IConfiguration config, ILogger<LinkRepository> log)
{
    private readonly TimeSpan _writeWindow = TimeSpan.FromSeconds(config.GetValue("Resilience:WriteRetryWindowSeconds", 45));
    private readonly TimeSpan _readWindow = TimeSpan.FromSeconds(config.GetValue("Resilience:ReadRetryWindowSeconds", 3));

    private const string Columns = "short_code, long_url, created_at";

    public Task EnsureSchemaAsync(CancellationToken ct) =>
        // The cluster may still be forming when the app starts, so wait for it.
        Resilience.RetryAsync(async c =>
        {
            await using var cmd = db.Writer.CreateCommand("""
                CREATE TABLE IF NOT EXISTS links (
                    id              bigserial PRIMARY KEY,
                    short_code      text NOT NULL UNIQUE,
                    long_url        text NOT NULL,
                    idempotency_key text UNIQUE,
                    created_at      timestamptz NOT NULL DEFAULT now()
                )
                """);
            await cmd.ExecuteNonQueryAsync(c);
            return true;
        }, TimeSpan.FromSeconds(120), log, "ensure schema", ct);

    /// <summary>
    /// Writes always go to the primary. The insert is idempotent, so the retry loop
    /// is safe even when a commit succeeded but its acknowledgement was lost in a failover:
    ///   - the code is chosen ONCE, outside the loop, so every attempt targets the same row;
    ///   - ON CONFLICT DO NOTHING turns a repeat into "already exists", not an error.
    /// </summary>
    public async Task<Attempt<CreateResult>> CreateAsync(string url, string? code, string? idempotencyKey, CancellationToken ct)
    {
        var chosen = code ?? NewCode();
        return await Resilience.RetryAsync(async c =>
        {
            await using var insert = db.Writer.CreateCommand($"""
                INSERT INTO links (short_code, long_url, idempotency_key)
                VALUES ($1, $2, $3)
                ON CONFLICT DO NOTHING
                RETURNING {Columns}
                """);
            insert.Parameters.AddWithValue(chosen);
            insert.Parameters.AddWithValue(url);
            insert.Parameters.AddWithValue((object?)idempotencyKey ?? DBNull.Value);
            await using (var r = await insert.ExecuteReaderAsync(c))
                if (await r.ReadAsync(c))
                    return new CreateResult(ReadLink(r), Created: true);

            // Nothing inserted: a row with this key or code already exists.
            await using var find = db.Writer.CreateCommand($"""
                SELECT {Columns}, long_url = $2 AS same_url
                FROM links WHERE idempotency_key = $3 OR short_code = $1
                ORDER BY (idempotency_key = $3) DESC NULLS LAST
                LIMIT 1
                """);
            find.Parameters.AddWithValue(chosen);
            find.Parameters.AddWithValue(url);
            find.Parameters.AddWithValue((object?)idempotencyKey ?? DBNull.Value);
            await using var f = await find.ExecuteReaderAsync(c);
            if (!await f.ReadAsync(c))
                throw new NpgsqlException("insert conflicted but no row found; retrying");

            var existing = ReadLink(f);
            return f.GetBoolean(3)
                ? new CreateResult(existing, Created: false)                               // a replay of the same request
                : new CreateResult(existing, Created: false, Conflict: "code already used for a different URL");
        }, _writeWindow, log, "create link", ct);
    }

    /// <summary>
    /// Reads try a replica first. A replica can be a few milliseconds behind, so a
    /// miss is re-checked on the primary: that is what keeps "create, then open" working.
    /// If the reader endpoint is down entirely, the primary serves the read.
    /// </summary>
    public async Task<ReadResult> GetAsync(string code, CancellationToken ct)
    {
        try
        {
            var fromReplica = await Resilience.RetryAsync(c => Lookup(db.Reader, code, c), _readWindow, log, "read replica", ct);
            if (fromReplica.Value is not null)
                return new ReadResult(fromReplica.Value, "replica", fromReplica.Attempts);
        }
        catch (Exception e) when (Resilience.IsTransient(e))
        {
            log.LogWarning("Reader endpoint unavailable ({Error}); falling back to the primary", e.Message.Split('\n')[0]);
        }

        var fromPrimary = await Resilience.RetryAsync(c => Lookup(db.Writer, code, c), _writeWindow, log, "read primary", ct);
        return new ReadResult(fromPrimary.Value, "primary", fromPrimary.Attempts);
    }

    private static async Task<Link?> Lookup(Npgsql.NpgsqlDataSource source, string code, CancellationToken ct)
    {
        await using var cmd = source.CreateCommand($"SELECT {Columns} FROM links WHERE short_code = $1");
        cmd.Parameters.AddWithValue(code);
        await using var r = await cmd.ExecuteReaderAsync(ct);
        return await r.ReadAsync(ct) ? ReadLink(r) : null;
    }

    private static Link ReadLink(NpgsqlDataReader r) => new(r.GetString(0), r.GetString(1), r.GetDateTime(2));

    private static string NewCode()
    {
        const string alphabet = "abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789";
        return string.Create(7, alphabet, (span, a) =>
        {
            for (var i = 0; i < span.Length; i++) span[i] = a[RandomNumberGenerator.GetInt32(a.Length)];
        });
    }
}
