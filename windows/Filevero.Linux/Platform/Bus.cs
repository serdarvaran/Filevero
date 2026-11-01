using Tmds.DBus.Protocol;
namespace Filevero.Linux;

/// The session bus: calls into the desktop (portals, GNOME Shell extension, KWin) and Filevero's own
/// io.github.serdarvaran.Filevero object, which desktop scripts call to report events.
/// MessageWriter is a struct: a body writer takes it by reference so what it writes is counted in the message.
internal delegate void BodyWriter(ref MessageWriter writer);
internal static class Bus
{
    internal const string Name="io.github.serdarvaran.Filevero",ObjectPath="/io/github/serdarvaran/Filevero",Interface="io.github.serdarvaran.Filevero.Bridge";
    private static readonly Lazy<Task<DBusConnection>> session=new(async()=>{var connection=new DBusConnection(DBusAddress.Session??throw new InvalidOperationException("No desktop session bus."));await connection.ConnectAsync();return connection;});
    internal static Task<DBusConnection> Session=>session.Value;
    internal static async Task<T> CallAsync<T>(string destination,string path,string @interface,string member,string? signature,BodyWriter? body,MessageValueReader<T> read)
    {
        var connection=await Session;
        return await connection.CallMethodAsync(Build(connection,destination,path,@interface,member,signature,body),read,null);
    }
    private static MessageBuffer Build(DBusConnection connection,string destination,string path,string @interface,string member,string? signature,BodyWriter? body)
    {
        var writer=connection.GetMessageWriter();
        try{writer.WriteMethodCallHeader(destination,path,@interface,member,signature);body?.Invoke(ref writer);return writer.CreateMessage();}
        finally{writer.Dispose();}
    }
    internal static Task CallAsync(string destination,string path,string @interface,string member,string? signature=null,BodyWriter? body=null)=>
        CallAsync<bool>(destination,path,@interface,member,signature,body,static (_,_)=>true);
    internal static async Task<bool> HasOwnerAsync(string name)
    {
        try{return await CallAsync("org.freedesktop.DBus","/org/freedesktop/DBus","org.freedesktop.DBus","NameHasOwner","s",(ref MessageWriter w)=>w.WriteString(name),static (m,_)=>m.GetBodyReader().ReadBool());}
        catch(DBusExceptionBase){return false;}
    }
    /// Desktop scripts report events as Event(kind, tab-separated values).
    internal static async Task ExportAsync(Action<string,string[]> received)
    {
        var connection=await Session;connection.AddMethodHandler(new EventHandler(received));
        await connection.RequestNameAsync(Name,RequestNameOptions.Default);
    }
    private sealed class EventHandler(Action<string,string[]> received):IPathMethodHandler
    {
        public string Path=>ObjectPath;public bool HandlesChildPaths=>false;
        public ValueTask HandleMethodAsync(MethodContext context)
        {
            var request=context.Request;
            if(request.InterfaceAsString!=Interface||request.MemberAsString!="Event"||request.SignatureAsString!="ss"){context.ReplyUnknownMethodError();return ValueTask.CompletedTask;}
            var reader=request.GetBodyReader();var kind=reader.ReadString();var payload=reader.ReadString();
            received(kind,payload.Length==0?[]:payload.Split('\t'));
            if(!context.NoReplyExpected){using var writer=context.CreateReplyWriter(null!);context.Reply(writer.CreateMessage());}
            return ValueTask.CompletedTask;
        }
    }
}
