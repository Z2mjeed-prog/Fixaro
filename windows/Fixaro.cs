// Fixaro for Windows: private grammar fixing and rewriting with a local AI model.
//
// Select text in any app, then:
//   Ctrl+Alt+R  rewrites it in your usual style
//   Ctrl+Alt+S  opens a popup: pick a style, or type how you want it rewritten
//
// The AI runs on your own computer through Ollama (or another local AI app), so your text never leaves it.
// Built with the C# compiler that comes with Windows: run build.cmd. Written in C# 5 so that compiler can build it.

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.IO;
using System.Linq;
using System.Net;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using System.Windows.Forms;
using Microsoft.Win32;

namespace Fixaro
{
    static class Program
    {
        [STAThread]
        static void Main()
        {
            bool first;
            using (var once = new Mutex(true, "Fixaro.Windows.SingleInstance", out first))
            {
                if (!first) return;   // already running
                Application.EnableVisualStyles();
                Application.SetCompatibleTextRenderingDefault(false);
                Application.Run(new App());
            }
        }
    }

    // ------------------------------------------------------------------ Settings and log

    static class Store
    {
        public static readonly string Dir = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Fixaro");
        static readonly string SettingsPath = Path.Combine(Dir, "settings.ini");
        public static readonly string StylesPath = Path.Combine(Dir, "styles.txt");
        public static readonly string LogPath = Path.Combine(Dir, "fixaro.log");
        static Dictionary<string, string> values;

        static void Load()
        {
            if (values != null) return;
            values = new Dictionary<string, string>();
            try
            {
                Directory.CreateDirectory(Dir);
                if (!File.Exists(SettingsPath)) return;
                foreach (var line in File.ReadAllLines(SettingsPath, Encoding.UTF8))
                {
                    int eq = line.IndexOf('=');
                    if (eq > 0) values[line.Substring(0, eq).Trim()] = line.Substring(eq + 1).Trim();
                }
            }
            catch (Exception) { }
        }

        public static string Get(string key, string fallback)
        {
            Load();
            string v;
            return values.TryGetValue(key, out v) && v.Length > 0 ? v : fallback;
        }

        public static void Set(string key, string value)
        {
            Load();
            if (value == null) values.Remove(key); else values[key] = value;
            try
            {
                Directory.CreateDirectory(Dir);
                File.WriteAllLines(SettingsPath, values.Select(kv => kv.Key + "=" + kv.Value), Encoding.UTF8);
            }
            catch (Exception) { }
        }

        /// The log never contains what you write: only timings, models and errors.
        public static void Log(string line)
        {
            try
            {
                Directory.CreateDirectory(Dir);
                var info = new FileInfo(LogPath);
                if (info.Exists && info.Length > 512 * 1024) File.Delete(LogPath);
                File.AppendAllText(LogPath, DateTime.UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ") + "  " + line + Environment.NewLine);
            }
            catch (Exception) { }
        }
    }

    // ------------------------------------------------------------------ Styles

    class RephraseStyle
    {
        public string Key, Title, Instruction;
        public RephraseStyle(string key, string title, string instruction) { Key = key; Title = title; Instruction = instruction; }
        public bool IsCustom { get { return Key.StartsWith("custom:"); } }
    }

    static class Styles
    {
        // The same wording as the Mac app (Sources/main.swift)
        public static readonly RephraseStyle[] BuiltIn = {
            new RephraseStyle("natural", "Natural (same tone)", "Keep the same tone and roughly the same length, but make it read smoothly and naturally, the way a fluent native English writer would put it."),
            new RephraseStyle("professional", "Professional", "Make it sound polished and professional, suitable for a work email."),
            new RephraseStyle("shorter", "Shorter", "Make it noticeably shorter and more concise."),
            new RephraseStyle("friendly", "Friendly", "Make it warm and friendly.")
        };

        public static List<RephraseStyle> Custom()
        {
            var list = new List<RephraseStyle>();
            var seen = new HashSet<string>();
            try
            {
                if (!File.Exists(Store.StylesPath)) return list;
                foreach (var raw in File.ReadAllLines(Store.StylesPath, Encoding.UTF8))
                {
                    var line = raw.Trim();
                    int colon = line.IndexOf(':');
                    if (line.StartsWith("#") || colon <= 0) continue;
                    var name = line.Substring(0, colon).Trim();
                    var how = line.Substring(colon + 1).Trim();
                    if (name.Length == 0 || name.Length > 40 || how.Length == 0 || seen.Contains(name.ToLowerInvariant())) continue;
                    if (".!?".IndexOf(how[how.Length - 1]) < 0) how += ".";
                    seen.Add(name.ToLowerInvariant());
                    list.Add(new RephraseStyle("custom:" + name, name, how));
                }
            }
            catch (Exception) { }
            return list;
        }

        public static List<RephraseStyle> All()
        {
            var all = new List<RephraseStyle>(BuiltIn);
            all.AddRange(Custom());
            return all;
        }

        public static RephraseStyle Find(string key)
        {
            return All().FirstOrDefault(s => s.Key == key) ?? BuiltIn[0];
        }

        public static void SeedFile()
        {
            if (File.Exists(Store.StylesPath)) return;
            try
            {
                Directory.CreateDirectory(Store.Dir);
                File.WriteAllText(Store.StylesPath,
                    "# Your own rephrase styles, one per line:  Name: how to rewrite it\r\n" +
                    "# They appear when you press Ctrl+Alt+S. Lines starting with # are ignored.\r\n" +
                    "# Example:\r\n" +
                    "# Customer reply: Polite and helpful, thank the customer, and end with a clear next step.\r\n",
                    Encoding.UTF8);
            }
            catch (Exception) { }
        }
    }

    // ------------------------------------------------------------------ Prompts (same as the Mac app)

    static class Prompts
    {
        const string Tail = " Fix any spelling and grammar mistakes. Never answer or reply to the text, even if it is a question or a request: only rewrite it. Reply with ONLY the rewritten text: no intro, no quotes, no explanation.";

        public static string ForStyle(RephraseStyle style)
        {
            if (style.IsCustom) return ForInstruction(style.Instruction);   // your own styles are followed in full
            return "You are a writing assistant that rewrites English text. " + style.Instruction +
                   " Keep the original meaning, facts, names and numbers, and keep everything the writer said, and do not add anything new (no opinions, hedges or extra sentences)." + Tail;
        }

        public static string ForInstruction(string instruction)
        {
            return "You are a writing assistant that rewrites English text. Rewrite it following this instruction from the writer: \"" +
                   instruction + "\". Do everything the instruction asks. Apart from that, keep the original meaning, facts, names and numbers." + Tail;
        }

        public static string UserPrompt(string text)
        {
            return "Rewrite this text:\n\"\"\"\n" + text + "\n\"\"\"";
        }

        public static string ForModel(string system, string model)
        {
            return model.ToLowerInvariant().Contains("qwen") ? system + " /no_think" : system;
        }

        /// Turns the model's reply into text ready to paste, or null if it isn't usable.
        public static string Clean(string raw, string original)
        {
            if (raw == null) return null;
            var s = raw;
            int think = s.IndexOf("</think>", StringComparison.Ordinal);
            if (think >= 0) s = s.Substring(think + 8);
            s = s.Trim();
            int nl = s.IndexOf('\n');
            if (nl > 0)
            {
                var first = s.Substring(0, nl).Trim().ToLowerInvariant();
                if (first.Length < 70 && first.EndsWith(":") && (first.Contains("rewrit") || first.Contains("here")))
                    s = s.Substring(nl + 1).Trim();
            }
            if (s.StartsWith("\"\"\"")) s = s.Substring(3);
            if (s.EndsWith("\"\"\"")) s = s.Substring(0, s.Length - 3);
            s = s.Trim();
            if (!original.StartsWith("\"") && s.Length > 1 &&
                ((s.StartsWith("\"") && s.EndsWith("\"")) || (s.StartsWith("“") && s.EndsWith("”"))))
                s = s.Substring(1, s.Length - 2);
            s = DropOpener(s, original);
            if (s.Length == 0 || s.Length > original.Length * 4 + 100) return null;
            // Windows apps expect \r\n line breaks
            s = Regex.Replace(s, "\r?\n", "\r\n");
            int end = original.Length;
            while (end > 0 && char.IsWhiteSpace(original[end - 1])) end--;
            return s + original.Substring(end);
        }

        /// Removes an opener some models add, such as "Here's your friendly reminder: " or "Sure! ".
        public static string DropOpener(string text, string original)
        {
            var low = original.ToLowerInvariant();
            if (low.StartsWith("here") || low.StartsWith("sure")) return text;
            var m = Regex.Match(text, "^((here(’|')s|here is)[^:\\n]{0,50}:|(sure|certainly|of course)[!,.]?)\\s*", RegexOptions.IgnoreCase);
            if (!m.Success || m.Length >= text.Length) return text;
            var rest = text.Substring(m.Length);
            return char.ToUpperInvariant(rest[0]) + rest.Substring(1);
        }
    }

    // ------------------------------------------------------------------ The local AI (Ollama, or an OpenAI-compatible app)

    class ModelInfo
    {
        public string Name; public long Size;
        public ModelInfo(string name, long size) { Name = name; Size = size; }
    }

    static class AI
    {
        public static string Kind { get { return Store.Get("serverKind", "ollama"); } }   // "ollama" or "openai"
        public static string Base { get { return Store.Get("serverURL", "http://127.0.0.1:11434").TrimEnd('/'); } }
        public static string DisplayName
        {
            get
            {
                if (Kind == "ollama") return "Ollama";
                var b = Base;
                if (b.Contains(":1234")) return "LM Studio";
                if (b.Contains(":1337")) return "Jan";
                if (b.Contains(":8080")) return "llama.cpp / MLX server";
                return "AI app";
            }
        }

        static readonly JavaScriptSerializer Json = new JavaScriptSerializer { MaxJsonLength = int.MaxValue };

        static string Send(string method, string url, object body, int timeoutMs)
        {
            var req = (HttpWebRequest)WebRequest.Create(url);
            req.Method = method;
            req.Timeout = timeoutMs;
            req.ReadWriteTimeout = timeoutMs;
            req.Proxy = null;   // local servers only
            if (body != null)
            {
                var bytes = Encoding.UTF8.GetBytes(Json.Serialize(body));
                req.ContentType = "application/json";
                req.ContentLength = bytes.Length;
                using (var s = req.GetRequestStream()) s.Write(bytes, 0, bytes.Length);
            }
            using (var resp = (HttpWebResponse)req.GetResponse())
            using (var r = new StreamReader(resp.GetResponseStream(), Encoding.UTF8))
                return r.ReadToEnd();
        }

        static Dictionary<string, object> Parse(string s)
        {
            return Json.Deserialize<Dictionary<string, object>>(s);
        }

        public static Task<List<ModelInfo>> ListModels()
        {
            return Task.Run(() =>
            {
                var list = new List<ModelInfo>();
                try
                {
                    if (Kind == "ollama")
                    {
                        var obj = Parse(Send("GET", Base + "/api/tags", null, 3000));
                        foreach (Dictionary<string, object> m in (System.Collections.ArrayList)obj["models"])
                        {
                            var name = (string)m["name"];
                            if (name.ToLowerInvariant().Contains("embed")) continue;   // embedding models can't write
                            long size = 0;
                            object sz;
                            if (m.TryGetValue("size", out sz) && sz != null) size = Convert.ToInt64(sz);
                            list.Add(new ModelInfo(name, size));
                        }
                    }
                    else
                    {
                        var obj = Parse(Send("GET", Base + "/models", null, 3000));
                        foreach (Dictionary<string, object> m in (System.Collections.ArrayList)obj["data"])
                            list.Add(new ModelInfo((string)m["id"], 0));
                    }
                }
                catch (Exception) { return null; }   // the AI app isn't running
                return list;
            });
        }

        public static Task<string> Generate(string model, string system, string prompt, int numPredict, int timeoutSec, string keepAlive)
        {
            return Task.Run(() =>
            {
                try
                {
                    if (Kind == "openai")
                    {
                        var body = new Dictionary<string, object> {
                            { "model", model }, { "temperature", 0 }, { "max_tokens", numPredict }, { "stream", false },
                            { "messages", new object[] {
                                new Dictionary<string, object> { { "role", "system" }, { "content", system } },
                                new Dictionary<string, object> { { "role", "user" }, { "content", prompt } } } }
                        };
                        var obj = Parse(Send("POST", Base + "/chat/completions", body, timeoutSec * 1000));
                        var choice = (Dictionary<string, object>)((System.Collections.ArrayList)obj["choices"])[0];
                        return (string)((Dictionary<string, object>)choice["message"])["content"];
                    }
                    foreach (var sendThink in new[] { true, false })
                    {
                        var body = new Dictionary<string, object> {
                            { "model", model }, { "prompt", prompt }, { "system", system }, { "stream", false }, { "keep_alive", keepAlive },
                            { "options", new Dictionary<string, object> { { "temperature", 0 }, { "num_predict", numPredict } } }
                        };
                        if (sendThink) body["think"] = false;
                        try
                        {
                            return (string)Parse(Send("POST", Base + "/api/generate", body, timeoutSec * 1000))["response"];
                        }
                        catch (WebException e)
                        {
                            var http = e.Response as HttpWebResponse;
                            if (!sendThink || http == null) { Store.Log("AI error: " + e.Message); return null; }
                            // older Ollama versions reject "think": try once without it
                        }
                    }
                }
                catch (Exception e) { Store.Log("AI error: " + e.Message); }
                return null;
            });
        }

        public static Task<List<string>> LoadedModels()
        {
            return Task.Run(() =>
            {
                var list = new List<string>();
                if (Kind != "ollama") return list;
                try
                {
                    var obj = Parse(Send("GET", Base + "/api/ps", null, 2000));
                    foreach (Dictionary<string, object> m in (System.Collections.ArrayList)obj["models"]) list.Add((string)m["name"]);
                }
                catch (Exception) { }
                return list;
            });
        }

        /// Changes how long a loaded model stays in memory ("0s" frees it now).
        public static Task SetKeepAlive(string model, string keepAlive)
        {
            return Task.Run(() =>
            {
                try { Send("POST", Base + "/api/generate", new Dictionary<string, object> { { "model", model }, { "keep_alive", keepAlive } }, 10000); }
                catch (Exception) { }
            });
        }

        /// Downloads a model with Ollama, reporting progress as text ("Downloading qwen3.5:4b… 42%").
        public static Task<bool> Pull(string name, Action<string> progress)
        {
            return Task.Run(() =>
            {
                try
                {
                    var req = (HttpWebRequest)WebRequest.Create(Base + "/api/pull");
                    req.Method = "POST";
                    req.Proxy = null;
                    req.Timeout = Timeout.Infinite;
                    req.ReadWriteTimeout = 10 * 60 * 1000;
                    var bytes = Encoding.UTF8.GetBytes(Json.Serialize(new Dictionary<string, object> { { "name", name }, { "stream", true } }));
                    req.ContentType = "application/json";
                    using (var s = req.GetRequestStream()) s.Write(bytes, 0, bytes.Length);
                    using (var resp = req.GetResponse())
                    using (var r = new StreamReader(resp.GetResponseStream(), Encoding.UTF8))
                    {
                        string line;
                        while ((line = r.ReadLine()) != null)
                        {
                            if (line.Trim().Length == 0) continue;
                            var obj = Parse(line);
                            object err;
                            if (obj.TryGetValue("error", out err)) { Store.Log("Download error: " + err); return false; }
                            object total, done;
                            if (obj.TryGetValue("total", out total) && obj.TryGetValue("completed", out done) && Convert.ToDouble(total) > 0)
                                progress("Downloading " + name + "… " + (int)(100 * Convert.ToDouble(done) / Convert.ToDouble(total)) + "%");
                        }
                    }
                    return true;
                }
                catch (Exception e) { Store.Log("Download error: " + e.Message); return false; }
            });
        }
    }

    // ------------------------------------------------------------------ Windows plumbing

    static class Native
    {
        public const int WM_HOTKEY = 0x0312;
        public const uint MOD_ALT = 0x1, MOD_CONTROL = 0x2, MOD_NOREPEAT = 0x4000;

        [DllImport("user32.dll", SetLastError = true)] public static extern bool RegisterHotKey(IntPtr hWnd, int id, uint mods, uint vk);
        [DllImport("user32.dll")] public static extern bool UnregisterHotKey(IntPtr hWnd, int id);
        [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
        [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int vk);
        [DllImport("user32.dll")] public static extern uint GetClipboardSequenceNumber();
        [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr hWnd, StringBuilder name, int max);
        [DllImport("user32.dll")] public static extern bool GetGUIThreadInfo(uint threadId, ref GUITHREADINFO info);
        [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr hWnd, ref POINT p);
        [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr hWnd);
        [DllImport("user32.dll", SetLastError = true)] static extern uint SendInput(uint n, INPUT[] inputs, int size);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr SendMessage(IntPtr hWnd, int msg, IntPtr w, string l);
        [DllImport("user32.dll")] public static extern bool DestroyIcon(IntPtr h);

        [StructLayout(LayoutKind.Sequential)]
        public class MEMORYSTATUSEX
        {
            public uint dwLength = (uint)Marshal.SizeOf(typeof(MEMORYSTATUSEX));
            public uint dwMemoryLoad;
            public ulong ullTotalPhys, ullAvailPhys, ullTotalPageFile, ullAvailPageFile, ullTotalVirtual, ullAvailVirtual, ullAvailExtendedVirtual;
        }
        [DllImport("kernel32.dll")] public static extern bool GlobalMemoryStatusEx([In, Out] MEMORYSTATUSEX m);

        [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
        [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
        [StructLayout(LayoutKind.Sequential)]
        public struct GUITHREADINFO
        {
            public int cbSize, flags;
            public IntPtr hwndActive, hwndFocus, hwndCapture, hwndMenuOwner, hwndMoveSize, hwndCaret;
            public RECT rcCaret;
        }

        [StructLayout(LayoutKind.Sequential)] struct MOUSEINPUT { public int dx, dy; public uint mouseData, dwFlags, time; public IntPtr dwExtraInfo; }
        [StructLayout(LayoutKind.Sequential)] struct KEYBDINPUT { public ushort wVk, wScan; public uint dwFlags, time; public IntPtr dwExtraInfo; }
        [StructLayout(LayoutKind.Sequential)] struct HARDWAREINPUT { public uint uMsg; public ushort wParamL, wParamH; }
        [StructLayout(LayoutKind.Explicit)]
        struct InputUnion
        {
            [FieldOffset(0)] public MOUSEINPUT mi;
            [FieldOffset(0)] public KEYBDINPUT ki;
            [FieldOffset(0)] public HARDWAREINPUT hi;
        }
        [StructLayout(LayoutKind.Sequential)] struct INPUT { public uint type; public InputUnion u; }

        const uint INPUT_KEYBOARD = 1, KEYEVENTF_KEYUP = 0x2;
        public const int VK_SHIFT = 0x10, VK_CONTROL = 0x11, VK_MENU = 0x12, VK_LWIN = 0x5B, VK_RWIN = 0x5C;

        static INPUT Key(ushort vk, bool up)
        {
            var i = new INPUT { type = INPUT_KEYBOARD };
            i.u.ki = new KEYBDINPUT { wVk = vk, dwFlags = up ? KEYEVENTF_KEYUP : 0 };
            return i;
        }

        /// Presses Ctrl + a key (C to copy, V to paste).
        public static void CtrlKey(char letter)
        {
            ushort vk = (ushort)char.ToUpperInvariant(letter);
            var keys = new[] { Key((ushort)VK_CONTROL, false), Key(vk, false), Key(vk, true), Key((ushort)VK_CONTROL, true) };
            SendInput((uint)keys.Length, keys, Marshal.SizeOf(typeof(INPUT)));
        }

        /// Taps an unused key while Alt is held, so releasing Alt doesn't open the app's menu bar.
        public static void MaskAlt()
        {
            var keys = new[] { Key(0xE8, false), Key(0xE8, true) };
            SendInput((uint)keys.Length, keys, Marshal.SizeOf(typeof(INPUT)));
        }

        public static bool AnyModifierDown()
        {
            foreach (var vk in new[] { VK_SHIFT, VK_CONTROL, VK_MENU, VK_LWIN, VK_RWIN })
                if ((GetAsyncKeyState(vk) & 0x8000) != 0) return true;
            return false;
        }

        public static string ClassOf(IntPtr h)
        {
            var sb = new StringBuilder(256);
            GetClassName(h, sb, sb.Capacity);
            return sb.ToString();
        }

        /// Where the text cursor is on screen, if the app says (many modern apps don't).
        public static Point? CaretPoint(IntPtr window)
        {
            uint pid;
            uint thread = GetWindowThreadProcessId(window, out pid);
            var info = new GUITHREADINFO { cbSize = Marshal.SizeOf(typeof(GUITHREADINFO)) };
            if (!GetGUIThreadInfo(thread, ref info) || info.hwndCaret == IntPtr.Zero) return null;
            var p = new POINT { X = info.rcCaret.Left, Y = info.rcCaret.Bottom };
            if (p.X == 0 && p.Y == 0) return null;
            ClientToScreen(info.hwndCaret, ref p);
            return new Point(p.X, p.Y);
        }
    }

    /// An invisible window that receives the global shortcuts.
    class HotkeyWindow : NativeWindow, IDisposable
    {
        public event Action<int> Pressed;
        public HotkeyWindow() { CreateHandle(new CreateParams()); }
        protected override void WndProc(ref Message m)
        {
            if (m.Msg == Native.WM_HOTKEY && Pressed != null) Pressed(m.WParam.ToInt32());
            base.WndProc(ref m);
        }
        public void Dispose() { DestroyHandle(); }
    }

    // ------------------------------------------------------------------ Look and feel

    static class Look
    {
        public static readonly Color Navy = Color.FromArgb(30, 42, 61);
        public static readonly Color Green = Color.FromArgb(126, 226, 168);

        /// The Fixaro "F" monogram, drawn at any size.
        public static Icon AppIcon(int size, bool paused)
        {
            using (var bmp = new Bitmap(size, size))
            {
                using (var g = Graphics.FromImage(bmp))
                {
                    g.SmoothingMode = SmoothingMode.AntiAlias;
                    g.Clear(Color.Transparent);
                    float u = size / 32f;
                    using (var bg = RoundRect(new RectangleF(1 * u, 1 * u, 30 * u, 30 * u), 7 * u))
                    using (var b = new SolidBrush(paused ? Color.FromArgb(110, 116, 128) : Navy))
                        g.FillPath(b, bg);
                    using (var w = new SolidBrush(Color.White))
                    {
                        g.FillRectangle(w, 10 * u, 7 * u, 4 * u, 18 * u);   // stem
                        g.FillRectangle(w, 10 * u, 7 * u, 13 * u, 4 * u);   // top bar
                        g.FillRectangle(w, 10 * u, 14 * u, 9 * u, 4 * u);   // middle bar
                    }
                    using (var gr = new SolidBrush(paused ? Color.FromArgb(200, 200, 200) : Green))
                        g.FillRectangle(gr, 21 * u, 14 * u, 2 * u, 5 * u);   // the green "cursor"
                }
                var h = bmp.GetHicon();
                var icon = (Icon)Icon.FromHandle(h).Clone();
                Native.DestroyIcon(h);
                return icon;
            }
        }

        public static GraphicsPath RoundRect(RectangleF r, float radius)
        {
            var p = new GraphicsPath();
            float d = radius * 2;
            p.AddArc(r.X, r.Y, d, d, 180, 90);
            p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
            p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
            p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
            p.CloseFigure();
            return p;
        }

        /// Keeps a window on screen near a point (below it, or above if there's no room).
        public static Point Place(Size size, Point near)
        {
            var area = Screen.FromPoint(near).WorkingArea;
            int x = Math.Min(Math.Max(near.X, area.Left + 8), area.Right - size.Width - 8);
            int y = near.Y + 6;
            if (y + size.Height > area.Bottom - 8) y = Math.Max(area.Top + 8, near.Y - size.Height - 30);
            return new Point(x, y);
        }
    }

    /// "Rewriting…" next to your text. It never takes the focus from the app you're writing in.
    class Bubble : Form
    {
        readonly Label label = new Label();
        readonly System.Windows.Forms.Timer dots = new System.Windows.Forms.Timer { Interval = 400 };
        string baseText = "";
        int tick;

        public Bubble()
        {
            FormBorderStyle = FormBorderStyle.None;
            ShowInTaskbar = false;
            TopMost = true;
            StartPosition = FormStartPosition.Manual;
            BackColor = Color.FromArgb(48, 50, 56);
            Padding = new Padding(12, 7, 14, 7);
            label.AutoSize = true;
            label.ForeColor = Color.White;
            label.Font = new Font("Segoe UI", 9.5f, FontStyle.Bold);
            label.Location = new Point(12, 7);
            Controls.Add(label);
            dots.Tick += (s, e) => { tick = (tick + 1) % 4; label.Text = baseText + new string('.', tick); };
        }

        protected override bool ShowWithoutActivation { get { return true; } }
        protected override CreateParams CreateParams
        {
            get
            {
                var cp = base.CreateParams;
                cp.ExStyle |= 0x08000000 /* NOACTIVATE */ | 0x00000080 /* TOOLWINDOW */ | 0x00000008 /* TOPMOST */;
                return cp;
            }
        }

        public void ShowNear(string text, Point near, bool busy)
        {
            baseText = busy ? text.TrimEnd('.', '…') : text;
            tick = 0;
            label.Text = baseText;
            ClientSize = new Size(label.PreferredWidth + 34, label.PreferredHeight + 14);
            Location = Look.Place(Size, near);
            using (var path = Look.RoundRect(new RectangleF(0, 0, Width, Height), 9))
                Region = new Region(path);
            if (busy) dots.Start(); else dots.Stop();
            if (!Visible) Show();
        }

        public void HideBubble() { dots.Stop(); Hide(); }
    }

    /// The Ctrl+Alt+S popup: type how to rewrite it, or pick a style.
    class PromptForm : Form
    {
        public string Instruction;      // what you typed (null if you picked a style)
        public string StyleKey;         // the style you picked
        readonly TextBox box = new TextBox();
        readonly List<RephraseStyle> styles;
        readonly string usual;
        bool done;

        public PromptForm(List<RephraseStyle> styles, string usual)
        {
            this.styles = styles;
            this.usual = usual;
            FormBorderStyle = FormBorderStyle.None;
            ShowInTaskbar = false;
            TopMost = true;
            StartPosition = FormStartPosition.Manual;
            KeyPreview = true;
            BackColor = Color.FromArgb(43, 45, 50);
            ForeColor = Color.White;
            Font = new Font("Segoe UI", 9.5f);
            int w = 340, x = 12, y = 12;

            box.SetBounds(x, y, w - 24, 26);
            box.Font = new Font("Segoe UI", 10.5f);
            box.BorderStyle = BorderStyle.FixedSingle;
            box.BackColor = Color.FromArgb(30, 31, 34);
            box.ForeColor = Color.White;
            Controls.Add(box);
            Native.SendMessage(box.Handle, 0x1501 /* EM_SETCUEBANNER */, (IntPtr)1, "How should it be rewritten?");
            y += 32;

            Controls.Add(MakeLabel("For example: more formal, and ask for a reply by Sunday", x, y, 8.5f, Color.FromArgb(140, 144, 152)));
            y += 26;
            Controls.Add(MakeLabel("Or pick a style", x, y, 8.5f, Color.FromArgb(170, 174, 182)));
            y += 20;

            for (int i = 0; i < styles.Count; i++)
            {
                var st = styles[i];
                var b = new Button
                {
                    Text = (i < 9 ? (i + 1).ToString() : " ") + "    " + st.Title + (st.Key == usual ? "     (usual)" : ""),
                    TextAlign = ContentAlignment.MiddleLeft,
                    FlatStyle = FlatStyle.Flat,
                    ForeColor = Color.White,
                    BackColor = BackColor,
                    Tag = st.Key,
                    TabStop = false
                };
                b.FlatAppearance.BorderSize = 0;
                b.FlatAppearance.MouseOverBackColor = Color.FromArgb(62, 99, 140);
                b.SetBounds(x - 4, y, w - 16, 26);
                b.Click += (s, e) => Finish(null, (string)((Button)s).Tag);
                Controls.Add(b);
                y += 27;
            }
            y += 4;
            Controls.Add(MakeLabel("Enter rewrites  ·  Esc cancels", x, y, 8.5f, Color.FromArgb(140, 144, 152)));
            ClientSize = new Size(w, y + 26);

            box.TextChanged += (s, e) =>
            {
                // A number typed into the empty box picks that style straight away
                int n;
                if (box.Text.Length == 1 && int.TryParse(box.Text, out n) && n >= 1 && n <= Math.Min(9, styles.Count))
                    Finish(null, styles[n - 1].Key);
            };
            Deactivate += (s, e) => Finish(null, null);   // clicking elsewhere cancels
        }

        static Label MakeLabel(string text, int x, int y, float size, Color color)
        {
            return new Label { Text = text, AutoSize = true, Location = new Point(x, y), ForeColor = color, Font = new Font("Segoe UI", size) };
        }

        protected override void OnShown(EventArgs e)
        {
            base.OnShown(e);
            using (var path = Look.RoundRect(new RectangleF(0, 0, Width, Height), 10)) Region = new Region(path);
            Activate();
            box.Focus();
        }

        protected override bool ProcessCmdKey(ref Message msg, Keys key)
        {
            if (key == Keys.Escape) { Finish(null, null); return true; }
            if (key == Keys.Enter)
            {
                var t = box.Text.Trim();
                if (t.Length > 0) Finish(t, null); else Finish(null, usual);
                return true;
            }
            return base.ProcessCmdKey(ref msg, key);
        }

        void Finish(string instruction, string styleKey)
        {
            if (done) return;
            done = true;
            Instruction = instruction;
            StyleKey = styleKey;
            DialogResult = instruction != null || styleKey != null ? DialogResult.OK : DialogResult.Cancel;
            Close();
        }
    }

    /// A small dialog with two text boxes (for "Add a style…" and "Download a model…").
    static class Ask
    {
        public static string[] Fields(string title, string intro, string[] labels, string[] hints)
        {
            var f = new Form
            {
                Text = title, FormBorderStyle = FormBorderStyle.FixedDialog, MaximizeBox = false, MinimizeBox = false,
                StartPosition = FormStartPosition.CenterScreen, Font = new Font("Segoe UI", 9.5f), TopMost = true, ShowInTaskbar = true
            };
            int y = 14;
            var introLabel = new Label { Text = intro, Location = new Point(14, y), MaximumSize = new Size(400, 0), AutoSize = true };
            f.Controls.Add(introLabel);
            y += introLabel.PreferredHeight + 14;
            var boxes = new List<TextBox>();
            for (int i = 0; i < labels.Length; i++)
            {
                f.Controls.Add(new Label { Text = labels[i], Location = new Point(14, y), AutoSize = true });
                y += 20;
                var tb = new TextBox { Location = new Point(14, y), Width = 400 };
                f.Controls.Add(tb);
                if (hints != null && i < hints.Length) Native.SendMessage(tb.Handle, 0x1501, (IntPtr)1, hints[i]);
                boxes.Add(tb);
                y += 34;
            }
            var ok = new Button { Text = "OK", DialogResult = DialogResult.OK, Location = new Point(258, y), Width = 75 };
            var cancel = new Button { Text = "Cancel", DialogResult = DialogResult.Cancel, Location = new Point(339, y), Width = 75 };
            f.Controls.Add(ok);
            f.Controls.Add(cancel);
            f.AcceptButton = ok;
            f.CancelButton = cancel;
            f.ClientSize = new Size(428, y + 40);
            f.Shown += (s, e) => { f.Activate(); boxes[0].Focus(); };
            if (f.ShowDialog() != DialogResult.OK) return null;
            return boxes.Select(b => b.Text.Trim()).ToArray();
        }
    }

    // ------------------------------------------------------------------ The app

    class App : ApplicationContext
    {
        const int HotkeyRephrase = 1, HotkeyChoose = 2;
        readonly NotifyIcon tray = new NotifyIcon();
        readonly ContextMenuStrip menu = new ContextMenuStrip();
        readonly HotkeyWindow hotkeys = new HotkeyWindow();
        readonly Bubble bubble = new Bubble();
        readonly System.Windows.Forms.Timer watchFocus = new System.Windows.Forms.Timer { Interval = 400 };
        List<ModelInfo> models = new List<ModelInfo>();
        bool aiReachable, busy;
        IntPtr lastOtherWindow = IntPtr.Zero;   // the last app you were in, for menu actions
        string lastRephrase = "none yet", downloadStatus;
        readonly uint myPid = (uint)Process.GetCurrentProcess().Id;

        bool Paused { get { return Store.Get("paused", "no") == "yes"; } set { Store.Set("paused", value ? "yes" : "no"); } }
        string UsualStyle { get { return Store.Get("rephraseStyle", "natural"); } set { Store.Set("rephraseStyle", value); } }
        string FreeMemoryAfter { get { return Store.Get("freeMemoryAfter", "5m"); } set { Store.Set("freeMemoryAfter", value); } }

        public App()
        {
            Styles.SeedFile();
            Store.Log("Fixaro for Windows starting · " + Environment.OSVersion + " · " + (Environment.Is64BitProcess ? "64-bit" : "32-bit"));
            tray.Icon = Look.AppIcon(32, Paused);
            tray.Text = "Fixaro";
            tray.ContextMenuStrip = menu;
            tray.Visible = true;
            menu.Opening += (s, e) => { BuildMenu(); };
            tray.MouseUp += (s, e) =>
            {
                if (e.Button != MouseButtons.Left) return;
                var show = typeof(NotifyIcon).GetMethod("ShowContextMenu",
                    System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic);
                if (show != null) show.Invoke(tray, null);
            };
            hotkeys.Pressed += id => { var _ = OnHotkey(id == HotkeyChoose); };
            if (!Paused) RegisterHotkeys();
            watchFocus.Tick += (s, e) => RememberOtherWindow();
            watchFocus.Start();
            var __ = Startup();
        }

        void RegisterHotkeys()
        {
            uint mods = Native.MOD_CONTROL | Native.MOD_ALT | Native.MOD_NOREPEAT;
            bool r = Native.RegisterHotKey(hotkeys.Handle, HotkeyRephrase, mods, (uint)Keys.R);
            bool s = Native.RegisterHotKey(hotkeys.Handle, HotkeyChoose, mods, (uint)Keys.S);
            if (!r || !s)
            {
                Store.Log("Shortcut taken by another app: " + (!r ? "Ctrl+Alt+R " : "") + (!s ? "Ctrl+Alt+S" : ""));
                tray.ShowBalloonTip(6000, "Fixaro", "Another app is already using " + (!r ? "Ctrl+Alt+R" : "Ctrl+Alt+S") +
                    ". Close it, then pause and resume Fixaro.", ToolTipIcon.Warning);
            }
        }

        void UnregisterHotkeys()
        {
            Native.UnregisterHotKey(hotkeys.Handle, HotkeyRephrase);
            Native.UnregisterHotKey(hotkeys.Handle, HotkeyChoose);
        }

        void RememberOtherWindow()
        {
            var fg = Native.GetForegroundWindow();
            if (fg == IntPtr.Zero) return;
            uint pid;
            Native.GetWindowThreadProcessId(fg, out pid);
            if (pid == myPid) return;
            var cls = Native.ClassOf(fg);
            if (cls == "Shell_TrayWnd" || cls == "NotifyIconOverflowWindow" || cls == "TopLevelWindowForOverflowXamlIsland" ||
                cls == "Shell_SecondaryTrayWnd" || cls == "Progman" || cls == "WorkerW") return;
            lastOtherWindow = fg;
        }

        async Task Startup()
        {
            await RefreshModels();
            if (Store.Get("welcomed", "no") != "yes")
            {
                Store.Set("welcomed", "yes");
                if (!aiReachable)
                {
                    var answer = MessageBox.Show(
                        "Fixaro rewrites your text with an AI model that runs on this PC, so nothing you write leaves it.\n\n" +
                        "It needs the free Ollama app. Open the Ollama download page now?\n\n" +
                        "After installing Ollama, open Fixaro's menu (the F icon near the clock) and choose Settings → Download a model.",
                        "Welcome to Fixaro", MessageBoxButtons.YesNo, MessageBoxIcon.Information);
                    if (answer == DialogResult.Yes) Process.Start("https://ollama.com/download/windows");
                }
                else
                {
                    tray.ShowBalloonTip(8000, "Fixaro is ready",
                        "Select text in any app and press Ctrl+Alt+R to rewrite it, or Ctrl+Alt+S to choose how.", ToolTipIcon.Info);
                }
            }
        }

        async Task RefreshModels()
        {
            var list = await AI.ListModels();
            aiReachable = list != null;
            models = list ?? new List<ModelInfo>();
        }

        /// The model used for rephrasing: your choice, or the best one installed.
        string RephraseModel()
        {
            if (models.Count == 0) return null;
            var chosen = Store.Get("rephraseModel", null);
            if (chosen != null && models.Any(m => m.Name == chosen)) return chosen;
            foreach (var pick in new[] { "qwen3.5:9b", "gemma4:e4b", "qwen3.5:4b", "nemotron-3-nano:4b" })
                if (models.Any(m => m.Name == pick)) return pick;
            return models.OrderByDescending(m => m.Size).First().Name;
        }

        // ---------------------------------------------------------------- Rewriting

        async Task OnHotkey(bool choose)
        {
            Native.MaskAlt();   // releasing Alt shouldn't open the app's menu bar
            await Rephrase(choose, Native.GetForegroundWindow());
        }

        async Task Rephrase(bool choose, IntPtr target)
        {
            if (busy || Paused) return;
            busy = true;
            IDataObject saved = null;
            try
            {
                // Wait until you let go of Ctrl and Alt, so the copy below is a plain Ctrl+C
                for (int i = 0; i < 40 && Native.AnyModifierDown(); i++) await Task.Delay(25);

                if (models.Count == 0) await RefreshModels();
                var model = RephraseModel();
                var near = Native.CaretPoint(target) ?? Cursor.Position;
                if (model == null)
                {
                    bubble.ShowNear(aiReachable ? "No AI model yet: Settings → Download a model" : "Start Ollama first", near, false);
                    await Task.Delay(2600);
                    return;
                }

                // Copy what you selected
                saved = SaveClipboard();
                uint before = Native.GetClipboardSequenceNumber();
                Native.CtrlKey('c');
                string original = null;
                for (int i = 0; i < 30; i++)
                {
                    await Task.Delay(20);
                    if (Native.GetClipboardSequenceNumber() != before) { await Task.Delay(30); original = ReadClipboardText(); break; }
                }
                if (string.IsNullOrEmpty(original) || original.Trim().Length == 0)
                {
                    RestoreClipboard(saved);
                    saved = null;
                    bubble.ShowNear("Select some text first, then try again", near, false);
                    await Task.Delay(2200);
                    return;
                }

                var style = Styles.Find(UsualStyle);
                string system = Prompts.ForStyle(style), title = style.Title;
                if (choose)
                {
                    using (var popup = new PromptForm(Styles.All(), Styles.Find(UsualStyle).Key))
                    {
                        popup.Location = Look.Place(popup.Size, near);
                        var result = popup.ShowDialog();
                        if (Native.IsWindow(target)) Native.SetForegroundWindow(target);   // back to your app
                        if (result != DialogResult.OK)
                        {
                            RestoreClipboard(saved);
                            saved = null;
                            lastRephrase = "cancelled";
                            return;
                        }
                        if (popup.Instruction != null) { system = Prompts.ForInstruction(popup.Instruction); title = "your instruction"; }
                        else { style = Styles.Find(popup.StyleKey); system = Prompts.ForStyle(style); title = style.Title; }
                    }
                }

                bubble.ShowNear(title == "your instruction" ? "Rewriting" : "Rewriting · " + title.Split(new[] { " (" }, StringSplitOptions.None)[0], near, true);
                var watch = Stopwatch.StartNew();
                int budget = Math.Min(2048, Math.Max(128, original.Length));
                var raw = await AI.Generate(model, Prompts.ForModel(system, model), Prompts.UserPrompt(original.Replace("\r\n", "\n")),
                                            budget, 180, FreeMemoryAfter);
                var cleaned = Prompts.Clean(raw, original);
                bubble.HideBubble();
                if (cleaned == null)
                {
                    RestoreClipboard(saved);
                    saved = null;
                    bubble.ShowNear(raw == null ? "Couldn't reach " + AI.DisplayName : "The AI's answer didn't look right, so nothing was changed", near, false);
                    await Task.Delay(2600);
                    return;
                }

                // Paste it over your selection
                if (Native.IsWindow(target)) Native.SetForegroundWindow(target);
                await Task.Delay(60);
                WriteClipboardText(cleaned);
                Native.CtrlKey('v');
                await Task.Delay(450);
                lastRephrase = title + " · " + (watch.ElapsedMilliseconds / 100 / 10.0) + " s";
                Store.Log("rephrase: " + original.Length + " → " + cleaned.Length + " chars [" + AI.DisplayName + " · " + model + ", " +
                          watch.ElapsedMilliseconds + " ms, " + (title == "your instruction" ? "instruction" : title) + "]");
            }
            catch (Exception e)
            {
                Store.Log("rephrase error: " + e.Message);
            }
            finally
            {
                if (saved != null) RestoreClipboard(saved);
                bubble.HideBubble();
                busy = false;
            }
        }

        // ---------------------------------------------------------------- Clipboard (put back the way it was)

        static IDataObject SaveClipboard()
        {
            for (int i = 0; i < 5; i++)
            {
                try
                {
                    var current = Clipboard.GetDataObject();
                    var copy = new DataObject();
                    if (current != null)
                        foreach (var f in current.GetFormats(false))
                            try { var d = current.GetData(f, false); if (d != null) copy.SetData(f, false, d); } catch (Exception) { }
                    return copy;
                }
                catch (ExternalException) { Thread.Sleep(30); }
            }
            return null;
        }

        static void RestoreClipboard(IDataObject saved)
        {
            if (saved == null) return;
            for (int i = 0; i < 5; i++)
            {
                try
                {
                    if (saved.GetFormats().Length == 0) Clipboard.Clear(); else Clipboard.SetDataObject(saved, true);
                    return;
                }
                catch (ExternalException) { Thread.Sleep(30); }
            }
        }

        static string ReadClipboardText()
        {
            for (int i = 0; i < 5; i++)
            {
                try { return Clipboard.ContainsText() ? Clipboard.GetText() : null; }
                catch (ExternalException) { Thread.Sleep(30); }
            }
            return null;
        }

        static void WriteClipboardText(string text)
        {
            for (int i = 0; i < 5; i++)
            {
                try { Clipboard.SetText(text); return; }
                catch (ExternalException) { Thread.Sleep(30); }
            }
        }

        // ---------------------------------------------------------------- Menu

        void BuildMenu()
        {
            menu.Items.Clear();
            var header = new ToolStripMenuItem("Fixaro — " + (Paused ? "paused" : "on")) { Enabled = false };
            menu.Items.Add(header);
            menu.Items.Add(new ToolStripSeparator());
            var reph = new ToolStripMenuItem("Rephrase selected text", null, (s, e) => { var _ = FromMenu(false); }) { ShortcutKeyDisplayString = "Ctrl+Alt+R" };
            var rephAs = new ToolStripMenuItem("Rephrase as…", null, (s, e) => { var _ = FromMenu(true); }) { ShortcutKeyDisplayString = "Ctrl+Alt+S" };
            reph.Enabled = rephAs.Enabled = !Paused;
            menu.Items.Add(reph);
            menu.Items.Add(rephAs);
            menu.Items.Add(StyleMenu());
            menu.Items.Add(new ToolStripMenuItem("Last rephrase: " + lastRephrase) { Enabled = false });
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add(SettingsMenu());
            menu.Items.Add(new ToolStripMenuItem(Paused ? "Resume Fixaro" : "Pause Fixaro", null, (s, e) => TogglePause()));
            menu.Items.Add(new ToolStripMenuItem("Quit Fixaro", null, (s, e) => Quit()));
            var __ = RefreshInBackground();
        }

        async Task RefreshInBackground()
        {
            var wasReachable = aiReachable;
            var count = models.Count;
            await RefreshModels();
            if (menu.Visible && (wasReachable != aiReachable || count != models.Count)) BuildMenu();
        }

        async Task FromMenu(bool choose)
        {
            // The menu took the focus: go back to the app you were in first
            if (lastOtherWindow == IntPtr.Zero || !Native.IsWindow(lastOtherWindow)) return;
            Native.SetForegroundWindow(lastOtherWindow);
            await Task.Delay(200);
            await Rephrase(choose, lastOtherWindow);
        }

        ToolStripMenuItem StyleMenu()
        {
            var usual = Styles.Find(UsualStyle);
            var root = new ToolStripMenuItem("Rephrase style: " + usual.Title);
            root.DropDownItems.Add(new ToolStripMenuItem("Ctrl+Alt+R uses") { Enabled = false });
            foreach (var st in Styles.All())
            {
                var key = st.Key;
                root.DropDownItems.Add(new ToolStripMenuItem(st.Title, null, (s, e) => UsualStyle = key) { Checked = key == usual.Key });
            }
            root.DropDownItems.Add(new ToolStripSeparator());
            root.DropDownItems.Add(new ToolStripMenuItem("Add a style…", null, (s, e) => AddStyle()));
            root.DropDownItems.Add(new ToolStripMenuItem("Edit my styles…", null, (s, e) =>
            {
                Styles.SeedFile();
                Process.Start("notepad.exe", "\"" + Store.StylesPath + "\"");
            }));
            return root;
        }

        void AddStyle()
        {
            var f = Ask.Fields("Add a style", "Your style appears in the Ctrl+Alt+S popup. Describe how the text should be rewritten.",
                new[] { "Name", "How to rewrite it" },
                new[] { "Customer reply", "Polite and helpful, thank the customer, and end with a clear next step" });
            if (f == null || f[0].Length == 0 || f[1].Length == 0) return;
            var name = f[0].Replace(":", " -");
            if (name.Length > 40) name = name.Substring(0, 40);
            try
            {
                Styles.SeedFile();
                File.AppendAllText(Store.StylesPath, name + ": " + f[1].Replace("\r", " ").Replace("\n", " ") + "\r\n", Encoding.UTF8);
            }
            catch (Exception e) { Store.Log("Couldn't save the style: " + e.Message); }
        }

        ToolStripMenuItem SettingsMenu()
        {
            var root = new ToolStripMenuItem("Settings");
            root.DropDownItems.Add(new ToolStripMenuItem("AI") { Enabled = false });
            if (models.Count > 0)
            {
                var current = RephraseModel();
                var mm = new ToolStripMenuItem("Rephrase model: " + current);
                foreach (var m in models)
                {
                    var name = m.Name;
                    var title = m.Size > 0 ? name + "  (" + (m.Size / 1e9).ToString("0.0") + " GB)" : name;
                    mm.DropDownItems.Add(new ToolStripMenuItem(title, null, (s, e) => Store.Set("rephraseModel", name)) { Checked = name == current });
                }
                root.DropDownItems.Add(mm);
            }
            else
            {
                root.DropDownItems.Add(new ToolStripMenuItem(aiReachable ? "No models yet" : "Can't reach " + AI.DisplayName + ". Is it running?") { Enabled = false });
                if (!aiReachable && AI.Kind == "ollama")
                    root.DropDownItems.Add(new ToolStripMenuItem("Get Ollama…", null, (s, e) => Process.Start("https://ollama.com/download/windows")));
            }
            if (AI.Kind == "ollama")
            {
                if (downloadStatus != null) root.DropDownItems.Add(new ToolStripMenuItem(downloadStatus) { Enabled = false });
                else root.DropDownItems.Add(new ToolStripMenuItem("Download a model…", null, (s, e) => { var _ = DownloadModel(); }));

                var keeps = new[] { new[] { "0s", "Right away (slower rewrites)" }, new[] { "5m", "After 5 minutes" },
                                    new[] { "15m", "After 15 minutes" }, new[] { "30m", "After 30 minutes" } };
                var current = keeps.FirstOrDefault(k => k[0] == FreeMemoryAfter) ?? keeps[1];
                var fm = new ToolStripMenuItem("Free AI memory: " + current[1].Replace(" (slower rewrites)", "").ToLowerInvariant());
                foreach (var k in keeps)
                {
                    var value = k[0];
                    fm.DropDownItems.Add(new ToolStripMenuItem(k[1], null, (s, e) => { var _ = SetFreeMemory(value); }) { Checked = value == FreeMemoryAfter });
                }
                root.DropDownItems.Add(fm);
            }

            var apps = new ToolStripMenuItem("AI app: " + AI.DisplayName);
            var presets = new[] {
                new[] { "Ollama", "ollama", "http://127.0.0.1:11434" },
                new[] { "LM Studio (localhost:1234)", "openai", "http://localhost:1234/v1" },
                new[] { "llama.cpp server (localhost:8080)", "openai", "http://localhost:8080/v1" },
                new[] { "Jan (localhost:1337)", "openai", "http://localhost:1337/v1" } };
            bool isPreset = false;
            foreach (var p in presets)
            {
                var kind = p[1]; var url = p[2];
                bool on = AI.Kind == kind && AI.Base == url.TrimEnd('/');
                isPreset |= on;
                apps.DropDownItems.Add(new ToolStripMenuItem(p[0], null, (s, e) => SetServer(kind, url)) { Checked = on });
            }
            apps.DropDownItems.Add(new ToolStripMenuItem(isPreset ? "Other app (OpenAI-compatible)…" : "Other: " + AI.Base + "…", null, (s, e) =>
            {
                var f = Ask.Fields("Other AI app", "The address of an OpenAI-compatible server running on this PC or your network.",
                                   new[] { "Address" }, new[] { "http://localhost:1234/v1" });
                if (f != null && f[0].StartsWith("http")) SetServer("openai", f[0]);
            }) { Checked = !isPreset });
            root.DropDownItems.Add(apps);

            root.DropDownItems.Add(new ToolStripSeparator());
            root.DropDownItems.Add(new ToolStripMenuItem("Start Fixaro when Windows starts", null, (s, e) => ToggleStartup()) { Checked = StartsWithWindows() });
            root.DropDownItems.Add(new ToolStripMenuItem("Open Fixaro's folder", null, (s, e) => Process.Start("explorer.exe", "\"" + Store.Dir + "\"")));
            return root;
        }

        void SetServer(string kind, string url)
        {
            Store.Set("serverKind", kind);
            Store.Set("serverURL", url.TrimEnd('/'));
            Store.Set("rephraseModel", null);
            models = new List<ModelInfo>();
            Store.Log("AI app set to " + kind + " " + url);
            var _ = RefreshModels();
        }

        async Task SetFreeMemory(string value)
        {
            FreeMemoryAfter = value;
            Store.Log("Free AI memory after: " + value);
            var model = RephraseModel();
            foreach (var loaded in await AI.LoadedModels())
                if (loaded == model) await AI.SetKeepAlive(loaded, value);   // applies now, so "Right away" frees it at once
        }

        async Task DownloadModel()
        {
            var recommended = TotalMemoryGB() >= 15 ? "qwen3.5:4b" : "nemotron-3-nano:4b";
            var f = Ask.Fields("Download a model",
                "Type the name of an Ollama model. For this PC we suggest " + recommended + ". Smaller models are faster, bigger ones write better.",
                new[] { "Model name" }, new[] { recommended });
            if (f == null) return;
            var name = f[0].Length > 0 ? f[0] : recommended;
            downloadStatus = "Downloading " + name + "…";
            Store.Log("Downloading " + name);
            var ok = await AI.Pull(name, status => { downloadStatus = status; });
            downloadStatus = null;
            await RefreshModels();
            if (ok) Store.Set("rephraseModel", name);
            tray.ShowBalloonTip(6000, "Fixaro", ok ? name + " is ready. Select text and press Ctrl+Alt+R." : "Couldn't download " + name + ". Check the name and your connection.",
                                ok ? ToolTipIcon.Info : ToolTipIcon.Warning);
        }

        static double TotalMemoryGB()
        {
            var m = new Native.MEMORYSTATUSEX();
            return Native.GlobalMemoryStatusEx(m) ? m.ullTotalPhys / 1e9 : 16;
        }

        const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";

        static bool StartsWithWindows()
        {
            using (var k = Registry.CurrentUser.OpenSubKey(RunKey)) return k != null && k.GetValue("Fixaro") != null;
        }

        static void ToggleStartup()
        {
            using (var k = Registry.CurrentUser.CreateSubKey(RunKey))
            {
                if (k.GetValue("Fixaro") != null) k.DeleteValue("Fixaro");
                else k.SetValue("Fixaro", "\"" + Application.ExecutablePath + "\"");
            }
        }

        void TogglePause()
        {
            Paused = !Paused;
            if (Paused) UnregisterHotkeys(); else RegisterHotkeys();
            var old = tray.Icon;
            tray.Icon = Look.AppIcon(32, Paused);
            old.Dispose();
        }

        void Quit()
        {
            UnregisterHotkeys();
            tray.Visible = false;
            hotkeys.Dispose();
            ExitThread();
        }
    }
}
