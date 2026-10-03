// PC Migration Kit - pieces several screens share: the live log list and the
// progress maths for copies.
// Written by Claude 2026-10-02.
using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Threading;

namespace PCMK
{
    /// <summary>Fills a ListBox with the engine's messages (an icon per kind, newest at the bottom).</summary>
    public class LogView
    {
        readonly ListBox _list;
        public readonly List<string> Warnings = new List<string>();
        public bool ShowRaw = true;
        string _lastRaw;

        public LogView(ListBox list) { _list = list; }

        public void Clear() { _list.Items.Clear(); Warnings.Clear(); }

        public void Add(string level, string text)
        {
            if (string.IsNullOrWhiteSpace(text)) return;
            string glyph = null; Brush fg = Ui.Brush("Text"); Brush ic = Ui.Brush("TextMuted"); var weight = FontWeights.Normal; double size = 13;
            switch (level)
            {
                case "ok": glyph = G.Check; ic = Ui.Brush("Ok"); break;
                case "warn": glyph = G.Warn; ic = Ui.Brush("Warn"); Warnings.Add(text); break;
                case "fail": glyph = G.Error; ic = Ui.Brush("Bad"); fg = Ui.Brush("Bad"); Warnings.Add(text); break;
                case "step": glyph = G.ChevronRight; ic = Ui.Brush("Accent"); weight = FontWeights.SemiBold; text = text.Trim('=', ' '); break;
                case "info": glyph = null; fg = Ui.Brush("TextMuted"); break;
                case "raw": glyph = null; fg = Ui.Brush("TextFaint"); size = 12; break;
                default: fg = Ui.Brush("Text"); break;
            }
            var g = new Grid { Margin = new Thickness(6, level == "step" ? 10 : 1, 6, 1) };
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(24) });
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            if (glyph != null) { var i = Ui.Icon(glyph, 12, ic); i.VerticalAlignment = VerticalAlignment.Top; i.Margin = new Thickness(0, 3, 0, 0); g.Children.Add(i); }
            var t = new TextBlock { Text = text, Foreground = fg, FontWeight = weight, FontSize = size, TextWrapping = TextWrapping.Wrap };
            if (level == "raw") t.FontFamily = (FontFamily)Application.Current.Resources["MonoFont"];
            Grid.SetColumn(t, 1);
            g.Children.Add(t);
            _list.Items.Add(g);
            if (_list.Items.Count > 4000) _list.Items.RemoveAt(0);
            _list.ScrollIntoView(g);
        }

        /// <summary>Takes any engine event and shows what is worth showing.</summary>
        public void Handle(EngineEvent ev)
        {
            switch (ev.Type)
            {
                case "log": Add(ev.S("lvl"), ev.S("text")); break;
                case "raw":
                case "stderr":
                    if (!ShowRaw) break;
                    var r = (ev.Raw ?? "").Trim();
                    if (r.Length == 0 || r == _lastRaw) break;
                    _lastRaw = r;
                    Add(ev.Type == "stderr" ? "warn" : "raw", r);
                    break;
            }
        }
    }

    /// <summary>Overall progress of a run made of copy jobs (backup) or steps (restore).</summary>
    public class CopyMeter
    {
        public double TotalExpected;      // the plan's estimate of all bytes
        public double DoneExpected;       // estimates of finished jobs
        public double CurExpected, CurBytes;
        public double CopiedBytes;        // really copied so far (for the speed)
        public int JobsDone, JobsTotal;
        readonly Queue<KeyValuePair<DateTime, double>> _samples = new Queue<KeyValuePair<DateTime, double>>();

        public double Fraction
        {
            get
            {
                if (TotalExpected > 0)
                {
                    var cur = CurExpected > 0 ? Math.Min(1.0, CurBytes / CurExpected) * CurExpected : 0;
                    return Math.Max(0, Math.Min(1, (DoneExpected + cur) / TotalExpected));
                }
                if (JobsTotal > 0) return Math.Min(1, (double)JobsDone / JobsTotal);
                return 0;
            }
        }

        public void Sample()
        {
            var now = DateTime.UtcNow;
            _samples.Enqueue(new KeyValuePair<DateTime, double>(now, CopiedBytes + CurBytes));
            while (_samples.Count > 2 && (now - _samples.Peek().Key).TotalSeconds > 20) _samples.Dequeue();
        }

        /// <summary>Bytes per second over the last ~20 seconds.</summary>
        public double Speed
        {
            get
            {
                if (_samples.Count < 2) return 0;
                var a = _samples.Peek(); var b = _samples.Last();
                var s = (b.Key - a.Key).TotalSeconds;
                return s > 1 ? Math.Max(0, (b.Value - a.Value) / s) : 0;
            }
        }
    }
}
