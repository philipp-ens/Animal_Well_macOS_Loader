// Prototype: reach ANIMAL WELL's Steam Cloud save without the Steam app, through a Steam client connection
// (SteamKit2). Tested on 2026-11-22: list, download, upload and delete all work with a QR sign-in.
// NOT yet tested: that Steam on Windows takes an upload made this way as the game's save.
//
// Build and run (needs the .NET 8 SDK and Apple's command line tools):
//     swiftc -O qr.swift -o qr
//     dotnet run -- . out [local save to compare downloads with]
// A browser page opens with a QR code for the Steam mobile app (Steam Guard tab, "Scan a QR code").
// After the sign-in the program lists the cloud files, downloads the first one into out/, and then stays signed
// in and carries out commands written to out/command.txt, one per line, fields separated by TABs:
//     list
//     download <number from the list>
//     upload <local file> <cloud name> [platforms: 1 = Windows only, default all]
//     delete <cloud name>
//     quit
// The save's cloud name is "%WinAppDataLocalLow%Billy Basso/Animal Well/AnimalWell.sav" (platforms: 1).
// It signs off by itself after 45 idle minutes. The login tokens stay in memory and are never printed or saved;
// each sign-in still shows up in the account's Steam Guard device list as "Cloud prototype (temporary)".
// Known gap: uploads are sent unzipped (the Steam client zips them).
using System.Diagnostics;
using System.IO.Compression;
using System.Security.Cryptography;
using System.Text.Json;
using SteamKit2;
using SteamKit2.Authentication;
using SteamKit2.Internal;

const uint AppId = 813230;
string qrDir = args[0], outDir = args[1];
string? localSave = args.Length > 2 ? args[2] : null;
Directory.CreateDirectory(outDir);

void PageStatus(string text) =>
    File.WriteAllText(Path.Combine(qrDir, "status.js"), "showStatus(" + JsonSerializer.Serialize(text) + ");");
void ShowQr(string url)
{
    var tmp = Path.Combine(qrDir, "qr_new.png");
    Process.Start(Path.Combine(qrDir, "qr"), new[] { url, tmp })!.WaitForExit();
    File.Move(tmp, Path.Combine(qrDir, "qr.png"), true);
}
string Sha1(byte[] data) => Convert.ToHexString(SHA1.HashData(data)).ToLowerInvariant();

var client = new SteamClient();
var manager = new CallbackManager(client);
var user = client.GetHandler<SteamUser>()!;
var unified = client.GetHandler<SteamUnifiedMessages>()!;

var connected = new TaskCompletionSource();
var loggedOn = new TaskCompletionSource<EResult>();
manager.Subscribe<SteamClient.ConnectedCallback>(_ => connected.TrySetResult());
manager.Subscribe<SteamClient.DisconnectedCallback>(_ => { connected.TrySetException(new Exception("disconnected")); loggedOn.TrySetResult(EResult.NoConnection); });
manager.Subscribe<SteamUser.LoggedOnCallback>(cb => loggedOn.TrySetResult(cb.Result));

var running = true;
var pump = Task.Run(() => { while (running) manager.RunWaitCallbacks(TimeSpan.FromMilliseconds(200)); });

Console.WriteLine("connecting to Steam's network ...");
client.Connect();
await connected.Task;
Console.WriteLine("connected");

// --- sign in by QR code
var session = await client.Authentication.BeginAuthSessionViaQRAsync(new AuthSessionDetails { DeviceFriendlyName = "Cloud prototype (temporary)" });
session.ChallengeURLChanged = () => ShowQr(session.ChallengeURL);
ShowQr(session.ChallengeURL);
PageStatus("Waiting for you to scan the code with the Steam mobile app ...");
Process.Start("open", new[] { Path.Combine(qrDir, "page.html") });
using var limit = new CancellationTokenSource(TimeSpan.FromMinutes(4));
AuthPollResult poll;
try { poll = await session.PollingWaitForResultAsync(limit.Token); }
catch (OperationCanceledException)
{
    PageStatus("No approval arrived. Nothing was logged in. You can close this page.");
    Console.WriteLine("no approval within the time limit");
    running = false; client.Disconnect(); return 1;
}
PageStatus("Signed in. Running the cloud test ... you can close this page.");
user.LogOn(new SteamUser.LogOnDetails { Username = poll.AccountName, AccessToken = poll.RefreshToken });
var result = await loggedOn.Task;
Console.WriteLine("logged on to Steam: " + result);
if (result != EResult.OK) { running = false; client.Disconnect(); return 1; }

// --- stay signed in and carry out commands written to <output folder>/command.txt, one line each:
//       list | download <number> | upload <local file> <cloud name> | delete <cloud name> | quit
var cloud = unified.CreateService<Cloud>();
using var http = new HttpClient();
var files = new List<CCloud_UserFile>();
var commandFile = Path.Combine(outDir, "command.txt");
File.Delete(commandFile);
T Wait<T>(AsyncJob<T> job) where T : CallbackMsg { job.Timeout = TimeSpan.FromSeconds(40); return job.ToTask().GetAwaiter().GetResult(); }

async Task List()
{
    var list = Wait(cloud.EnumerateUserFiles(new CCloud_EnumerateUserFiles_Request { appid = AppId, extended_details = true, count = 100 }));
    Console.WriteLine($"Cloud.EnumerateUserFiles: {list.Result}, total_files={list.Body.total_files}");
    files = list.Body.files;
    for (int i = 0; i < files.Count; i++)
    {
        var f = files[i];
        Console.WriteLine($"  [{i}] \"{f.filename}\" size={f.file_size} time={DateTimeOffset.FromUnixTimeSeconds((long)f.timestamp):u} " +
                          $"sha={f.file_sha} platforms=[{string.Join(",", f.platforms_to_sync)}] flags={f.flags}");
    }
    await Task.CompletedTask;
}

async Task Download(int i)
{
    var f = files[i];
    var dl = Wait(cloud.ClientFileDownload(new CCloud_ClientFileDownload_Request { appid = AppId, filename = f.filename }));
    Console.WriteLine($"Cloud.ClientFileDownload: {dl.Result}, stored size={dl.Body.file_size}, raw size={dl.Body.raw_file_size}, " +
                      $"encrypted={dl.Body.encrypted}, host={dl.Body.url_host}");
    if (dl.Result != EResult.OK || string.IsNullOrEmpty(dl.Body.url_host)) return;
    var request = new HttpRequestMessage(HttpMethod.Get, (dl.Body.use_https ? "https://" : "http://") + dl.Body.url_host + dl.Body.url_path);
    foreach (var h in dl.Body.request_headers) request.Headers.TryAddWithoutValidation(h.name, h.value);
    var response = await http.SendAsync(request);
    var data = await response.Content.ReadAsByteArrayAsync();
    Console.WriteLine($"  download: http {(int)response.StatusCode}, {data.Length} bytes");
    if (!response.IsSuccessStatusCode) return;
    if (dl.Body.file_size != dl.Body.raw_file_size)             // Steam stored it zipped
    {
        using var zip = new ZipArchive(new MemoryStream(data));
        using var entry = zip.Entries[0].Open();
        using var plain = new MemoryStream();
        entry.CopyTo(plain);
        data = plain.ToArray();
        Console.WriteLine($"  unzipped to {data.Length} bytes");
    }
    var outFile = Path.Combine(outDir, $"cloud_{i}.bin");
    File.WriteAllBytes(outFile, data);
    Console.WriteLine($"  saved as {outFile}, sha1={Sha1(data)}, matches listing: {Sha1(data) == f.file_sha.ToLowerInvariant()}");
    if (localSave != null && File.Exists(localSave))
    {
        var local = File.ReadAllBytes(localSave);
        Console.WriteLine($"  local save: {local.Length} bytes, sha1={Sha1(local)}, identical to cloud file: {local.AsSpan().SequenceEqual(data)}");
    }
}

// Upload the way the Steam client does: open a batch, announce the file, PUT the bytes, commit, close the batch.
async Task Upload(string localFile, string cloudName, uint platforms)
{
    var data = File.ReadAllBytes(localFile);
    var sha = SHA1.HashData(data);
    var batch = Wait(cloud.BeginAppUploadBatch(new CCloud_BeginAppUploadBatch_Request
        { appid = AppId, machine_name = "Mac", files_to_upload = { cloudName }, client_id = (ulong)Random.Shared.NextInt64() }));
    Console.WriteLine($"Cloud.BeginAppUploadBatch: {batch.Result}, batch_id={batch.Body.batch_id}, app_change_number={batch.Body.app_change_number}");
    if (batch.Result != EResult.OK) return;
    var ok = false;
    try
    {
        var begin = Wait(cloud.ClientBeginFileUpload(new CCloud_ClientBeginFileUpload_Request
        {
            appid = AppId, file_size = (uint)data.Length, raw_file_size = (uint)data.Length, file_sha = sha,
            time_stamp = (ulong)DateTimeOffset.UtcNow.ToUnixTimeSeconds(), filename = cloudName,
            platforms_to_sync = platforms, can_encrypt = false, is_shared_file = false, upload_batch_id = batch.Body.batch_id,
        }));
        Console.WriteLine($"Cloud.ClientBeginFileUpload: {begin.Result}, blocks={begin.Body.block_requests.Count}, encrypt={begin.Body.encrypt_file}");
        if (begin.Result == EResult.OK)
        {
            var sent = true;
            foreach (var b in begin.Body.block_requests)
            {
                var req = new HttpRequestMessage(new HttpMethod(b.http_method switch { 1 => "GET", 3 => "POST", _ => "PUT" }),
                                                 (b.use_https ? "https://" : "http://") + b.url_host + b.url_path);
                var body = b.explicit_body_data is { Length: > 0 } ? b.explicit_body_data : data.AsSpan((int)b.block_offset, (int)b.block_length).ToArray();
                req.Content = new ByteArrayContent(body);
                foreach (var h in b.request_headers)
                    if (!req.Headers.TryAddWithoutValidation(h.name, h.value)) req.Content.Headers.TryAddWithoutValidation(h.name, h.value);
                var resp = await http.SendAsync(req);
                Console.WriteLine($"  block {b.block_offset}+{b.block_length}: {req.Method} -> http {(int)resp.StatusCode}");
                sent &= resp.IsSuccessStatusCode;
            }
            var commit = Wait(cloud.ClientCommitFileUpload(new CCloud_ClientCommitFileUpload_Request
                { transfer_succeeded = sent, appid = AppId, file_sha = sha, filename = cloudName }));
            Console.WriteLine($"Cloud.ClientCommitFileUpload: {commit.Result}, file_committed={commit.Body.file_committed}");
            ok = sent && commit.Result == EResult.OK && commit.Body.file_committed;
        }
    }
    finally
    {
        var done = Wait(cloud.CompleteAppUploadBatchBlocking(new CCloud_CompleteAppUploadBatch_Request
            { appid = AppId, batch_id = batch.Body.batch_id, batch_eresult = (uint)(ok ? EResult.OK : EResult.Fail) }));
        Console.WriteLine($"Cloud.CompleteAppUploadBatchBlocking: {done.Result}");
    }
}

async Task Delete(string cloudName)
{
    var batch = Wait(cloud.BeginAppUploadBatch(new CCloud_BeginAppUploadBatch_Request
        { appid = AppId, machine_name = "Mac", files_to_delete = { cloudName }, client_id = (ulong)Random.Shared.NextInt64() }));
    Console.WriteLine($"Cloud.BeginAppUploadBatch: {batch.Result}, batch_id={batch.Body.batch_id}");
    if (batch.Result != EResult.OK) return;
    var del = Wait(cloud.ClientDeleteFile(new CCloud_ClientDeleteFile_Request { appid = AppId, filename = cloudName, upload_batch_id = batch.Body.batch_id }));
    Console.WriteLine($"Cloud.ClientDeleteFile: {del.Result}");
    var done = Wait(cloud.CompleteAppUploadBatchBlocking(new CCloud_CompleteAppUploadBatch_Request
        { appid = AppId, batch_id = batch.Body.batch_id, batch_eresult = (uint)del.Result }));
    Console.WriteLine($"Cloud.CompleteAppUploadBatchBlocking: {done.Result}");
}

var queue = new Queue<string>(new[] { "list", "download 0" });
var idleSince = DateTime.UtcNow;
while (true)
{
    if (queue.Count == 0)
    {
        if (File.Exists(commandFile))
        {
            foreach (var l in File.ReadAllLines(commandFile)) if (l.Trim().Length > 0) queue.Enqueue(l.Trim());
            File.Delete(commandFile);
        }
        else if (DateTime.UtcNow - idleSince > TimeSpan.FromMinutes(45)) { Console.WriteLine("idle for 45 minutes, signing off"); break; }
        else { await Task.Delay(500); continue; }
    }
    var line = queue.Dequeue();
    idleSince = DateTime.UtcNow;
    Console.WriteLine("> " + line);
    if (line == "quit") break;
    try
    {
        var parts = line.Split('\t');
        if (parts.Length == 1) parts = line.Split(' ', 2);
        switch (parts[0])
        {
            case "list": await List(); break;
            case "download": await Download(int.Parse(parts[1])); break;
            case "upload": await Upload(parts[1], parts[2], parts.Length > 3 ? uint.Parse(parts[3]) : 0xffffffff); break;         // tab-separated: upload<TAB>local file<TAB>cloud name
            case "delete": await Delete(parts[1]); break;
            default: Console.WriteLine("unknown command"); break;
        }
    }
    catch (Exception e) { Console.WriteLine("  failed: " + e.GetType().Name + ": " + e.Message); }
    Console.WriteLine("< end");
}

user.LogOff();
await Task.Delay(500);
running = false;
client.Disconnect();
Console.WriteLine("done");
return 0;
