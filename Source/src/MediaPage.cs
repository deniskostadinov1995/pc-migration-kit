// PC Migration Kit - Media server & smart home: check every part, set up what is down.
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
    public class MediaPage : IPage, IStoppable, IDemo
    {
        readonly Shell _shell;
        readonly FrameworkElement _v;
        EngineRun _run;
        bool _busy, _checkedOnce;
        readonly ObservableCollection<SelItem> _items = new ObservableCollection<SelItem>();

        public FrameworkElement View { get { return _v; } }
        public bool IsBusy { get { return _busy; } }
        T E<T>(string n) where T : class { return Ui.Find<T>(_v, n); }

        static readonly Dictionary<string, string> Explain = new Dictionary<string, string>
        {
            { "qbittorrent", "download client - starts with Windows" }, { "radarr", "movies - a Windows service" }, { "radarr4k", "4K movies - a second Radarr service" },
            { "sonarr", "TV shows - a Windows service" }, { "jackett", "indexers - a Windows service" }, { "prowlarr", "indexers - runs from G:" },
            { "jellyfin", "the media server - runs from G:" }, { "caddy", "HTTPS for Jellyfin and Seerr from outside" }, { "duckdns", "keeps your domain pointed at your home" },
            { "docker", "runs Seerr and Jellystat" }, { "seerr", "requests - a Docker container" }, { "jellystat", "statistics - two Docker containers" },
            { "homeassistant", "Home Assistant OS in VirtualBox" }, { "network", "Private, so TVs and phones can reach the server" }
        };

        public MediaPage(Shell shell)
        {
            _shell = shell;
            _v = (FrameworkElement)Ui.LoadXaml("Media.xaml");
            E<TreeView>("Parts").ItemsSource = _items;
            E<Button>("CheckNow").Click += (s, e) => Run(false, null);
            E<Button>("Repair").Click += async (s, e) => await Repair();
            E<TextBlock>("FootLine").Text = _shell.IsAdmin ? "Repairs use the newest backup for data (settings, databases, the Home Assistant disk)." : "Checking works as you are; setting parts up needs administrator rights (you'll be asked).";
        }

        public void OnShown()
        {
            _shell.SetTitle("Media server & smart home");
            if (_shell.Opts.Page == "media" && !string.IsNullOrEmpty(_shell.Opts.RunSelection) && !_checkedOnce)
            {
                _checkedOnce = true;
                var only = File.Exists(_shell.Opts.RunSelection) ? string.Join(",", Json.Strs(Json.ReadFile(_shell.Opts.RunSelection), "Only")) : "";
                Run(true, only);
                return;
            }
            if (!_checkedOnce && !_busy) { _checkedOnce = true; Run(false, null); }
        }

        static string NewestBackup()
        {
            try { var b = Kit.FindBackups().FirstOrDefault(); return b == null ? null : b.Dir; } catch { return null; }
        }

        void Run(bool repair, string only)
        {
            if (_busy) return;
            _busy = true;
            var args = new List<string> { "-Mode", repair ? "Repair" : "Check" };
            var b = NewestBackup();
            if (b != null) { args.Add("-BackupPath"); args.Add(b); }
            if (repair && !string.IsNullOrEmpty(only)) { args.Add("-Only"); args.Add(only); args.Add("-Force"); args.Add(only); }
            if (repair && E<CheckBox>("DryRun").IsChecked == true) args.Add("-DryRun");
            _run = new EngineRun("ServerSetup.ps1", args.ToArray());
            E<ProgressBar>("CheckBar").Visibility = Visibility.Visible;
            E<Button>("CheckNow").IsEnabled = false;
            E<Button>("Repair").IsEnabled = false;
            E<TextBlock>("ResultTitle").Text = repair ? "Setting up" : "Checking";
            E<TextBlock>("ResultLine").Text = repair ? "Each part is installed, given its data back, registered and started as needed." : "Every part is checked - about half a minute.";
            var log = new LogView(E<ListBox>("LogList"));
            log.Clear();
            E<Border>("LogCard").Visibility = repair ? Visibility.Visible : Visibility.Collapsed;
            object lastTable = null;
            _run.OnEvent += ev =>
            {
                log.Handle(ev);
                if (ev.Type == "mstable") { lastTable = ev.Data; Show(ev.Data); }
                if (ev.Type == "log" && repair && ev.S("lvl") == "step") E<TextBlock>("ResultLine").Text = ev.S("text").Trim('=', ' ');
            };
            _run.OnExit += code =>
            {
                _busy = false;
                E<ProgressBar>("CheckBar").Visibility = Visibility.Collapsed;
                E<Button>("CheckNow").IsEnabled = true;
                if (lastTable == null) { E<TextBlock>("ResultTitle").Text = "The check did not finish"; E<TextBlock>("ResultLine").Text = "Exit code " + code + (_run.Issues.Count > 0 ? ": " + _run.Issues.Last() : ""); }
                UpdateRepair();
                _shell.Taskbar.ProgressState = TaskbarItemProgressState.None;
            };
            _shell.Taskbar.ProgressState = TaskbarItemProgressState.Indeterminate;
            try { _run.Start(); }
            catch (Exception ex) { _busy = false; E<TextBlock>("ResultLine").Text = "Could not start the engine: " + ex.Message; }
        }

        void Show(object table)
        {
            _items.Clear();
            var rows = Json.Arr(table, "rows");
            var g = Model.Group("Parts", null, G.Media);
            int bad = 0;
            foreach (var r in rows)
            {
                var key = Json.Str(r, "key");
                var status = Json.Str(r, "status");
                var ok = status == "OK";
                if (!ok) bad++;
                string what;
                Explain.TryGetValue(key ?? "", out what);
                var it = Model.Leaf(g, "Media", key, Json.Str(r, "name"), Json.Str(r, "detail") + (string.IsNullOrEmpty(what) ? "" : "   ·   " + what), key == "network" ? G.Network : G.Media, !ok);
                it.Tags.Add(new Tag(status, ok ? "ok" : status == "WARN" ? "warn" : "bad"));
                it.PropertyChanged += (s, e) => { if (e.PropertyName == "IsChecked") UpdateRepair(); };
            }
            _items.Add(g);
            E<TextBlock>("ResultTitle").Text = bad == 0 ? "Everything is running" : Fmt.Plural(bad, "part") + " need" + (bad == 1 ? "s" : "") + " attention";
            E<TextBlock>("ResultLine").Text = rows.Count + " parts checked at " + DateTime.Now.ToString("HH:mm") + (bad > 0 ? " - the ones that are not OK are ticked for setting up" : "");
            UpdateRepair();
        }

        List<string> Ticked() { return _items.SelectMany(i => i.All()).Where(i => i.Section == "Media" && i.Kind == ItemKind.Item && i.IsChecked == true).Select(i => i.Key).ToList(); }

        void UpdateRepair()
        {
            var n = Ticked().Count;
            E<Button>("Repair").IsEnabled = n > 0 && !_busy;
            E<TextBlock>("RepairText").Text = n == 0 ? "Set up the ticked parts" : "Set up " + Fmt.Plural(n, "part");
        }

        async Task Repair()
        {
            var parts = Ticked();
            if (parts.Count == 0) return;
            if (!_shell.IsAdmin && E<CheckBox>("DryRun").IsChecked != true)
            {
                var a = await _shell.Ask("Administrator rights needed", "Installing, registering services and starting the VM need administrator rights. The program restarts as administrator and sets up the " + Fmt.Plural(parts.Count, "part") + " you ticked.", null, "go|Restart and set up", "cancel|Cancel");
                if (a != "go") return;
                var file = Path.Combine(Kit.TempDir, "media-repair-" + DateTime.Now.ToString("yyyyMMdd-HHmmss") + ".json");
                Json.WriteFile(file, new Dictionary<string, object> { { "Only", parts.ToArray() } });
                if (Native.RelaunchAsAdmin("--page media --run-selection " + Native.QuoteArg(file))) Application.Current.Shutdown();
                else await _shell.Info("Not restarted", "Windows did not give administrator rights (the prompt was cancelled).");
                return;
            }
            Run(true, string.Join(",", parts));
        }

        public void Stop() { if (_run != null) _run.Cancel(); }

        public async Task Demo(string dir, Shell shell)
        {
            for (int i = 0; i < 180 && _busy; i++) await Task.Delay(500);
            await shell.Settle(300);
        }
    }
}
