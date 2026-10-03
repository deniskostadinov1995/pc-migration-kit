// PC Migration Kit - Verify & fix: what from the backup is not on this PC (any more),
// and putting back the items you tick.
// Written by Claude 2026-10-02.
using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Shell;

namespace PCMK
{
    public class VerifyPage : IPage, IStoppable, IDemo
    {
        readonly Shell _shell;
        readonly FrameworkElement _v;
        BackupInfo _b;
        EngineRun _run;
        bool _busy, _started, _autostart;
        List<object> _checks = new List<object>();
        readonly ObservableCollection<SelItem> _items = new ObservableCollection<SelItem>();

        public FrameworkElement View { get { return _v; } }
        public bool IsBusy { get { return _busy; } }
        T E<T>(string n) where T : class { return Ui.Find<T>(_v, n); }

        public VerifyPage(Shell shell)
        {
            _shell = shell;
            _v = (FrameworkElement)Ui.LoadXaml("Verify.xaml");
            E<TreeView>("Results").ItemsSource = _items;
            E<Button>("CheckNow").Click += (s, e) => RunCheck(null);
            E<Button>("FixSelected").Click += async (s, e) => await Fix();
            E<Button>("ChangeBackup").Click += async (s, e) =>
            {
                var b = await _shell.PickBackup("Compare with which backup?", _b);
                if (b != null) { SetBackup(b); _checks.Clear(); Rebuild(); }
            };
            E<CheckBox>("OnlyProblems").Checked += (s, e) => Rebuild();
            E<CheckBox>("OnlyProblems").Unchecked += (s, e) => Rebuild();
        }

        public void Select(string dir, bool autostart = false)
        {
            var b = BackupInfo.Load(dir);
            if (b != null) SetBackup(b);
            _autostart = autostart;
        }

        public void OnShown()
        {
            _shell.SetTitle("Verify & fix");
            if (!_started)
            {
                _started = true;
                if (_b == null && !string.IsNullOrEmpty(_shell.Opts.BackupPath)) { var b = BackupInfo.Load(_shell.Opts.BackupPath.TrimEnd('\\')); if (b != null) SetBackup(b); }
                if (_b == null) SetBackup(DefaultBackup());
                if (_shell.Opts.Page == "verify")
                {
                    if (!string.IsNullOrEmpty(_shell.Opts.RunSelection) && _b != null) { RunCheck(_shell.Opts.RunSelection); return; }
                    if (_shell.Opts.AutoStart) _autostart = true;
                }
            }
            if (_autostart && !_busy && _b != null) { _autostart = false; RunCheck(null); }
        }

        /// <summary>The backup this PC was restored from (it has a restore state), else the newest one.</summary>
        static BackupInfo DefaultBackup()
        {
            List<BackupInfo> list;
            try { list = Kit.FindBackups(); } catch { return null; }
            foreach (var b in list) if (File.Exists(Path.Combine(Kit.StateDir, "restore-state-" + b.Id + ".json"))) return b;
            return list.FirstOrDefault();
        }

        void SetBackup(BackupInfo b)
        {
            _b = b;
            E<TextBlock>("BackupTitle").Text = b == null ? "No backup found" : "Compared with: " + b.Title;
            E<TextBlock>("BackupLine").Text = b == null ? "Open the program from a backup folder, or use \"Other backup...\"." : b.Subtitle + "   ·   " + b.Dir;
            E<Button>("CheckNow").IsEnabled = b != null;
        }

        // ============================================================== check ===
        void RunCheck(string fixFile)
        {
            if (_b == null || _busy) return;
            _busy = true;
            var outFile = Path.Combine(Kit.TempDir, "verify-" + DateTime.Now.ToString("yyyyMMdd-HHmmss") + ".json");
            var args = new List<string> { "-BackupPath", _b.Dir, "-Out", outFile };
            if (fixFile != null) { args.Add("-FixFile"); args.Add(fixFile); }
            _run = new EngineRun("Verify.ps1", args.ToArray());
            E<ProgressBar>("CheckBar").Visibility = Visibility.Visible;
            E<Button>("CheckNow").IsEnabled = false;
            E<Button>("FixSelected").IsEnabled = false;
            E<TextBlock>("ResultTitle").Text = fixFile != null ? "Putting things back" : "Checking";
            var log = new LogView(E<ListBox>("LogList"));
            log.Clear();
            E<Border>("LogCard").Visibility = fixFile != null ? Visibility.Visible : Visibility.Collapsed;
            var live = new List<object>();
            bool fixing = fixFile != null;
            _run.OnEvent += ev =>
            {
                log.Handle(ev);
                switch (ev.Type)
                {
                    case "phase": if (ev.S("state") == "start") E<TextBlock>("ResultLine").Text = "Checking: " + ev.S("name") + "..."; break;
                    case "check": live.Add(ev.Data); if (!fixing) E<TextBlock>("ResultTitle").Text = "Checking  ·  " + live.Count + " things looked at"; break;
                    case "log": if (fixing && ev.S("lvl") == "step") { E<TextBlock>("ResultLine").Text = ev.S("text").Trim('=', ' '); live.Clear(); } break;
                }
            };
            _run.OnExit += code =>
            {
                _busy = false;
                E<ProgressBar>("CheckBar").Visibility = Visibility.Collapsed;
                E<Button>("CheckNow").IsEnabled = true;
                var res = Json.ReadFile(outFile);
                _checks = res != null ? Json.Arr(res, "Checks") : live;
                if (_run.Cancelled) E<TextBlock>("ResultLine").Text = "Stopped.";
                else if (res == null && code != 0 && code != 2) E<TextBlock>("ResultLine").Text = "The check stopped with an error (code " + code + ")" + (_run.Issues.Count > 0 ? ": " + _run.Issues.Last() : "");
                Rebuild();
                _shell.Taskbar.ProgressState = TaskbarItemProgressState.None;
            };
            _shell.Taskbar.ProgressState = TaskbarItemProgressState.Indeterminate;
            try { _run.Start(); }
            catch (Exception ex) { _busy = false; E<TextBlock>("ResultLine").Text = "Could not start the engine: " + ex.Message; }
        }

        void Rebuild()
        {
            _items.Clear();
            var only = E<CheckBox>("OnlyProblems").IsChecked == true;
            int total = _checks.Count, problems = 0, fixable = 0;
            foreach (var grp in _checks.GroupBy(c => Json.Str(c, "Area") ?? "Other"))
            {
                var bad = grp.Where(c => Json.Str(c, "Status") != "ok" && Json.Str(c, "Status") != "info").ToList();
                var g = Model.Group(grp.Key, (grp.Count() - grp.Count(c => Json.Str(c, "Status") != "ok")) + " ok" + (bad.Count > 0 ? "  ·  " + bad.Count + " to look at" : ""), AreaGlyph(grp.Key));
                foreach (var c in grp)
                {
                    var status = Json.Str(c, "Status") ?? "info";
                    if (status != "ok" && status != "info") problems++;
                    if (only && status == "ok") continue;
                    var fixId = Json.Str(c, "FixId");
                    SelItem it;
                    if (!string.IsNullOrEmpty(fixId) && status != "ok" && !fixId.StartsWith("step|"))
                    {
                        it = Model.Leaf(g, "Fix", fixId, Json.Str(c, "Name"), Json.Str(c, "Detail"), G.Repair, status != "info");
                        it.Note = "Fix: " + Json.Str(c, "FixText");
                        fixable++;
                    }
                    else it = Model.Info(g, Json.Str(c, "Name"), Json.Str(c, "Detail") + (fixId != null && fixId.StartsWith("step|") ? "  ·  run it from the Restore page" : ""), status == "ok" ? G.Check : G.Info);
                    var tone = status == "ok" ? "ok" : status == "missing" ? "bad" : status == "info" ? null : "warn";
                    it.Tags.Add(new Tag(status, tone));
                    it.PropertyChanged += (s, e) => { if (e.PropertyName == "IsChecked") UpdateFixButton(); };
                }
                if (g.Children.Count == 0) continue;
                g.IsExpanded = bad.Count > 0 || !only;
                _items.Add(g);
            }
            if (total > 0)
            {
                E<TextBlock>("ResultTitle").Text = problems == 0 ? "Everything from the backup is in place" : Fmt.Plural(problems, "thing") + " to look at";
                E<TextBlock>("ResultLine").Text = total + " checks  ·  " + fixable + " can be put back automatically  ·  " + (only ? "showing only what needs attention" : "showing everything") +
                    (_shell.IsAdmin ? "" : "  ·  checked without administrator rights: SYSTEM tasks and Windows features can't be seen (the admin chip bottom-left restarts the program as administrator)");
            }
            UpdateFixButton();
        }

        static string AreaGlyph(string area)
        {
            switch (area)
            {
                case "Apps": return G.Apps;
                case "Services": return G.Service;
                case "Scheduled tasks": return G.Clock;
                case "Startup": return G.Rocket;
                case "Environment": return G.Env;
                case "Windows settings": return G.Desktop;
                case "Windows features": return G.Settings;
                case "WSL": return G.Linux;
                case "Drives": return G.Drive;
                case "Docker": return G.Box;
                case "Media server": return G.Media;
                case "Restore": return G.Download;
                default: return G.Info;
            }
        }

        List<string> Ticked()
        {
            return _items.SelectMany(g => g.All()).Where(i => i.Section == "Fix" && i.Kind == ItemKind.Item && i.IsChecked == true).Select(i => i.Key).Distinct().ToList();
        }

        void UpdateFixButton()
        {
            var n = Ticked().Count;
            E<Button>("FixSelected").IsEnabled = n > 0 && !_busy;
            E<TextBlock>("FixText").Text = n == 0 ? "Fix the ticked items" : "Fix " + Fmt.Plural(n, "item");
        }

        async Task Fix()
        {
            var ids = Ticked();
            if (ids.Count == 0 || _b == null) return;
            var file = Path.Combine(Kit.TempDir, "verify-fix-" + DateTime.Now.ToString("yyyyMMdd-HHmmss") + ".json");
            Json.WriteFile(file, new Dictionary<string, object> { { "Fix", ids.ToArray() } });
            if (!_shell.IsAdmin)
            {
                var a = await _shell.Ask("Administrator rights needed", "Recreating tasks and services, installing programs and changing the power plan need administrator rights. The program restarts as administrator and puts back the " + Fmt.Plural(ids.Count, "item") + " you ticked.", null, "go|Restart and fix", "cancel|Cancel");
                if (a != "go") return;
                var args = "--page verify --backup " + Native.QuoteArg(_b.Dir) + " --run-selection " + Native.QuoteArg(file);
                if (Native.RelaunchAsAdmin(args)) Application.Current.Shutdown();
                else await _shell.Info("Not restarted", "Windows did not give administrator rights (the prompt was cancelled).");
                return;
            }
            RunCheck(file);
        }

        public void Stop() { if (_run != null) _run.Cancel(); }

        public async Task Demo(string dir, Shell shell)
        {
            if (_b == null) return;
            RunCheck(null);
            for (int i = 0; i < 240 && _busy; i++) await Task.Delay(500);
            await shell.Settle(500);
        }
    }
}
