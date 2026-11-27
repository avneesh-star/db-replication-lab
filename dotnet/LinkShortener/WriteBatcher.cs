using System.Threading.Channels;
using Npgsql;

namespace LinkShortener;

/// <summary>
/// Group commit at the application level.
///
/// Every database write has to wait for a commit: a WAL flush on the primary and then on the synchronous standby.
/// One-row-per-transaction pays that cost for every row, so it caps out at a few hundred writes per second.
/// This groups concurrent creates into one multi-row INSERT in one transaction, so one commit covers many rows.
///
/// How batches form (no timer, so no added latency at low load):
///   * requests are put on a queue;
///   * a small pool of workers each take everything currently waiting (up to MaxSize) and commit it as one batch;
///   * while a worker is committing, new requests accumulate, so batches grow on their own as load grows.
///
/// Guarantees kept:
///   * a request is acknowledged only after its batch has committed (same durability as before);
///   * duplicates are still handled: a row that was not inserted (code or idempotency key already exists, or a
///     duplicate inside the same batch) is reported back as "not inserted" and the caller resolves it exactly as
///     it did for a single insert;
///   * the whole batch is retried through a failover like a single write; it is safe to repeat because the INSERT
///     is ON CONFLICT DO NOTHING.
/// Costs: a failed batch fails every request in it, and a request may wait behind other batches in the queue.
/// </summary>
public sealed class WriteBatcher : IAsyncDisposable
{
    private sealed record Pending(string Code, string Url, string? Key, TaskCompletionSource<Link?> Done);

    private readonly Db _db;
    private readonly ILogger<WriteBatcher> _log;
    private readonly Channel<Pending> _queue;
    private readonly int _maxSize;
    private readonly TimeSpan _retryWindow;
    private readonly CancellationTokenSource _stop = new();
    private readonly Task[] _workers;

    public bool Enabled { get; }

    public WriteBatcher(Db db, IConfiguration config, ILogger<WriteBatcher> log)
    {
        _db = db;
        _log = log;
        Enabled = config.GetValue("Writes:Batch:Enabled", false);
        _maxSize = Math.Max(1, config.GetValue("Writes:Batch:MaxSize", 100));
        _retryWindow = TimeSpan.FromSeconds(config.GetValue("Resilience:WriteRetryWindowSeconds", 45));
        var workers = Math.Max(1, config.GetValue("Writes:Batch:Workers", 4));

        // Bounded, so a flood of requests waits (async) instead of growing memory without limit.
        _queue = Channel.CreateBounded<Pending>(new BoundedChannelOptions(10_000)
        {
            FullMode = BoundedChannelFullMode.Wait, SingleReader = false, SingleWriter = false,
        });
        _workers = Enabled
            ? Enumerable.Range(0, workers).Select(_ => Task.Run(() => RunWorkerAsync(_stop.Token))).ToArray()
            : [];
    }

    /// <summary>Queues a create. Returns the inserted link, or null if nothing was inserted (needs resolving).</summary>
    public async Task<Link?> EnqueueAsync(string code, string url, string? key)
    {
        var item = new Pending(code, url, key, new TaskCompletionSource<Link?>(TaskCreationOptions.RunContinuationsAsynchronously));
        await _queue.Writer.WriteAsync(item);
        return await item.Done.Task;
    }

    private async Task RunWorkerAsync(CancellationToken stop)
    {
        var batch = new List<Pending>(_maxSize);
        try
        {
            while (await _queue.Reader.WaitToReadAsync(stop))
            {
                batch.Clear();
                while (batch.Count < _maxSize && _queue.Reader.TryRead(out var item)) batch.Add(item);
                if (batch.Count > 0) await FlushAsync(batch);
            }
        }
        catch (OperationCanceledException) { /* shutting down */ }
    }

    private async Task FlushAsync(List<Pending> batch)
    {
        // A code that appears twice in one batch cannot both be inserted: the second goes back as "not inserted".
        var seen = new HashSet<string>(batch.Count);
        var unique = new List<Pending>(batch.Count);
        foreach (var p in batch)
        {
            if (seen.Add(p.Code)) unique.Add(p);
            else p.Done.TrySetResult(null);
        }

        var codes = unique.Select(p => p.Code).ToArray();
        var urls = unique.Select(p => p.Url).ToArray();
        var keys = unique.Select(p => p.Key).ToArray();
        try
        {
            var inserted = await Resilience.RetryAsync(async c =>
            {
                await using var cmd = _db.Writer.CreateCommand("""
                    INSERT INTO links (short_code, long_url, idempotency_key)
                    SELECT * FROM unnest($1::text[], $2::text[], $3::text[])
                    ON CONFLICT DO NOTHING
                    RETURNING short_code, long_url, created_at
                    """);
                cmd.Parameters.AddWithValue(codes);
                cmd.Parameters.AddWithValue(urls);
                cmd.Parameters.AddWithValue(keys);
                var rows = new Dictionary<string, Link>(codes.Length);
                await using var r = await cmd.ExecuteReaderAsync(c);
                while (await r.ReadAsync(c)) rows[r.GetString(0)] = new Link(r.GetString(0), r.GetString(1), r.GetDateTime(2));
                return rows;
            }, _retryWindow, _log, $"batch insert ({unique.Count} rows)", CancellationToken.None);

            foreach (var p in unique)
                p.Done.TrySetResult(inserted.Value.TryGetValue(p.Code, out var link) ? link : null);
        }
        catch (Exception e)
        {
            // Fail every request in the batch, so no caller waits forever.
            _log.LogError(e, "Batch of {Count} writes failed", unique.Count);
            foreach (var p in unique) p.Done.TrySetException(e);
        }
    }

    public async ValueTask DisposeAsync()
    {
        _queue.Writer.TryComplete();
        await _stop.CancelAsync();
        try { await Task.WhenAll(_workers); } catch { /* shutting down */ }
        _stop.Dispose();
    }
}
