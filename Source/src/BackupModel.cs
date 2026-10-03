// PC Migration Kit - turns the engine's catalog and the drive scans into the
// categories on the "Choose what to keep" screen.
// Written by Claude 2026-10-02.
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;

namespace PCMK
{
    public class BackupModel
    {
        public object Catalog;
        public Dictionary<string, DriveScan> Scans = new Dictionary<string, DriveScan>(StringComparer.OrdinalIgnoreCase);
        public readonly PathModel Paths = new PathModel();
        public readonly List<Category> Categories = new List<Category>();
        public string SysRoot = Path.GetPathRoot(Environment.SystemDirectory);
        public string Profile = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        public long MediaFileBytes;       // Home Assistant disk files (copied file by file, not as folders)
        public List<string> Warnings = new List<string>();

        FolderNode NodeFor(string path)
        {
            if (string.IsNullOrEmpty(path) || path.Length < 2) return null;
            DriveScan d;
            if (!Scans.TryGetValue(path.Substring(0, 1), out d) || d.Tree == null) return null;
            return d.Tree.Find(path);
        }

        SelItem Folder(SelItem group, string path, string title)
        {
            var n = NodeFor(path);
            var it = Model.FolderItem(path, title ?? Path.GetFileName(path.TrimEnd('\\')), n, Paths, group);
            if (group != null) { it.Level = group.Level + 1; group.Children.Add(it); }
            return it;
        }

        static string Pretty(string id)
        {
            if (string.IsNullOrEmpty(id)) return id;
            var parts = id.Split('.');
            return parts.Length > 1 ? string.Join(" ", parts.Skip(1)) : id;
        }

        public void Build()
        {
            var c = Catalog;
            var sys = Json.Get(c, "System");
            var sd = Json.Str(sys, "SystemDrive");
            if (!string.IsNullOrEmpty(sd)) SysRoot = sd.TrimEnd('\\') + "\\";
            var prof = Json.Str(sys, "UserProfile");
            if (!string.IsNullOrEmpty(prof)) Profile = prof;

            // ---------------------------------------------- what the plan covers
            foreach (var job in Json.Arr(c, "Plan"))
            {
                var rel = Json.Str(job, "Rel");
                if (string.IsNullOrEmpty(rel)) continue;
                var ex = Json.Strs(job, "ExcludeRel").Select(r => Path.Combine(SysRoot, r));
                Paths.AddDefault(Path.Combine(SysRoot, rel), ex, Json.Strs(job, "ExcludeNames"));
            }
            var media = Json.Get(c, "Media");
            foreach (var job in Json.Arr(media, "Jobs"))
            {
                var p = Json.Str(job, "Path");
                var files = Json.Strs(job, "Files");
                if (string.IsNullOrEmpty(p)) continue;
                if (files.Count == 0) Paths.AddDefault(p);
                else
                {
                    DriveScan d;
                    if (Scans.TryGetValue(p.Substring(0, 1), out d))
                        foreach (var f in files) { var full = Path.Combine(p, f); var hit = d.VmDiskFileSizes.FirstOrDefault(x => x.Key.Equals(full, StringComparison.OrdinalIgnoreCase)); MediaFileBytes += hit.Value; }
                }
            }
            Paths.AddNever(Path.Combine(Kit.Root, "Backups"));

            Categories.Add(Programs());
            Categories.Add(Files());
            Categories.Add(AppData());
            Categories.Add(Games());
            Categories.Add(Automations());
            Categories.Add(WindowsSettings());
            var m = Media();
            if (m != null) Categories.Add(m);
            Categories.Add(Detected());
            Categories.Add(AllDrives());
            foreach (var cat in Categories) foreach (var it in cat.Items) Wire(it, cat);
            Paths.Changed += () => { foreach (var cat in Categories) cat.Refresh(); };
        }

        void Wire(SelItem it, Category cat)
        {
            it.PropertyChanged += (s, e) => { if (e.PropertyName == "IsChecked") cat.Refresh(); };
            foreach (var ch in it.Children) Wire(ch, cat);
        }

        // ------------------------------------------------------------ programs ---
        Category Programs()
        {
            var cat = new Category { Key = "programs", Title = "Programs", Glyph = G.Apps, Description = "Programs are installed fresh on the new PC (with winget) and get your settings back from the backup. Untick the ones you don't want any more." };
            var plan = Json.Get(Catalog, "AppPlan");
            var names = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            foreach (var kv in (Json.Get(Catalog, "WingetNames") as IDictionary<string, object>) ?? new Dictionary<string, object>()) names[kv.Key] = Json.Str(kv.Value);

            var auto = Model.Group("Reinstalled automatically", "winget downloads and installs them; your settings come back from the backup", G.Download);
            foreach (var a in Json.Arr(plan, "Install").Where(a => string.IsNullOrEmpty(Json.Str(a, "Skip"))).OrderBy(a => names.ContainsKey(Json.Str(a, "Id")) ? names[Json.Str(a, "Id")] : Pretty(Json.Str(a, "Id"))))
            {
                var id = Json.Str(a, "Id");
                var src = Json.Str(a, "Source");
                string nm;
                var title = names.TryGetValue(id, out nm) ? nm : (Json.Str(a, "Name") ?? Pretty(id));
                var sub = id + (src == "msstore" ? "  ·  Microsoft Store" : "") + (!string.IsNullOrEmpty(Json.Str(a, "Version")) ? "  ·  version " + Json.Str(a, "Version") : "");
                var it = Model.Leaf(auto, "Apps", id, title, sub, G.Package);
                if (id.StartsWith("OpenJS.NodeJS") || id.StartsWith("Python.Python") || id.Contains("JDK") || id.StartsWith("GoLang")) it.Tags.Add(new Tag("same version as now", "accent"));
                if (Json.Str(a, "How") == "matched by name") it.Note = "Found in winget by its name (\"" + Json.Str(a, "Name") + "\").";
            }
            cat.Items.Add(auto);

            var store = Model.Group("Microsoft Store apps", "installed from the Store again", G.Store);
            foreach (var s in Json.Arr(Catalog, "StoreApps"))
                Model.Leaf(store, "Apps", "store:" + Json.Str(s, "PackageName"), Json.Str(s, "Name"), "Microsoft Store  ·  " + Json.Str(s, "Version"), G.Store);
            if (store.Children.Count > 0) cat.Items.Add(store);

            var manual = Model.Group("No automatic installer known", "on the new PC the program looks for them again by name; what it can't find goes on your to-do list", G.Hand);
            foreach (var p in Json.Arr(plan, "Manual"))
            {
                var it = Model.Leaf(manual, "Apps", "manual:" + Json.Str(p, "Name"), Json.Str(p, "Name"), string.Join("  ·  ", new[] { Json.Str(p, "Version"), Json.Str(p, "Publisher") }.Where(x => !string.IsNullOrEmpty(x))), G.Hand);
                it.Tags.Add(new Tag("by hand", "warn"));
            }
            if (manual.Children.Count > 0) cat.Items.Add(manual);

            var other = Model.Group("On another drive - they stay where they are", "games and portable programs on drives you keep", G.Drive);
            other.IsExpanded = false;
            foreach (var p in Json.Arr(plan, "OtherDrive")) Model.Info(other, Json.Str(p, "Name"), Json.Str(p, "Home"), G.Drive);
            if (other.Children.Count > 0) cat.Items.Add(other);

            var skipped = Model.Group("Not reinstalled on purpose", "frameworks and things Windows or another app brings back", G.Info);
            skipped.IsExpanded = false;
            foreach (var a in Json.Arr(plan, "Install").Where(a => !string.IsNullOrEmpty(Json.Str(a, "Skip")))) Model.Info(skipped, names.ContainsKey(Json.Str(a, "Id")) ? names[Json.Str(a, "Id")] : Json.Str(a, "Id"), Json.Str(a, "Skip"));
            foreach (var p in Json.Arr(plan, "System")) Model.Info(skipped, Json.Str(p, "Name"), "comes back with Windows, a driver or its parent app");
            if (skipped.Children.Count > 0) cat.Items.Add(skipped);
            return cat;
        }

        // ------------------------------------------------------------ files ------
        Category Files()
        {
            var cat = new Category { Key = "files", Title = "Your files", Glyph = G.Document, Description = "Your own folders. Open a folder to leave out parts of it." };
            var sys = Json.Get(Catalog, "System");
            var known = Json.Get(sys, "KnownFolders") as IDictionary<string, object>;
            var g1 = Model.Group("Your folders", null, G.Folder);
            var knownPaths = new List<string>();
            if (known != null)
                foreach (var name in new[] { "Desktop", "Documents", "Downloads", "Pictures", "Music", "Videos" })
                {
                    object v; if (!known.TryGetValue(name, out v)) continue;
                    var p = Json.Str(v);
                    if (string.IsNullOrEmpty(p) || !Directory.Exists(p)) continue;
                    knownPaths.Add(p);
                    var it = Folder(g1, p, name);
                    if (!p.StartsWith(SysRoot, StringComparison.OrdinalIgnoreCase)) it.Tags.Add(new Tag("on " + p.Substring(0, 2) + " - stays there"));
                }
            cat.Items.Add(g1);

            var g2 = Model.Group("Other folders in your profile", Profile, G.Folder);
            var profNode = NodeFor(Profile);
            if (profNode != null && profNode.Children != null)
                foreach (var ch in profNode.Children)
                {
                    if (ch.Name.Equals("AppData", StringComparison.OrdinalIgnoreCase)) continue;
                    if (knownPaths.Any(k => k.Equals(ch.Path, StringComparison.OrdinalIgnoreCase))) continue;
                    var it = Folder(g2, ch.Path, ch.Name);
                    if (ch.Name.StartsWith(".")) it.Subtitle = "settings of a developer tool or app";
                    if (ch.Bytes > 10L << 30) it.Tags.Add(new Tag("big", "warn"));
                }
            cat.Items.Add(g2);

            var g3 = Model.Group("Folders at the root of " + SysRoot.TrimEnd('\\'), "your own folders next to Windows (programs like Python, tools, projects)", G.Folder);
            foreach (var r in Json.Strs(Catalog, "RootFolders")) Folder(g3, Path.Combine(SysRoot, r), SysRoot + r);
            if (g3.Children.Count > 0) cat.Items.Add(g3);

            var g4 = Model.Group("Shared folders", null, G.Folder);
            Folder(g4, Path.Combine(Path.GetDirectoryName(Profile) ?? (SysRoot + "Users"), "Public"), "Public (shared with every account)");
            cat.Items.Add(g4);

            var users = Json.Strs(Catalog, "OtherUsers");
            if (users.Count > 0)
            {
                var g5 = Model.Group("Other accounts on this PC", "only their files can be copied - their programs and settings stay behind", G.Lock);
                g5.IsExpanded = false;
                foreach (var u in users) Folder(g5, Path.Combine(Path.GetDirectoryName(Profile) ?? (SysRoot + "Users"), u), u);
                cat.Items.Add(g5);
            }
            return cat;
        }

        // ------------------------------------------------------------ app data ---
        Category AppData()
        {
            var cat = new Category { Key = "appdata", Title = "App data & settings", Glyph = G.Settings, Description = "Where programs keep their settings, logins, databases and caches. Caches the program knows about are already left out." };
            var g = Model.Group("Per-app folders in your profile", "AppData - what makes your programs feel like yours", G.Settings);
            foreach (var sub in new[] { "Roaming", "Local", "LocalLow" })
            {
                var p = Path.Combine(Profile, "AppData", sub);
                if (!Directory.Exists(p)) continue;
                var it = Folder(g, p, "AppData\\" + sub);
                it.Subtitle = sub == "Roaming" ? "settings that follow you" : sub == "Local" ? "settings, databases and caches of this PC" : "low-trust apps: browsers' sandboxes, some games";
            }
            cat.Items.Add(g);

            var g2 = Model.Group("Program and service data", null, G.Service);
            var pd = Path.Combine(SysRoot, "ProgramData");
            var it2 = Folder(g2, pd, "ProgramData");
            it2.Subtitle = "data of services like Radarr, Sonarr, Jackett, Tailscale (Windows' own parts are left out)";
            foreach (var pf in new[] { "Program Files", "Program Files (x86)" })
            {
                var p = Path.Combine(SysRoot, pf);
                if (!Directory.Exists(p)) continue;
                var it = Folder(g2, p, pf);
                it.Subtitle = "a reference copy - programs are reinstalled; only Steam's library list, licences and a few settings are put back from it";
                it.Tags.Add(new Tag("reference copy"));
            }
            cat.Items.Add(g2);

            var reg = Model.Group("Registry settings of your apps", "each app's own branch of HKEY_CURRENT_USER\\Software", G.Registry);
            reg.IsExpanded = false;
            foreach (var r in Json.Strs(Catalog, "RegistryApps").OrderBy(x => x)) Model.Leaf(reg, "Registry", r, r, "HKCU\\Software\\" + r, G.Registry);
            cat.Items.Add(reg);
            return cat;
        }

        // ------------------------------------------------------------ games ------
        static readonly string[] SaveSpots =
        {
            @"%USERPROFILE%\Saved Games", @"%USERPROFILE%\Documents\My Games", @"%USERPROFILE%\Documents\Rockstar Games", @"%USERPROFILE%\Documents\Electronic Arts",
            @"%USERPROFILE%\Documents\EA Games", @"%USERPROFILE%\Documents\Ubisoft", @"%USERPROFILE%\Documents\CD Projekt Red", @"%USERPROFILE%\Documents\Paradox Interactive",
            @"%USERPROFILE%\Documents\SquareEnix", @"%USERPROFILE%\Documents\WB Games", @"%USERPROFILE%\Documents\NBGI", @"%USERPROFILE%\Documents\FromSoftware",
            @"%APPDATA%\Goldberg SteamEmu Saves", @"%APPDATA%\GSE Saves", @"%APPDATA%\SmartSteamEmu", @"%APPDATA%\Steam\CODEX", @"%APPDATA%\EMPRESS",
            @"%APPDATA%\CPY_SAVES", @"%USERPROFILE%\Documents\CPY_SAVES", @"%LOCALAPPDATA%\SKIDROW", @"%USERPROFILE%\Documents\SKIDROW", @"%APPDATA%\TENOKE",
            @"%APPDATA%\DOGE", @"%APPDATA%\FLT", @"%APPDATA%\RUNE", @"%APPDATA%\OnlineFix", @"%APPDATA%\CreamAPI", @"%LOCALAPPDATA%\anadius",
            @"%PUBLIC%\Documents\Steam", @"%PUBLIC%\Documents\EMPRESS", @"%PUBLIC%\Documents\OnlineFix", @"%PUBLIC%\Documents\Ubisoft",
            @"%ProgramData%\Steam", @"%ProgramData%\3DMGAME", @"%LOCALAPPDATA%\Packages\Microsoft.XboxApp_8wekyb3d8bbwe", @"%APPDATA%\.minecraft",
            @"%LOCALAPPDATA%\Larian Studios", @"%LOCALAPPDATA%\Pal\Saved\SaveGames", @"%USERPROFILE%\Documents\Klei", @"%APPDATA%\StardewValley",
            @"%PROGRAMFILES(X86)%\Steam\userdata", @"%PROGRAMFILES(X86)%\Ubisoft\Ubisoft Game Launcher\savegames"
        };

        Category Games()
        {
            var cat = new Category { Key = "games", Title = "Games & saves", Glyph = G.Game, Description = "Save games - including the ones cracked games keep in emulator folders or in the game folder itself - and where your games are installed." };
            var saves = Model.Group("Save games found", "kept with your profile; untick to leave one out", G.Save);
            var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (var spot in SaveSpots)
            {
                var p = Environment.ExpandEnvironmentVariables(spot.Replace("%USERPROFILE%", Profile));
                if (!Directory.Exists(p) || !seen.Add(p)) continue;
                var n = NodeFor(p);
                if (n != null && n.Bytes == 0) continue;
                var it = Folder(saves, p, p.Replace(Profile, "~"));
                if (spot.Contains("Goldberg") || spot.Contains("CODEX") || spot.Contains("EMPRESS") || spot.Contains("CPY") || spot.Contains("SKIDROW") || spot.Contains("SmartSteamEmu") || spot.Contains("OnlineFix") || spot.Contains("TENOKE") || spot.Contains("RUNE") || spot.Contains("FLT") || spot.Contains("DOGE") || spot.Contains("GSE") || spot.Contains("anadius") || spot.Contains("CreamAPI") || spot.Contains("3DMGAME") || spot.Contains(@"Documents\Steam"))
                    it.Tags.Add(new Tag("cracked / emulated games", "warn"));
            }
            // Unreal Engine games: %LOCALAPPDATA%\<Game>\Saved\SaveGames
            var local = NodeFor(Path.Combine(Profile, "AppData", "Local"));
            if (local != null && local.Children != null)
                foreach (var g in local.Children)
                {
                    var sv = g.Children == null ? null : g.Children.FirstOrDefault(x => x.Name.Equals("Saved", StringComparison.OrdinalIgnoreCase));
                    var sg = sv == null || sv.Children == null ? null : sv.Children.FirstOrDefault(x => x.Name.Equals("SaveGames", StringComparison.OrdinalIgnoreCase));
                    if (sg != null && sg.Bytes > 0 && seen.Add(sg.Path)) Folder(saves, sg.Path, g.Name + " (save games)");
                }
            cat.Items.Add(saves);

            var inside = Model.Group("Games that keep their saves inside the game folder", "emulated or cracked games (steam_settings, steam_emu.ini, CODEX.ini ...) - their folder is the only copy of your progress", G.Game);
            var games = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (var n in Flagged(NodeFlags.EmuSaves).Take(80))
            {
                var g = GameRoot(n);
                if (!games.Add(g.Path) || games.Count > 60) continue;
                Folder(inside, g.Path, g.Name).Subtitle = g.Path;
            }
            if (inside.Children.Count > 0) cat.Items.Add(inside);

            var libs = Model.Group("Game libraries", "Steam and other launchers find installed games again; tick a folder only if that drive is being replaced", G.Drive);
            libs.IsExpanded = false;
            foreach (var n in Flagged(NodeFlags.SteamLibrary).Take(30)) Folder(libs, n.Path, n.Path).Subtitle = "Steam library";
            foreach (var n in Flagged(NodeFlags.GameFolder).Where(n => n.Path.IndexOf("steamapps", StringComparison.OrdinalIgnoreCase) < 0 && n.Path.IndexOf(@"\Program Files", StringComparison.OrdinalIgnoreCase) < 0).Take(40))
                Folder(libs, n.Path, Path.GetFileName(n.Path)).Subtitle = n.Path;
            if (libs.Children.Count > 0) cat.Items.Add(libs);
            return cat;
        }

        static readonly System.Text.RegularExpressions.Regex GenericGameDir = new System.Text.RegularExpressions.Regex(
            @"^(bin|bin32|bin64|x64|x86|x86_64|win32|win64|binaries|game|data|retail|shipping|engine|release|common|plugins|managed|.+_data)$", System.Text.RegularExpressions.RegexOptions.IgnoreCase);

        /// <summary>The game's own folder for a folder deep inside it (CarX\x86_64 -> CarX).</summary>
        static FolderNode GameRoot(FolderNode n)
        {
            var g = n;
            while (g.Parent != null && g.Parent.Parent != null && GenericGameDir.IsMatch(g.Name)) g = g.Parent;
            return g;
        }

        /// <summary>The topmost folders with a flag, on every scanned drive. Drive roots, your
        /// profile itself and backups (this program's or a copy of a profile) are looked through, not reported.</summary>
        IEnumerable<FolderNode> Flagged(NodeFlags f)
        {
            foreach (var d in Scans.Values)
            {
                if (d.Tree == null) continue;
                var st = new Stack<FolderNode>();
                st.Push(d.Tree);
                while (st.Count > 0)
                {
                    var n = st.Pop();
                    if (n.Parent != null && n.Name.Equals("Backups", StringComparison.OrdinalIgnoreCase) && n.Parent.Name.Equals("PC-Migration-Kit", StringComparison.OrdinalIgnoreCase)) continue;
                    if (n.Path.EndsWith(@"\Windows.old", StringComparison.OrdinalIgnoreCase) || Paths.IsNever(n.Path)) continue;
                    var lookThrough = n.Parent == null || n.Path.Equals(Profile, StringComparison.OrdinalIgnoreCase) || (n.Parent.Parent == null && n.Name.Equals("Users", StringComparison.OrdinalIgnoreCase));
                    if ((n.Flags & f) != 0 && !lookThrough) { yield return n; continue; }
                    if (n.Children == null) continue;
                    if (n.Name.Equals("node_modules", StringComparison.OrdinalIgnoreCase) || n.Name.Equals(".git", StringComparison.OrdinalIgnoreCase)) continue;
                    for (int i = n.Children.Count - 1; i >= 0; i--) st.Push(n.Children[i]);
                }
            }
        }

        // ------------------------------------------------------------ automations ---
        Category Automations()
        {
            var cat = new Category { Key = "automations", Title = "Automations", Glyph = G.Clock, Description = "Scheduled tasks, programs that start with Windows, and background services - recreated on the new PC, pointing at the right places." };
            var tasks = Model.Group("Scheduled tasks", null, G.Clock);
            foreach (var t in Json.Arr(Catalog, "Tasks"))
            {
                var full = Json.Str(t, "Path") + Json.Str(t, "Name");
                if (Json.Bool(t, "IsVendor")) { Model.Info(tasks, full, "recreated by its own app"); continue; }
                var it = Model.Leaf(tasks, "Tasks", full, full, Json.Str(t, "Command"), G.Clock);
                if (Json.Str(t, "State") == "Disabled") it.Tags.Add(new Tag("switched off"));
                if (Json.Str(t, "UserId") == "SYSTEM" || Json.Str(t, "UserId") == "S-1-5-18") it.Tags.Add(new Tag("runs as SYSTEM"));
            }
            cat.Items.Add(tasks);

            var st = Model.Group("Start with Windows", null, G.Rocket);
            foreach (var s in Json.Arr(Catalog, "Startup"))
            {
                var key = Json.Str(s, "Hive") + "|" + Json.Str(s, "Name");
                var it = Model.Leaf(st, "Startup", key, Json.Str(s, "Name"), Json.Str(s, "Command"), G.Rocket);
                if (!Json.Bool(s, "Enabled", true)) it.Tags.Add(new Tag("switched off"));
                it.Tags.Add(new Tag(Json.Str(s, "Type") == "Run" ? (Json.Str(s, "Hive") == "HKCU" ? "you" : "all users") : "Startup folder"));
            }
            cat.Items.Add(st);

            var sv = Model.Group("Background services", "services of your programs (Windows' own are not listed)", G.Service);
            foreach (var s in Json.Arr(Catalog, "Services").OrderBy(x => Json.Str(x, "DisplayName")))
            {
                var title = Json.Str(s, "DisplayName") + " (" + Json.Str(s, "Name") + ")";
                if (Json.Str(s, "Origin") != "app") { Model.Info(sv, title, Json.Str(s, "Origin") == "driver" ? "comes back with its driver" : "comes back with its Store app"); continue; }
                var it = Model.Leaf(sv, "Services", Json.Str(s, "Name"), title, Json.Str(s, "PathName"), G.Service);
                it.Tags.Add(new Tag(Json.Str(s, "State") == "Running" ? "running" : Json.Str(s, "State"), Json.Str(s, "State") == "Running" ? "ok" : null));
            }
            cat.Items.Add(sv);
            return cat;
        }

        // ------------------------------------------------------------ settings ---
        static readonly HashSet<string> SystemEnv = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
            { "TEMP", "TMP", "OneDrive", "OneDriveConsumer", "OneDriveCommercial", "USERNAME", "USERPROFILE", "ComSpec", "DriverData", "NUMBER_OF_PROCESSORS", "OS", "PROCESSOR_ARCHITECTURE", "PROCESSOR_IDENTIFIER", "PROCESSOR_LEVEL", "PROCESSOR_REVISION", "windir", "PSModulePath", "PATHEXT", "ChocolateyLastPathUpdate" };

        Category WindowsSettings()
        {
            var cat = new Category { Key = "settings", Title = "Windows settings", Glyph = G.Desktop, Description = "Settings that live inside Windows itself." };
            var g = Model.Group("Windows", null, G.Desktop);
            var wifi = Json.Strs(Catalog, "Wifi");
            var w = Model.Leaf(g, "Settings", "wifi", "Wi-Fi networks and their passwords", wifi.Count == 0 ? "none saved" : string.Join(", ", wifi), G.Wifi);
            if (wifi.Count > 0) w.Tags.Add(new Tag("passwords", "warn"));
            Model.Leaf(g, "Settings", "hosts", "hosts file entries", Fmt.Plural(Json.Arr(Catalog, "Hosts").Count, "entry").Replace("entrys", "entries"), G.Globe);
            Model.Leaf(g, "Settings", "power", "Power plan", "the plan you use now", G.Power);
            var fonts = Json.Get(Catalog, "Fonts");
            Model.Leaf(g, "Settings", "fonts", "Extra fonts", Fmt.Plural(Json.Arr(fonts, "Machine").Count + Json.Arr(fonts, "User").Count, "font") + " you installed", G.Font);
            Model.Leaf(g, "Settings", "features", "Windows features", Fmt.Plural(Json.Arr(Catalog, "Features").Count, "feature") + " switched on (WSL, Hyper-V ...)", G.Settings);
            Model.Leaf(g, "Settings", "drivers", "Drivers", "a copy of every driver - saves hunting for network, audio and chipset drivers on the same motherboard", G.Settings);
            Model.Leaf(g, "Settings", "taskbar", "Taskbar pins", "the order of your pinned apps", G.Pin);
            if (Json.Arr(Catalog, "MappedDrives").Count > 0) Model.Leaf(g, "Settings", "mappeddrives", "Mapped network drives", string.Join(", ", Json.Arr(Catalog, "MappedDrives").Select(m => Json.Str(m, "Letter") + ": " + Json.Str(m, "RemotePath"))), G.Network);
            var rr = Model.Leaf(g, "Settings", "registry-reference", "Full registry reference copy", "the whole of your settings registry, to look things up later (not restored)", G.Registry);
            cat.Items.Add(g);

            var env = Model.Group("Environment variables", "values that look like passwords or tokens are hidden here, but are kept in the backup", G.Env);
            env.IsExpanded = false;
            foreach (var v in Json.Arr(Catalog, "Environment"))
            {
                var name = Json.Str(v, "Name");
                if (SystemEnv.Contains(name)) continue;
                var it = Model.Leaf(env, "Env", Json.Str(v, "Scope") + "|" + name, name, Json.Str(v, "Value"), G.Env);
                it.Tags.Add(new Tag(Json.Str(v, "Scope") == "User" ? "you" : "all users"));
                if ((Json.Str(v, "Value") ?? "").StartsWith("(hidden")) it.Tags.Add(new Tag("secret", "warn"));
            }
            cat.Items.Add(env);

            var wsl = Json.Arr(Catalog, "Wsl").Where(d => !Json.Bool(d, "IsDocker")).ToList();
            if (wsl.Count > 0)
            {
                var gw = Model.Group("WSL Linux distros", "registered again from their disk file (which travels with your profile)", G.Linux);
                foreach (var d in wsl) Model.Leaf(gw, "Wsl", Json.Str(d, "Name"), Json.Str(d, "Name"), Json.Str(d, "Vhdx"), G.Linux, true, Json.Long(d, "VhdxBytes"));
                cat.Items.Add(gw);
            }
            var info = Model.Group("You will do these by hand", null, G.Hand);
            info.IsExpanded = false;
            foreach (var p in Json.Arr(Catalog, "Printers")) Model.Info(info, "Printer: " + Json.Str(p, "Name"), "add it again in Settings > Printers");
            foreach (var cr in Json.Strs(Catalog, "Credentials")) Model.Info(info, "Saved sign-in: " + cr, "Windows Credential Manager - sign in again");
            if (info.Children.Count > 0) cat.Items.Add(info);
            return cat;
        }

        // ------------------------------------------------------------ media ------
        static readonly HashSet<string> MediaParts = new HashSet<string> { "jellyfin", "prowlarr", "caddy", "docker", "seerr", "jellystat", "homeassistant" };

        Category Media()
        {
            var media = Json.Get(Catalog, "Media");
            var states = Json.Arr(media, "States");
            if (states.Count == 0) return null;
            var cat = new Category { Key = "media", Title = "Media server & smart home", Glyph = G.Media, Description = "Jellyfin, the *arr apps, Seerr, Jellystat, Caddy and the Home Assistant VM. On the new PC the program sets each one up and checks it." };
            var g = Model.Group("Parts", null, G.Media);
            var jobs = Json.Arr(media, "Jobs");
            foreach (var s in states)
            {
                var key = Json.Str(s, "Key");
                if (key == "network") continue;
                var status = Json.Str(s, "Status");
                var tone = status == "OK" ? "ok" : status == "WARN" ? "warn" : "bad";
                SelItem it;
                if (MediaParts.Contains(key))
                {
                    long bytes = -1;
                    foreach (var j in jobs.Where(j => Json.Str(j, "Key") == key))
                    {
                        var n = NodeFor(Json.Str(j, "Path"));
                        if (Json.Strs(j, "Files").Count > 0) bytes = Math.Max(0, bytes) + MediaFileBytes;
                        else if (n != null) bytes = Math.Max(0, bytes) + n.Bytes;
                    }
                    var copies = jobs.Where(j => Json.Str(j, "Key") == key).Select(j => Json.Str(j, "Path")).ToList();
                    var what = copies.Count > 0 ? "  ·  copies " + string.Join(", ", copies) : (key == "seerr" || key == "jellystat" ? "  ·  exports its database" : "");
                    it = Model.Leaf(g, "Media", key, Json.Str(s, "Name"), Json.Str(s, "Detail") + what, G.Media, true, bytes);
                }
                else it = Model.Info(g, Json.Str(s, "Name"), Json.Str(s, "Detail") + "  ·  comes back with its program and data", G.Media);
                it.Tags.Add(new Tag(status, tone));
            }
            cat.Items.Add(g);
            return cat;
        }

        // ------------------------------------------------------------ detected ---
        Category Detected()
        {
            var cat = new Category { Key = "detected", Title = "Found on your drives", Glyph = G.Search, Description = "Things the scan found on every drive. Folders on drives you keep can stay unticked - tick them if that drive is being replaced or you want a second copy." };
            var code = Model.Group("Code projects", "folders with git, package.json, pyproject.toml, .sln ...", G.Code);
            foreach (var n in Flagged(NodeFlags.GitRepo | NodeFlags.CodeProject).Where(n => !InNoise(n.Path)).OrderByDescending(n => n.Bytes).Take(80))
                Folder(code, n.Path, n.Path);
            if (code.Children.Count > 0) cat.Items.Add(code);

            var vm = Model.Group("Virtual machine disks", "VirtualBox, Hyper-V and VMware disks", G.Vm);
            foreach (var d in Scans.Values) foreach (var n in d.VmDisks.OrderByDescending(x => x.VmBytes).Take(30)) Folder(vm, n.Path, n.Path);
            if (vm.Children.Count > 0) cat.Items.Add(vm);

            var lib = Model.Group("Video, music and photo libraries", "big folders that are mostly media", G.Video);
            lib.IsExpanded = false;
            foreach (var n in Flagged(NodeFlags.MediaLibrary).OrderByDescending(n => n.Bytes).Take(40)) Folder(lib, n.Path, n.Path);
            if (lib.Children.Count > 0) cat.Items.Add(lib);
            return cat;
        }

        bool InNoise(string p)
        {
            return p.IndexOf(@"\AppData\", StringComparison.OrdinalIgnoreCase) >= 0 || p.IndexOf(@"\Program Files", StringComparison.OrdinalIgnoreCase) >= 0 ||
                   p.IndexOf(@"\node_modules", StringComparison.OrdinalIgnoreCase) >= 0 || p.IndexOf(@"\site-packages", StringComparison.OrdinalIgnoreCase) >= 0 ||
                   p.IndexOf(@"\.cache", StringComparison.OrdinalIgnoreCase) >= 0 || p.IndexOf(@"\ProgramData\", StringComparison.OrdinalIgnoreCase) >= 0 ||
                   p.IndexOf(@"\Windows.old", StringComparison.OrdinalIgnoreCase) >= 0;
        }

        // ------------------------------------------------------------ all drives ---
        Category AllDrives()
        {
            var cat = new Category { Key = "drives", Title = "All drives", Glyph = G.Drive, Description = "Every folder on every scanned drive, biggest first. Ticked = in the backup. The program already ticks what belongs to your setup on " + SysRoot.TrimEnd('\\') + "; drives you keep stay unticked." };
            foreach (var d in Scans.Values.OrderBy(x => x.Root))
            {
                if (d.Tree == null) continue;
                var it = Model.FolderItem(d.Root, d.Root.TrimEnd('\\') + "  " + (string.IsNullOrEmpty(d.Label) ? "Local disk" : d.Label), d.Tree, Paths, null);
                it.Checkable = false;
                it.Subtitle = Fmt.Bytes(d.TotalBytes - d.FreeBytes) + " used of " + Fmt.Bytes(d.TotalBytes) + (d.IsSystem ? "  ·  Windows drive" : "") + "  ·  " + d.FilesSeen.ToString("N0") + " files scanned in " + Fmt.Duration(d.Took);
                it.Glyph = G.Drive;
                if (d.Error != null) it.Tags.Add(new Tag("scan error", "bad"));
                cat.Items.Add(it);
            }
            return cat;
        }

        // ------------------------------------------------------------ totals -----
        public long TotalSelectedBytes()
        {
            long s = 0;
            foreach (var d in Scans.Values) if (d.Tree != null) s += Paths.IncludedBytes(d.Tree);
            var mediaCat = Categories.FirstOrDefault(c => c.Key == "media");
            if (mediaCat != null)
                foreach (var it in mediaCat.Items.SelectMany(i => i.All()))
                    if (it.Key == "homeassistant" && it.IsChecked == true) s += MediaFileBytes;
            return s;
        }
    }
}
