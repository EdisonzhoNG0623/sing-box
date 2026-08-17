using System;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;

internal static class PortableLauncher
{
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int MessageBoxW(IntPtr hWnd, string text, string caption, uint type);

    [STAThread]
    private static int Main()
    {
        try
        {
            string root = AppDomain.CurrentDomain.BaseDirectory;
            string script = Path.Combine(root, "start.ps1");
            if (!File.Exists(script))
            {
                throw new FileNotFoundException("Portable startup script was not found.", script);
            }

            var startInfo = new ProcessStartInfo
            {
                FileName = "powershell.exe",
                Arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + script + "\"",
                WorkingDirectory = root,
                UseShellExecute = false,
                CreateNoWindow = true,
                WindowStyle = ProcessWindowStyle.Hidden
            };

            using (Process process = Process.Start(startInfo))
            {
                if (process == null)
                {
                    throw new InvalidOperationException("PowerShell could not be started.");
                }
                process.WaitForExit();
                if (process.ExitCode != 0)
                {
                    throw new InvalidOperationException("Portable startup failed. See data\\logs\\daemon.stderr.log.");
                }
                return 0;
            }
        }
        catch (Exception error)
        {
            MessageBoxW(IntPtr.Zero, error.Message, "sing-box portable", 0x10);
            return 1;
        }
    }
}
