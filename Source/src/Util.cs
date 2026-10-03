// PC Migration Kit - small helpers: JSON, formatting, Windows calls, paths.
// Written by Claude 2026-10-02.
using System;
using System.Collections;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Text;
using System.Web.Script.Serialization;

namespace PCMK
{
    /// <summary>JSON in and out (JavaScriptSerializer: objects come back as dictionaries).</summary>
    public static class Json
    {
        static JavaScriptSerializer Ser()
        {
            return new JavaScriptSerializer { MaxJsonLength = int.MaxValue, RecursionLimit = 256 };
        }

        public static object Parse(string text)
        {
            if (string.IsNullOrWhiteSpace(text)) return null;
            return Ser().DeserializeObject(text);
        }

        public static object ReadFile(string path)
        {
            try
            {
                if (!File.Exists(path)) return null;
                var t = File.ReadAllText(path, Encoding.UTF8);
                if (t.Length > 0 && t[0] == '﻿') t = t.Substring(1);
                return Parse(t);
            }
            catch { return null; }
        }

        public static string Write(object o) { return Ser().Serialize(o); }

        public static void WriteFile(string path, object o)
        {
            Directory.CreateDirectory(Path.GetDirectoryName(path));
            File.WriteAllText(path, Write(o), new UTF8Encoding(false));
        }

        // ---- reading the dictionaries the serializer gives back
        public static object Get(object o, string key)
        {
            var d = o as IDictionary<string, object>;
            if (d == null) return null;
            object v;
            if (d.TryGetValue(key, out v)) return v;
            foreach (var kv in d) if (string.Equals(kv.Key, key, StringComparison.OrdinalIgnoreCase)) return kv.Value;
            return null;
        }

        public static object Dig(object o, params string[] keys)
        {
            foreach (var k in keys) { o = Get(o, k); if (o == null) return null; }
            return o;
        }

        public static string Str(object o, string key) { var v = Get(o, key); return v == null ? null : Convert.ToString(v, System.Globalization.CultureInfo.InvariantCulture); }
        public static string Str(object v) { return v == null ? null : Convert.ToString(v, System.Globalization.CultureInfo.InvariantCulture); }

        public static long Long(object o, string key, long def = 0) { return ToLong(Get(o, key), def); }
        public static long ToLong(object v, long def = 0)
        {
            if (v == null) return def;
            try { return Convert.ToInt64(Convert.ToDouble(v, System.Globalization.CultureInfo.InvariantCulture)); } catch { return def; }
        }
        public static double Dbl(object o, string key, double def = 0)
        {
            var v = Get(o, key);
            if (v == null) return def;
            try { return Convert.ToDouble(v, System.Globalization.CultureInfo.InvariantCulture); } catch { return def; }
        }
        public static bool Bool(object o, string key, bool def = false)
        {
            var v = Get(o, key);
            if (v == null) return def;
            if (v is bool) return (bool)v;
            bool b; if (bool.TryParse(Convert.ToString(v), out b)) return b;
            return ToLong(v, 0) != 0;
        }

        /// <summary>Always a list: an array, a single object (PowerShell's single-item arrays) or nothing.</summary>
        public static List<object> Arr(object o, string key) { return ToList(Get(o, key)); }
        public static List<object> ToList(object v)
        {
            var l = new List<object>();
            if (v == null) return l;
            if (v is string || v is IDictionary<string, object>) { l.Add(v); return l; }
            var e = v as IEnumerable;
            if (e != null) { foreach (var x in e) if (x != null) l.Add(x); return l; }
            l.Add(v);
            return l;
        }
        public static List<string> Strs(object o, string key) { return Arr(o, key).Select(x => Str(x)).Where(x => !string.IsNullOrEmpty(x)).ToList(); }
    }

    public static class Fmt
    {
        public static string Bytes(double b)
        {
            if (b < 0) return "";
            if (b >= 1099511627776.0) return (b / 1099511627776.0).ToString("0.00") + " TB";
            if (b >= 1073741824.0) return (b / 1073741824.0).ToString(b >= 107374182400.0 ? "0" : "0.0") + " GB";
            if (b >= 1048576.0) return (b / 1048576.0).ToString("0") + " MB";
            if (b >= 1024.0) return (b / 1024.0).ToString("0") + " KB";
            return b.ToString("0") + " B";
        }

        public static string Duration(TimeSpan t)
        {
            if (t.TotalSeconds < 60) return Math.Max(1, (int)t.TotalSeconds) + " s";
            if (t.TotalMinutes < 60) return (int)t.TotalMinutes + " min " + t.Seconds.ToString("00") + " s";
            return (int)t.TotalHours + " h " + t.Minutes.ToString("00") + " min";
        }

        public static string Count(long n, string one, string many) { return n.ToString("N0") + " " + (n == 1 ? one : many); }

        public static string Plural(long n, string word) { return n.ToString("N0") + " " + word + (n == 1 ? "" : "s"); }
    }

    public static class Native
    {
        [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);
        [DllImport("user32.dll")] public static extern bool FlashWindow(IntPtr hwnd, bool invert);

        public static bool IsAdmin()
        {
            try { return new WindowsPrincipal(WindowsIdentity.GetCurrent()).IsInRole(WindowsBuiltInRole.Administrator); }
            catch { return false; }
        }

        public static bool IsWindows11 { get { return Environment.OSVersion.Version.Build >= 22000; } }

        public static int Build
        {
            get
            {
                try
                {
                    var v = Microsoft.Win32.Registry.GetValue(@"HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion", "CurrentBuildNumber", null) as string;
                    int b; if (int.TryParse(v, out b)) return b;
                }
                catch { }
                return Environment.OSVersion.Version.Build;
            }
        }

        public static string WindowsName
        {
            get
            {
                try
                {
                    var name = Microsoft.Win32.Registry.GetValue(@"HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion", "ProductName", "Windows") as string ?? "Windows";
                    var disp = Microsoft.Win32.Registry.GetValue(@"HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion", "DisplayVersion", "") as string ?? "";
                    // Windows 11 still says "Windows 10" in ProductName
                    if (Build >= 22000) name = name.Replace("Windows 10", "Windows 11");
                    return (name + " " + disp).Trim();
                }
                catch { return "Windows"; }
            }
        }

        public static bool AppsUseLightTheme
        {
            get
            {
                try
                {
                    var v = Microsoft.Win32.Registry.GetValue(@"HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize", "AppsUseLightTheme", 1);
                    return v is int && (int)v != 0;
                }
                catch { return true; }
            }
        }

        /// <summary>Dark title bar and rounded corners (Windows 11), quietly ignored elsewhere.</summary>
        public static void StyleWindow(IntPtr hwnd, bool dark)
        {
            try
            {
                int v = dark ? 1 : 0;
                DwmSetWindowAttribute(hwnd, 20, ref v, 4);       // DWMWA_USE_IMMERSIVE_DARK_MODE
                int round = 2;
                DwmSetWindowAttribute(hwnd, 33, ref round, 4);   // DWMWA_WINDOW_CORNER_PREFERENCE = round
            }
            catch { }
        }

        /// <summary>Opens a file or folder through Explorer, so it starts with normal (not admin) rights.</summary>
        public static void OpenAsUser(string path)
        {
            try { Process.Start(new ProcessStartInfo(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "explorer.exe"), "\"" + path + "\"") { UseShellExecute = false }); }
            catch { }
        }

        public static void SelectInExplorer(string path)
        {
            try { Process.Start(new ProcessStartInfo(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "explorer.exe"), "/select,\"" + path + "\"") { UseShellExecute = false }); }
            catch { }
        }

        /// <summary>Starts this program again as administrator. False when the person said no.</summary>
        public static bool RelaunchAsAdmin(string args)
        {
            try
            {
                var psi = new ProcessStartInfo(Kit.ExePath, args ?? "") { UseShellExecute = true, Verb = "runas", WorkingDirectory = Kit.ExeDir };
                Process.Start(psi);
                return true;
            }
            catch (System.ComponentModel.Win32Exception) { return false; }
        }

        public static string QuoteArg(string s)
        {
            if (s == null) return "\"\"";
            if (s.Length > 0 && s.IndexOfAny(new[] { ' ', '\t', '"' }) < 0) return s;
            var sb = new StringBuilder("\"");
            int bs = 0;
            foreach (var c in s)
            {
                if (c == '\\') { bs++; continue; }
                if (c == '"') { sb.Append('\\', bs * 2 + 1); sb.Append('"'); bs = 0; continue; }
                sb.Append('\\', bs); bs = 0; sb.Append(c);
            }
            sb.Append('\\', bs * 2);
            sb.Append('"');
            return sb.ToString();
        }
    }

    /// <summary>Where the program and its engine (the PowerShell scripts) are.</summary>
    public static class Kit
    {
        public const string Version = "2.0";
        public static string ExePath { get { return Assembly.GetEntryAssembly().Location; } }
        public static string ExeDir { get { return Path.GetDirectoryName(ExePath); } }

        static string _engine;
        /// <summary>The Engine folder next to the program, or a copy of the scripts built into it.</summary>
        public static string EngineDir
        {
            get
            {
                if (_engine != null) return _engine;
                var local = Path.Combine(ExeDir, "Engine");
                if (File.Exists(Path.Combine(local, "Common.ps1")) && File.Exists(Path.Combine(local, "Catalog.ps1"))) return _engine = local;
                // the program travels alone (or with an older engine): unpack the scripts it was built with
                var asm = Assembly.GetExecutingAssembly();
                var names = asm.GetManifestResourceNames().Where(n => n.StartsWith("Engine/", StringComparison.Ordinal)).ToList();
                long sum = 0;
                foreach (var n in names) using (var s = asm.GetManifestResourceStream(n)) sum += s.Length;
                var dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "PCMigrationKit", "Engine-" + Version + "-" + sum);
                Directory.CreateDirectory(dir);
                foreach (var n in names)
                {
                    var file = Path.Combine(dir, n.Substring("Engine/".Length));
                    using (var s = asm.GetManifestResourceStream(n))
                    using (var f = File.Create(file)) s.CopyTo(f);
                }
                return _engine = dir;
            }
        }

        /// <summary>The kit folder: where Backups\ lives (the program's own folder).</summary>
        public static string Root { get { return ExeDir; } }

        public static string TempDir
        {
            get
            {
                var d = Path.Combine(Path.GetTempPath(), "PCMigrationKit");
                Directory.CreateDirectory(d);
                return d;
            }
        }

        public static string StateDir { get { return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "PCMigrationKit"); } }

        /// <summary>Backups next to the program, the backup the program sits in, and any found on other drives' kit folders.</summary>
        public static List<BackupInfo> FindBackups()
        {
            var list = new List<BackupInfo>();
            var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            Action<string> add = dir =>
            {
                try
                {
                    if (!seen.Add(dir)) return;
                    var b = BackupInfo.Load(dir);
                    if (b != null) list.Add(b);
                }
                catch { }
            };
            if (File.Exists(Path.Combine(ExeDir, "manifest.json"))) add(ExeDir);
            foreach (var root in new[] { Path.Combine(ExeDir, "Backups") }.Concat(DriveInfo.GetDrives().Where(d => d.IsReady && d.DriveType == DriveType.Fixed || d.IsReady && d.DriveType == DriveType.Removable).Select(d => Path.Combine(d.RootDirectory.FullName, "PC-Migration-Kit", "Backups"))))
            {
                try
                {
                    if (!Directory.Exists(root)) continue;
                    foreach (var d in Directory.GetDirectories(root)) if (File.Exists(Path.Combine(d, "manifest.json"))) add(d);
                }
                catch { }
            }
            return list.OrderByDescending(b => b.CreatedAt).ToList();
        }
    }

    /// <summary>What a backup folder holds, from its manifest.json.</summary>
    public class BackupInfo
    {
        public string Dir;
        public object Manifest;
        public string Id, Computer, User, UserProfile, Windows;
        public DateTime CreatedAt;
        public double Bytes;
        public long Files;
        public bool TestMode;

        public static BackupInfo Load(string dir)
        {
            var m = Json.ReadFile(Path.Combine(dir, "manifest.json"));
            if (m == null) return null;
            var sys = Json.Get(m, "System");
            var b = new BackupInfo
            {
                Dir = dir, Manifest = m, Id = Json.Str(m, "BackupId"),
                Computer = Json.Str(sys, "ComputerName"), User = Json.Str(sys, "UserName"), UserProfile = Json.Str(sys, "UserProfile"),
                Windows = (Json.Str(sys, "OS") + " " + Json.Str(sys, "DisplayVersion")).Trim(),
                TestMode = Json.Bool(m, "TestMode")
            };
            DateTime t;
            if (DateTime.TryParse(Json.Str(m, "CreatedAt"), out t)) b.CreatedAt = t;
            foreach (var c in Json.Arr(m, "Copies")) { b.Bytes += Json.Dbl(c, "Bytes"); b.Files += Json.Long(c, "Files"); }
            return b;
        }

        public string P(string rel) { return Path.Combine(Dir, rel); }

        public string Title { get { return Computer + " - " + CreatedAt.ToString("d MMM yyyy, HH:mm"); } }
        public string Subtitle { get { return "user " + User + " · " + Windows + (Bytes > 0 ? " · " + Fmt.Bytes(Bytes) + " copied" : "") + (TestMode ? " · TEST" : ""); } }
    }
}
