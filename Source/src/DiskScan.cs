// PC Migration Kit - a fast scan of whole drives: the size of every folder, plus
// what the folders hold (code projects, game folders and the saves cracked
// games keep in them, virtual machine disks, video/music/photo libraries).
// Uses FindFirstFileEx with large fetches; never follows junctions or links.
// Written by Claude 2026-10-02.
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;

namespace PCMK
{
    [Flags]
    public enum NodeFlags
    {
        None = 0, GitRepo = 1, CodeProject = 2, SteamLibrary = 4, GameFolder = 8, EmuSaves = 16,
        VmDisk = 32, Denied = 64, Skipped = 128, MediaLibrary = 256, PortableApp = 512
    }

    public sealed class FolderNode
    {
        public string Name;
        public string Path;
        public FolderNode Parent;
        public List<FolderNode> Children;
        public long OwnBytes, Bytes, OwnFiles, Files, Dirs;
        public long VideoBytes, AudioBytes, PhotoBytes, VmBytes, ExeCount;
        public NodeFlags Flags;
        public bool HasChildren { get { return Children != null && Children.Count > 0; } }

        public FolderNode Find(string path)
        {
            if (string.IsNullOrEmpty(path)) return null;
            var p = path.TrimEnd('\\');
            if (string.Equals(p, Path.TrimEnd('\\'), StringComparison.OrdinalIgnoreCase)) return this;
            if (!p.StartsWith(Path.TrimEnd('\\') + "\\", StringComparison.OrdinalIgnoreCase)) return null;
            var rest = p.Substring(Path.TrimEnd('\\').Length + 1).Split('\\');
            var n = this;
            foreach (var part in rest)
            {
                if (n.Children == null) return null;
                FolderNode next = null;
                foreach (var c in n.Children) if (string.Equals(c.Name, part, StringComparison.OrdinalIgnoreCase)) { next = c; break; }
                if (next == null) return null;
                n = next;
            }
            return n;
        }
    }

    public class DriveScan
    {
        public string Root;                 // "D:\"
        public string Label;
        public long TotalBytes, FreeBytes;
        public bool IsSystem;
        public FolderNode Tree;
        public volatile bool Done;
        public long DirsSeen, FilesSeen, BytesSeen;
        public volatile string Current = "";
        public string Error;
        public readonly List<FolderNode> VmDisks = new List<FolderNode>();   // folders holding VM disks (with VmBytes)
        public readonly List<string> VmDiskFiles = new List<string>();
        public readonly List<KeyValuePair<string, long>> VmDiskFileSizes = new List<KeyValuePair<string, long>>();
        public TimeSpan Took;
    }

    public static class DiskScanner
    {
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        struct WIN32_FIND_DATAW
        {
            public uint dwFileAttributes;
            public System.Runtime.InteropServices.ComTypes.FILETIME ftCreationTime, ftLastAccessTime, ftLastWriteTime;
            public uint nFileSizeHigh, nFileSizeLow, dwReserved0, dwReserved1;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string cFileName;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 14)] public string cAlternateFileName;
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern IntPtr FindFirstFileExW(string lpFileName, int fInfoLevelId, out WIN32_FIND_DATAW lpFindFileData, int fSearchOp, IntPtr lpSearchFilter, int dwAdditionalFlags);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern bool FindNextFileW(IntPtr hFindFile, out WIN32_FIND_DATAW lpFindFileData);
        [DllImport("kernel32.dll")] static extern bool FindClose(IntPtr hFindFile);

        static readonly IntPtr Invalid = new IntPtr(-1);
        const uint AttrDir = 0x10, AttrReparse = 0x400;

        static readonly HashSet<string> Video = new HashSet<string>(StringComparer.OrdinalIgnoreCase) { ".mkv", ".mp4", ".avi", ".m4v", ".mov", ".wmv", ".ts", ".m2ts", ".webm", ".flv", ".mpg", ".mpeg", ".iso" };
        static readonly HashSet<string> Audio = new HashSet<string>(StringComparer.OrdinalIgnoreCase) { ".mp3", ".flac", ".m4a", ".wav", ".ogg", ".opus", ".aac", ".wma", ".alac", ".aiff" };
        static readonly HashSet<string> Photo = new HashSet<string>(StringComparer.OrdinalIgnoreCase) { ".jpg", ".jpeg", ".png", ".heic", ".heif", ".raw", ".cr2", ".cr3", ".nef", ".arw", ".dng", ".gif", ".webp", ".tif", ".tiff" };
        static readonly HashSet<string> VmExt = new HashSet<string>(StringComparer.OrdinalIgnoreCase) { ".vdi", ".vhdx", ".vhd", ".vmdk", ".qcow2", ".avhdx" };
        static readonly HashSet<string> ProjectFiles = new HashSet<string>(StringComparer.OrdinalIgnoreCase) { "package.json", "pyproject.toml", "requirements.txt", "go.mod", "Cargo.toml", "pom.xml", "build.gradle", "composer.json", "Gemfile", "CMakeLists.txt", "platformio.ini" };
        // files that cracked or emulated Steam games keep next to the game - their saves often live in the game folder too
        static readonly HashSet<string> EmuFiles = new HashSet<string>(StringComparer.OrdinalIgnoreCase) { "steam_emu.ini", "cream_api.ini", "codex.ini", "cpy.ini", "smartsteamemu.ini", "steam_interfaces.txt", "onlinefix.ini", "empress.ini", "rune.ini", "ali213.ini", "3dmgame.ini", "valve.ini", "skidrow.ini", "reloaded.ini", "steam_appid.txt", "OnlineFix64.dll", "steamclient_loader.exe", "ColdClientLoader.ini" };

        /// <summary>Folders not worth descending into: Windows itself and the system's own areas.</summary>
        public static bool ShouldSkip(string path, bool isSystemDrive)
        {
            var name = System.IO.Path.GetFileName(path);
            if (name.Equals("System Volume Information", StringComparison.OrdinalIgnoreCase) || name.Equals("$Recycle.Bin", StringComparison.OrdinalIgnoreCase)
                || name.Equals("$WinREAgent", StringComparison.OrdinalIgnoreCase) || name.Equals("$SysReset", StringComparison.OrdinalIgnoreCase)
                || name.Equals("$WINDOWS.~BT", StringComparison.OrdinalIgnoreCase) || name.Equals("$GetCurrent", StringComparison.OrdinalIgnoreCase)) return true;
            if (isSystemDrive)
            {
                var p = path.TrimEnd('\\');
                if (p.Length == 10 && p.EndsWith("\\Windows", StringComparison.OrdinalIgnoreCase)) return true;
                if (p.EndsWith("\\Recovery", StringComparison.OrdinalIgnoreCase) && p.Length <= 11) return true;
            }
            return false;
        }

        public static void Scan(DriveScan d, CancellationToken ct, int workers)
        {
            var sw = System.Diagnostics.Stopwatch.StartNew();
            var root = new FolderNode { Name = d.Root.TrimEnd('\\'), Path = d.Root };
            d.Tree = root;
            try
            {
                // the top level first, then each top folder as its own job
                var top = new List<FolderNode>();
                ScanDir(d, root, top, ct);
                if (workers <= 1 || top.Count <= 1)
                {
                    var stack = new Stack<FolderNode>(top.AsEnumerable().Reverse());
                    Walk(d, stack, ct);
                }
                else
                {
                    var queue = new System.Collections.Concurrent.ConcurrentQueue<FolderNode>(top.OrderByDescending(n => n.Name.StartsWith("Users", StringComparison.OrdinalIgnoreCase) ? 1 : 0));
                    var tasks = new List<Task>();
                    for (int i = 0; i < workers; i++)
                    {
                        tasks.Add(Task.Factory.StartNew(() =>
                        {
                            FolderNode n;
                            while (!ct.IsCancellationRequested && queue.TryDequeue(out n))
                            {
                                var st = new Stack<FolderNode>();
                                st.Push(n);
                                Walk(d, st, ct);
                            }
                        }, TaskCreationOptions.LongRunning));
                    }
                    Task.WaitAll(tasks.ToArray());
                }
                Aggregate(root);
                Classify(root, d);
            }
            catch (Exception ex) { d.Error = ex.Message; }
            d.Took = sw.Elapsed;
            d.Done = true;
        }

        static void Walk(DriveScan d, Stack<FolderNode> stack, CancellationToken ct)
        {
            var kids = new List<FolderNode>();
            while (stack.Count > 0)
            {
                if (ct.IsCancellationRequested) return;
                var n = stack.Pop();
                if (ShouldSkip(n.Path, d.IsSystem)) { n.Flags |= NodeFlags.Skipped; continue; }
                kids.Clear();
                ScanDir(d, n, kids, ct);
                for (int i = kids.Count - 1; i >= 0; i--) stack.Push(kids[i]);
            }
        }

        static void ScanDir(DriveScan d, FolderNode n, List<FolderNode> subdirs, CancellationToken ct)
        {
            WIN32_FIND_DATAW f;
            var path = n.Path.EndsWith("\\") ? n.Path : n.Path + "\\";
            var h = FindFirstFileExW(@"\\?\" + path + "*", 1, out f, 0, IntPtr.Zero, 2);
            if (h == Invalid)
            {
                var err = Marshal.GetLastWin32Error();
                if (err == 5) n.Flags |= NodeFlags.Denied;
                return;
            }
            try
            {
                do
                {
                    var name = f.cFileName;
                    if ((f.dwFileAttributes & AttrDir) != 0)
                    {
                        if (name == "." || name == "..") continue;
                        if ((f.dwFileAttributes & AttrReparse) != 0) continue;   // junctions and links point elsewhere
                        var c = new FolderNode { Name = name, Path = path + name, Parent = n };
                        if (n.Children == null) n.Children = new List<FolderNode>();
                        n.Children.Add(c);
                        subdirs.Add(c);
                        if (name.Equals(".git", StringComparison.OrdinalIgnoreCase)) n.Flags |= NodeFlags.GitRepo;
                        else if (name.Equals("node_modules", StringComparison.OrdinalIgnoreCase) || name.Equals(".venv", StringComparison.OrdinalIgnoreCase)) n.Flags |= NodeFlags.CodeProject;
                        else if (name.Equals("steamapps", StringComparison.OrdinalIgnoreCase)) n.Flags |= NodeFlags.SteamLibrary;
                        else if (name.Equals("steam_settings", StringComparison.OrdinalIgnoreCase) || name.Equals("SteamEmu", StringComparison.OrdinalIgnoreCase)) n.Flags |= NodeFlags.EmuSaves;
                        Interlocked.Increment(ref d.DirsSeen);
                    }
                    else
                    {
                        long size = ((long)f.nFileSizeHigh << 32) | f.nFileSizeLow;
                        n.OwnBytes += size;
                        n.OwnFiles++;
                        var ext = System.IO.Path.GetExtension(name);
                        if (ext.Length > 0)
                        {
                            if (Video.Contains(ext)) n.VideoBytes += size;
                            else if (Audio.Contains(ext)) n.AudioBytes += size;
                            else if (Photo.Contains(ext)) n.PhotoBytes += size;
                            else if (VmExt.Contains(ext) && size > 100L * 1024 * 1024) { n.VmBytes += size; n.Flags |= NodeFlags.VmDisk; lock (d.VmDiskFiles) { d.VmDiskFiles.Add(path + name); d.VmDiskFileSizes.Add(new KeyValuePair<string, long>(path + name, size)); } }
                            else if (ext.Equals(".exe", StringComparison.OrdinalIgnoreCase)) n.ExeCount++;
                            else if (ext.Equals(".sln", StringComparison.OrdinalIgnoreCase) || ext.Equals(".csproj", StringComparison.OrdinalIgnoreCase)) n.Flags |= NodeFlags.CodeProject;
                        }
                        if (ProjectFiles.Contains(name)) n.Flags |= NodeFlags.CodeProject;
                        else if (name.Equals("steam_api64.dll", StringComparison.OrdinalIgnoreCase) || name.Equals("steam_api.dll", StringComparison.OrdinalIgnoreCase)) n.Flags |= NodeFlags.GameFolder;
                        else if (EmuFiles.Contains(name)) n.Flags |= NodeFlags.EmuSaves;
                        Interlocked.Increment(ref d.FilesSeen);
                        Interlocked.Add(ref d.BytesSeen, size);
                    }
                } while (FindNextFileW(h, out f) && !ct.IsCancellationRequested);
            }
            finally { FindClose(h); }
            d.Current = n.Path;
        }

        static void Aggregate(FolderNode root)
        {
            // post-order without recursion (deep trees)
            var order = new List<FolderNode>();
            var st = new Stack<FolderNode>();
            st.Push(root);
            while (st.Count > 0)
            {
                var n = st.Pop();
                order.Add(n);
                if (n.Children != null) foreach (var c in n.Children) st.Push(c);
            }
            for (int i = order.Count - 1; i >= 0; i--)
            {
                var n = order[i];
                n.Bytes += n.OwnBytes; n.Files += n.OwnFiles;
                if (n.Children != null)
                {
                    n.Children.Sort((a, b) => b.Bytes.CompareTo(a.Bytes));
                    n.Dirs += n.Children.Count;
                }
                var p = n.Parent;
                if (p != null)
                {
                    p.Bytes += n.Bytes; p.Files += n.Files; p.Dirs += n.Dirs;
                    p.VideoBytes += n.VideoBytes; p.AudioBytes += n.AudioBytes; p.PhotoBytes += n.PhotoBytes; p.VmBytes += n.VmBytes;
                }
            }
        }

        static void Classify(FolderNode root, DriveScan d)
        {
            var st = new Stack<FolderNode>();
            st.Push(root);
            while (st.Count > 0)
            {
                var n = st.Pop();
                if (n.Bytes > 5L * 1024 * 1024 * 1024 && n.VideoBytes + n.AudioBytes + n.PhotoBytes > n.Bytes * 0.6) n.Flags |= NodeFlags.MediaLibrary;
                if ((n.Flags & NodeFlags.VmDisk) != 0) lock (d.VmDisks) d.VmDisks.Add(n);
                if (n.Children != null) foreach (var c in n.Children) st.Push(c);
            }
        }

        /// <summary>Size of one folder tree (for the few known places outside a full scan).</summary>
        public static FolderNode ScanFolder(string path, CancellationToken ct)
        {
            if (!Directory.Exists(path)) return null;
            var d = new DriveScan { Root = path };
            var root = new FolderNode { Name = System.IO.Path.GetFileName(path.TrimEnd('\\')), Path = path.TrimEnd('\\') };
            d.Tree = root;
            var st = new Stack<FolderNode>();
            st.Push(root);
            Walk(d, st, ct);
            Aggregate(root);
            return root;
        }
    }
}
