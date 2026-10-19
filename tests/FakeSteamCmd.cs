using System;
using System.IO;

// Test executable only: never connects to Steam or accepts real credentials.
public class FakeSteamCmd
{
    private static void Log(string text)
    {
        Directory.CreateDirectory("logs");
        File.AppendAllText(Path.Combine("logs", "console_log.txt"), text + Environment.NewLine);
        Console.WriteLine(text);
    }

    public static int Main(string[] args)
    {
        Console.Write("Two-factor code: ");
        Console.Out.Flush();
        System.Threading.Thread.Sleep(150);
        if (Array.IndexOf(args, "guard_fail") >= 0)
        {
            Log("ERROR! Failed to log on (Invalid Login Auth Code)");
            return 0;
        }
        if (Array.IndexOf(args, "no_log") >= 0) return 0;
        Log("\nWaiting for user info...OK");
        int item = Array.IndexOf(args, "+workshop_download_item");
        if (item >= 0)
        {
            string id = args[item + 2];
            if (id == "222") Log("ERROR! Download item 222 failed (Failure).");
            else Log("Success. Downloaded item " + id + " to cached content");
        }
        return 0;
    }
}
