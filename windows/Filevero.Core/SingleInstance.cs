using System.Buffers.Binary;
using System.Diagnostics;
using System.IO.Pipes;
using System.Text.Json;
namespace Filevero.Core;
/// One Filevero per user session: later launches hand their arguments to the first over a user-only pipe.
public sealed class SingleInstance:IDisposable
{
    private readonly Mutex mutex;private readonly string pipe;private readonly CancellationTokenSource lifetime=new();private NamedPipeServerStream? server;
    public bool Primary{get;}
    public SingleInstance(string? testName=null)
    {
        // Linux sessions of different users can share an id, so the user name is part of the name there.
        var name=testName??"Filevero.Desktop.v1."+Process.GetCurrentProcess().SessionId+(OperatingSystem.IsWindows()?"":"."+Environment.UserName);pipe=name;mutex=new(false,"Local\\"+name);try{Primary=mutex.WaitOne(0);}catch(AbandonedMutexException){Primary=true;}
    }
    public void Start(Action<string[]> receive)
    {
        if(!Primary)throw new InvalidOperationException("Only the primary instance can listen.");_ = Task.Run(async()=>
        {
            while(!lifetime.IsCancellationRequested)
            {
                try
                {
                    using var connection=new NamedPipeServerStream(pipe,PipeDirection.InOut,1,PipeTransmissionMode.Byte,PipeOptions.Asynchronous|PipeOptions.CurrentUserOnly);server=connection;await connection.WaitForConnectionAsync(lifetime.Token);var prefix=new byte[4];await connection.ReadExactlyAsync(prefix,lifetime.Token);var length=BinaryPrimitives.ReadInt32LittleEndian(prefix);if(length is <2 or >131072)continue;var data=new byte[length];await connection.ReadExactlyAsync(data,lifetime.Token);var paths=JsonSerializer.Deserialize<string[]>(data);if(paths is null||paths.Length>256||paths.Any(p=>p is null||p.Length>16384))continue;receive(paths);await connection.WriteAsync(new byte[]{1},lifetime.Token);
                }
                catch(OperationCanceledException){break;}catch(ObjectDisposedException)when(lifetime.IsCancellationRequested){break;}catch(Exception error)when(error is IOException or JsonException or UnauthorizedAccessException){if(!lifetime.IsCancellationRequested)await Task.Delay(100);}
                finally{server=null;}
            }
        });
    }
    public async Task Notify(string[] paths)
    {
        using var timeout=new CancellationTokenSource(TimeSpan.FromSeconds(4));using var client=new NamedPipeClientStream(".",pipe,PipeDirection.InOut,PipeOptions.Asynchronous|PipeOptions.CurrentUserOnly);await client.ConnectAsync(timeout.Token);var data=JsonSerializer.SerializeToUtf8Bytes(paths.Take(256));if(data.Length>131072)throw new IOException("Choose fewer files to open.");var prefix=new byte[4];BinaryPrimitives.WriteInt32LittleEndian(prefix,data.Length);await client.WriteAsync(prefix,timeout.Token);await client.WriteAsync(data,timeout.Token);var ack=new byte[1];await client.ReadExactlyAsync(ack,timeout.Token);
    }
    public void Dispose(){lifetime.Cancel();server?.Dispose();if(Primary)mutex.ReleaseMutex();mutex.Dispose();}
}
