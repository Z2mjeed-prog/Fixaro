# Fixaro installer for Windows. Paste into PowerShell:
#   irm https://raw.githubusercontent.com/Z2mjeed-prog/Fixaro/main/install.ps1 | iex
# It gets Ollama (if you don't have it), installs Fixaro, offers to download the AI model, and starts Fixaro.
# It asks before installing anything. Paste the same line again any time to update Fixaro.
#   $env:FIXARO_UPDATE='1'   update Fixaro only, with no questions (Fixaro's "Update Fixaro..." menu item uses this)
#   $env:FIXARO_BRANCH='x'   install the test build of branch x (for testing before a release)
#   $env:FIXARO_SOURCE='1'   build Fixaro on this PC instead of downloading the ready-made app

& {
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'   # much faster downloads in Windows PowerShell
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072   # TLS 1.2

    $repo = 'Z2mjeed-prog/Fixaro'
    $branch = if ($env:FIXARO_BRANCH) { $env:FIXARO_BRANCH } else { 'main' }
    $update = [bool]$env:FIXARO_UPDATE
    $ollamaUrl = 'http://127.0.0.1:11434'
    $dest = Join-Path $env:LOCALAPPDATA 'Programs\Fixaro'
    $work = Join-Path ([IO.Path]::GetTempPath()) ('fixaro-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $work | Out-Null

    function Step($text) { Write-Host ''; Write-Host $text -ForegroundColor White }
    function Say($text) { Write-Host "  $text" }
    function Ask($question) {   # Enter means yes
        $answer = Read-Host "  $question [Y/n]"
        return -not ($answer -match '^[nN]')
    }
    function OllamaUp {
        try { Invoke-RestMethod "$ollamaUrl/api/version" -TimeoutSec 2 | Out-Null; return $true } catch { return $false }
    }
    function FindOllama {
        $cmd = Get-Command ollama -ErrorAction SilentlyContinue
        if ($cmd) { return $cmd.Source }
        $exe = Join-Path $env:LOCALAPPDATA 'Programs\Ollama\ollama.exe'
        if (Test-Path $exe) { return $exe }
        return $null
    }

    try {
        if ($update) { Step "Updating Fixaro - $(Get-Date)" } else { Step 'Installing Fixaro' }

        # --- Ollama, the free app that runs the AI on your PC ----------------------------------------------
        if (-not $update) {
            Step 'Step 1 of 3: Ollama, the free app that runs the AI on your PC'
            if ((FindOllama) -or (OllamaUp)) {
                Say 'Already installed.'
            } elseif (Ask "Ollama isn't installed. Install it from ollama.com now?") {
                Say 'Installing Ollama with its official installer...'
                powershell -NoProfile -ExecutionPolicy Bypass -Command "irm https://ollama.com/install.ps1 | iex"
                $env:Path = [Environment]::GetEnvironmentVariable('Path', 'User') + ';' + [Environment]::GetEnvironmentVariable('Path', 'Machine')
                if (FindOllama) { Say 'Installed Ollama.' }
                else { Say "Ollama didn't install. Get it from https://ollama.com/download/windows, then run this again." }
            } else {
                Say 'Skipped. Fixaro needs Ollama (or another local AI app) to rewrite text: https://ollama.com/download/windows'
            }
            # Make sure Ollama is running
            if (-not (OllamaUp)) {
                $app = Join-Path $env:LOCALAPPDATA 'Programs\Ollama\ollama app.exe'
                if (Test-Path $app) { Start-Process $app }
                elseif (FindOllama) { Start-Process (FindOllama) -ArgumentList 'serve' -WindowStyle Hidden }
                for ($i = 0; $i -lt 30 -and -not (OllamaUp); $i++) { Start-Sleep 1 }
            }
        }

        # --- Fixaro ----------------------------------------------------------------------------------------
        if (-not $update) { Step 'Step 2 of 3: Fixaro' }
        $exe = $null
        if (-not $env:FIXARO_SOURCE) {
            $url = if ($branch -eq 'main') { "https://github.com/$repo/releases/latest/download/Fixaro-windows.zip" }
                   else { "https://github.com/$repo/releases/download/test-build/Fixaro-windows.zip" }
            Say 'Downloading Fixaro...'
            try {
                Invoke-WebRequest $url -OutFile "$work\Fixaro-windows.zip" -UseBasicParsing
                Expand-Archive "$work\Fixaro-windows.zip" "$work\ready" -Force
                if (Test-Path "$work\ready\Fixaro.exe") { $exe = "$work\ready\Fixaro.exe" }
            } catch { }
            if (-not $exe) { Say "The ready-made app isn't available right now, so Fixaro will be built on your PC instead." }
        }
        if (-not $exe) {
            Say 'Downloading the source...'
            Invoke-WebRequest "https://github.com/$repo/archive/refs/heads/$branch.zip" -OutFile "$work\source.zip" -UseBasicParsing
            Expand-Archive "$work\source.zip" "$work\src" -Force
            $src = (Get-ChildItem "$work\src" -Directory | Select-Object -First 1).FullName
            Say 'Building it with the compiler that comes with Windows...'
            cmd /c "`"$src\windows\build.cmd`" ci"
            if ($LASTEXITCODE -ne 0 -or -not (Test-Path "$src\windows\build\Fixaro.exe")) { throw 'The build failed. Please share the lines above in a GitHub issue.' }
            $exe = "$src\windows\build\Fixaro.exe"
        }

        Get-Process Fixaro -ErrorAction SilentlyContinue | Stop-Process -Force
        Start-Sleep 1
        New-Item -ItemType Directory -Force -Path $dest | Out-Null
        Copy-Item $exe "$dest\Fixaro.exe" -Force
        # A Start menu shortcut, so you can find and start Fixaro like any other app
        $shell = New-Object -ComObject WScript.Shell
        $link = $shell.CreateShortcut((Join-Path ([Environment]::GetFolderPath('Programs')) 'Fixaro.lnk'))
        $link.TargetPath = "$dest\Fixaro.exe"
        $link.Save()
        Say "Installed Fixaro in $dest."

        # --- The AI model ----------------------------------------------------------------------------------
        if (-not $update) {
            Step 'Step 3 of 3: the AI model'
            $tags = $null
            try { $tags = Invoke-RestMethod "$ollamaUrl/api/tags" -TimeoutSec 3 } catch { }
            if ($tags -and $tags.models -and $tags.models.Count -gt 0) {
                Say "You already have a model. You can change it in Fixaro's menu: Settings > AI model."
            } elseif ($tags) {
                $gb = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
                if ($gb -ge 15) { $model = 'qwen3.5:9b'; $size = '7.6 GB' } else { $model = 'nemotron-3-nano:4b'; $size = '2.9 GB' }
                if (Ask "Download the AI model for this PC ($model, $size)? It only happens once.") {
                    $ollama = FindOllama
                    if ($ollama) { & $ollama pull $model }
                    else {
                        Say 'Downloading (this can take a while)...'
                        Invoke-RestMethod "$ollamaUrl/api/pull" -Method Post -Body (@{ name = $model; stream = $false } | ConvertTo-Json) -TimeoutSec 7200 | Out-Null
                    }
                } else { Say "Skipped. You can download one later: Fixaro's menu > Settings > Download a model..." }
            } else {
                Say "Ollama isn't running, so this is skipped. Later: Fixaro's menu > Settings > Download a model..."
            }
        }

        Start-Process "$dest\Fixaro.exe"
        if ($update) { Say 'Done.' }
        else {
            Step 'Fixaro is installed'
            Say 'Look for the F icon near the clock (it may be under the ^ arrow).'
            Say 'Select text in any app and press Ctrl+Alt+R to polish it, or Ctrl+Alt+S to rewrite it your way.'
            Say "Fixaro tells you in its menu when there's an update."
            Write-Host ''
        }
    } catch {
        Write-Host ''
        Write-Host "  $($_.Exception.Message)" -ForegroundColor Red
    } finally {
        Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
    }
}
