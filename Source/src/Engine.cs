// PC Migration Kit - runs the PowerShell engine and turns its "@@PCMK {json}"
// lines into events on the UI thread. Questions from the engine (Read-KitAnswer)
// are answered through stdin.
// Written by Claude 2026-10-02.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Threading;
using System.Windows.Threading;

namespace PCMK
{
    public class EngineEvent
    {
        public string Type;          // log, step, progress, copy, job, ask, phase, check, mstable, summary, exit, raw, steps, catalog ...
        public object Data;          // the parsed JSON (a dictionary), or null for raw lines
        public string Raw;           // the line as written
        public string S(string key) { return Json.Str(Data, key); }
        public double D(string key) { return Json.Dbl(Data, key); }
        public long L(string key) { return Json.Long(Data, key); }
        public bool B(string key) { return Json.Bool(Data, key); }
    }

    public class EngineRun
    {
        public string Script;
        public List<string> Args = new List<string>();
        public event Action<EngineEvent> OnEvent;
        public event Action<int> OnExit;
        public int ExitCode = -1;
        public bool Running { get; private set; }
        public bool Cancelled { get; private set; }
        public string LogFile;
        public readonly List<string> Issues = new List<string>();
        Process _p;
        readonly Dispatcher _ui;

        public EngineRun(string script, params string[] args)
        {
            Script = script;
            Args.AddRange(args);
            _ui = Dispatcher.CurrentDispatcher;
        }

        public void Start()
        {
            var file = Path.Combine(Kit.EngineDir, Script);
            var sb = new StringBuilder("-NoProfile -NonInteractive -ExecutionPolicy Bypass -File ");
            sb.Append(Native.QuoteArg(file));
            foreach (var a in Args) { sb.Append(' '); sb.Append(Native.QuoteArg(a)); }
            var psi = new ProcessStartInfo(Path.Combine(Environment.SystemDirectory, @"WindowsPowerShell\v1.0\powershell.exe"), sb.ToString())
            {
                UseShellExecute = false, CreateNoWindow = true,
                RedirectStandardOutput = true, RedirectStandardError = true, RedirectStandardInput = true,
                StandardOutputEncoding = Encoding.UTF8, StandardErrorEncoding = Encoding.UTF8,
                WorkingDirectory = Kit.EngineDir
            };
            psi.EnvironmentVariables["PCMK_GUI"] = "1";
            psi.EnvironmentVariables["PCMK_APP_EXE"] = Kit.ExePath;
            _p = new Process { StartInfo = psi, EnableRaisingEvents = true };
            _p.OutputDataReceived += (s, e) => { if (e.Data != null) Handle(e.Data, false); };
            _p.ErrorDataReceived += (s, e) => { if (e.Data != null) Handle(e.Data, true); };
            _p.Exited += (s, e) =>
            {
                // let the output readers drain before reporting the end
                try { _p.WaitForExit(); } catch { }
                int code = -1; try { code = _p.ExitCode; } catch { }
                ExitCode = code;
                Running = false;
                _ui.BeginInvoke(new Action(() => { var h = OnExit; if (h != null) h(code); }));
            };
            Running = true;
            _p.Start();
            // PowerShell reads its stdin with the console's code page unless told otherwise
            _p.StandardInput.AutoFlush = true;
            _p.BeginOutputReadLine();
            _p.BeginErrorReadLine();
        }

        void Handle(string line, bool isErr)
        {
            EngineEvent ev;
            if (line.StartsWith("@@PCMK ", StringComparison.Ordinal))
            {
                object data = null;
                try { data = Json.Parse(line.Substring(7)); } catch { }
                ev = new EngineEvent { Type = Json.Str(data, "t") ?? "raw", Data = data, Raw = line };
                if (ev.Type == "logfile") LogFile = ev.S("path");
                if (ev.Type == "log" && (ev.S("lvl") == "warn" || ev.S("lvl") == "fail")) lock (Issues) Issues.Add(ev.S("text"));
            }
            else
            {
                if (string.IsNullOrWhiteSpace(line)) return;
                ev = new EngineEvent { Type = isErr ? "stderr" : "raw", Raw = line.TrimEnd() };
            }
            _ui.BeginInvoke(new Action(() => { var h = OnEvent; if (h != null) h(ev); }));
        }

        /// <summary>Answers the engine's current question (Read-KitAnswer).</summary>
        public void Answer(string text)
        {
            try { if (_p != null && !_p.HasExited) _p.StandardInput.WriteLine(text ?? ""); } catch { }
        }

        /// <summary>Stops the engine and everything it started (robocopy, winget ...).</summary>
        public void Cancel()
        {
            Cancelled = true;
            try
            {
                if (_p != null && !_p.HasExited)
                {
                    var k = Process.Start(new ProcessStartInfo("taskkill.exe", "/T /F /PID " + _p.Id) { CreateNoWindow = true, UseShellExecute = false });
                    if (k != null) k.WaitForExit(5000);
                }
            }
            catch { }
        }
    }
}
