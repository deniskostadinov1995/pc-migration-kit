// PC Migration Kit - the program: start-up, theme, dialogs and the main window.
// Written by Claude 2026-10-02.
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Markup;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Shell;
using System.Windows.Threading;

namespace PCMK
{
    public class Options
    {
        public string Page = "home";
        public string BackupPath;
        public bool AutoStart;
        public string Screenshot;     // developer: render every page to PNG files in this folder, then quit
        public string Theme;          // light / dark
        public string RunSelection;   // backup: start right away with this selection file (after a restart as administrator)
        public string Dest;           // backup: ... into this folder
        public bool Update;           // backup: ... updating the backup there
        public string TestRun;        // developer, with --screenshot: also run a test-mode backup into this folder and a practice restore

        public static Options Parse(string[] args)
        {
            var o = new Options();
            for (int i = 0; i < args.Length; i++)
            {
                var a = args[i].ToLowerInvariant();
                Func<string> next = () => i + 1 < args.Length ? args[++i] : null;
                if (a == "--page") o.Page = (next() ?? "home").ToLowerInvariant();
                else if (a == "--backup") o.BackupPath = next();
                else if (a == "--autostart" || a == "--autoscan" || a == "--autorun") o.AutoStart = true;
                else if (a == "--screenshot") o.Screenshot = next();
                else if (a == "--theme") o.Theme = next();
                else if (a == "--run-selection") o.RunSelection = next();
                else if (a == "--dest") o.Dest = next();
                else if (a == "--update") o.Update = true;
                else if (a == "--test-run") o.TestRun = next();
            }
            return o;
        }

        public string ToArgs(string page, bool autostart, string backup = null)
        {
            var s = "--page " + page;
            if (autostart) s += " --autostart";
            if (!string.IsNullOrEmpty(backup)) s += " --backup " + Native.QuoteArg(backup);
            return s;
        }
    }

    public static class Program
    {
        [STAThread]
        public static int Main(string[] args)
        {
            var opts = Options.Parse(args);
            var app = new Application { ShutdownMode = ShutdownMode.OnMainWindowClose };
            app.DispatcherUnhandledException += (s, e) =>
            {
                try
                {
                    var log = Path.Combine(Kit.TempDir, "app-error.log");
                    File.AppendAllText(log, DateTime.Now + "  " + e.Exception + Environment.NewLine + Environment.NewLine);
                    MessageBox.Show("Something went wrong inside PC Migration Kit:\n\n" + e.Exception.Message + "\n\nDetails were written to " + log, "PC Migration Kit", MessageBoxButton.OK, MessageBoxImage.Warning);
                }
                catch { }
                e.Handled = true;
            };
            Ui.Init(app, opts.Theme);
            var shell = new Shell(opts);
            if (opts.Screenshot != null) { shell.Window.Loaded += async (s, e) => await shell.Screenshots(opts.Screenshot); }
            app.Run(shell.Window);
            return 0;
        }
    }

    public static class G   // icon glyphs (Segoe Fluent Icons / MDL2 Assets)
    {
        public const string Home = "", Upload = "", Download = "", Shield = "", Check = "", Cancel = "",
            Warn = "", Info = "", Error = "", Apps = "", Folder = "", Document = "", Settings = "",
            Clock = "", Game = "", Server = "", Code = "", Drive = "", Search = "", Refresh = "",
            Play = "", Admin = "", Repair = "", Wifi = "", Power = "", Font = "", Env = "",
            Task = "", Rocket = "", Service = "", Linux = "", Media = "", Vm = "", Photo = "",
            Music = "", Video = "", Registry = "", Store = "", Hand = "", Link = "", Lock = "",
            Desktop = "", Star = "", Heart = "", Sync = "", Up = "", ChevronRight = "", Package = "",
            Globe = "", Key = "", Save = "", Box = "", Pin = "", Network = "", Usb = "";
    }

    public static class Ui
    {
        public static bool Dark { get; private set; }
        static Application _app;

        public static void Init(Application app, string theme)
        {
            _app = app;
            var dict = (ResourceDictionary)LoadXaml("Theme.xaml");
            app.Resources.MergedDictionaries.Add(dict);
            bool dark = theme == null ? !Native.AppsUseLightTheme : theme.Equals("dark", StringComparison.OrdinalIgnoreCase);
            var saved = Settings.Get("theme");
            if (theme == null && saved != null) dark = saved == "dark";
            ApplyTheme(dark);
        }

        public static void ApplyTheme(bool dark)
        {
            Dark = dark;
            var c = dark ? new Dictionary<string, string>
            {
                { "Bg", "#0F1116" }, { "Sidebar", "#13161C" }, { "Surface", "#181B22" }, { "Surface2", "#20242D" }, { "Surface3", "#292E39" },
                { "Border", "#2A2F3A" }, { "BorderStrong", "#3B4352" }, { "Text", "#E9EBF0" }, { "TextMuted", "#A0A8B7" }, { "TextFaint", "#6E7687" },
                { "Accent", "#5B8DEF" }, { "AccentHover", "#6E9BF2" }, { "AccentPressed", "#4A79D8" }, { "AccentSoft", "#1C2945" }, { "AccentText", "#FFFFFF" },
                { "Ok", "#43C98A" }, { "OkSoft", "#16302A" }, { "Warn", "#F2B544" }, { "WarnSoft", "#3A2F15" }, { "Bad", "#FF6B6B" }, { "BadSoft", "#3A1C20" },
                { "Info", "#8AB4F8" }, { "InfoSoft", "#1C2945" }, { "ScrollThumb", "#3B4352" }, { "Shadow", "#000000" }
            } : new Dictionary<string, string>
            {
                { "Bg", "#F4F6FA" }, { "Sidebar", "#ECEFF5" }, { "Surface", "#FFFFFF" }, { "Surface2", "#F3F5F9" }, { "Surface3", "#E7EBF2" },
                { "Border", "#E1E5EC" }, { "BorderStrong", "#C7CEDA" }, { "Text", "#17202E" }, { "TextMuted", "#586275" }, { "TextFaint", "#8A93A3" },
                { "Accent", "#2F6FEB" }, { "AccentHover", "#3F7DF2" }, { "AccentPressed", "#2559C9" }, { "AccentSoft", "#E4ECFD" }, { "AccentText", "#FFFFFF" },
                { "Ok", "#15803D" }, { "OkSoft", "#E3F5E9" }, { "Warn", "#B45309" }, { "WarnSoft", "#FDF2DC" }, { "Bad", "#DC2626" }, { "BadSoft", "#FDE8E8" },
                { "Info", "#2F6FEB" }, { "InfoSoft", "#E4ECFD" }, { "ScrollThumb", "#C7CEDA" }, { "Shadow", "#1A2233" }
            };
            foreach (var kv in c)
            {
                var b = new SolidColorBrush((Color)ColorConverter.ConvertFromString(kv.Value));
                b.Freeze();
                _app.Resources["B." + kv.Key] = b;
                _app.Resources["C." + kv.Key] = b.Color;
            }
        }

        public static Brush Brush(string key) { return (Brush)_app.Resources["B." + key]; }

        public static object LoadXaml(string name)
        {
            var asm = Assembly.GetExecutingAssembly();
            using (var s = asm.GetManifestResourceStream("Xaml/" + name))
            {
                if (s == null) throw new FileNotFoundException("Missing built-in screen: " + name);
                using (var r = new StreamReader(s)) return XamlReader.Parse(r.ReadToEnd());
            }
        }

        public static T Find<T>(FrameworkElement root, string name) where T : class
        {
            var o = root.FindName(name) as T;
            if (o == null) throw new InvalidOperationException("Screen element not found: " + name);
            return o;
        }

        // ---- small element factories for lists built in code
        public static TextBlock Text(string s, string style = "T.Body", Brush fg = null)
        {
            var t = new TextBlock { Text = s ?? "" };
            t.Style = (Style)_app.Resources[style];
            if (fg != null) t.Foreground = fg;
            return t;
        }

        public static TextBlock Icon(string glyph, double size = 16, Brush fg = null)
        {
            var t = new TextBlock { Text = glyph, FontSize = size };
            t.Style = (Style)_app.Resources["T.Icon"];
            if (fg != null) t.Foreground = fg;
            return t;
        }

        public static Border Chip(string text, string tone = null)
        {
            var b = new Border { Style = (Style)_app.Resources["Chip"] };
            var fg = Brush("TextMuted");
            if (tone == "ok") { b.Background = Brush("OkSoft"); fg = Brush("Ok"); }
            else if (tone == "warn") { b.Background = Brush("WarnSoft"); fg = Brush("Warn"); }
            else if (tone == "bad") { b.Background = Brush("BadSoft"); fg = Brush("Bad"); }
            else if (tone == "accent") { b.Background = Brush("AccentSoft"); fg = Brush("Accent"); }
            b.Child = new TextBlock { Text = text, FontSize = 11, Foreground = fg };
            return b;
        }

        public static Button Button(string text, string style = "Btn", string glyph = null)
        {
            var b = new Button { Style = (Style)_app.Resources[style] };
            if (glyph == null) b.Content = text;
            else
            {
                var sp = new StackPanel { Orientation = Orientation.Horizontal };
                sp.Children.Add(new TextBlock { Text = glyph, FontFamily = (FontFamily)_app.Resources["IconFont"], FontSize = 13, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 8, 0) });
                sp.Children.Add(new TextBlock { Text = text, VerticalAlignment = VerticalAlignment.Center });
                b.Content = sp;
            }
            return b;
        }

        public static Brush ToneBrush(string tone)
        {
            switch (tone)
            {
                case "ok": return Brush("Ok");
                case "warn": return Brush("Warn");
                case "bad": return Brush("Bad");
                case "accent": return Brush("Accent");
                case "info": return Brush("Info");
                default: return Brush("TextMuted");
            }
        }

        public static string ToneGlyph(string tone)
        {
            switch (tone)
            {
                case "ok": return G.Check;
                case "warn": return G.Warn;
                case "bad": return G.Error;
                case "accent": return G.Info;
                default: return G.Info;
            }
        }
    }

    /// <summary>A few remembered choices (theme, last backup folder) in %LOCALAPPDATA%.</summary>
    public static class Settings
    {
        static Dictionary<string, object> _d;
        static string File_ { get { return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "PCMigrationKit", "settings.json"); } }
        static Dictionary<string, object> D
        {
            get
            {
                if (_d != null) return _d;
                _d = Json.ReadFile(File_) as Dictionary<string, object> ?? new Dictionary<string, object>();
                return _d;
            }
        }
        public static string Get(string key) { object v; return D.TryGetValue(key, out v) ? Json.Str(v) : null; }
        public static void Set(string key, string value) { D[key] = value; try { Json.WriteFile(File_, D); } catch { } }
    }

    // =====================================================================
    public interface IPage
    {
        FrameworkElement View { get; }
        bool IsBusy { get; }
        void OnShown();
    }

    public class Shell
    {
        public readonly Window Window;
        public readonly Options Opts;
        readonly FrameworkElement _root;
        readonly ContentControl _host, _overlayHost;
        readonly Grid _overlay;
        readonly Dictionary<string, IPage> _pages = new Dictionary<string, IPage>();
        readonly Dictionary<string, RadioButton> _nav = new Dictionary<string, RadioButton>();
        string _current;
        bool _leaving;
        public readonly bool IsAdmin = Native.IsAdmin();
        public TaskbarItemInfo Taskbar = new TaskbarItemInfo();

        public Shell(Options opts)
        {
            Opts = opts;
            Window = (Window)Ui.LoadXaml("MainWindow.xaml");
            Window.TaskbarItemInfo = Taskbar;
            try { Window.Icon = BitmapFrame.Create(Assembly.GetExecutingAssembly().GetManifestResourceStream("App/app.ico")); } catch { }
            _root = (FrameworkElement)Window.Content;
            _host = Ui.Find<ContentControl>(Window, "PageHost");
            _overlay = Ui.Find<Grid>(Window, "Overlay");
            _overlayHost = Ui.Find<ContentControl>(Window, "OverlayHost");
            Ui.Find<TextBlock>(Window, "VersionText").Text = "version " + Kit.Version + (IsAdmin ? " · administrator" : "");

            Ui.Find<Button>(Window, "MinButton").Click += (s, e) => Window.WindowState = WindowState.Minimized;
            var max = Ui.Find<Button>(Window, "MaxButton");
            max.Click += (s, e) => Window.WindowState = Window.WindowState == WindowState.Maximized ? WindowState.Normal : WindowState.Maximized;
            Ui.Find<Button>(Window, "CloseButton").Click += (s, e) => Window.Close();
            Window.StateChanged += (s, e) =>
            {
                // a maximized borderless window reaches past the screen edge by the resize border
                ((FrameworkElement)Window.Content).Margin = Window.WindowState == WindowState.Maximized ? new Thickness(7) : new Thickness(0);
                max.Content = Window.WindowState == WindowState.Maximized ? "" : "";
            };
            Window.SourceInitialized += (s, e) => Native.StyleWindow(new WindowInteropHelper(Window).Handle, Ui.Dark);
            Window.Closing += (s, e) =>
            {
                var busy = _leaving ? null : _pages.Values.FirstOrDefault(p => p.IsBusy);
                if (busy == null) return;
                if (MessageBox.Show(Window, "Something is still running (a scan, backup, restore or repair). Stop it and close the program?", "PC Migration Kit", MessageBoxButton.YesNo, MessageBoxImage.Warning) != MessageBoxResult.Yes) { e.Cancel = true; return; }
                foreach (var p in _pages.Values.OfType<IStoppable>()) p.Stop();
            };

            var adminChip = Ui.Find<Border>(Window, "AdminChip");
            if (IsAdmin)
            {
                Ui.Find<TextBlock>(Window, "AdminIcon").Text = G.Shield;
                Ui.Find<TextBlock>(Window, "AdminIcon").Foreground = Ui.Brush("Ok");
                Ui.Find<TextBlock>(Window, "AdminText").Text = "Running as administrator";
                adminChip.ToolTip = "Everything can be read and changed.";
                adminChip.Cursor = Cursors.Arrow;
            }
            else adminChip.MouseLeftButtonUp += (s, e) => Elevate(_current ?? "home", false);

            var themeBtn = Ui.Find<Button>(Window, "ThemeButton");
            Action themeLabel = () =>
            {
                Ui.Find<TextBlock>(Window, "ThemeText").Text = Ui.Dark ? "Light mode" : "Dark mode";
                Ui.Find<TextBlock>(Window, "ThemeIcon").Text = Ui.Dark ? "" : "";
            };
            themeLabel();
            themeBtn.Click += (s, e) =>
            {
                Ui.ApplyTheme(!Ui.Dark);
                Settings.Set("theme", Ui.Dark ? "dark" : "light");
                Native.StyleWindow(new WindowInteropHelper(Window).Handle, Ui.Dark);
                themeLabel();
            };

            foreach (var key in new[] { "home", "backup", "restore", "verify", "media" })
            {
                var rb = Ui.Find<RadioButton>(Window, "Nav" + char.ToUpper(key[0]) + key.Substring(1));
                _nav[key] = rb;
                var k = key;
                rb.Checked += (s, e) => Show(k);
            }
            var start = _nav.ContainsKey(opts.Page) ? opts.Page : "home";
            Window.Loaded += (s, e) => _nav[start].IsChecked = true;
        }

        public IPage Page(string key)
        {
            IPage p;
            if (_pages.TryGetValue(key, out p)) return p;
            switch (key)
            {
                case "backup": p = new BackupPage(this); break;
                case "restore": p = new RestorePage(this); break;
                case "verify": p = new VerifyPage(this); break;
                case "media": p = new MediaPage(this); break;
                default: p = new HomePage(this); break;
            }
            _pages[key] = p;
            return p;
        }

        public void Show(string key)
        {
            if (_nav.ContainsKey(key) && _nav[key].IsChecked != true) { _nav[key].IsChecked = true; return; }   // comes back here through Checked
            _current = key;
            var p = Page(key);
            _host.Content = p.View;
            p.OnShown();
        }

        public void SetTitle(string text) { Ui.Find<TextBlock>(Window, "TitleText").Text = text ?? ""; }

        /// <summary>Starts the program again as administrator on the given page; closes this one if that worked.</summary>
        public bool Elevate(string page, bool autostart, string backup = null)
        {
            if (Native.RelaunchAsAdmin(Opts.ToArgs(page, autostart, backup)))
            {
                foreach (var p in _pages.Values.OfType<IStoppable>()) p.Stop();
                _leaving = true;
                Application.Current.Shutdown();
                return true;
            }
            return false;
        }

        // ---------------------------------------------------------- dialogs ---
        /// <summary>Shows a dialog over the window and returns the key of the button pressed.</summary>
        public Task<string> Ask(string title, string message, IEnumerable<string> items, params string[] buttons)
        {
            var tcs = new TaskCompletionSource<string>();
            var card = new Border { Style = (Style)Application.Current.Resources["Card"], Padding = new Thickness(26, 22, 26, 22), MaxWidth = 620, MinWidth = 420 };
            card.Effect = new System.Windows.Media.Effects.DropShadowEffect { BlurRadius = 30, ShadowDepth = 6, Opacity = 0.35 };
            var sp = new StackPanel();
            sp.Children.Add(Ui.Text(title, "T.H2"));
            if (!string.IsNullOrEmpty(message)) { var m = Ui.Text(message, "T.Muted"); m.Margin = new Thickness(0, 10, 0, 0); sp.Children.Add(m); }
            var list = items == null ? new List<string>() : items.ToList();
            if (list.Count > 0)
            {
                var box = new Border { Background = Ui.Brush("Surface2"), CornerRadius = new CornerRadius(8), Padding = new Thickness(12, 8, 12, 8), Margin = new Thickness(0, 14, 0, 0) };
                var inner = new StackPanel();
                foreach (var it in list.Take(14)) inner.Children.Add(new TextBlock { Text = "•  " + it, Margin = new Thickness(0, 2, 0, 2), Foreground = Ui.Brush("Text"), TextWrapping = TextWrapping.Wrap });
                if (list.Count > 14) inner.Children.Add(new TextBlock { Text = "... and " + (list.Count - 14) + " more", Foreground = Ui.Brush("TextMuted"), Margin = new Thickness(0, 4, 0, 0) });
                box.Child = new ScrollViewer { Content = inner, MaxHeight = 260, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
                sp.Children.Add(box);
            }
            var row = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 22, 0, 0) };
            for (int i = 0; i < buttons.Length; i++)
            {
                // "key|Label" or just "Label"; the first button is the main one
                var parts = buttons[i].Split(new[] { '|' }, 2);
                var key = parts[0]; var label = parts.Length > 1 ? parts[1] : parts[0];
                var b = Ui.Button(label, i == 0 ? "Btn.Primary" : "Btn");
                b.Margin = new Thickness(8, 0, 0, 0);
                b.Click += (s, e) => { _overlay.Visibility = Visibility.Collapsed; _overlayHost.Content = null; tcs.TrySetResult(key); };
                if (i == 0) b.IsDefault = true;
                if (i == buttons.Length - 1 && buttons.Length > 1) b.IsCancel = true;
                row.Children.Insert(0, b);
            }
            sp.Children.Add(row);
            card.Child = sp;
            _overlayHost.Content = card;
            _overlay.Visibility = Visibility.Visible;
            return tcs.Task;
        }

        public Task<string> Info(string title, string message) { return Ask(title, message, null, "ok|OK"); }

        /// <summary>A list of the backups the program can see; null when cancelled.</summary>
        public Task<BackupInfo> PickBackup(string title, BackupInfo current)
        {
            var tcs = new TaskCompletionSource<BackupInfo>();
            List<BackupInfo> list;
            try { list = Kit.FindBackups(); } catch { list = new List<BackupInfo>(); }
            var card = new Border { Style = (Style)Application.Current.Resources["Card"], Padding = new Thickness(26, 22, 26, 22), Width = 640 };
            card.Effect = new System.Windows.Media.Effects.DropShadowEffect { BlurRadius = 30, ShadowDepth = 6, Opacity = 0.35 };
            var sp = new StackPanel();
            sp.Children.Add(Ui.Text(title, "T.H2"));
            var inner = new StackPanel { Margin = new Thickness(0, 14, 0, 0) };
            BackupInfo chosen = current;
            foreach (var b in list)
            {
                var rb = new RadioButton { Style = (Style)Application.Current.Resources["Segment"], GroupName = "pick", Margin = new Thickness(0, 0, 0, 8) };
                var t = new StackPanel();
                t.Children.Add(Ui.Text(b.Title, "T.H3"));
                t.Children.Add(Ui.Text(b.Subtitle + "   ·   " + b.Dir, "T.Small"));
                rb.Content = t;
                var bb = b;
                rb.Checked += (s, e) => chosen = bb;
                if (current != null && current.Dir.Equals(b.Dir, StringComparison.OrdinalIgnoreCase)) rb.IsChecked = true;
                inner.Children.Add(rb);
            }
            Action<BackupInfo> close = r => { _overlay.Visibility = Visibility.Collapsed; _overlayHost.Content = null; tcs.TrySetResult(r); };
            var browse = Ui.Button("Find a backup folder...", "Btn.Ghost");
            browse.HorizontalAlignment = HorizontalAlignment.Left;
            browse.Click += (s, e) =>
            {
                using (var dlg = new System.Windows.Forms.FolderBrowserDialog { Description = "Pick the backup folder (the one with manifest.json in it).", ShowNewFolderButton = false })
                {
                    if (dlg.ShowDialog() != System.Windows.Forms.DialogResult.OK) return;
                    var b = BackupInfo.Load(dlg.SelectedPath);
                    if (b == null) { MessageBox.Show(Window, "That folder has no manifest.json - it is not a backup.", "PC Migration Kit"); return; }
                    close(b);
                }
            };
            if (list.Count == 0) inner.Children.Add(Ui.Text("No backups found next to the program.", "T.Muted"));
            sp.Children.Add(new ScrollViewer { Content = inner, MaxHeight = 380, VerticalScrollBarVisibility = ScrollBarVisibility.Auto });
            sp.Children.Add(browse);
            var row = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 18, 0, 0) };
            var cancel = Ui.Button("Cancel"); cancel.IsCancel = true; cancel.Click += (s, e) => close(null);
            var ok = Ui.Button("Use this backup", "Btn.Primary"); ok.Margin = new Thickness(8, 0, 0, 0); ok.IsDefault = true; ok.Click += (s, e) => close(chosen);
            row.Children.Add(cancel); row.Children.Add(ok);
            sp.Children.Add(row);
            card.Child = sp;
            _overlayHost.Content = card;
            _overlay.Visibility = Visibility.Visible;
            return tcs.Task;
        }

        // ---------------------------------------------------------- screenshots (developer check) ---
        public async Task Screenshots(string dir)
        {
            Directory.CreateDirectory(dir);
            foreach (var key in new[] { "home", "backup", "restore", "verify", "media" })
            {
                Show(key);
                var demo = Page(key) as IDemo;
                if (demo != null) await demo.Demo(dir, this);
                await Settle(800);
                Save(Path.Combine(dir, key + ".png"));
            }
            Application.Current.Shutdown();
        }

        public async Task Settle(int ms)
        {
            await Task.Delay(ms);
            await Window.Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
        }

        public void Save(string file)
        {
            var el = (FrameworkElement)Window.Content;
            el.UpdateLayout();
            var dpi = VisualTreeHelper.GetDpi(el);
            var bmp = new RenderTargetBitmap((int)(el.ActualWidth * dpi.DpiScaleX), (int)(el.ActualHeight * dpi.DpiScaleY), dpi.PixelsPerInchX, dpi.PixelsPerInchY, PixelFormats.Pbgra32);
            var bg = new DrawingVisual();
            using (var dc = bg.RenderOpen()) dc.DrawRectangle(Ui.Brush("Bg"), null, new Rect(0, 0, el.ActualWidth, el.ActualHeight));
            bmp.Render(bg);
            bmp.Render(el);
            var enc = new PngBitmapEncoder();
            enc.Frames.Add(BitmapFrame.Create(bmp));
            using (var f = File.Create(file)) enc.Save(f);
        }
    }

    public interface IStoppable { void Stop(); }
    public interface IDemo { Task Demo(string dir, Shell shell); }
}
