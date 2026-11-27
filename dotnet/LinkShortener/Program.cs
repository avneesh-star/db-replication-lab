using System.Text.RegularExpressions;
using LinkShortener;
using Npgsql;

var builder = WebApplication.CreateBuilder(args);
builder.Services.AddSingleton<Db>();
builder.Services.AddSingleton<LinkCache>();
builder.Services.AddSingleton<LinkRepository>();
var app = builder.Build();

var codePattern = new Regex("^[A-Za-z0-9_-]{3,32}$", RegexOptions.Compiled);

// Wait for the cluster and create the table on the primary. Replicas receive it by replication.
// In production the schema is created by migrations and the app's database role cannot run DDL,
// so set Database__EnsureSchema=false there.
if (app.Configuration.GetValue("Database:EnsureSchema", true))
    await app.Services.GetRequiredService<LinkRepository>().EnsureSchemaAsync(app.Lifetime.ApplicationStopping);

app.MapGet("/", () => Results.Text("""
    Link shortener on a Patroni PostgreSQL cluster
      POST /links           {"url": "...", "code": "optional"}   header Idempotency-Key: <any string>
      GET  /links/{code}    lookup (replica first, primary fallback)
      GET  /r/{code}        302 redirect
      GET  /stats           row count and replication lag, from a replica
      GET  /health/db       which node serves the writer and reader endpoints
    """));

app.MapPost("/links", async (CreateLinkRequest body, HttpContext http, LinkRepository repo, CancellationToken ct) =>
{
    if (!Uri.TryCreate(body.Url, UriKind.Absolute, out var uri) || uri.Scheme is not ("http" or "https"))
        return Results.BadRequest(new { error = "url must be an absolute http(s) URL" });
    if (body.Code is not null && !codePattern.IsMatch(body.Code))
        return Results.BadRequest(new { error = "code must be 3-32 characters of A-Z a-z 0-9 _ -" });

    var key = http.Request.Headers["Idempotency-Key"].FirstOrDefault();
    var result = await repo.CreateAsync(uri.ToString(), body.Code, key, ct);
    var r = result.Value;

    http.Response.Headers["X-DB-Attempts"] = result.Attempts.ToString();
    http.Response.Headers["X-DB-Elapsed-Ms"] = result.ElapsedMs.ToString();
    if (r.Conflict is not null)
        return Results.Conflict(new { error = r.Conflict, existing = r.Link });
    return Results.Json(new { r.Link.Code, r.Link.Url, r.Link.CreatedAt, replayed = !r.Created, attempts = result.Attempts, elapsedMs = result.ElapsedMs },
        statusCode: r.Created ? StatusCodes.Status201Created : StatusCodes.Status200OK);
});

app.MapGet("/links/{code}", async (string code, HttpContext http, LinkRepository repo, CancellationToken ct) =>
{
    var r = await repo.GetAsync(code, ct);
    http.Response.Headers["X-Served-By"] = r.ServedBy;
    return r.Link is null
        ? Results.NotFound(new { error = "unknown code", servedBy = r.ServedBy })
        : Results.Ok(new { r.Link.Code, r.Link.Url, r.Link.CreatedAt, servedBy = r.ServedBy });
});

app.MapGet("/r/{code}", async (string code, HttpContext http, LinkRepository repo, CancellationToken ct) =>
{
    var r = await repo.GetAsync(code, ct);
    http.Response.Headers["X-Served-By"] = r.ServedBy;
    return r.Link is null ? Results.NotFound() : Results.Redirect(r.Link.Url);
});

app.MapGet("/stats", async (Db db, CancellationToken ct) =>
{
    await using var cmd = db.Reader.CreateCommand("""
        SELECT (SELECT count(*) FROM links),
               extract(epoch FROM now() - pg_last_xact_replay_timestamp()) * 1000
        """);
    await using var r = await cmd.ExecuteReaderAsync(ct);
    await r.ReadAsync(ct);
    return Results.Ok(new { links = r.GetInt64(0), replayLagMs = r.IsDBNull(1) ? (double?)null : Math.Round(r.GetDouble(1)), servedBy = "replica" });
});

app.MapGet("/health/db", async (Db db, LinkCache cache, CancellationToken ct) =>
{
    async Task<object> Probe(NpgsqlDataSource source)
    {
        try
        {
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct);
            timeout.CancelAfter(TimeSpan.FromSeconds(3));
            await using var cmd = source.CreateCommand("SELECT inet_server_addr()::text, pg_is_in_recovery()");
            await using var r = await cmd.ExecuteReaderAsync(timeout.Token);
            await r.ReadAsync(timeout.Token);
            return new { ok = true, server = r.GetString(0), isReplica = r.GetBoolean(1) };
        }
        catch (Exception e) { return new { ok = false, error = e.Message.Split('\n')[0] }; }
    }

    var writer = await Probe(db.Writer);
    var reader = await Probe(db.Reader);
    return Results.Ok(new { writer, reader, cache = await cache.ProbeAsync() });
});

app.Run();

public sealed record CreateLinkRequest(string Url, string? Code);
