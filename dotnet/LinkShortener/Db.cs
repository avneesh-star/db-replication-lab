using System.Diagnostics;
using System.Net.Sockets;
using Npgsql;

namespace LinkShortener;

/// <summary>
/// The two data sources the app uses. Both point at HAProxy, never at a specific
/// Postgres node, so a failover needs no configuration change here.
/// </summary>
public sealed class Db : IAsyncDisposable
{
    public NpgsqlDataSource Writer { get; }   // :5450, always the current leader
    public NpgsqlDataSource Reader { get; }   // :5451, the healthy replicas

    public Db(IConfiguration config)
    {
        Writer = NpgsqlDataSource.Create(config.GetConnectionString("Writer")!);
        Reader = NpgsqlDataSource.Create(config.GetConnectionString("Reader")!);
    }

    public async ValueTask DisposeAsync()
    {
        await Writer.DisposeAsync();
        await Reader.DisposeAsync();
    }
}

public sealed record Attempt<T>(T Value, int Attempts, long ElapsedMs);

public static class Resilience
{
    /// <summary>
    /// Errors that mean "the database moved or is restarting, try again":
    /// dropped connections, connect timeouts, a node shutting down, or a write
    /// that reached a node that has just become read-only.
    /// </summary>
    public static bool IsTransient(Exception e) => e switch
    {
        // Multi-host connection strings wrap per-host failures: "Unable to connect to a suitable host"
        // holds an AggregateException of timeouts and socket errors. Look inside.
        AggregateException ae => ae.Flatten().InnerExceptions.Any(IsTransient),
        NpgsqlException { InnerException: AggregateException inner } => IsTransient(inner),
        NpgsqlException ne when ne.Message.StartsWith("Unable to connect to a suitable host", StringComparison.Ordinal) => true,
        PostgresException pe => pe.SqlState is
            "57P01" or "57P02" or "57P03"   // admin shutdown, crash shutdown, cannot connect now
            or "25006"                      // read_only_sql_transaction (node was demoted)
            or "08000" or "08001" or "08003" or "08004" or "08006", // connection exceptions
        NpgsqlException ne => ne.IsTransient || ne.InnerException is SocketException or IOException or TimeoutException,
        SocketException or IOException or TimeoutException => true,
        _ => false,
    };

    /// <summary>
    /// Retries <paramref name="op"/> with backoff for up to <paramref name="window"/>.
    /// The window must be longer than a failover (about 25 s in this lab).
    /// <paramref name="op"/> MUST be safe to run twice: a commit can succeed while the
    /// client never hears back, so the retry may repeat a write that already happened.
    /// </summary>
    public static async Task<Attempt<T>> RetryAsync<T>(
        Func<CancellationToken, Task<T>> op, TimeSpan window, ILogger log, string what, CancellationToken ct)
    {
        var clock = Stopwatch.StartNew();
        var delay = TimeSpan.FromMilliseconds(250);
        var attempt = 0;
        while (true)
        {
            attempt++;
            try
            {
                return new Attempt<T>(await op(ct), attempt, clock.ElapsedMilliseconds);
            }
            catch (Exception e) when (IsTransient(e) && !ct.IsCancellationRequested && clock.Elapsed + delay < window)
            {
                log.LogWarning("{What}: attempt {Attempt} failed ({Error}); retrying in {Delay} ms",
                    what, attempt, e.Message.Split('\n')[0], (int)delay.TotalMilliseconds);
                await Task.Delay(delay, ct);
                delay = TimeSpan.FromMilliseconds(Math.Min(delay.TotalMilliseconds * 2, 2000));
            }
        }
    }
}
