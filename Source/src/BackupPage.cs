// PC Migration Kit - Scan & back up: scan -> choose -> destination -> copy -> done.
// Written by Claude 2026-10-02.
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Shell;
using System.Windows.Threading;

namespace PCMK
{
    public class BackupPage : IPage, IStoppable, IDemo
    {
        readonly Shell _shell;
        readonly FrameworkElement _v;
        readonly Dictionary<string, CheckBox> _driveChecks = new Dictionary<string, CheckBox>(StringComparer.OrdinalIgnoreCase);
        List<DriveDetails> _drives = new List<DriveDetails>();
        BackupModel _model;
        EngineRun _run;
        CancellationTokenSource _cts;
        DispatcherTimer _timer;
        bool _busy, _started;
        string _catalogFile;
        bool _engineDone, _engineOk;
        DateTime _scanStart;
        readonly Dictionary<string, Tuple<TextBlock, TextBlock, TextBlock>> _driveRows = new Dictionary<string, Tuple<TextBlock, TextBlock, TextBlock>>();

        public FrameworkElement View { get { return _v; } }
        public bool IsBusy { get { return _busy; } }
        T E<T>(string n) where T : class { return Ui.Find<T>(_v, n); }

        public BackupPage(Shell shell)
        {
            _shell = shell;
            _v = (FrameworkElement)Ui.LoadXaml("Backup.xaml");
            E<Border>("AdminNote").Visibility = shell.IsAdmin ? Visibility.Collapsed : Visibility.Visible;
            E<Button>("AdminButton").Click += (s, e) => { if (!_shell.Elevate("backup", true)) _shell.Info("Not restarted", "Windows did not give administrator rights (the prompt was cancelled)."); };
            E<Button>("StartScan").Click += async (s, e) => await StartScan();
            E<Button>("CancelScan").Click += (s, e) => StopScan();
            E<Button>("BackToScan").Click += (s, e) => ShowView("ScanView");
            E<Button>("ToDest").Click += (s, e) => ShowDest();
            E<Button>("BackToChoose").Click += (s, e) => ShowView("ChooseView");
            E<Button>("Browse").Click += (s, e) => Browse();
            E<Button>("StartBackup").Click += async (s, e) => await StartBackup();
            E<Button>("StopRun").Click += async (s, e) => await StopRun();
            E<Button>("NewRun").Click += (s, e) => ShowView("ScanView");
            E<Button>("SelAll").Click += (s, e) => TickCategory(true);
            E<Button>("SelNone").Click += (s, e) => TickCategory(false);
            E<ListBox>("CatList").SelectionChanged += (s, e) => ShowCategory(E<ListBox>("CatList").SelectedItem as Category);
            var search = E<TextBox>("SearchBox");
            var searchTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(300) };
            searchTimer.Tick += (s, e) => { searchTimer.Stop(); Search(search.Text); };
            search.TextChanged += (s, e) => { E<TextBlock>("SearchHint").Visibility = search.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed; searchTimer.Stop(); searchTimer.Start(); };
            E<TextBox>("DestBox").TextChanged += (s, e) => UpdateSpace();
            E<RadioButton>("UpdateRadio").Checked += (s, e) => UpdateSpace();
            E<RadioButton>("NewRadio").Checked += (s, e) => UpdateSpace();
            LoadDriveChecks();
        }

        public void OnShown()
        {
            _shell.SetTitle("Scan & back up");
            if (_started) return;
            _started = true;
            if (!string.IsNullOrEmpty(_shell.Opts.RunSelection) && !string.IsNullOrEmpty(_shell.Opts.Dest))
            {
                // restarted as administrator to run a backup that was chosen before
                RunBackup(_shell.Opts.Dest, _shell.Opts.RunSelection, _shell.Opts.Update);
            }
            else if (_shell.Opts.AutoStart && _shell.Opts.Page == "backup") _v.Dispatcher.BeginInvoke(new Action(async () => await StartScan()), DispatcherPriority.ApplicationIdle);
        }

        void ShowView(string name)
        {
            foreach (var n in new[] { "ScanView", "ChooseView", "DestView", "RunView" }) E<FrameworkElement>(n).Visibility = n == name ? Visibility.Visible : Visibility.Collapsed;
        }

        async void LoadDriveChecks()
        {
            _drives = await Task.Run(() => DriveDetails.Load());
            var host = E<WrapPanel>("DriveChecks");
            host.Children.Clear();
            _driveChecks.Clear();
            foreach (var d in _drives)
            {
                var cb = new CheckBox { IsChecked = !d.IsRemovable, Margin = new Thickness(0, 0, 22, 10), MinWidth = 200 };
                var sp = new StackPanel();
                sp.Children.Add(new TextBlock { Text = d.Letter + ":  " + (string.IsNullOrEmpty(d.Label) ? "Local disk" : d.Label), Foreground = Ui.Brush("Text") });
                sp.Children.Add(Ui.Text(Fmt.Bytes(d.Total - d.Free) + " used" + (string.IsNullOrEmpty(d.Media) ? "" : "  ·  " + d.Media) + (d.IsRemovable ? "  ·  USB" : ""), "T.Small"));
                cb.Content = sp;
                if (d.IsSystem) { cb.IsChecked = true; cb.IsEnabled = false; cb.ToolTip = "The Windows drive is always scanned."; }
                _driveChecks[d.Letter] = cb;
                host.Children.Add(cb);
            }
        }

        // =============================================================== scan ===
        async Task StartScan()
        {
            if (_busy) return;
            if (!_shell.IsAdmin && _shell.Opts.Screenshot == null)
            {
                var a = await _shell.Ask("Scan as administrator?", "As administrator the scan sees everything: every folder, the drivers and Windows features, and the health of your SSDs. Without it some folders show as \"no access\", and you'll be asked again before the backup itself starts.", null,
                    "admin|Restart as administrator", "user|Scan without", "cancel|Cancel");
                if (a == "cancel") return;
                if (a == "admin") { if (!_shell.Elevate("backup", true)) await _shell.Info("Not restarted", "Windows did not give administrator rights (the prompt was cancelled). You can still scan without them."); return; }
            }
            if (_drives.Count == 0) _drives = await Task.Run(() => DriveDetails.Load());
            _busy = true;
            ShowView("ScanView");
            E<Button>("StartScan").IsEnabled = false;
            E<Button>("CancelScan").Visibility = Visibility.Visible;
            E<Border>("ScanProgress").Visibility = Visibility.Visible;
            _model = new BackupModel();
            _scanStart = DateTime.Now;
            _cts = new CancellationTokenSource();

            // programs, settings and automations: the engine
            _engineDone = false; _engineOk = false;
            _catalogFile = Path.Combine(Kit.TempDir, "catalog-" + DateTime.Now.ToString("yyyyMMdd-HHmmss") + ".json");
            var args = new List<string> { "-Out", _catalogFile };
            if (E<CheckBox>("LookupCheck").IsChecked != true) args.Add("-Quick");
            _run = new EngineRun("Catalog.ps1", args.ToArray());
            E<TextBlock>("EngineIcon").Text = G.Sync;
            E<TextBlock>("EngineIcon").Foreground = Ui.Brush("Accent");
            _run.OnEvent += ev =>
            {
                if (ev.Type == "log" && !string.IsNullOrEmpty(ev.S("text"))) E<TextBlock>("EngineLine").Text = ev.S("text");
                else if (ev.Type == "progress" && !ev.B("done") && !string.IsNullOrEmpty(ev.S("status"))) E<TextBlock>("EngineLine").Text = ev.S("activity") + ": " + ev.S("status");
            };
            _run.OnExit += code =>
            {
                _engineDone = true;
                _engineOk = code == 0 && File.Exists(_catalogFile);
                E<TextBlock>("EngineIcon").Text = _engineOk ? G.Check : G.Error;
                E<TextBlock>("EngineIcon").Foreground = _engineOk ? Ui.Brush("Ok") : Ui.Brush("Bad");
                if (!_engineOk) E<TextBlock>("EngineLine").Text = _run.Cancelled ? "stopped" : "failed (exit code " + code + ")" + (_run.Issues.Count > 0 ? ": " + _run.Issues.Last() : "");
                else E<TextBlock>("EngineLine").Text = "done";
                CheckScanDone();
            };
            try { _run.Start(); }
            catch (Exception ex) { _engineDone = true; E<TextBlock>("EngineLine").Text = "could not start PowerShell: " + ex.Message; }

            // every folder on the drives that were ticked
            var rows = E<StackPanel>("DriveRows");
            rows.Children.Clear();
            _driveRows.Clear();
            foreach (var d in _drives)
            {
                CheckBox cb;
                if (!_driveChecks.TryGetValue(d.Letter, out cb) || cb.IsChecked != true) continue;
                var scan = new DriveScan { Root = d.Letter + ":\\", Label = d.Label, TotalBytes = d.Total, FreeBytes = d.Free, IsSystem = d.IsSystem };
                _model.Scans[d.Letter] = scan;
                var g = new Grid { Margin = new Thickness(0, 12, 0, 0) };
                g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(26) });
                g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                var icon = Ui.Icon(G.Sync, 14, Ui.Brush("Accent")); icon.VerticalAlignment = VerticalAlignment.Top; icon.Margin = new Thickness(0, 2, 0, 0);
                g.Children.Add(icon);
                var sp = new StackPanel();
                var title = new TextBlock { Text = d.Letter + ":  " + (string.IsNullOrEmpty(d.Label) ? "Local disk" : d.Label), Foreground = Ui.Brush("Text") };
                var line = Ui.Text("", "T.Small");
                sp.Children.Add(title); sp.Children.Add(line);
                Grid.SetColumn(sp, 1);
                g.Children.Add(sp);
                rows.Children.Add(g);
                _driveRows[d.Letter] = Tuple.Create(icon, title, line);
                var workers = d.IsSystem || d.Media == "SSD" ? 4 : 1;
                var ct = _cts.Token;
                _ = Task.Factory.StartNew(() => DiskScanner.Scan(scan, ct, workers), TaskCreationOptions.LongRunning);
            }
            _timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(250) };
            _timer.Tick += (s, e) => UpdateScanRows();
            _timer.Start();
            _shell.Taskbar.ProgressState = TaskbarItemProgressState.Indeterminate;
        }

        void UpdateScanRows()
        {
            E<TextBlock>("ScanTime").Text = Fmt.Duration(DateTime.Now - _scanStart);
            foreach (var kv in _driveRows)
            {
                var d = _model.Scans[kv.Key];
                var line = d.FilesSeen.ToString("N0") + " files  ·  " + Fmt.Bytes(d.BytesSeen);
                if (d.Done)
                {
                    kv.Value.Item1.Text = d.Error == null ? G.Check : G.Error;
                    kv.Value.Item1.Foreground = d.Error == null ? Ui.Brush("Ok") : Ui.Brush("Bad");
                    kv.Value.Item3.Text = line + "  ·  done in " + Fmt.Duration(d.Took) + (d.Error != null ? "  ·  " + d.Error : "");
                }
                else kv.Value.Item3.Text = line + "  ·  " + d.Current;
            }
            CheckScanDone();
        }

        void CheckScanDone()
        {
            if (_model == null || !_busy) return;
            if (!_engineDone || _model.Scans.Values.Any(d => !d.Done)) return;
            if (_timer != null) _timer.Stop();
            _busy = false;
            E<Button>("StartScan").IsEnabled = true;
            E<Button>("CancelScan").Visibility = Visibility.Collapsed;
            _shell.Taskbar.ProgressState = TaskbarItemProgressState.None;
            if (_cts.IsCancellationRequested) return;
            if (!_engineOk)
            {
                var detail = _run != null && _run.Issues.Count > 0 ? string.Join("\n", _run.Issues) : "";
                var _ = _shell.Ask("The scan did not finish", "The part that reads programs and settings stopped with an error. " + detail, null, "ok|OK");
                return;
            }
            try
            {
                _model.Catalog = Json.ReadFile(_catalogFile);
                _model.Build();
                ShowChoose();
            }
            catch (Exception ex) { var _ = _shell.Ask("Could not show the results", ex.Message, null, "ok|OK"); }
        }

        void StopScan()
        {
            if (_cts != null) _cts.Cancel();
            if (_run != null) _run.Cancel();
            _busy = false;
            if (_timer != null) _timer.Stop();
            E<Button>("StartScan").IsEnabled = true;
            E<Button>("CancelScan").Visibility = Visibility.Collapsed;
            E<TextBlock>("EngineLine").Text = "stopped";
            _shell.Taskbar.ProgressState = TaskbarItemProgressState.None;
        }

        // ============================================================= choose ===
        DispatcherTimer _totals;

        void ShowChoose()
        {
            var cats = E<ListBox>("CatList");
            cats.ItemsSource = _model.Categories;
            cats.SelectedIndex = 0;
            var sys = Json.Get(_model.Catalog, "System");
            E<TextBlock>("ChooseLine").Text = "Everything the scan found, sorted into groups. Ticked items go into the backup - the program has ticked what belongs to your setup. " +
                (Json.Bool(_model.Catalog, "IsAdmin") ? "" : "(Scanned without administrator rights - some folders could not be read.)");
            _totals = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(250) };
            _totals.Tick += (s, e) => { _totals.Stop(); UpdateTotals(); };
            _model.Paths.Changed += () => { _totals.Stop(); _totals.Start(); };
            foreach (var c in _model.Categories) c.PropertyChanged += (s, e) => { _totals.Stop(); _totals.Start(); };
            UpdateTotals();
            ShowView("ChooseView");
        }

        void ShowCategory(Category c)
        {
            if (c == null) return;
            E<TextBlock>("CatTitle").Text = c.Title;
            E<TextBlock>("CatDesc").Text = c.Description;
            E<TreeView>("ItemTree").ItemsSource = c.Items;
            E<TextBox>("SearchBox").Text = "";
        }

        void TickCategory(bool on)
        {
            var c = E<ListBox>("CatList").SelectedItem as Category;
            if (c == null) return;
            foreach (var it in c.Items)
            {
                if (it.Kind == ItemKind.Group) { foreach (var ch in it.Children) if (ch.Checkable && ch.Kind != ItemKind.Info) ch.IsChecked = on; it.Refresh("IsChecked", "SizeText"); }
                else if (it.Checkable && it.Kind != ItemKind.Info) it.IsChecked = on;
            }
            c.Refresh();
        }

        void Search(string q)
        {
            var tree = E<TreeView>("ItemTree");
            var list = E<ListBox>("SearchList");
            if (string.IsNullOrWhiteSpace(q) || _model == null) { list.Visibility = Visibility.Collapsed; tree.Visibility = Visibility.Visible; return; }
            q = q.Trim();
            var hits = new List<SelItem>();
            var seenPaths = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (var c in _model.Categories)
                foreach (var it in c.Items.SelectMany(i => i.All()))
                {
                    if (it.Kind == ItemKind.Group || it == SelItem.Placeholder) continue;
                    if ((it.Search ?? it.Title ?? "").IndexOf(q, StringComparison.OrdinalIgnoreCase) < 0) continue;
                    if (it.Path != null && !seenPaths.Add(it.Path)) continue;
                    hits.Add(it);
                    if (hits.Count > 300) break;
                }
            // folders anywhere on the scanned drives whose name matches
            foreach (var d in _model.Scans.Values)
            {
                if (d.Tree == null || hits.Count > 300) continue;
                var st = new Stack<FolderNode>();
                st.Push(d.Tree);
                while (st.Count > 0 && hits.Count <= 300)
                {
                    var n = st.Pop();
                    if (n.Parent != null && n.Name.IndexOf(q, StringComparison.OrdinalIgnoreCase) >= 0 && seenPaths.Add(n.Path))
                    {
                        var it = Model.FolderItem(n.Path, n.Path, n, _model.Paths, null);
                        hits.Add(it);
                    }
                    if (n.Children != null) foreach (var ch in n.Children) st.Push(ch);
                }
            }
            foreach (var h in hits) h.Refresh("IndentWidth");
            list.ItemsSource = hits;
            tree.Visibility = Visibility.Collapsed;
            list.Visibility = Visibility.Visible;
        }

        Dictionary<string, object> Selection() { return Model.BuildSelection(_model.Categories, _model.Paths); }

        void UpdateTotals()
        {
            if (_model == null) return;
            long bytes = _model.TotalSelectedBytes();
            int apps = 0, appsAll = 0, autos = 0;
            foreach (var c in _model.Categories)
                foreach (var it in c.Items.SelectMany(i => i.All()).Where(x => x.Kind == ItemKind.Item && x.Checkable))
                {
                    if (it.Section == "Apps") { appsAll++; if (it.IsChecked == true) apps++; }
                    if ((it.Section == "Tasks" || it.Section == "Startup" || it.Section == "Services") && it.IsChecked == true) autos++;
                }
            E<TextBlock>("TotalLine").Text = "About " + Fmt.Bytes(bytes) + " of files  ·  " + apps + " of " + appsAll + " programs  ·  " + autos + " automations";
            var ex = _model.Paths.ExcludePaths().Count; var extra = _model.Paths.ExtraPaths().Count;
            E<TextBlock>("TotalSub").Text = (ex + extra == 0 ? "The program's suggestion - nothing changed yet." : (ex > 0 ? Fmt.Plural(ex, "folder") + " left out" : "") + (ex > 0 && extra > 0 ? ", " : "") + (extra > 0 ? Fmt.Plural(extra, "folder") + " added" : "")) +
                "   ·   sizes are what is on disk now";
            foreach (var c in _model.Categories) c.Refresh();
        }

        // ======================================================== destination ===
        string _destBase;

        void ShowDest()
        {
            var host = E<WrapPanel>("DestDrives");
            host.Children.Clear();
            long need = _model.TotalSelectedBytes();
            var sysLetter = Path.GetPathRoot(Environment.SystemDirectory).Substring(0, 1).ToUpper();
            var kitLetter = Kit.Root.Substring(0, 1).ToUpper();
            string preferred = null;
            foreach (var d in _drives.Where(x => x.Letter != sysLetter))
            {
                var rb = new RadioButton { Style = (Style)Application.Current.Resources["Segment"], GroupName = "dest", Width = 236, Margin = new Thickness(0, 0, 12, 12) };
                var sp = new StackPanel();
                var top = new StackPanel { Orientation = Orientation.Horizontal };
                top.Children.Add(Ui.Icon(d.IsRemovable ? G.Usb : G.Drive, 18, Ui.Brush("TextMuted")));
                top.Children.Add(new TextBlock { Text = "  " + d.Letter + ":  " + (string.IsNullOrEmpty(d.Label) ? "Local disk" : d.Label), Foreground = Ui.Brush("Text"), FontWeight = FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center });
                sp.Children.Add(top);
                sp.Children.Add(Ui.Text(Fmt.Bytes(d.Free) + " free of " + Fmt.Bytes(d.Total), "T.Small"));
                var fits = d.Free > need * 1.05 + 6.0 * (1 << 30);
                var chip = Ui.Chip(fits ? "enough space" : "too small for a new backup", fits ? "ok" : "warn");
                chip.Margin = new Thickness(0, 8, 0, 0); chip.HorizontalAlignment = HorizontalAlignment.Left;
                sp.Children.Add(chip);
                rb.Content = sp;
                var letter = d.Letter;
                rb.Checked += (s, e) => SetDestDrive(letter);
                host.Children.Add(rb);
                if (preferred == null && letter == kitLetter) preferred = letter;
            }
            if (host.Children.Count == 0)
            {
                host.Children.Add(Ui.Text("There is only one drive in this PC. Plug in an external drive (it needs about " + Fmt.Bytes(need) + " free), then come back to this step.", "T.Muted"));
            }
            if (preferred == null)
            {
                var best = _drives.Where(x => x.Letter != sysLetter).OrderByDescending(x => x.Free).FirstOrDefault();
                if (best != null) preferred = best.Letter;
            }
            foreach (RadioButton rb in host.Children.OfType<RadioButton>())
                if (((StackPanel)((StackPanel)rb.Content).Children[0]).Children.OfType<TextBlock>().Any(t => t.Text.StartsWith("  " + preferred + ":"))) { rb.IsChecked = true; break; }
            ShowView("DestView");
        }

        void SetDestDrive(string letter)
        {
            var kitLetter = Kit.Root.Substring(0, 1).ToUpper();
            _destBase = letter == kitLetter ? Path.Combine(Kit.Root, "Backups") : letter + @":\PC-Migration-Kit\Backups";
            E<TextBox>("DestBox").Text = Path.Combine(_destBase, Environment.MachineName + "_" + DateTime.Now.ToString("yyyy-MM-dd_HHmm"));
        }

        void Browse()
        {
            using (var dlg = new System.Windows.Forms.FolderBrowserDialog { Description = "Where should the backup go? Pick a folder on a drive that is NOT the Windows drive.", ShowNewFolderButton = true })
            {
                if (dlg.ShowDialog() == System.Windows.Forms.DialogResult.OK) E<TextBox>("DestBox").Text = Path.Combine(dlg.SelectedPath, Environment.MachineName + "_" + DateTime.Now.ToString("yyyy-MM-dd_HHmm"));
            }
        }

        /// <summary>An earlier backup of this PC in the chosen place, to update instead of starting over.</summary>
        string PreviousBackup()
        {
            try
            {
                var dest = E<TextBox>("DestBox").Text.Trim();
                if (dest.Length < 4) return null;
                if (File.Exists(Path.Combine(dest, "manifest.json"))) return dest;
                var parent = Path.GetDirectoryName(dest);
                if (parent == null || !Directory.Exists(parent)) return null;
                return Directory.GetDirectories(parent, Environment.MachineName + "_*").Where(d => File.Exists(Path.Combine(d, "manifest.json"))).OrderByDescending(d => d).FirstOrDefault();
            }
            catch { return null; }
        }

        void UpdateSpace()
        {
            if (_model == null) return;
            var dest = E<TextBox>("DestBox").Text.Trim();
            var prev = PreviousBackup();
            var up = E<StackPanel>("UpdatePanel");
            if (prev != null)
            {
                up.Visibility = Visibility.Visible;
                E<TextBlock>("UpdateTitle").Text = "Update " + Path.GetFileName(prev);
                if (E<RadioButton>("UpdateRadio").IsChecked != true && E<RadioButton>("NewRadio").IsChecked != true) E<RadioButton>("UpdateRadio").IsChecked = true;
            }
            else up.Visibility = Visibility.Collapsed;
            long need = _model.TotalSelectedBytes();
            bool update = prev != null && E<RadioButton>("UpdateRadio").IsChecked == true;
            var ok = true;
            string root = null;
            try { root = Path.GetPathRoot(dest); } catch { }
            if (string.IsNullOrEmpty(root) || root.Length < 2) { E<TextBlock>("SpaceLine").Text = "Pick a drive or a folder"; E<TextBlock>("SpaceSub").Text = ""; E<Button>("StartBackup").IsEnabled = false; return; }
            var sysLetter = Path.GetPathRoot(Environment.SystemDirectory).Substring(0, 1).ToUpper();
            var drive = _drives.FirstOrDefault(d => d.Letter == root.Substring(0, 1).ToUpper());
            if (root.Substring(0, 1).ToUpper() == sysLetter)
            {
                E<TextBlock>("SpaceLine").Text = "Not on " + sysLetter + ": - that is the drive being replaced";
                E<TextBlock>("SpaceSub").Text = "Pick another drive.";
                ok = false;
            }
            else if (drive != null)
            {
                var needNow = update ? 6.0 * (1 << 30) : need * 1.05 + 6.0 * (1 << 30);
                ok = drive.Free > needNow;
                E<TextBlock>("SpaceLine").Text = (update ? "Updating: only what changed is copied" : "About " + Fmt.Bytes(need) + " to copy") + "  ·  " + Fmt.Bytes(drive.Free) + " free on " + drive.Letter + ":";
                E<TextBlock>("SpaceSub").Text = ok ? (update ? "The first backup took a while; an update usually takes minutes." : "A first backup of this size takes roughly " + Fmt.Duration(TimeSpan.FromSeconds(need / (90.0 * 1024 * 1024))) + " on a hard disk, less on an SSD.") : "Not enough free space there - pick another drive or untick big folders.";
            }
            E<Button>("StartBackup").IsEnabled = ok;
        }

        async Task StartBackup()
        {
            var dest = E<TextBox>("DestBox").Text.Trim();
            var prev = PreviousBackup();
            bool update = prev != null && E<RadioButton>("UpdateRadio").IsChecked == true;
            if (update) dest = prev;
            var selFile = Path.Combine(Kit.TempDir, "selection-" + DateTime.Now.ToString("yyyyMMdd-HHmmss") + ".json");
            Json.WriteFile(selFile, Selection());
            if (!_shell.IsAdmin)
            {
                var a = await _shell.Ask("Administrator rights needed", "The backup copies open files through a snapshot of the drive and reads every program's data - that needs administrator rights. The program restarts as administrator and starts the backup with your choices right away.", null, "go|Restart and back up", "cancel|Cancel");
                if (a != "go") return;
                var args = "--page backup --run-selection " + Native.QuoteArg(selFile) + " --dest " + Native.QuoteArg(dest) + (update ? " --update" : "");
                if (Native.RelaunchAsAdmin(args)) Application.Current.Shutdown();
                else await _shell.Info("Not restarted", "Windows did not give administrator rights (the prompt was cancelled).");
                return;
            }
            Settings.Set("lastDest", dest);
            RunBackup(dest, selFile, update);
        }

        // ================================================================ run ===
        CopyMeter _meter;
        DateTime _runStart;
        string _destReal, _report;

        void RunBackup(string dest, string selFile, bool update)
        {
            ShowView("RunView");
            _busy = true;
            _runStart = DateTime.Now;
            _meter = new CopyMeter();
            _destReal = dest;
            _report = null;
            var log = new LogView(E<ListBox>("LogList"));
            log.Clear();
            E<TextBlock>("RunTitle").Text = update ? "Updating the backup" : "Backing up";
            E<TextBlock>("RunLine").Text = "Into " + dest;
            E<TextBlock>("OverallLeft").Text = "Getting ready - reading the PC again";
            E<ProgressBar>("OverallBar").IsIndeterminate = true;
            foreach (var b in new[] { "OpenLog", "OpenFolder", "OpenReport", "NewRun" }) E<Button>(b).Visibility = Visibility.Collapsed;
            E<Button>("StopRun").Visibility = Visibility.Visible;
            _shell.Taskbar.ProgressState = TaskbarItemProgressState.Indeterminate;
            var args = new List<string> { "-Destination", dest, "-Selection", selFile };
            if (update) args.Add("-Update");
            if (!string.IsNullOrEmpty(_shell.Opts.TestRun)) args.Add("-TestMode");
            _run = new EngineRun("Backup.ps1", args.ToArray());
            var tick = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1) };
            tick.Tick += (s, e) => { _meter.Sample(); UpdateRunTexts(); };
            tick.Start();
            _run.OnEvent += ev =>
            {
                log.Handle(ev);
                switch (ev.Type)
                {
                    case "destination": _destReal = ev.S("path"); E<TextBlock>("RunLine").Text = "Into " + _destReal + (ev.B("update") ? "  (updating)" : ""); break;
                    case "plan": _meter.TotalExpected = ev.D("total"); _meter.JobsTotal = (int)ev.L("jobs"); E<ProgressBar>("OverallBar").IsIndeterminate = false; break;
                    case "job":
                        E<TextBlock>("JobLeft").Text = ev.S("label");
                        _meter.CurExpected = ev.D("expected"); _meter.CurBytes = 0;
                        E<TextBlock>("OverallLeft").Text = "Copying files  ·  part " + ev.L("n") + " of " + ev.L("of");
                        E<ProgressBar>("JobBar").Value = 0;
                        break;
                    case "progress":
                        if (ev.S("kind") == "copy")
                        {
                            _meter.CurBytes = ev.D("bytes");
                            var exp = ev.D("expected");
                            E<ProgressBar>("JobBar").Value = exp > 0 ? Math.Min(100, 100 * _meter.CurBytes / exp) : 0;
                            E<TextBlock>("JobRight").Text = Fmt.Bytes(_meter.CurBytes) + (exp > 0 ? " of ~" + Fmt.Bytes(exp) : "") + "  ·  " + ev.L("files").ToString("N0") + " files";
                            E<TextBlock>("JobFile").Text = ev.S("current");
                        }
                        else if (!ev.B("done")) { E<TextBlock>("JobLeft").Text = ev.S("activity"); E<TextBlock>("JobFile").Text = ev.S("status"); }
                        break;
                    case "copy":
                        if (ev.S("state") == "end") { _meter.DoneExpected += _meter.CurExpected; _meter.CopiedBytes += ev.D("bytes"); _meter.CurExpected = 0; _meter.CurBytes = 0; _meter.JobsDone++; }
                        break;
                    case "log":
                        if (ev.S("lvl") == "step") E<TextBlock>("OverallLeft").Text = ev.S("text").Trim('=', ' ');
                        break;
                    case "summary": _report = ev.S("report"); break;
                }
                UpdateRunTexts();
            };
            _run.OnExit += code =>
            {
                tick.Stop();
                _busy = false;
                E<Button>("StopRun").Visibility = Visibility.Collapsed;
                E<Button>("NewRun").Visibility = Visibility.Visible;
                E<ProgressBar>("OverallBar").IsIndeterminate = false;
                E<TextBlock>("OverallRight").Text = Fmt.Bytes(_meter.CopiedBytes) + " copied  ·  " + Fmt.Duration(DateTime.Now - _runStart);
                var warn = log.Warnings.Count;
                if (_run.Cancelled) { E<TextBlock>("RunTitle").Text = "Backup stopped"; E<TextBlock>("OverallLeft").Text = "Stopped - what was copied so far stays in the folder; running it again continues."; }
                else if (code == 0)
                {
                    E<ProgressBar>("OverallBar").Value = 100;
                    E<TextBlock>("RunTitle").Text = warn == 0 ? "Backup finished" : "Backup finished with " + Fmt.Plural(warn, "warning");
                    E<TextBlock>("OverallLeft").Text = "Done in " + Fmt.Duration(DateTime.Now - _runStart) + (warn > 0 ? " - the warnings are in the list below and in the report" : "");
                    E<TextBlock>("RunFoot").Text = "To restore: on the new PC open \"PC Migration Kit.exe\" from this backup folder. Keep the folder private - it holds Wi-Fi passwords and app logins.";
                }
                else { E<TextBlock>("RunTitle").Text = "The backup stopped with an error"; E<TextBlock>("OverallLeft").Text = "Exit code " + code + " - see the messages below."; }
                if (!string.IsNullOrEmpty(_destReal) && Directory.Exists(_destReal)) E<Button>("OpenFolder").Visibility = Visibility.Visible;
                if (!string.IsNullOrEmpty(_report) && File.Exists(_report)) E<Button>("OpenReport").Visibility = Visibility.Visible;
                if (!string.IsNullOrEmpty(_run.LogFile)) E<Button>("OpenLog").Visibility = Visibility.Visible;
                _shell.Taskbar.ProgressState = code == 0 && !_run.Cancelled ? TaskbarItemProgressState.None : TaskbarItemProgressState.Error;
                Native.FlashWindow(new System.Windows.Interop.WindowInteropHelper(_shell.Window).Handle, true);
            };
            E<Button>("OpenFolder").Click += (s, e) => Native.OpenAsUser(_destReal);
            E<Button>("OpenReport").Click += (s, e) => Native.OpenAsUser(_report);
            E<Button>("OpenLog").Click += (s, e) => Native.OpenAsUser(_run.LogFile);
            try { _run.Start(); }
            catch (Exception ex) { _busy = false; log.Add("fail", "Could not start the engine: " + ex.Message); }
        }

        void UpdateRunTexts()
        {
            if (_meter == null || !_busy) return;
            var f = _meter.Fraction;
            if (!E<ProgressBar>("OverallBar").IsIndeterminate) E<ProgressBar>("OverallBar").Value = f * 100;
            var speed = _meter.Speed;
            var parts = new List<string>();
            if (_meter.TotalExpected > 0) parts.Add(Fmt.Bytes(_meter.DoneExpected + Math.Min(_meter.CurBytes, Math.Max(_meter.CurExpected, _meter.CurBytes))) + " of ~" + Fmt.Bytes(_meter.TotalExpected));
            if (speed > 1024 * 1024) parts.Add(Fmt.Bytes(speed) + "/s");
            if (f > 0.02 && speed > 1024 * 1024 && _meter.TotalExpected > 0)
            {
                var left = (_meter.TotalExpected * (1 - f)) / speed;
                if (left < 3600 * 48) parts.Add("about " + Fmt.Duration(TimeSpan.FromSeconds(left)) + " left");
            }
            parts.Add(Fmt.Duration(DateTime.Now - _runStart));
            E<TextBlock>("OverallRight").Text = string.Join("  ·  ", parts);
            _shell.Taskbar.ProgressState = TaskbarItemProgressState.Normal;
            _shell.Taskbar.ProgressValue = f;
        }

        async Task StopRun()
        {
            if (_run == null || !_run.Running) return;
            var a = await _shell.Ask("Stop the backup?", "What has been copied so far stays. Running the backup again into the same folder continues from there (choose \"Update\").", null, "stop|Stop", "go|Keep going");
            if (a == "stop") _run.Cancel();
        }

        public void Stop()
        {
            if (_cts != null) _cts.Cancel();
            if (_run != null) _run.Cancel();
        }

        // ============================================================= demo ===
        public async Task Demo(string dir, Shell shell)
        {
            // a real scan of this PC, then the screens are photographed
            await StartScan();
            for (int i = 0; i < 600 && _busy; i++) { await Task.Delay(500); if (i == 6) shell.Save(Path.Combine(dir, "backup-scanning.png")); }
            if (_model == null || _model.Categories.Count == 0) return;
            await shell.Settle(600);
            shell.Save(Path.Combine(dir, "backup-choose-programs.png"));
            var cats = E<ListBox>("CatList");
            foreach (var key in new[] { "files", "games", "automations", "media", "detected", "drives" })
            {
                var c = _model.Categories.FirstOrDefault(x => x.Key == key);
                if (c == null) continue;
                cats.SelectedItem = c;
                await shell.Settle(500);
                shell.Save(Path.Combine(dir, "backup-choose-" + key + ".png"));
            }
            Json.WriteFile(Path.Combine(dir, "selection-default.json"), Selection());
            ShowDest();
            await shell.Settle(500);
            shell.Save(Path.Combine(dir, "backup-destination.png"));
            if (string.IsNullOrEmpty(shell.Opts.TestRun)) { ShowView("ChooseView"); return; }

            // a test-mode backup through the real run screen: one small folder from another
            // drive added, one folder on the Desktop left out
            DriveScan other = _model.Scans.Values.FirstOrDefault(d => !d.IsSystem && d.Tree != null && d.Tree.Children != null);
            if (other != null)
            {
                var small = other.Tree.Children.Where(c => c.Bytes > (1 << 20) && c.Bytes < (40 << 20) && (c.Flags & NodeFlags.Denied) == 0).OrderBy(c => c.Bytes).FirstOrDefault();
                if (small != null) _model.Paths.Set(small.Path, true);
            }
            var desk = Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory);
            var deskNode = _model.Scans.Values.Select(d => d.Tree == null ? null : d.Tree.Find(desk)).FirstOrDefault(n => n != null);
            if (deskNode != null && deskNode.Children != null && deskNode.Children.Count > 0) _model.Paths.Set(deskNode.Children[0].Path, false);
            var sel = Path.Combine(dir, "selection-test.json");
            Json.WriteFile(sel, Selection());
            RunBackup(Path.Combine(shell.Opts.TestRun, Environment.MachineName + "_TEST"), sel, false);
            await shell.Settle(4000);
            shell.Save(Path.Combine(dir, "backup-run-progress.png"));
            for (int i = 0; i < 1200 && _busy; i++) await Task.Delay(500);
            await shell.Settle(800);
            shell.Save(Path.Combine(dir, "backup-run-done.png"));
        }
    }
}
