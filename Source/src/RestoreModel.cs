// PC Migration Kit - what a backup holds, as things to tick for the restore:
// the steps, programs, folders (from a scan of the backup's files), registry
// settings, automations, Windows settings and media server parts.
// Written by Claude 2026-10-02.
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;

namespace PCMK
{
    public class RestoreModel
    {
        public BackupInfo B;
        public readonly PathModel Paths = new PathModel();
        public readonly List<Category> Categories = new List<Category>();
        public FolderNode Files;                  // the backup's files\ folder
        public Dictionary<string, string> Done = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        public string OldProfile, OldUser;
        public bool SamePc;

        public static readonly string[][] StepDefs =
        {
            new[] { "1", "letters", "Drive letters", "gives your other drives their old letters back (matched by partition, not by luck)" },
            new[] { "2", "features", "Windows features", "WSL, Hyper-V and the other features you had switched on" },
            new[] { "3", "apps", "Install programs", "installs every ticked program with winget - takes a while" },
            new[] { "4", "files", "Your files and profile", "Desktop, Documents, Downloads ..., AppData, your C:\\ folders" },
            new[] { "5", "appdata", "App data", "ProgramData, Steam, licences, Store apps and your Claude chats" },
            new[] { "6", "registry", "Programs' registry settings", "each ticked app's own settings" },
            new[] { "7", "env", "Environment variables", "PATH additions and your own variables (tokens included)" },
            new[] { "8", "services", "Services", "recreates the background services that are missing" },
            new[] { "9", "tasks", "Scheduled tasks", "recreated for this account" },
            new[] { "10", "startup", "Start with Windows", "programs and shortcuts that start when you sign in" },
            new[] { "11", "wsl", "WSL Linux distros", "registers your Linux distros again" },
            new[] { "12", "drivers", "Drivers", "adds the old PC's drivers - Windows uses the ones that fit" },
            new[] { "13", "system", "Wi-Fi, hosts, power plan, fonts", "Windows settings" },
            new[] { "14", "explorer", "Taskbar pins and Quick Access", "only between the same Windows version" },
            new[] { "15", "mediaserver", "Media server and smart home", "sets up and checks every ticked part" },
            new[] { "16", "extra", "Folders from other drives", "folders you added when backing up" },
        };

        public string P(string rel) { return Path.Combine(B.Dir, rel); }

        static string MaskValue(string v)
        {
            if (string.IsNullOrEmpty(v)) return "";
            if (Regex.IsMatch(v, @"^(%[^%]+%|[A-Za-z]:\\|\\\\)") || v.Contains(";") && v.Contains("\\")) return v;
            if (Regex.IsMatch(v, @"^\d{1,6}$")) return v;
            return "(hidden - " + v.Length + " characters)";
        }

        /// <summary>Reads the backup (scans its files folder, which can take a minute on a hard disk).</summary>
        public void Load(BackupInfo b, CancellationToken ct)
        {
            B = b;
            var sys = Json.Get(b.Manifest, "System");
            OldProfile = Json.Str(sys, "UserProfile");
            OldUser = Json.Str(sys, "UserName");
            try
            {
                var mine = Microsoft.Win32.Registry.GetValue(@"HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Cryptography", "MachineGuid", null) as string;
                SamePc = !string.IsNullOrEmpty(mine) && string.Equals(mine, Json.Str(sys, "MachineGuid"), StringComparison.OrdinalIgnoreCase);
            }
            catch { }
            var st = Json.ReadFile(Path.Combine(Kit.StateDir, "restore-state-" + b.Id + ".json"));
            var done = Json.Get(st, "Done") as IDictionary<string, object>;
            if (done != null) foreach (var kv in done) Done[kv.Key] = Json.Str(kv.Value);
            Files = DiskScanner.ScanFolder(P("files"), ct);
        }

        FolderNode Node(string full) { return Files == null ? null : Files.Find(full); }

        SelItem Folder(SelItem group, string full, string title, string subtitle = null)
        {
            var it = Model.FolderItem(full, title, Node(full), Paths, group);
            it.Level = group == null ? 0 : group.Level + 1;
            if (subtitle != null) it.Subtitle = subtitle;
            if (group != null) group.Children.Add(it);
            return it;
        }

        public void Build()
        {
            var m = B.Manifest;
            Categories.Add(Steps());
            Categories.Add(Programs());
            Categories.Add(FilesCat());
            Categories.Add(Settings());
            Categories.Add(Automations());
            var media = Media();
            if (media != null) Categories.Add(media);
            foreach (var cat in Categories) foreach (var it in cat.Items) Wire(it, cat);
            Paths.Changed += () => { foreach (var cat in Categories) cat.Refresh(); };
        }

        void Wire(SelItem it, Category cat)
        {
            it.PropertyChanged += (s, e) => { if (e.PropertyName == "IsChecked") cat.Refresh(); };
            foreach (var ch in it.Children) Wire(ch, cat);
        }

        Category Steps()
        {
            var cat = new Category { Key = "steps", Title = "Steps", Glyph = G.Task, Description = "Everything the restore does, in order. Steps that already ran on this PC are unticked - tick one to run it again (files you changed since are kept)." };
            var g = Model.Group("Steps", null, G.Task);
            var extra = Json.Arr(B.Manifest, "ExtraFolders").Count;
            foreach (var s in StepDefs)
            {
                if (s[0] == "16" && extra == 0) continue;
                string when;
                var isDone = Done.TryGetValue(s[1], out when);
                var it = Model.Leaf(g, "Steps", s[0], s[0] + ".  " + s[2], s[3], isDone ? G.Check : G.Play, !isDone);
                it.Tags.Add(isDone ? new Tag("done " + when, "ok") : new Tag("to do", "accent"));
            }
            cat.Items.Add(g);
            return cat;
        }

        Category Programs()
        {
            var cat = new Category { Key = "programs", Title = "Programs", Glyph = G.Apps, Description = "Installed with winget (step 3). Runtimes such as Node.js come back at the version you had, so your projects keep working." };
            var auto = Model.Group("Installed automatically", null, G.Rocket);
            var off = Model.Group("Not installed", "left out when the backup was made, or not needed", G.Info);
            off.IsExpanded = false;
            var list = P(@"settings\apps\install-list.txt");
            if (File.Exists(list))
            {
                foreach (var raw in File.ReadAllLines(list, Encoding.UTF8))
                {
                    var line = raw.Trim();
                    if (line.Length == 0) continue;
                    if (line.StartsWith("#"))
                    {
                        var mm = Regex.Match(line, @"^#\s+(\S+)(?:\s+\S+)?\s+\((.+)\)\s*$");
                        if (mm.Success) Model.Info(off, mm.Groups[1].Value, mm.Groups[2].Value);
                        continue;
                    }
                    var body = Regex.Replace(line, "#.*$", "").Trim();
                    var parts = body.Split(new[] { ' ', '\t' }, StringSplitOptions.RemoveEmptyEntries);
                    if (parts.Length == 0) continue;
                    var id = parts[0];
                    var name = Regex.Match(line, @"matched by name:\s*([^;]+)").Groups[1].Value.Trim();
                    var ver = Regex.Match(line, @"#.*?\bversion\s+([^\s;]+)").Groups[1].Value;
                    var title = name.Length > 0 ? name : (id.Contains(".") ? string.Join(" ", id.Split('.').Skip(1)) : id);
                    Model.Leaf(auto, "Apps", id, title, id + (parts.Length > 1 ? "  ·  " + parts[1] : "") + (ver.Length > 0 ? "  ·  version " + ver : ""), G.Package);
                }
            }
            cat.Items.Add(auto);
            var apps = Json.ReadFile(P(@"settings\apps\apps.json"));
            var store = Model.Group("Microsoft Store apps", null, G.Store);
            foreach (var s in Json.Arr(apps, "StoreApps")) Model.Leaf(store, "Apps", "store:" + Json.Str(s, "PackageName"), Json.Str(s, "Name"), "Microsoft Store", G.Store);
            if (store.Children.Count > 0) cat.Items.Add(store);
            var manual = Model.Group("Look for these by name", "no installer was known when the backup was made - the restore searches winget and the Store again", G.Hand);
            foreach (var p in Json.Arr(Json.Get(apps, "Plan"), "Manual"))
            {
                var it = Model.Leaf(manual, "Apps", "manual:" + Json.Str(p, "Name"), Json.Str(p, "Name"), Json.Str(p, "Version") + "  ·  " + Json.Str(p, "Publisher"), G.Hand);
                if (Regex.IsMatch(Json.Str(p, "Name") ?? "", @"(?i)\b(AVG|Avast|Norton|McAfee|Kaspersky|ESET|Malwarebytes|Bitdefender)\b")) { it.Tags.Add(new Tag("antivirus - left to you")); it.SetCheckedSilently(false); }
            }
            if (manual.Children.Count > 0) cat.Items.Add(manual);
            if (off.Children.Count > 0) cat.Items.Add(off);
            return cat;
        }

        Category FilesCat()
        {
            var cat = new Category { Key = "files", Title = "Files & folders", Glyph = G.Document, Description = "Folders in the backup. Open one to leave parts of it out. The first run puts the backup's copy back; later runs keep files that are newer on this PC." };
            var root = P("files");
            var g1 = Model.Group("Your folders", null, G.Folder);
            var kf = Path.Combine(root, "KnownFolders");
            if (Directory.Exists(kf)) foreach (var d in Directory.GetDirectories(kf).OrderBy(x => x)) { Folder(g1, d, Path.GetFileName(d)); Paths.AddDefault(d); }
            cat.Items.Add(g1);

            if (!string.IsNullOrEmpty(OldProfile) && OldProfile.Length > 3)
            {
                var prof = Path.Combine(root, "C", OldProfile.Substring(3));
                if (Directory.Exists(prof))
                {
                    var g2 = Model.Group("Your profile", "AppData (programs' settings and data) and the other folders in " + OldProfile, G.Folder);
                    Paths.AddDefault(prof, new[] { "AppData\\Local\\Microsoft", "AppData\\Roaming\\Microsoft", "AppData\\LocalLow\\Microsoft", "AppData\\Local\\Packages", "AppData\\Local\\Comms" }.Select(x => Path.Combine(prof, x)));
                    var pn = Node(prof);
                    if (pn != null && pn.Children != null)
                        foreach (var c in pn.Children) Folder(g2, c.Path, c.Name);
                    cat.Items.Add(g2);
                }
            }
            var g3 = Model.Group("Folders at the root of C:", null, G.Folder);
            foreach (var r in Json.Strs(B.Manifest, "RootFolders"))
            {
                var p = Path.Combine(root, "C", r);
                if (!Directory.Exists(p)) continue;
                Paths.AddDefault(p);
                Folder(g3, p, "C:\\" + r);
            }
            var pub = Path.Combine(root, "C", "Users", "Public");
            if (Directory.Exists(pub)) { Paths.AddDefault(pub); Folder(g3, pub, "Public folders"); }
            if (g3.Children.Count > 0) cat.Items.Add(g3);

            var g4 = Model.Group("Program and service data", "ProgramData folders of your services (Radarr, Sonarr, Jackett ...)", G.Service);
            foreach (var t in Json.Arr(B.Manifest, "ProgramDataRestore"))
            {
                var p = Path.Combine(root, "C", "ProgramData", Json.Str(t, "Folder") ?? "");
                if (!Directory.Exists(p)) continue;
                Paths.AddDefault(p);
                Folder(g4, p, "ProgramData\\" + Json.Str(t, "Folder"));
            }
            if (g4.Children.Count > 0) cat.Items.Add(g4);

            var extra = Json.Arr(B.Manifest, "ExtraFolders");
            if (extra.Count > 0)
            {
                var g5 = Model.Group("Folders from other drives", "go back where they were (step 16)", G.Drive);
                foreach (var x in extra)
                {
                    var it = Model.Leaf(g5, "Extra", Json.Str(x, "Path"), Json.Str(x, "Path"), "from the backup's " + Json.Str(x, "Dest"), G.Folder, true, Json.Long(x, "Bytes", -1));
                }
                cat.Items.Add(g5);
            }
            var info = Model.Group("Also in the backup (used only when needed)", null, G.Info);
            info.IsExpanded = false;
            foreach (var pf in new[] { "Program Files", "Program Files (x86)" })
            {
                var n = Node(Path.Combine(root, "C", pf));
                if (n != null) Model.Info(info, "C:\\" + pf + "  (" + Fmt.Bytes(n.Bytes) + ")", "a reference copy - programs are installed fresh; only Steam's library list, licences and a few settings are taken from it");
            }
            if (Files != null && Files.Children != null)
                foreach (var d in Files.Children.Where(x => x.Name.Length == 1 && !x.Name.Equals("C", StringComparison.OrdinalIgnoreCase)))
                    Model.Info(info, d.Name + ":  (" + Fmt.Bytes(d.Bytes) + ")", "media server folders from drive " + d.Name + ": - put back by step 15 only if they are missing there");
            if (info.Children.Count > 0) cat.Items.Add(info);
            return cat;
        }

        Category Settings()
        {
            var cat = new Category { Key = "settings", Title = "Settings", Glyph = G.Settings, Description = "Programs' registry settings, environment variables, WSL, drive letters and Windows settings." };
            var g = Model.Group("Windows", null, G.Desktop);
            var wifi = new List<string>();
            var wdir = P(@"settings\network\wifi");
            if (Directory.Exists(wdir))
                foreach (var f in Directory.GetFiles(wdir, "*.xml"))
                {
                    try { var x = System.Xml.Linq.XDocument.Load(f); var n = x.Descendants().FirstOrDefault(e => e.Name.LocalName == "name"); if (n != null) wifi.Add(n.Value); } catch { }
                }
            if (wifi.Count > 0) Model.Leaf(g, "Settings", "wifi", "Wi-Fi networks", string.Join(", ", wifi), G.Wifi);
            if (File.Exists(P(@"settings\network\hosts"))) Model.Leaf(g, "Settings", "hosts", "hosts file entries", "your own lines (Docker's and Tailscale's sections are left to them)", G.Globe);
            if (File.Exists(P(@"settings\power\power.json"))) Model.Leaf(g, "Settings", "power", "Power plan", "the plan the old PC used", G.Power);
            if (File.Exists(P(@"settings\fonts\fonts.json"))) Model.Leaf(g, "Settings", "fonts", "Extra fonts", null, G.Font);
            if (File.Exists(P(@"settings\registry\special\mapped-drives.reg"))) Model.Leaf(g, "Settings", "mappeddrives", "Mapped network drives", null, G.Network);
            cat.Items.Add(g);

            var vols = Json.Arr(B.Manifest, "Volumes").Where(v => !Json.Bool(v, "IsSystemDrive") && Json.Long(v, "DriveType") == 3 && Json.Str(v, "BusType") != "USB").ToList();
            if (vols.Count > 0)
            {
                var gl = Model.Group("Drive letters", "matched by partition, so each drive gets the letter it had", G.Drive);
                foreach (var v in vols) Model.Leaf(gl, "Letters", Json.Str(v, "Letter"), Json.Str(v, "Letter") + ":  " + Json.Str(v, "Label"), Json.Str(v, "DiskModel"), G.Drive);
                cat.Items.Add(gl);
            }

            var reg = Model.Group("Programs' registry settings", null, G.Registry);
            reg.IsExpanded = false;
            var rdir = P(@"settings\registry\hkcu");
            if (Directory.Exists(rdir))
                foreach (var f in Directory.GetFiles(rdir, "*.reg").OrderBy(x => x))
                    Model.Leaf(reg, "Registry", Path.GetFileNameWithoutExtension(f), Path.GetFileNameWithoutExtension(f), "HKCU\\Software\\" + Path.GetFileNameWithoutExtension(f), G.Registry, true, new FileInfo(f).Length);
            cat.Items.Add(reg);

            var env = Model.Group("Environment variables", null, G.Env);
            env.IsExpanded = false;
            var ej = Json.ReadFile(P(@"settings\env\environment.json"));
            var skip = new HashSet<string>(StringComparer.OrdinalIgnoreCase) { "TEMP", "TMP", "OneDrive", "OneDriveConsumer", "OneDriveCommercial", "USERNAME", "USERPROFILE", "ComSpec", "DriverData", "NUMBER_OF_PROCESSORS", "OS", "PROCESSOR_ARCHITECTURE", "PROCESSOR_IDENTIFIER", "PROCESSOR_LEVEL", "PROCESSOR_REVISION", "windir", "PSModulePath", "PATHEXT", "ChocolateyLastPathUpdate" };
            foreach (var v in Json.Arr(ej, "Variables"))
            {
                var name = Json.Str(v, "Name");
                if (skip.Contains(name)) continue;
                var it = Model.Leaf(env, "Env", Json.Str(v, "Scope") + "|" + name, name, MaskValue(Json.Str(v, "Value")), G.Env);
                it.Tags.Add(new Tag(Json.Str(v, "Scope") == "User" ? "you" : "all users"));
            }
            cat.Items.Add(env);

            var wj = Json.ReadFile(P(@"settings\wsl\wsl.json"));
            var distros = Json.Arr(wj, "Distros").Where(d => !Json.Bool(d, "IsDocker")).ToList();
            if (distros.Count > 0)
            {
                var gw = Model.Group("WSL Linux distros", null, G.Linux);
                foreach (var d in distros) Model.Leaf(gw, "Wsl", Json.Str(d, "Name"), Json.Str(d, "Name"), Json.Str(d, "Vhdx"), G.Linux, true, Json.Long(d, "VhdxBytes", -1));
                cat.Items.Add(gw);
            }
            return cat;
        }

        Category Automations()
        {
            var cat = new Category { Key = "automations", Title = "Automations", Glyph = G.Clock, Description = "Recreated for this account - paths to the old account's folder are rewritten on the way." };
            var tj = Json.ReadFile(P(@"settings\tasks\tasks.json"));
            var tasks = Model.Group("Scheduled tasks", null, G.Clock);
            foreach (var t in Json.Arr(tj, "Tasks"))
            {
                var full = Json.Str(t, "Path") + Json.Str(t, "Name");
                if (Json.Bool(t, "IsVendor") || string.IsNullOrEmpty(Json.Str(t, "XmlFile"))) { Model.Info(tasks, full, "recreated by its own app"); continue; }
                var it = Model.Leaf(tasks, "Tasks", full, full, Json.Str(t, "Command"), G.Clock);
                if (Json.Str(t, "State") == "Disabled") it.Tags.Add(new Tag("switched off"));
            }
            cat.Items.Add(tasks);
            var sj = Json.ReadFile(P(@"settings\startup\startup.json"));
            var st = Model.Group("Start with Windows", null, G.Rocket);
            foreach (var s in Json.Arr(sj, "Items"))
            {
                var it = Model.Leaf(st, "Startup", Json.Str(s, "Hive") + "|" + Json.Str(s, "Name"), Json.Str(s, "Name"), Json.Str(s, "Command"), G.Rocket);
                if (!Json.Bool(s, "Enabled", true)) it.Tags.Add(new Tag("switched off"));
            }
            cat.Items.Add(st);
            var vj = Json.ReadFile(P(@"settings\services\services.json"));
            var sv = Model.Group("Background services", null, G.Service);
            foreach (var s in Json.Arr(vj, "Services").Where(x => Json.Str(x, "Origin") == "app").OrderBy(x => Json.Str(x, "DisplayName")))
                Model.Leaf(sv, "Services", Json.Str(s, "Name"), Json.Str(s, "DisplayName") + " (" + Json.Str(s, "Name") + ")", Json.Str(s, "PathName"), G.Service);
            cat.Items.Add(sv);
            return cat;
        }

        static readonly string[][] MediaParts =
        {
            new[] { "qbittorrent", "qBittorrent" }, new[] { "radarr", "Radarr" }, new[] { "radarr4k", "Radarr 4K" }, new[] { "sonarr", "Sonarr" },
            new[] { "jackett", "Jackett" }, new[] { "prowlarr", "Prowlarr" }, new[] { "jellyfin", "Jellyfin" }, new[] { "caddy", "Caddy (HTTPS)" },
            new[] { "duckdns", "DuckDNS updater" }, new[] { "docker", "Docker Desktop" }, new[] { "seerr", "Seerr" }, new[] { "jellystat", "Jellystat" },
            new[] { "homeassistant", "Home Assistant (VirtualBox VM)" }
        };

        Category Media()
        {
            if (!File.Exists(P(@"settings\mediaserver\mediaserver.json"))) return null;
            var cat = new Category { Key = "media", Title = "Media server", Glyph = G.Media, Description = "Step 15 checks each ticked part and sets up whatever is not running - installs it, puts its data back, registers it the way it ran and starts it. Parts that already work are left alone." };
            var g = Model.Group("Parts", null, G.Media);
            foreach (var p in MediaParts) Model.Leaf(g, "Media", p[0], p[1], null, G.Media);
            cat.Items.Add(g);
            return cat;
        }

        // ------------------------------------------------------------ selection ---
        public Dictionary<string, object> Selection()
        {
            var sel = Model.BuildSelection(Categories, null);
            // steps: the ticked ones run
            var steps = Categories.SelectMany(c => c.Items).SelectMany(i => i.All()).Where(i => i.Section == "Steps" && i.IsChecked == true).Select(i => (object)int.Parse(i.Key)).ToArray();
            sel.Remove("Steps");
            sel["Steps"] = new Dictionary<string, object> { { "Include", steps } };
            var rel = Paths.ExcludePaths().Where(p => p.StartsWith(B.Dir, StringComparison.OrdinalIgnoreCase)).Select(p => p.Substring(B.Dir.TrimEnd('\\').Length + 1)).ToArray();
            sel["Files"] = new Dictionary<string, object> { { "ExcludeRel", rel } };
            return sel;
        }

        public int StepCount { get { return Categories.SelectMany(c => c.Items).SelectMany(i => i.All()).Count(i => i.Section == "Steps" && i.IsChecked == true); } }
    }
}
