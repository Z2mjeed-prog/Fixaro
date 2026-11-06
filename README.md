<p align="center">
  <img src="docs/icon.png" width="112" alt="Fixaro icon">
</p>

<h1 align="center">Fixaro</h1>

<p align="center"><b>Private grammar fixing and rewriting, in every app on your Mac or Windows PC.<br>Your text never leaves your computer.</b></p>

<p align="center"><a href="#install">Install</a> · <a href="#styles">Styles</a> · <a href="#which-model">Models</a> · <a href="#good-to-know">Good to know</a> · <a href="#uninstall">Uninstall</a></p>

Select text in any app and press one shortcut. Fixaro fixes the grammar and rewrites it in the tone you want, right where you're typing. The AI runs on your own computer, so it's safe for confidential emails, client details and reports.

<p align="center">
  <img src="docs/demo-email.gif" width="800" alt="A casual email draft in Apple Mail, 'Hey, can you send me the sales numbers by tomorrow? ... thanks', is selected, Control-Option-R is pressed, and with the Professional style it becomes 'Could you please send me the sales numbers by tomorrow? I require them for the meeting on Thursday. Please let me know if this presents any issues. Thank you.'">
</p>

## How to use it

| | Mac | Windows |
|---|---|---|
| **Polish:** fix the grammar, in your usual style | Select text, press **⌃⌥R** | Select text, press **Ctrl + Alt + R** |
| **Rewrite as…:** pick a style, or say how | **⌃⌥S** | **Ctrl + Alt + S** |
| **Undo** | **⌘Z** | **Ctrl + Z** |

With **⌃⌥S** (**Ctrl + Alt + S** on Windows) a popup opens next to your text. Type how you want it, like *more formal, and ask for a reply by Sunday*, and press **Enter**. Or press a style's number.

<p align="center">
  <img src="docs/demo-ask.gif" width="720" alt="A draft, 'hi sara, sorry the report is late. the data team didn't send the numbers yet so we can't finish it. will send when we get them', is selected and Control-Option-S is pressed. A popup opens next to the text with a box and a list of styles. Typing 'polite email to my manager, and promise it by Thursday' and pressing Return turns it into 'Hi Sara, I'm sorry the report is running late. The data team hasn't sent us the numbers yet, so we can't finish it. I'll send it to you by Thursday.'">
  <br><sub>An illustration of the popup</sub>
</p>

It keeps your names, numbers and meaning, and never answers your text: a question stays a question. It's also faster than a chatbot, with no copying, switching apps and pasting back.

## Private by design

<p align="center">
  <img src="docs/demo-private.gif" width="640" alt="A confidential note full of mistakes, 'the client in acount 48213 have missed two payment and owe 3,750 SAR. her salary went down to 9,000 so we need to restructure the loan befor it go to collections', is selected, Control-Option-R is pressed, and on the Mac it becomes 'The client in account 48213 has missed two payments and currently owes 3,750 SAR. Since her salary has decreased to 9,000, we need to restructure the loan before it goes to collections.'">
</p>

- **Your text stays on your computer.** The AI runs locally through [Ollama](https://ollama.com). No account, no cloud, no tracking.
- **Works offline** once your AI model is downloaded.
- **Saves nothing you write.** Rewrites are never stored. It never sees password fields.
- **Free and open source.** Anyone can check exactly what it does.

## Styles

| Style | You wrote | Fixaro wrote |
|---|---|---|
| **Natural** (fixes grammar, keeps your tone) | i think we should of finished the report yesterday but we was to busy | I think we should have finished the report yesterday, but we were too busy. |
| **Professional** | hey can u send me the Q3 numbers by tmrw? need them for the 10am meeting | Could you please send me the Q3 numbers by tomorrow? I need them for the 10:00 AM meeting. |
| **Shorter** | I just wanted to let you know that I will not be able to attend the meeting on Thursday because I have a doctor's appointment that I cannot move. | I cannot attend Thursday's meeting due to an unavoidable doctor's appointment. |
| **Friendly** | Your payment of 450 SAR is overdue. Pay it by June 5 or your account will be suspended. | Just a friendly heads-up that your payment of 450 SAR is a little overdue. Could you please take care of it by June 5th? |

**Make your own:** menu → **Usual style → Add a style…**, give it a name, and describe how it should sound, like *Customer reply: polite, warm and short*. It appears in the Rewrite as… popup. Pick your usual style, the one Polish uses, in the same menu.

## Install

### Mac

You need **macOS 14 or later**. It takes about 5 minutes.

1. **Get [Ollama](https://ollama.com/download)**, the free app that runs the AI. Move it into Applications and open it.
2. **Install Fixaro:** open **Terminal** (⌘ Space, type `Terminal`) and paste:
   ```bash
   git clone https://github.com/Z2mjeed-prog/Fixaro.git && bash Fixaro/build.sh
   ```
   If macOS asks to install developer tools, click **Install**, then paste the line again.
3. **In Fixaro's welcome window**, click **Allow…** and switch Fixaro on, then click **Download** to get an AI model.

The **F** in your menu bar means it's on. To update: `cd Fixaro && git pull && bash build.sh`

### Windows (preview)

You need **Windows 10 or 11**. The Windows version does Polish and Rewrite as…, everything on this page.

1. **Get [Ollama for Windows](https://ollama.com/download/windows)** and open it.
2. **Install Fixaro:** open **PowerShell** (Start menu, type `PowerShell`) and paste:
   ```powershell
   cd $env:USERPROFILE; iwr https://github.com/Z2mjeed-prog/Fixaro/archive/refs/heads/main.zip -OutFile fixaro.zip; Expand-Archive fixaro.zip . -Force; cmd /c Fixaro-main\windows\build.cmd
   ```
   It builds with the compiler that comes with Windows, so there's nothing else to install.
3. **Click the F icon** near the clock → **Settings → Download a model…**

To update, paste the same line again.

### Which model?

**A better model gives better results.** Bigger models write more naturally and follow your instructions more closely, but they need more memory and take a little longer.

| Your computer's memory | Best model |
|---|---|
| **8 GB** | `nemotron-3-nano:4b` (2.9 GB) |
| **16 GB or more** | `qwen3.5:9b` (7.6 GB), the best writing in [our tests](docs/MODELS.md) |

Download one from Fixaro's menu: **Settings → Download a model…**, then pick it under **Settings → AI model**.

## Good to know

- **Mac permission:** Fixaro needs **Accessibility** permission to read and replace text in other apps. If the menu bar icon shows ⚠ after an update, switch Fixaro off and on again under Accessibility.
- **Clipboard:** to rewrite, it copies your selection and then puts your clipboard back, so a clipboard manager may keep a copy.
- **Memory:** the AI model frees its memory 5 minutes after you last use it. On a tight computer, choose **Settings → Free AI memory → Right away**.
- **Nothing happens?** Make sure Ollama is running and some text is selected. Fixaro's log shows what went wrong, never your text.
- **English only** for now. It also works with LM Studio, Jan and other local AI apps ([how](docs/MODELS.md#use-another-ai-app-instead-of-ollama-beta)).

## Uninstall

<details>
<summary>Mac</summary>

```bash
osascript -e 'quit app "Fixaro"'
rm -rf /Applications/Fixaro.app ~/Applications/Fixaro.app ~/Library/Application\ Support/Fixaro ~/Library/Logs/Fixaro.log
defaults delete io.github.z2mjeed-prog.fixaro; tccutil reset Accessibility io.github.z2mjeed-prog.fixaro
```
If you turned on **Start at login**, also remove Fixaro under **System Settings → General → Login Items**.
</details>

<details>
<summary>Windows</summary>

```powershell
Stop-Process -Name Fixaro -ErrorAction SilentlyContinue; Remove-Item -Recurse -Force "$env:LOCALAPPDATA\Programs\Fixaro", "$env:APPDATA\Fixaro", "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Fixaro.lnk" -ErrorAction SilentlyContinue; Remove-ItemProperty HKCU:\Software\Microsoft\Windows\CurrentVersion\Run -Name Fixaro -ErrorAction SilentlyContinue
```
</details>

## How it works

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/how-rephrase-works-dark.png">
  <img src="docs/how-rephrase-works-light.png" width="860" alt="How Fixaro rephrases: you select text in any app and press Control-Option-R for your usual style, or Control-Option-S to pick a style or type how to rewrite it; Fixaro sends your text and the style to an AI model running on your computer; the rewrite is pasted back in place and your clipboard is restored. Nothing is sent to the internet.">
</picture>

Each version is a single file: `Sources/main.swift` (Mac) and `windows/Fixaro.cs` (Windows), built on your own computer.

**Coming next:** a one-line installer that also gets Ollama, and signed downloads.

Issues and pull requests are welcome. If something doesn't work, open an issue with the relevant lines from the log.

[MIT License](LICENSE) © Z2mjeed-prog
