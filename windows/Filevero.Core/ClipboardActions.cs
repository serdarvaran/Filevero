using System.Globalization;
using System.Text;
using System.Text.Json;
namespace Filevero.Core;

/// One-step changes offered for a clipboard history item; mirrors the Mac `ClipboardAction`.
public enum ClipboardAction { Uppercase, Lowercase, TitleCase, TidyWhitespace, FormatJson, QrCode, SavePng, SaveJpg }

public static class ClipboardActions
{
    public static string Title(ClipboardAction action)=>action switch
    {
        ClipboardAction.Uppercase=>"UPPERCASE",ClipboardAction.Lowercase=>"lowercase",ClipboardAction.TitleCase=>"Title Case",
        ClipboardAction.TidyWhitespace=>"Tidy Whitespace",ClipboardAction.FormatJson=>"Format JSON",ClipboardAction.QrCode=>"Copy as QR Code",
        ClipboardAction.SavePng=>"Save as PNG",_=>"Save as JPG",
    };

    public static ClipboardAction[] Available(ClipboardKind kind)=>kind switch
    {
        ClipboardKind.Text or ClipboardKind.RichText=>[ClipboardAction.Uppercase,ClipboardAction.Lowercase,ClipboardAction.TitleCase,ClipboardAction.TidyWhitespace,ClipboardAction.FormatJson,ClipboardAction.QrCode],
        ClipboardKind.Link=>[ClipboardAction.QrCode],
        ClipboardKind.Image=>[ClipboardAction.SavePng,ClipboardAction.SaveJpg],
        _=>[],
    };

    /// The rewritten text, or null when the action does not rewrite text or the text cannot be rewritten (invalid JSON).
    /// Case changes use the interface language, so Turkish turns "i" into "İ".
    public static string? Transform(ClipboardAction action,string text,string language)
    {
        var culture=CultureInfo.GetCultureInfo(language=="tr"?"tr-TR":"en-US");
        return action switch
        {
            ClipboardAction.Uppercase=>text.ToUpper(culture),
            ClipboardAction.Lowercase=>text.ToLower(culture),
            ClipboardAction.TitleCase=>TitleCased(text,culture),
            ClipboardAction.TidyWhitespace=>Tidied(text),
            ClipboardAction.FormatJson=>IndentedJson(text),
            _=>null,
        };
    }

    private static string TitleCased(string text,CultureInfo culture)
    {
        var result=new StringBuilder(text.Length);var startsWord=true;
        foreach(var character in text){result.Append(startsWord?char.ToUpper(character,culture):char.ToLower(character,culture));startsWord=char.IsWhiteSpace(character);}
        return result.ToString();
    }

    private static string Tidied(string text)
    {
        var lines=new List<string>();
        foreach(var line in text.Replace("\r\n","\n").Split('\n','\r'))
        {
            var trimmed=line.TrimEnd();
            if(trimmed.Length==0&&(lines.Count==0||lines[^1].Length==0))continue;
            lines.Add(trimmed);
        }
        while(lines.Count>0&&lines[^1].Length==0)lines.RemoveAt(lines.Count-1);
        return string.Join("\n",lines);
    }

    /// Re-indents the text itself rather than re-encoding parsed values, so key order, numbers and escapes stay as copied.
    private static string? IndentedJson(string text)
    {
        try{using var _=JsonDocument.Parse(text);}catch(JsonException){return null;}
        var output=new StringBuilder();var depth=0;var inString=false;var escaped=false;
        void Newline()=>output.Append('\n').Append(' ',depth*2);
        for(var index=0;index<text.Length;index++)
        {
            var character=text[index];
            if(inString){output.Append(character);if(escaped)escaped=false;else if(character=='\\')escaped=true;else if(character=='"')inString=false;continue;}
            switch(character)
            {
                case '"':inString=true;output.Append(character);break;
                case '{' or '[':
                    var closing=character=='{'?'}':']';var next=index+1;while(next<text.Length&&char.IsWhiteSpace(text[next]))next++;
                    if(next<text.Length&&text[next]==closing){output.Append(character).Append(closing);index=next;}
                    else{output.Append(character);depth++;Newline();}
                    break;
                case '}' or ']':depth--;Newline();output.Append(character);break;
                case ',':output.Append(character);Newline();break;
                case ':':output.Append(": ");break;
                default:if(!char.IsWhiteSpace(character))output.Append(character);break;
            }
        }
        return output.ToString();
    }

    public static string ImageFileName(DateTime now,string format)=>"Clipboard Image "+now.ToString("yyyy-MM-dd HH.mm.ss",CultureInfo.InvariantCulture)+"."+format;
}
