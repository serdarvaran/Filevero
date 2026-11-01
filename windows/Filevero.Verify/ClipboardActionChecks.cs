using Filevero.Core;
internal static class ClipboardActionChecks
{
    internal static void Run(Action<bool,string> check)
    {
        check(ClipboardActions.Transform(ClipboardAction.Uppercase,"istanbul ılık","tr")=="İSTANBUL ILIK"&&ClipboardActions.Transform(ClipboardAction.Uppercase,"istanbul","en")=="ISTANBUL","Uppercase ignores the interface language");
        check(ClipboardActions.Transform(ClipboardAction.Lowercase,"İSTANBUL IŞIK","tr")=="istanbul ışık","Turkish lowercase differs from macOS");
        check(ClipboardActions.Transform(ClipboardAction.TitleCase,"iZMİR ve  ılgaz\ndağı","tr")=="İzmir Ve  Ilgaz\nDağı","Title case differs from macOS");
        check(ClipboardActions.Transform(ClipboardAction.TidyWhitespace,"  \n\nBaşlık   \r\n\r\n\r\n\tGövde satırı \t\n\n\n","en")=="Başlık\n\n\tGövde satırı","Whitespace tidying differs from macOS");
        check(ClipboardActions.Transform(ClipboardAction.FormatJson,"{\"ad\":\"Ayşe\",\"liste\":[1,2,{}],\"boş\":[], \"x\":\"a\\\"b, {c}\"}","en")=="{\n  \"ad\": \"Ayşe\",\n  \"liste\": [\n    1,\n    2,\n    {}\n  ],\n  \"boş\": [],\n  \"x\": \"a\\\"b, {c}\"\n}","JSON indentation differs from macOS");
        check(ClipboardActions.Transform(ClipboardAction.FormatJson,"{ad: 1}","en") is null&&ClipboardActions.Transform(ClipboardAction.QrCode,"x","en") is null,"Invalid JSON or a non-text action changed the text");
        check(ClipboardActions.Available(ClipboardKind.Text).Length==6&&ClipboardActions.Available(ClipboardKind.Link).SequenceEqual([ClipboardAction.QrCode])&&ClipboardActions.Available(ClipboardKind.Image).SequenceEqual([ClipboardAction.SavePng,ClipboardAction.SaveJpg])&&ClipboardActions.Available(ClipboardKind.File).Length==0,"Clipboard actions offered differ from macOS");
        foreach(var action in Enum.GetValues<ClipboardAction>())check(AppLocalization.Text(ClipboardActions.Title(action),"tr")!=ClipboardActions.Title(action),"Clipboard action has no Turkish title: "+action);
        check(ClipboardActions.ImageFileName(new DateTime(2026,11,1,2,3,4),"png")=="Clipboard Image 2026-11-01 02.03.04.png","Saved clipboard image name differs from macOS");
    }
}
