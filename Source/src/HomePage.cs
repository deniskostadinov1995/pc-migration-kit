// PC Migration Kit - Home: this PC, its drives (type and health), the four
// things the program does, and the backups it can see.
// Written by Claude 2026-10-02.
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Management;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;

namespace PCMK
{
    public class DriveDetails
    {
        public string Letter, Label, Format, Model, Media, Bus, Health;
        public long Total, Free;
        public bool IsSystem, IsRemovable;

        /// <summary>Every ready drive with a letter, plus what kind of disk it is (no admin rights needed).</summary>
        public static List<DriveDetails> Load()
        {
            var list = new List<DriveDetails>();
            var sys = Path.GetPathRoot(Environment.SystemDirectory).Substring(0, 1).ToUpper();
            foreach (var d in DriveInfo.GetDrives())
            {
                try
                {
                    if (!d.IsReady || (d.DriveType != DriveType.Fixed && d.DriveType != DriveType.Removable)) continue;
                    list.Add(new DriveDetails
                    {
                        Letter = d.Name.Substring(0, 1).ToUpper(), Label = d.VolumeLabel, Format = d.DriveFormat, Total = d.TotalSize, Free = d.AvailableFreeSpace,
                        IsSystem = d.Name.Substring(0, 1).ToUpper() == sys, IsRemovable = d.DriveType == DriveType.Removable
                    });
                }
                catch { }
            }
            try
            {
                // letter -> disk number. Without administrator rights MSFT_Partition only lists the
                // Windows disk; this older class sees every disk.
                var parts = new Dictionary<string, string>();
                using (var s = new ManagementObjectSearcher(new ManagementScope(@"root\cimv2"), new ObjectQuery("SELECT * FROM Win32_LogicalDiskToPartition")))
                    foreach (ManagementObject p in s.Get())
                    {
                        var disk = System.Text.RegularExpressions.Regex.Match(Convert.ToString(p["Antecedent"]), @"Disk #(\d+)");
                        var letter = System.Text.RegularExpressions.Regex.Match(Convert.ToString(p["Dependent"]), "DeviceID=\"([A-Za-z]):\"");
                        if (disk.Success && letter.Success) parts[letter.Groups[1].Value.ToUpper()] = disk.Groups[1].Value;
                    }
                var scope = new ManagementScope(@"root\Microsoft\Windows\Storage");
                var disks = new Dictionary<string, ManagementObject>();
                using (var s = new ManagementObjectSearcher(scope, new ObjectQuery("SELECT DeviceId, FriendlyName, MediaType, BusType, HealthStatus FROM MSFT_PhysicalDisk")))
                    foreach (ManagementObject p in s.Get()) disks[Convert.ToString(p["DeviceId"])] = p;
                foreach (var d in list)
                {
                    string num; ManagementObject pd;
                    if (!parts.TryGetValue(d.Letter, out num) || !disks.TryGetValue(num, out pd)) continue;
                    d.Model = Convert.ToString(pd["FriendlyName"]);
                    var mt = Convert.ToInt32(pd["MediaType"] ?? 0);
                    d.Media = mt == 4 ? "SSD" : mt == 3 ? "HDD" : mt == 5 ? "SCM" : "";
                    var bt = Convert.ToInt32(pd["BusType"] ?? 0);
                    d.Bus = bt == 17 ? "NVMe" : bt == 11 ? "SATA" : bt == 7 ? "USB" : bt == 8 ? "RAID" : bt == 10 ? "SAS" : "";
                    if (bt == 7) d.IsRemovable = true;
                    var hs = Convert.ToInt32(pd["HealthStatus"] ?? 0);
                    d.Health = hs == 0 ? "Healthy" : hs == 1 ? "Warning" : hs == 2 ? "Unhealthy" : "";
                }
            }
            catch { }
            return list.OrderBy(d => d.Letter).ToList();
        }
    }

    public class HomePage : IPage, IDemo
    {
        readonly Shell _shell;
        readonly FrameworkElement _v;
        public FrameworkElement View { get { return _v; } }
        public bool IsBusy { get { return false; } }

        public HomePage(Shell shell)
        {
            _shell = shell;
            _v = (FrameworkElement)Ui.LoadXaml("Home.xaml");
            Ui.Find<Button>(_v, "ActBackup").Click += (s, e) => _shell.Show("backup");
            Ui.Find<Button>(_v, "ActRestore").Click += (s, e) => _shell.Show("restore");
            Ui.Find<Button>(_v, "ActVerify").Click += (s, e) => _shell.Show("verify");
            Ui.Find<Button>(_v, "ActMedia").Click += (s, e) => _shell.Show("media");
            var user = Environment.UserName;
            Ui.Find<TextBlock>(_v, "Hello").Text = "Hello, " + user;
            Ui.Find<TextBlock>(_v, "PcLine").Text = Environment.MachineName + "  ·  " + Native.WindowsName + " (build " + Native.Build + ")  ·  signed in as " + user;
        }

        public void OnShown()
        {
            _shell.SetTitle("Home");
            LoadDrives();
            LoadBackups();
        }

        async void LoadDrives()
        {
            var host = Ui.Find<WrapPanel>(_v, "Drives");
            var drives = await Task.Run(() => DriveDetails.Load());
            host.Children.Clear();
            foreach (var d in drives) host.Children.Add(DriveCard(d));
            Ui.Find<TextBlock>(_v, "DrivesNote").Text = drives.Count + " drives, " + Fmt.Bytes(drives.Sum(x => (double)x.Total)) + " in total";
        }

        FrameworkElement DriveCard(DriveDetails d)
        {
            var card = new Border { Style = (Style)Application.Current.Resources["Card"], Width = 268, Margin = new Thickness(0, 0, 12, 12), Padding = new Thickness(16, 14, 16, 14) };
            var sp = new StackPanel();
            var top = new DockPanel();
            var icon = Ui.Icon(d.IsRemovable ? G.Usb : G.Drive, 20, d.IsSystem ? Ui.Brush("Accent") : Ui.Brush("TextMuted"));
            icon.Margin = new Thickness(0, 0, 10, 0);
            DockPanel.SetDock(icon, Dock.Left);
            top.Children.Add(icon);
            var name = new StackPanel();
            name.Children.Add(Ui.Text(d.Letter + ":  " + (string.IsNullOrEmpty(d.Label) ? "Local disk" : d.Label), "T.H3"));
            var kind = string.Join(" · ", new[] { d.Media, d.Bus, d.Model }.Where(x => !string.IsNullOrEmpty(x)));
            var k = Ui.Text(kind, "T.Small"); k.ToolTip = kind;
            name.Children.Add(k);
            top.Children.Add(name);
            sp.Children.Add(top);
            var used = d.Total - d.Free;
            var pb = new ProgressBar { Minimum = 0, Maximum = 100, Value = d.Total > 0 ? 100.0 * used / d.Total : 0, Margin = new Thickness(0, 12, 0, 8) };
            if (d.Total > 0 && d.Free < d.Total * 0.1) pb.Foreground = Ui.Brush("Warn");
            sp.Children.Add(pb);
            var row = new DockPanel();
            var free = Ui.Text(Fmt.Bytes(d.Free) + " free of " + Fmt.Bytes(d.Total), "T.Small");
            row.Children.Add(free);
            var chips = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right };
            if (d.IsSystem) chips.Children.Add(Ui.Chip("Windows", "accent"));
            if (!string.IsNullOrEmpty(d.Health) && d.Health != "Healthy") chips.Children.Add(Ui.Chip(d.Health, "bad"));
            DockPanel.SetDock(chips, Dock.Right);
            row.Children.Insert(0, chips);
            sp.Children.Add(row);
            card.Child = sp;
            return card;
        }

        void LoadBackups()
        {
            var host = Ui.Find<StackPanel>(_v, "Backups");
            host.Children.Clear();
            List<BackupInfo> list;
            try { list = Kit.FindBackups(); } catch { list = new List<BackupInfo>(); }
            if (list.Count == 0)
            {
                var c = new Border { Style = (Style)Application.Current.Resources["Card"] };
                c.Child = Ui.Text("No backups found next to the program yet. \"Scan & back up\" makes one.", "T.Muted");
                host.Children.Add(c);
            }
            foreach (var b in list.Take(6))
            {
                var c = new Border { Style = (Style)Application.Current.Resources["Card"], Margin = new Thickness(0, 0, 0, 10), Padding = new Thickness(16, 12, 12, 12) };
                var dp = new DockPanel();
                var btns = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
                DockPanel.SetDock(btns, Dock.Right);
                var bi = b;
                var r = Ui.Button("Restore", "Btn", G.Download); r.Margin = new Thickness(6, 0, 0, 0); r.Click += (s, e) => { ((RestorePage)_shell.Page("restore")).Select(bi.Dir); _shell.Show("restore"); };
                var v = Ui.Button("Verify", "Btn", G.Task); v.Margin = new Thickness(6, 0, 0, 0); v.Click += (s, e) => { ((VerifyPage)_shell.Page("verify")).Select(bi.Dir); _shell.Show("verify"); };
                var o = Ui.Button("Open", "Btn.Ghost", G.Folder); o.Margin = new Thickness(6, 0, 0, 0); o.Click += (s, e) => Native.OpenAsUser(bi.Dir);
                btns.Children.Add(o); btns.Children.Add(v); btns.Children.Add(r);
                dp.Children.Add(btns);
                var icon = Ui.Icon(G.Save, 20, Ui.Brush("Accent")); icon.Margin = new Thickness(0, 0, 14, 0);
                DockPanel.SetDock(icon, Dock.Left);
                dp.Children.Add(icon);
                var t = new StackPanel();
                t.Children.Add(Ui.Text(b.Title, "T.H3"));
                t.Children.Add(Ui.Text(b.Dir + "   ·   " + b.Subtitle, "T.Small"));
                dp.Children.Add(t);
                c.Child = dp;
                host.Children.Add(c);
            }
            // a restore that is not finished on this PC
            var card = Ui.Find<Border>(_v, "ResumeCard");
            card.Visibility = Visibility.Collapsed;
            try
            {
                foreach (var f in Directory.GetFiles(Kit.StateDir, "restore-state-*.json"))
                {
                    var st = Json.ReadFile(f);
                    var id = Json.Str(st, "BackupId");
                    var b = list.FirstOrDefault(x => x.Id == id);
                    if (b == null) continue;
                    var done = Json.Get(st, "Done") as IDictionary<string, object>;
                    int doneCount = done == null ? 0 : done.Count;
                    if (doneCount >= 15) continue;
                    var left = 15 - doneCount;
                    Ui.Find<TextBlock>(_v, "ResumeText").Text = "From " + b.Title + ": " + left + " step(s) are still \"to do\". Verify & fix shows exactly what is missing.";
                    var btn = Ui.Find<Button>(_v, "ResumeButton");
                    var bb = b;
                    btn.Click += (s, e) => { ((RestorePage)_shell.Page("restore")).Select(bb.Dir); _shell.Show("restore"); };
                    card.Visibility = Visibility.Visible;
                    break;
                }
            }
            catch { }
        }

        public Task Demo(string dir, Shell shell) { return Task.Delay(1500); }
    }
}
