// PC Migration Kit - Restore: pick a backup -> choose what to restore -> run the steps.
// Written by Claude 2026-10-02.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Shell;
using System.Windows.Threading;

namespace PCMK
{
    public class RestorePage : IPage, IStoppable, IDemo
    {
        readonly Shell _shell;
        readonly FrameworkElement _v;
        List<BackupInfo> _backups = new List<BackupInfo>();
        BackupInfo _sel;
        string _wanted;
        RestoreModel _model;
        EngineRun _run;
        bool _busy, _started, _reading;
        readonly Dictionary<int, Tuple<TextBlock, TextBlock>> _stepRows = new Dictionary<int, Tuple<TextBlock, TextBlock>>();

        public FrameworkElement View { get { return _v; } }
        public bool IsBusy { get { return _busy; } }
        T E<T>(string n) where T : class { return Ui.Find<T>(_v, n); }

        public RestorePage(Shell shell)
        {
            _shell = shell;
            _v = (FrameworkElement)Ui.LoadXaml("Restore.xaml");
            E<Button>("BrowseBackup").Click += (s, e) => BrowseBackup();
            E<Button>("ToChoose").Click += async (s, e) => await ReadBackup();
            E<Button>("BackToPick").Click += (s, e) => ShowView("PickView");
            E<Button>("StartRestore").Click += async (s, e) => await StartRestore();
            E<Button>("StopRun").Click += async (s, e) => await StopRun();
            E<Button>("RunAgain").Click += (s, e) => { _model = null; ShowView("PickView"); RefreshList(); };
            E<Button>("GoVerify").Click += (s, e) => { if (_sel != null) ((VerifyPage)_shell.Page("verify")).Select(_sel.Dir, true); _shell.Show("verify"); };
            E<Button>("RestartPc").Click += async (s, e) =>
            {
                if (await _shell.Ask("Restart the PC now?", "Save anything open first. After you sign in again, the restore opens by itself to finish what is left.", null, "go|Restart now", "cancel|Not now") == "go")
                    Process.Start(new ProcessStartInfo("shutdown.exe", "/r /t 5 /c \"PC Migration Kit: restarting to finish the restore\"") { CreateNoWindow = true, UseShellExecute = false });
            };
            E<Button>("SelAll").Click += (s, e) => Tick(true);
            E<Button>("SelNone").Click += (s, e) => Tick(false);
            E<ListBox>("CatList").SelectionChanged += (s, e) =>
            {
                var c = E<ListBox>("CatList").SelectedItem as Category;
                if (c == null) return;
                E<TextBlock>("CatTitle").Text = c.Title;
                E<TextBlock>("CatDesc").Text = c.Description;
                E<TreeView>("ItemTree").ItemsSource = c.Items;
            };
            E<CheckBox>("DryRun").Checked += (s, e) => UpdateTotals();
            E<CheckBox>("DryRun").Unchecked += (s, e) => UpdateTotals();
        }

        /// <summary>Opens the page with this backup chosen (from Home, or a restart as administrator).</summary>
        public void Select(string dir) { _wanted = dir; if (_backups.Count > 0) RefreshList(); }

        public void OnShown()
        {
            _shell.SetTitle("Restore");
            if (!_started)
            {
                _started = true;
                if (!string.IsNullOrEmpty(_shell.Opts.BackupPath)) _wanted = _shell.Opts.BackupPath;
                RefreshList();
                if (_shell.Opts.Page == "restore" && !string.IsNullOrEmpty(_shell.Opts.RunSelection) && _sel != null) { RunRestore(_sel, _shell.Opts.RunSelection, false); return; }
            }
            else if (!_busy && _model == null) RefreshList();
        }

        void ShowView(string name)
        {
            foreach (var n in new[] { "PickView", "ChooseView", "RunView" }) E<FrameworkElement>(n).Visibility = n == name ? Visibility.Visible : Visibility.Collapsed;
        }

        void RefreshList()
        {
            try { _backups = Kit.FindBackups(); } catch { _backups = new List<BackupInfo>(); }
            if (!string.IsNullOrEmpty(_wanted) && !_backups.Any(b => b.Dir.Equals(_wanted.TrimEnd('\\'), StringComparison.OrdinalIgnoreCase)))
            {
                var b = BackupInfo.Load(_wanted.TrimEnd('\\'));
                if (b != null) _backups.Insert(0, b);
            }
            var host = E<StackPanel>("BackupList");
            host.Children.Clear();
            if (_backups.Count == 0)
            {
                var c = new Border { Style = (Style)Application.Current.Resources["Card"] };
                c.Child = Ui.Text("No backup found next to the program. Open \"PC Migration Kit.exe\" from inside the backup folder on your backup drive, or use \"Find a backup folder...\".", "T.Muted");
                host.Children.Add(c);
            }
            RadioButton first = null, wanted = null;
            foreach (var b in _backups)
            {
                var rb = new RadioButton { Style = (Style)Application.Current.Resources["Segment"], GroupName = "rbk", Margin = new Thickness(0, 0, 0, 8) };
                var dp = new DockPanel();
                var icon = Ui.Icon(G.Save, 20, Ui.Brush("Accent")); icon.Margin = new Thickness(0, 0, 14, 0); DockPanel.SetDock(icon, Dock.Left);
                dp.Children.Add(icon);
                var sp = new StackPanel();
                sp.Children.Add(Ui.Text(b.Title, "T.H3"));
                sp.Children.Add(Ui.Text(b.Subtitle + "   ·   " + b.Dir, "T.Small"));
                dp.Children.Add(sp);
                rb.Content = dp;
                var bb = b;
                rb.Checked += (s, e) => ShowDetails(bb);
                host.Children.Add(rb);
                if (first == null) first = rb;
                if (_wanted != null && b.Dir.Equals(_wanted.TrimEnd('\\'), StringComparison.OrdinalIgnoreCase)) wanted = rb;
            }
            var pick = wanted ?? first;
            if (pick != null) pick.IsChecked = true;
        }

        void ShowDetails(BackupInfo b)
        {
            _sel = b;
            _model = null;
            E<Border>("Details").Visibility = Visibility.Visible;
            E<TextBlock>("DetTitle").Text = "From " + b.Computer + ", user " + b.User + ", " + b.CreatedAt.ToString("d MMMM yyyy, HH:mm");
            E<TextBlock>("DetLine").Text = b.Windows + "  ·  " + b.Dir;
            var warns = new List<string>();
            var sys = Json.Get(b.Manifest, "System");
            try
            {
                var mine = Microsoft.Win32.Registry.GetValue(@"HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Cryptography", "MachineGuid", null) as string;
                if (!string.IsNullOrEmpty(mine) && string.Equals(mine, Json.Str(sys, "MachineGuid"), StringComparison.OrdinalIgnoreCase))
                    warns.Add("This is the same Windows installation the backup was taken from. The restore is meant for the new Windows - only a practice run is possible here.");
            }
            catch { }
            if (!string.Equals(b.User, Environment.UserName, StringComparison.OrdinalIgnoreCase))
                warns.Add("The backup is from the account \"" + b.User + "\" and you are signed in as \"" + Environment.UserName + "\". Everything goes into your account, and paths that name the old one (" + b.UserProfile + ") are rewritten on the way.");
            if (b.TestMode) warns.Add("This backup was made in test mode - it only holds settings and a tiny sample of files.");
            E<Border>("DetWarn").Visibility = warns.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
            E<TextBlock>("DetWarnText").Text = string.Join("\n\n", warns);
            E<Button>("ToChoose").IsEnabled = true;
        }

        void BrowseBackup()
        {
            using (var dlg = new System.Windows.Forms.FolderBrowserDialog { Description = "Pick the backup folder (the one with manifest.json in it).", ShowNewFolderButton = false })
            {
                if (dlg.ShowDialog() != System.Windows.Forms.DialogResult.OK) return;
                if (!File.Exists(Path.Combine(dlg.SelectedPath, "manifest.json"))) { _shell.Info("Not a backup", "That folder has no manifest.json - pick the folder BACKUP made (named like PC-NAME_2026-09-27_1806)."); return; }
                _wanted = dlg.SelectedPath;
                RefreshList();
            }
        }

        // ============================================================ choose ===
        async Task ReadBackup()
        {
            if (_sel == null || _reading) return;
            _reading = true;
            E<Button>("ToChoose").IsEnabled = false;
            E<TextBlock>("ReadingLine").Text = "Reading the backup (its folders are measured - a minute on a hard disk)...";
            var m = new RestoreModel();
            var b = _sel;
            try
            {
                await Task.Run(() => m.Load(b, CancellationToken.None));
                m.Build();
                _model = m;
            }
            catch (Exception ex) { await _shell.Info("Could not read the backup", ex.Message); }
            _reading = false;
            E<Button>("ToChoose").IsEnabled = true;
            E<TextBlock>("ReadingLine").Text = "";
            if (_model == null) return;
            var cats = E<ListBox>("CatList");
            cats.ItemsSource = _model.Categories;
            cats.SelectedIndex = 0;
            E<TextBlock>("ChooseLine").Text = "From " + b.Computer + " (" + b.CreatedAt.ToString("d MMM yyyy") + "). Everything is ticked - untick what you don't want back. " + (_model.Done.Count > 0 ? "Steps already done on this PC are unticked." : "");
            foreach (var c in _model.Categories) c.PropertyChanged += (s, e) => UpdateTotals();
            _model.Paths.Changed += UpdateTotals;
            UpdateTotals();
            ShowView("ChooseView");
        }

        void Tick(bool on)
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

        void UpdateTotals()
        {
            if (_model == null) return;
            var steps = _model.StepCount;
            int apps = 0, appsAll = 0;
            foreach (var it in _model.Categories.SelectMany(c => c.Items).SelectMany(i => i.All()).Where(x => x.Section == "Apps" && x.Kind == ItemKind.Item))
            { appsAll++; if (it.IsChecked == true) apps++; }
            long bytes = 0;
            var files = _model.Categories.FirstOrDefault(c => c.Key == "files");
            if (files != null) bytes = files.SelectedBytes;
            E<TextBlock>("TotalLine").Text = Fmt.Plural(steps, "step") + " to run  ·  " + apps + " of " + appsAll + " programs  ·  about " + Fmt.Bytes(bytes) + " of files";
            E<TextBlock>("TotalSub").Text = E<CheckBox>("DryRun").IsChecked == true ? "Practice run: shows what each step would do and changes nothing." : "Needs administrator rights. You can keep using the PC; programs that hold files open are closed when their files are restored (you'll be asked first).";
            E<Button>("StartRestore").IsEnabled = steps > 0;
        }

        async Task StartRestore()
        {
            if (_model == null || _sel == null) return;
            var dry = E<CheckBox>("DryRun").IsChecked == true;
            if (_model.SamePc && !dry) { await _shell.Info("Same Windows as the backup", "This PC is the one the backup was made on. Switch on \"Practice run\" to see what the restore would do."); return; }
            var selFile = Path.Combine(Kit.TempDir, "restore-selection-" + DateTime.Now.ToString("yyyyMMdd-HHmmss") + ".json");
            Json.WriteFile(selFile, _model.Selection());
            if (!_shell.IsAdmin && !dry)
            {
                var a = await _shell.Ask("Administrator rights needed", "Installing programs, recreating services and tasks and writing to ProgramData need administrator rights. The program restarts as administrator and starts the restore with your choices right away.", null, "go|Restart and restore", "cancel|Cancel");
                if (a != "go") return;
                var args = "--page restore --backup " + Native.QuoteArg(_sel.Dir) + " --run-selection " + Native.QuoteArg(selFile);
                if (Native.RelaunchAsAdmin(args)) Application.Current.Shutdown();
                else await _shell.Info("Not restarted", "Windows did not give administrator rights (the prompt was cancelled).");
                return;
            }
            RunRestore(_sel, selFile, dry);
        }

        // =============================================================== run ===
        bool _dry;

        void RunRestore(BackupInfo b, string selFile, bool dry)
        {
            _sel = b;
            _dry = dry;
            ShowView("RunView");
            _busy = true;
            var start = DateTime.Now;
            var log = new LogView(E<ListBox>("LogList"));
            log.Clear();
            _stepRows.Clear();
            E<StackPanel>("StepRows").Children.Clear();
            E<TextBlock>("RunTitle").Text = dry ? "Practice run" : "Restoring";
            E<TextBlock>("RunLine").Text = "From " + b.Computer + " (" + b.CreatedAt.ToString("d MMM yyyy") + ")  ·  " + b.Dir;
            foreach (var n in new[] { "OpenLog", "RunAgain", "GoVerify", "RestartPc" }) E<Button>(n).Visibility = Visibility.Collapsed;
            E<Button>("StopRun").Visibility = Visibility.Visible;
            E<ProgressBar>("CurBar").IsIndeterminate = true;
            _shell.Taskbar.ProgressState = TaskbarItemProgressState.Indeterminate;
            var args = new List<string> { "-BackupPath", b.Dir, "-Selection", selFile };
            if (dry) args.Add("-DryRun");
            _run = new EngineRun("Restore.ps1", args.ToArray());
            int stepIndex = 0, stepCount = 0;
            object summary = null;
            _run.OnEvent += async ev =>
            {
                log.Handle(ev);
                switch (ev.Type)
                {
                    case "steps":
                        foreach (var s in Json.ToList(Json.Get(ev.Data, "steps"))) AddStepRow((int)Json.Long(s, "n"), Json.Str(s, "title"), Json.Str(s, "done"));
                        break;
                    case "step":
                        {
                            var n = (int)ev.L("n");
                            var state = ev.S("state");
                            stepIndex = (int)ev.L("index"); stepCount = (int)ev.L("of");
                            SetStep(n, state);
                            if (state == "start")
                            {
                                Tuple<TextBlock, TextBlock> row;
                                E<TextBlock>("CurLeft").Text = "Step " + n + (_stepRows.TryGetValue(n, out row) ? " - " + row.Item2.Text : "");
                                E<TextBlock>("CurRight").Text = stepIndex + " of " + stepCount;
                                E<ProgressBar>("CurBar").IsIndeterminate = true;
                                E<TextBlock>("CurFile").Text = "";
                                _shell.Taskbar.ProgressState = TaskbarItemProgressState.Normal;
                                _shell.Taskbar.ProgressValue = stepCount > 0 ? (double)(stepIndex - 1) / stepCount : 0;
                            }
                            break;
                        }
                    case "progress":
                        if (ev.S("kind") == "copy")
                        {
                            var exp = ev.D("expected");
                            E<ProgressBar>("CurBar").IsIndeterminate = exp <= 0;
                            if (exp > 0) E<ProgressBar>("CurBar").Value = Math.Min(100, 100 * ev.D("bytes") / exp);
                            E<TextBlock>("CurFile").Text = ev.S("activity") + "  ·  " + Fmt.Bytes(ev.D("bytes")) + "  ·  " + ev.L("files").ToString("N0") + " files  ·  " + ev.S("current");
                        }
                        else if (!ev.B("done"))
                        {
                            var pct = ev.L("pct");
                            E<ProgressBar>("CurBar").IsIndeterminate = pct < 0;
                            if (pct >= 0) E<ProgressBar>("CurBar").Value = pct;
                            E<TextBlock>("CurFile").Text = ev.S("activity") + (string.IsNullOrEmpty(ev.S("status")) ? "" : ": " + ev.S("status"));
                        }
                        break;
                    case "log":
                        if (ev.S("lvl") == "info" || ev.S("lvl") == "ok") E<TextBlock>("CurFile").Text = ev.S("text");
                        break;
                    case "mstable":
                        foreach (var r in Json.ToList(Json.Get(ev.Data, "rows")))
                        {
                            var st = Json.Str(r, "status");
                            log.Add(st == "OK" ? "ok" : st == "WARN" ? "warn" : "fail", Json.Str(r, "name") + "  -  " + st + "  -  " + Json.Str(r, "detail"));
                        }
                        break;
                    case "ask":
                        {
                            var id = ev.S("id");
                            var items = Json.Strs(ev.Data, "items");
                            string answer;
                            Native.FlashWindow(new System.Windows.Interop.WindowInteropHelper(_shell.Window).Handle, true);
                            if (id == "closeapps") answer = await _shell.Ask("Close these programs?", ev.S("text"), items, "close|Close them and continue", "keep|Leave them open");
                            else
                            {
                                var opts = Json.Strs(ev.Data, "options");
                                if (opts.Count == 0) opts = new List<string> { "y", "n" };
                                answer = await _shell.Ask("A question from the restore", ev.S("text"), items, opts.Select(o => o + "|" + (o == "y" ? "Yes" : o == "n" ? "No" : o)).ToArray());
                            }
                            _run.Answer(answer);
                            break;
                        }
                    case "summary": summary = ev.Data; break;
                }
            };
            _run.OnExit += code =>
            {
                _busy = false;
                E<Button>("StopRun").Visibility = Visibility.Collapsed;
                E<Button>("RunAgain").Visibility = Visibility.Visible;
                E<ProgressBar>("CurBar").IsIndeterminate = false;
                E<ProgressBar>("CurBar").Value = 100;
                if (!string.IsNullOrEmpty(_run.LogFile)) { E<Button>("OpenLog").Visibility = Visibility.Visible; E<Button>("OpenLog").Click += (s, e) => Native.OpenAsUser(_run.LogFile); }
                var left = Json.Arr(summary, "left").Count;
                var missing = Json.Strs(summary, "missing");
                var reboot = Json.Bool(summary, "reboot");
                if (_run.Cancelled) { E<TextBlock>("RunTitle").Text = "Restore stopped"; E<TextBlock>("CurLeft").Text = "Stopped. Start it again any time - finished steps are remembered."; }
                else if (code != 0) { E<TextBlock>("RunTitle").Text = "The restore could not run"; E<TextBlock>("CurLeft").Text = "See the messages - exit code " + code; }
                else if (dry) { E<TextBlock>("RunTitle").Text = "Practice run finished"; E<TextBlock>("CurLeft").Text = "Nothing was changed. The list shows what each step would do."; }
                else
                {
                    E<TextBlock>("RunTitle").Text = left == 0 ? "Restore finished" : "Restore finished - " + Fmt.Plural(left, "step") + " still to do";
                    E<TextBlock>("CurLeft").Text = "Took " + Fmt.Duration(DateTime.Now - start) + (missing.Count > 0 ? "  ·  " + Fmt.Plural(missing.Count, "thing") + " still need you (at the end of the list)" : "");
                    E<Button>("GoVerify").Visibility = Visibility.Visible;
                    if (reboot) { E<Button>("RestartPc").Visibility = Visibility.Visible; E<TextBlock>("RunFoot").Text = "Restart the PC now - Windows features or drivers need it. The restore opens again by itself afterwards to finish."; }
                    else E<TextBlock>("RunFoot").Text = "Restart the PC once so every program, service and startup item comes up cleanly. Then \"Verify\" checks that everything is back.";
                }
                E<TextBlock>("CurRight").Text = "";
                _shell.Taskbar.ProgressState = TaskbarItemProgressState.None;
                Native.FlashWindow(new System.Windows.Interop.WindowInteropHelper(_shell.Window).Handle, true);
            };
            try { _run.Start(); }
            catch (Exception ex) { _busy = false; log.Add("fail", "Could not start the engine: " + ex.Message); }
        }

        void AddStepRow(int n, string title, string done)
        {
            var g = new Grid { Margin = new Thickness(0, 4, 0, 4) };
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(26) });
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            var icon = Ui.Icon(string.IsNullOrEmpty(done) ? "" : G.Check, 13, string.IsNullOrEmpty(done) ? Ui.Brush("TextFaint") : Ui.Brush("Ok"));
            icon.VerticalAlignment = VerticalAlignment.Top; icon.Margin = new Thickness(0, 2, 0, 0);
            g.Children.Add(icon);
            var sp = new StackPanel();
            var t = new TextBlock { Text = title, Foreground = Ui.Brush("Text"), TextWrapping = TextWrapping.Wrap };
            var sub = Ui.Text(string.IsNullOrEmpty(done) ? "to do" : "done " + done, "T.Small");
            sp.Children.Add(t); sp.Children.Add(sub);
            Grid.SetColumn(sp, 1);
            g.Children.Add(sp);
            E<StackPanel>("StepRows").Children.Add(g);
            _stepRows[n] = Tuple.Create(icon, t);
            g.Tag = sub;
        }

        void SetStep(int n, string state)
        {
            Tuple<TextBlock, TextBlock> row;
            if (!_stepRows.TryGetValue(n, out row)) return;
            var sub = ((FrameworkElement)row.Item1.Parent).Tag as TextBlock;
            switch (state)
            {
                case "start": row.Item1.Text = G.Sync; row.Item1.Foreground = Ui.Brush("Accent"); row.Item2.FontWeight = FontWeights.SemiBold; if (sub != null) sub.Text = "running..."; break;
                case "done": row.Item1.Text = G.Check; row.Item1.Foreground = Ui.Brush("Ok"); row.Item2.FontWeight = FontWeights.Normal; if (sub != null) sub.Text = _dry ? "looked at - nothing changed" : "done just now"; break;
                default: row.Item1.Text = G.Warn; row.Item1.Foreground = Ui.Brush("Warn"); row.Item2.FontWeight = FontWeights.Normal; if (sub != null) sub.Text = "finished with warnings - stays \"to do\""; break;
            }
        }

        async Task StopRun()
        {
            if (_run == null || !_run.Running) return;
            if (await _shell.Ask("Stop the restore?", "The step that is running stops halfway. Finished steps are remembered; run the restore again later to carry on.", null, "stop|Stop", "go|Keep going") == "stop") _run.Cancel();
        }

        public void Stop() { if (_run != null) _run.Cancel(); }

        public async Task Demo(string dir, Shell shell)
        {
            if (_sel == null) return;
            await ReadBackup();
            await shell.Settle(800);
            if (_model == null) return;
            shell.Save(Path.Combine(dir, "restore-choose-steps.png"));
            var cats = E<ListBox>("CatList");
            foreach (var key in new[] { "programs", "files", "settings", "automations", "media" })
            {
                var c = _model.Categories.FirstOrDefault(x => x.Key == key);
                if (c == null) continue;
                cats.SelectedItem = c;
                await shell.Settle(400);
                shell.Save(Path.Combine(dir, "restore-choose-" + key + ".png"));
            }
            Json.WriteFile(Path.Combine(dir, "restore-selection-default.json"), _model.Selection());
            if (string.IsNullOrEmpty(shell.Opts.TestRun)) { ShowView("PickView"); return; }

            // a practice run (changes nothing) through the real run screen, every step ticked
            foreach (var it in _model.Categories.SelectMany(c => c.Items).SelectMany(i => i.All()).Where(i => i.Section == "Steps")) it.IsChecked = true;
            var sel = Path.Combine(dir, "restore-selection-test.json");
            Json.WriteFile(sel, _model.Selection());
            RunRestore(_sel, sel, true);
            await shell.Settle(5000);
            shell.Save(Path.Combine(dir, "restore-run-progress.png"));
            for (int i = 0; i < 1200 && _busy; i++) await Task.Delay(500);
            await shell.Settle(800);
            shell.Save(Path.Combine(dir, "restore-run-done.png"));
        }
    }
}
