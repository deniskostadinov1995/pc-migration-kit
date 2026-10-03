// PC Migration Kit - the things you can tick: one SelItem per program, task,
// setting or folder, grouped into categories. Folders share one PathModel, so
// a folder that shows up in two places (Saved Games under "Your files" and
// under "Games") is always ticked the same in both.
// Written by Claude 2026-10-02.
using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.ComponentModel;
using System.IO;
using System.Linq;
using System.Windows;

namespace PCMK
{
    public enum ItemKind { Group, Item, Folder, Info }

    public class Tag
    {
        public string Text { get; set; }
        public string Tone { get; set; }   // null, ok, warn, bad, accent
        public Tag(string text, string tone = null) { Text = text; Tone = tone; }
    }

    public class SelItem : INotifyPropertyChanged
    {
        public event PropertyChangedEventHandler PropertyChanged;
        void On(string p) { var h = PropertyChanged; if (h != null) h(this, new PropertyChangedEventArgs(p)); }
        public void Refresh(params string[] props) { foreach (var p in props) On(p); }

        public ItemKind Kind;
        public string Section;          // selection section: Apps, Tasks, Startup, Services, Env, Registry, Settings, Media, Wsl, Wifi, Steps, Extra ...
        public string Key;              // id within the section
        public string Path;             // folders: the full path
        public FolderNode Node;         // folders: the scanned tree (children appear when opened)
        public PathModel Paths;         // folders: the shared ticks
        public SelItem Parent;
        public int Level;
        public string Search;           // text the search box looks in
        public object Tag2;             // anything a page wants to keep with the item
        bool _checked = true, _expanded, _loaded;

        public string Title { get; set; }
        public string Subtitle { get; set; }
        public string Glyph { get; set; }
        public string Note { get; set; }          // tooltip
        public long Bytes { get; set; }           // -1 = unknown
        public ObservableCollection<Tag> Tags { get; private set; }
        public ObservableCollection<SelItem> Children { get; private set; }
        public bool Checkable { get; set; }

        public SelItem()
        {
            Tags = new ObservableCollection<Tag>();
            Children = new ObservableCollection<SelItem>();
            Bytes = -1;
            Checkable = true;
        }

        // ---- for the screen
        public double IndentWidth { get { return Level * 18; } }
        public string SizeText
        {
            get
            {
                // an unticked folder still shows what ticking it would add
                var b = Kind == ItemKind.Folder ? (IsChecked == false ? Bytes : SelectedBytes) : Kind == ItemKind.Group ? SelectedBytes : Bytes;
                return b > 0 ? Fmt.Bytes(b) : (Bytes == 0 && Kind == ItemKind.Folder ? "empty" : "");
            }
        }
        public Visibility CheckVisibility
        {
            get
            {
                if (!Checkable || Kind == ItemKind.Info) return Visibility.Collapsed;
                // a group of notes only has nothing to tick
                if (Kind == ItemKind.Group && Children.Count > 0 && !Children.Any(c => c.Checkable && c.Kind != ItemKind.Info)) return Visibility.Collapsed;
                return Visibility.Visible;
            }
        }
        public Visibility InfoVisibility { get { return Checkable && Kind != ItemKind.Info ? Visibility.Collapsed : Visibility.Visible; } }
        public Visibility SubtitleVisibility { get { return string.IsNullOrEmpty(Subtitle) ? Visibility.Collapsed : Visibility.Visible; } }
        public Visibility TagsVisibility { get { return Tags.Count == 0 ? Visibility.Collapsed : Visibility.Visible; } }
        public double TitleWeight { get { return Kind == ItemKind.Group ? 600 : 400; } }
        public FontWeight TitleFontWeight { get { return Kind == ItemKind.Group ? FontWeights.SemiBold : FontWeights.Normal; } }
        public object ToolTipText { get { return string.IsNullOrEmpty(Note) ? null : Note; } }
        public double Opacity { get { return Kind == ItemKind.Info || IsChecked == false && Checkable ? 0.62 : 1.0; } }

        public bool IsExpanded
        {
            get { return _expanded; }
            set { if (_expanded == value) return; _expanded = value; if (value) EnsureChildren(); On("IsExpanded"); }
        }

        /// <summary>Ticked (true), not ticked (false) or partly (null - for groups and folders).</summary>
        public bool? IsChecked
        {
            get
            {
                if (Kind == ItemKind.Folder && Paths != null) return Paths.State(Path);
                if (Kind == ItemKind.Group)
                {
                    var c = Children.Where(x => x.Checkable && x.Kind != ItemKind.Info).Select(x => x.IsChecked).ToList();
                    if (c.Count == 0) return _checked;
                    if (c.All(x => x == true)) return true;
                    if (c.All(x => x == false)) return false;
                    return null;
                }
                return _checked;
            }
            set
            {
                if (!Checkable || Kind == ItemKind.Info) return;
                bool v = value ?? true;
                if (Kind == ItemKind.Folder && Paths != null) { Paths.Set(Path, v); return; }   // the model refreshes every folder
                if (Kind == ItemKind.Group)
                {
                    EnsureChildren();
                    foreach (var c in Children) if (c.Checkable && c.Kind != ItemKind.Info) c.IsChecked = v;
                }
                _checked = v;
                RaiseChecked();
                if (Parent != null) Parent.RaiseChecked();
            }
        }

        public void SetCheckedSilently(bool v) { _checked = v; }

        public void RaiseChecked()
        {
            On("IsChecked"); On("Opacity"); On("SizeText");
            if (Parent != null && Kind != ItemKind.Group) Parent.Refresh("IsChecked", "SizeText");
        }

        /// <summary>Bytes of what is ticked under this item.</summary>
        public long SelectedBytes
        {
            get
            {
                if (Kind == ItemKind.Folder && Paths != null) return Node != null ? Paths.IncludedBytes(Node) : (IsChecked == true ? Math.Max(0, Bytes) : 0);
                if (Kind == ItemKind.Group)
                {
                    long s = 0;
                    foreach (var c in Children) if (c.Kind != ItemKind.Info) s += c.SelectedBytes;
                    if (s == 0 && Children.Count == 0) return IsChecked == true ? Math.Max(0, Bytes) : 0;
                    return s;
                }
                return IsChecked == true && Kind != ItemKind.Info ? Math.Max(0, Bytes) : 0;
            }
        }

        // ---- lazy children for folders
        public static readonly SelItem Placeholder = new SelItem { Kind = ItemKind.Info, Title = "...", Checkable = false };

        public void AddLazyChildren()
        {
            if (Node != null && Node.HasChildren && Children.Count == 0) Children.Add(new SelItem { Kind = ItemKind.Info, Title = "...", Checkable = false, Parent = this, Level = Level + 1 });
        }

        public void EnsureChildren()
        {
            if (_loaded || Kind != ItemKind.Folder || Node == null) return;
            _loaded = true;
            Children.Clear();
            if (Node.Children == null) return;
            int shown = 0; long restBytes = 0; int rest = 0;
            foreach (var c in Node.Children)
            {
                if (shown >= 400) { rest++; restBytes += c.Bytes; continue; }
                var it = Model.FolderItem(c.Path, c.Name, c, Paths, this);
                Children.Add(it);
                shown++;
            }
            if (rest > 0) Children.Add(new SelItem { Kind = ItemKind.Info, Checkable = false, Title = rest + " more, smaller folders (" + Fmt.Bytes(restBytes) + ")", Parent = this, Level = Level + 1, Glyph = G.Folder });
            if (Node.OwnFiles > 0) Children.Add(new SelItem { Kind = ItemKind.Info, Checkable = false, Title = Fmt.Plural(Node.OwnFiles, "file") + " directly in this folder (" + Fmt.Bytes(Node.OwnBytes) + ") - they follow the folder's tick", Parent = this, Level = Level + 1, Glyph = G.Document });
        }

        public IEnumerable<SelItem> All()
        {
            yield return this;
            foreach (var c in Children) foreach (var x in c.All()) yield return x;
        }
    }

    public class Category : INotifyPropertyChanged
    {
        public event PropertyChangedEventHandler PropertyChanged;
        public void Refresh() { var h = PropertyChanged; if (h != null) { h(this, new PropertyChangedEventArgs("Summary")); h(this, new PropertyChangedEventArgs("SizeText")); } }
        public string Key { get; set; }
        public string Title { get; set; }
        public string Glyph { get; set; }
        public string Description { get; set; }
        public ObservableCollection<SelItem> Items { get; private set; }
        public Category() { Items = new ObservableCollection<SelItem>(); }

        IEnumerable<SelItem> Leaves()
        {
            foreach (var i in Items)
                foreach (var x in i.All())
                    if (x.Kind == ItemKind.Item) yield return x;
        }

        public string Summary
        {
            get
            {
                var leaves = Leaves().Where(x => x.Checkable).ToList();
                var folders = Items.SelectMany(i => i.All()).Where(x => x.Kind == ItemKind.Folder && x.Parent == null || x.Kind == ItemKind.Folder && x.Parent != null && x.Parent.Kind == ItemKind.Group).ToList();
                if (Key == "drives") return Fmt.Plural(Items.Count, "drive") + " scanned";
                if (leaves.Count > 0) return leaves.Count(x => x.IsChecked == true) + " of " + leaves.Count;
                if (folders.Count > 0) return folders.Count(x => x.IsChecked != false) + " of " + folders.Count + " folders";
                return "";
            }
        }

        public long SelectedBytes
        {
            get
            {
                // folders that are not inside another folder of this category
                long s = 0;
                foreach (var i in Items) s += i.SelectedBytes;
                return s;
            }
        }
        public string SizeText { get { var b = SelectedBytes; return b > 0 ? Fmt.Bytes(b) : ""; } }
    }

    /// <summary>
    /// Ticks for folders. A folder is in the backup when the nearest folder above it
    /// (or itself) that you ticked or unticked says so; otherwise when the backup's
    /// plan covers it (your profile, ProgramData, C:\ folders, the media server ...).
    /// </summary>
    public class PathModel
    {
        readonly Dictionary<string, bool> _explicit = new Dictionary<string, bool>(StringComparer.OrdinalIgnoreCase);
        // what the backup's plan copies: one entry per copy job, each with its own exclusions
        // (the profile job leaves out Desktop because Desktop is a job of its own)
        class Job { public string Root; public List<string> Excl = new List<string>(); public HashSet<string> Names = new HashSet<string>(StringComparer.OrdinalIgnoreCase); }
        readonly List<Job> _jobs = new List<Job>();
        readonly List<string> _never = new List<string>();               // can never be in the backup (the backup folder itself)
        public event Action Changed;
        public readonly List<SelItem> Items = new List<SelItem>();

        static string N(string p) { return p == null ? null : (p.Length > 3 ? p.TrimEnd('\\') : p); }
        public static bool Under(string path, string root)
        {
            if (path == null || root == null) return false;
            var p = N(path); var r = N(root);
            if (p.Equals(r, StringComparison.OrdinalIgnoreCase)) return true;
            var rr = r.EndsWith("\\") ? r : r + "\\";
            return p.StartsWith(rr, StringComparison.OrdinalIgnoreCase);
        }
        static bool Below(string path, string root) { return Under(path, root) && !Same(path, root); }
        static string ParentOf(string p) { p = N(p); var i = p.LastIndexOf('\\'); if (i < 0) return null; if (i == 2) return p.Substring(0, 3); return p.Substring(0, i); }

        public void AddDefault(string root, IEnumerable<string> excluded = null, IEnumerable<string> excludedNames = null)
        {
            var j = new Job { Root = N(root) };
            if (excluded != null) foreach (var e in excluded) if (!string.IsNullOrEmpty(e)) j.Excl.Add(N(e));
            if (excludedNames != null) foreach (var n in excludedNames) if (!string.IsNullOrEmpty(n)) j.Names.Add(n);
            _jobs.Add(j);
        }
        public void AddNever(string path) { if (!string.IsNullOrEmpty(path)) _never.Add(N(path)); }
        public bool IsNever(string path) { return _never.Any(n => Under(path, n)); }

        static bool Covers(Job j, string path)
        {
            if (!Under(path, j.Root)) return false;
            foreach (var e in j.Excl) if (Under(path, e)) return false;
            if (j.Names.Count > 0)
            {
                var p = N(path);
                var rest = p.Length > j.Root.Length ? p.Substring(j.Root.Length).Trim('\\') : "";
                if (rest.Length > 0) foreach (var seg in rest.Split('\\')) if (j.Names.Contains(seg)) return false;
            }
            return true;
        }

        public bool DefaultIncluded(string path)
        {
            if (_never.Any(n => Under(path, n))) return false;
            foreach (var j in _jobs) if (Covers(j, path)) return true;
            return false;
        }

        string ExplicitAt(string path)
        {
            for (var p = N(path); p != null; p = ParentOf(p))
            {
                if (_explicit.ContainsKey(p)) return p;
                if (p.Length <= 3) break;
            }
            return null;
        }

        public bool Included(string path)
        {
            if (_never.Any(n => Under(path, n))) return false;
            var at = ExplicitAt(path);
            if (at != null) return _explicit[at];
            return DefaultIncluded(path);
        }

        /// <summary>True, false, or null when what is below this folder differs from the folder itself.</summary>
        public bool? State(string path)
        {
            var p = N(path);
            var self = Included(p);
            var at = ExplicitAt(p);
            if (self)
            {
                if (_explicit.Any(kv => !kv.Value && Below(kv.Key, p))) return null;
                if (_never.Any(n => Below(n, p))) return null;
                // the plan leaves something out below (a cache, Temp) that no other job copies
                if (at == null && _jobs.Any(j => Under(p, j.Root) && j.Excl.Any(e => Below(e, p) && !DefaultIncluded(e)))) return null;
            }
            else
            {
                if (_explicit.Any(kv => kv.Value && Below(kv.Key, p))) return null;
                var blocked = at != null && !_explicit[at];
                if (!blocked && _jobs.Any(j => Below(j.Root, p) && DefaultIncluded(j.Root))) return null;
            }
            return self;
        }
        static bool Same(string a, string b) { return string.Equals(N(a), N(b), StringComparison.OrdinalIgnoreCase); }

        public void Set(string path, bool value)
        {
            var p = N(path);
            foreach (var k in _explicit.Keys.Where(k => Under(k, p)).ToList()) _explicit.Remove(k);
            // only remember a tick that differs from what the folder above already says
            var parent = ParentOf(p);
            bool inherited = DefaultIncluded(p);
            if (parent != null && parent.Length > 3)
            {
                for (var q = parent; q != null; q = ParentOf(q)) { bool v; if (_explicit.TryGetValue(q, out v)) { inherited = v; break; } if (q.Length <= 3) break; }
            }
            if (inherited != value || !DefaultIncluded(p) && value) _explicit[p] = value;
            foreach (var it in Items) it.RaiseChecked();
            var h = Changed; if (h != null) h();
        }

        public long IncludedBytes(FolderNode n)
        {
            var st = State(n.Path);
            if (st == true) return n.Bytes;
            if (st == false) return 0;
            long s = Included(n.Path) ? n.OwnBytes : 0;
            if (n.Children != null) foreach (var c in n.Children) s += IncludedBytes(c);
            return s;
        }

        // ---- what goes to the engine
        public List<string> ExcludePaths()
        {
            return _explicit.Where(kv => !kv.Value).Select(kv => kv.Key).OrderBy(k => k.Length).ToList();
        }

        public List<string> ExtraPaths()
        {
            var list = new List<string>();
            foreach (var kv in _explicit.Where(kv => kv.Value).OrderBy(kv => kv.Key.Length))
            {
                if (list.Any(x => Under(kv.Key, x))) continue;
                var parent = ParentOf(kv.Key);
                if (DefaultIncluded(kv.Key) && (parent == null || Included(parent))) continue;   // already in the plan
                list.Add(kv.Key);
            }
            return list;
        }

        public bool HasChanges { get { return _explicit.Count > 0; } }
        public void Reset() { _explicit.Clear(); foreach (var it in Items) it.RaiseChecked(); var h = Changed; if (h != null) h(); }
    }

    public static class Model
    {
        public static SelItem FolderItem(string path, string title, FolderNode node, PathModel paths, SelItem parent)
        {
            var it = new SelItem
            {
                Kind = ItemKind.Folder, Path = path, Node = node, Paths = paths, Parent = parent, Level = parent == null ? 0 : parent.Level + 1,
                Title = title, Glyph = G.Folder, Bytes = node != null ? node.Bytes : -1, Search = title + " " + path
            };
            if (node != null)
            {
                if ((node.Flags & NodeFlags.Denied) != 0) it.Tags.Add(new Tag("no access", "warn"));
                if ((node.Flags & NodeFlags.Skipped) != 0) it.Tags.Add(new Tag("Windows - not copied"));
                if ((node.Flags & NodeFlags.GitRepo) != 0) it.Tags.Add(new Tag("git project", "accent"));
                else if ((node.Flags & NodeFlags.CodeProject) != 0) it.Tags.Add(new Tag("code project", "accent"));
                if ((node.Flags & NodeFlags.SteamLibrary) != 0) it.Tags.Add(new Tag("Steam library"));
                if ((node.Flags & NodeFlags.EmuSaves) != 0) it.Tags.Add(new Tag("game with its saves inside", "warn"));
                if (node.VmBytes > 0 && (node.Flags & NodeFlags.VmDisk) != 0) it.Tags.Add(new Tag("virtual machine disk", "accent"));
                if ((node.Flags & NodeFlags.MediaLibrary) != 0) it.Tags.Add(new Tag(node.VideoBytes >= node.AudioBytes && node.VideoBytes >= node.PhotoBytes ? "videos" : node.AudioBytes >= node.PhotoBytes ? "music" : "photos"));
                it.AddLazyChildren();
            }
            paths.Items.Add(it);
            return it;
        }

        public static SelItem Group(string title, string subtitle, string glyph, int level = 0)
        {
            return new SelItem { Kind = ItemKind.Group, Title = title, Subtitle = subtitle, Glyph = glyph, Level = level, IsExpanded = true, Search = title };
        }

        public static SelItem Leaf(SelItem group, string section, string key, string title, string subtitle, string glyph, bool on = true, long bytes = -1)
        {
            var it = new SelItem { Kind = ItemKind.Item, Section = section, Key = key, Title = title, Subtitle = subtitle, Glyph = glyph, Bytes = bytes, Parent = group, Level = group == null ? 0 : group.Level + 1, Search = title + " " + subtitle + " " + key };
            it.SetCheckedSilently(on);
            if (group != null) group.Children.Add(it);
            return it;
        }

        public static SelItem Info(SelItem group, string title, string subtitle, string glyph = null)
        {
            var it = new SelItem { Kind = ItemKind.Info, Checkable = false, Title = title, Subtitle = subtitle, Glyph = glyph ?? G.Info, Parent = group, Level = group == null ? 0 : group.Level + 1, Search = title + " " + subtitle };
            if (group != null) group.Children.Add(it);
            return it;
        }

        /// <summary>The selection file for the engine: unticked items per section, plus folder choices.</summary>
        public static Dictionary<string, object> BuildSelection(IEnumerable<Category> cats, PathModel paths)
        {
            var sel = new Dictionary<string, object>();
            var ex = new Dictionary<string, List<string>>(StringComparer.OrdinalIgnoreCase);
            foreach (var c in cats)
                foreach (var it in c.Items.SelectMany(i => i.All()))
                {
                    if (it.Kind != ItemKind.Item || !it.Checkable || string.IsNullOrEmpty(it.Section) || it.Key == null) continue;
                    if (it.IsChecked == true) continue;
                    List<string> l;
                    if (!ex.TryGetValue(it.Section, out l)) ex[it.Section] = l = new List<string>();
                    if (!l.Contains(it.Key)) l.Add(it.Key);
                }
            foreach (var kv in ex) sel[kv.Key] = new Dictionary<string, object> { { "Exclude", kv.Value.ToArray() } };
            if (paths != null)
            {
                sel["Files"] = new Dictionary<string, object>
                {
                    { "ExcludePaths", paths.ExcludePaths().ToArray() },
                    { "Extra", paths.ExtraPaths().Select(p => (object)new Dictionary<string, object> { { "Path", p } }).ToArray() }
                };
            }
            sel["Version"] = 1;
            sel["MadeBy"] = "PC Migration Kit " + Kit.Version;
            return sel;
        }
    }
}
