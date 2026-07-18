$ErrorActionPreference = 'SilentlyContinue'

# Force UTF-8 output so emoji / box-drawing characters render correctly
# even under Windows PowerShell 5.1 (powershell.exe).
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::InputEncoding = [System.Text.Encoding]::UTF8

# Icons constructed from code points so this .ps1 stays ASCII-safe
# (avoids encoding mishaps when the file is read without a BOM).
$I_MODEL   = [char]0x2726                              # sparkle
$I_FOLDER  = [System.Char]::ConvertFromUtf32(0x1F4C1)  # file folder
$I_BRANCH  = [char]0x26A1                              # high voltage
$I_ACTIVE  = [char]0x25CF                              # bullet (current session marker)
$I_DOT     = [char]0x00B7                              # middle dot
$BAR_FULL  = [char]0x2588                              # full block
$BAR_LIGHT = [char]0x2591                              # light shade

# ---------- Parse Claude Code input ----------
$raw = [Console]::In.ReadToEnd()
$j = $raw | ConvertFrom-Json

# ---------- Model (strip "Claude " prefix) ----------
$modelName = if ($j.model.display_name) { $j.model.display_name } else { $j.model.id }
$modelName = $modelName -replace '^Claude\s+', ''

# ---------- Current directory ----------
$cwd = if ($j.workspace.current_dir) { $j.workspace.current_dir } else { $j.cwd }
$dir = Split-Path -Leaf $cwd
if (-not $dir) { $dir = $cwd }

# ---------- Current session id (parsed from transcript path) ----------
$currentSessionId = $null
if ($j.transcript_path) {
    $currentSessionId = [System.IO.Path]::GetFileNameWithoutExtension($j.transcript_path)
}

# ---------- Git branch (optional) ----------
$branch = $null
if ($cwd -and (Test-Path $cwd)) {
    try {
        Push-Location $cwd
        $b = git rev-parse --abbrev-ref HEAD 2>$null
        if ($LASTEXITCODE -eq 0 -and $b) { $branch = $b.Trim() }
        Pop-Location
    } catch {}
}

# ---------- Context usage ----------
$ctxPct = $null
if ($null -ne $j.context_window -and $null -ne $j.context_window.used_percentage) {
    $ctxPct = [int][math]::Round([double]$j.context_window.used_percentage)
} else {
    $ctxMax = 200000
    if ($j.model.id -match '1m') { $ctxMax = 1000000 }
    if ($j.transcript_path -and (Test-Path $j.transcript_path)) {
        $lines = Get-Content $j.transcript_path -Tail 80 -Encoding UTF8
        for ($i = $lines.Count - 1; $i -ge 0; $i--) {
            try {
                $entry = $lines[$i] | ConvertFrom-Json -ErrorAction Stop
                $u = $entry.message.usage
                if ($u -and $u.input_tokens) {
                    $total = [int64]$u.input_tokens + `
                             [int64]$u.cache_read_input_tokens + `
                             [int64]$u.cache_creation_input_tokens
                    $ctxPct = [int][math]::Round(($total / $ctxMax) * 100)
                    break
                }
            } catch { continue }
        }
    }
}

# ---------- Progress bar (8 cells) ----------
$barWidth = 8
if ($null -ne $ctxPct) {
    $filled = [int][math]::Floor($barWidth * $ctxPct / 100)
    if ($filled -gt $barWidth) { $filled = $barWidth }
    if ($filled -lt 0)         { $filled = 0 }
    $bar = ($BAR_FULL.ToString() * $filled) + ($BAR_LIGHT.ToString() * ($barWidth - $filled))
    $ctxStr = "$bar $ctxPct%"
} else {
    $bar = $BAR_LIGHT.ToString() * $barWidth
    $ctxStr = "$bar --"
}

# ---------- Helper: slugify a cwd to Claude Code's projects-dir name ----------
function Convert-CwdToSlug([string]$path) {
    if (-not $path) { return $null }
    return ($path -replace '[:\\.]', '-')
}

# ---------- Helper: extract a short title from a transcript file ----------
#   Reads only the first ~60 lines, skips wrappers / command stdout,
#   returns the first real user-typed sentence (truncated).
function Get-SessionTitle([string]$transcriptPath, [int]$maxLen = 28) {
    if (-not $transcriptPath -or -not (Test-Path $transcriptPath)) { return $null }
    try {
        $head = Get-Content $transcriptPath -TotalCount 60 -Encoding UTF8 -ErrorAction Stop
    } catch { return $null }

    foreach ($line in $head) {
        try {
            $entry = $line | ConvertFrom-Json -ErrorAction Stop
        } catch { continue }

        if ($entry.type -ne 'user') { continue }
        $content = $entry.message.content
        if (-not $content) { continue }

        # content may be a plain string or an array of blocks
        $text = $null
        if ($content -is [string]) {
            $text = $content
        } elseif ($content -is [System.Collections.IEnumerable]) {
            foreach ($block in $content) {
                if ($block.type -eq 'text' -and $block.text) { $text = $block.text; break }
            }
        }
        if (-not $text) { continue }

        # Skip wrapper / synthetic messages
        if ($text -match '^<(local-command|system-reminder|command-name|command-message|command-args)') { continue }
        if ($text -match '^\s*$') { continue }

        # Strip leading tag prefixes like "<some-tag>...</some-tag>\nActual text"
        $cleaned = ($text -replace '<[^>]+>[\s\S]*?</[^>]+>', '').Trim()
        if (-not $cleaned) { $cleaned = $text.Trim() }

        # Collapse whitespace and truncate
        $cleaned = ($cleaned -replace '\s+', ' ').Trim()
        if ($cleaned.Length -gt $maxLen) {
            $cleaned = $cleaned.Substring(0, $maxLen - 1) + [char]0x2026  # ellipsis
        }
        return $cleaned
    }
    return $null
}

# ---------- Today's sessions ----------
$sessionDir = Join-Path $env:USERPROFILE '.claude\sessions'
$projectsDir = Join-Path $env:USERPROFILE '.claude\projects'
$sessions = @()
$totalMs = [int64]0
$nowMs = [DateTimeOffset]::Now.ToUnixTimeMilliseconds()
$todayStartMs = ([DateTimeOffset]((Get-Date).Date)).ToUnixTimeMilliseconds()

if (Test-Path $sessionDir) {
    Get-ChildItem -Path $sessionDir -Filter '*.json' -ErrorAction SilentlyContinue | ForEach-Object {
        try {
            $s = Get-Content $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
            # 只保留 PID 還活著的 session（目前正在跑的），而非「今天開的」
            # —— 跨夜 session 不會被誤過濾。
            if ($null -eq $s.pid) { return }
            if (-not (Get-Process -Id $s.pid -ErrorAction SilentlyContinue)) { return }

            if ($null -ne $s.startedAt) {
                # 對跨夜 session，只累計「今天這一段」的時間
                $startForToday = [int64]$s.startedAt
                if ($startForToday -lt $todayStartMs) { $startForToday = $todayStartMs }
                $elapsed = $nowMs - $startForToday
                if ($elapsed -gt 0) { $totalMs += $elapsed }
            }

            $slug = Convert-CwdToSlug $s.cwd
            $tPath = if ($slug) { Join-Path (Join-Path $projectsDir $slug) ("{0}.jsonl" -f $s.sessionId) } else { $null }
            $title = Get-SessionTitle $tPath

            $sessions += [PSCustomObject]@{
                SessionId = $s.sessionId
                ShortId   = if ($s.sessionId) { $s.sessionId.Substring(0, 8) } else { '????????' }
                Cwd       = $s.cwd
                CwdName   = if ($s.cwd) { Split-Path -Leaf $s.cwd } else { '?' }
                StartedAt = [int64]$s.startedAt
                Title     = $title
            }
        } catch {}
    }
}

# Sort sessions: current one first, then by start time (newest first).
# Wrap with @(...) to keep it an array even when only one session exists
# (PowerShell auto-unwraps single-element collections, breaking .Count).
$sessions = @($sessions | Sort-Object `
    @{Expression = { if ($_.SessionId -eq $currentSessionId) { 0 } else { 1 } }},
    @{Expression = { -$_.StartedAt }})

$sessionCount = $sessions.Count

# Format today's elapsed time
$totalMin = [int][math]::Floor($totalMs / 60000)
$hours = [int][math]::Floor($totalMin / 60)
$mins  = $totalMin % 60
$timeStr = if ($hours -gt 0) { "${hours}h${mins}m" } else { "${mins}m" }

# ---------- Compose line 1 (main status) ----------
$parts = @()
$parts += "$I_FOLDER $dir"
if ($branch) { $parts += "$I_BRANCH $branch" }
$left = $parts -join ' '

$sessionLabel = if ($sessionCount -eq 1) { 'session' } else { 'sessions' }
$currentSession = $sessions | Where-Object { $_.SessionId -eq $currentSessionId } | Select-Object -First 1
if ($currentSession) {
	$label = if ($currentSession.Title) { $currentSession.Title } else { $currentSession.CwdName }
	$line1 = "[$I_MODEL $modelName] $ctxStr | $timeStr [$sessionCount $sessionLabel] | $I_ACTIVE $label"
} else {
	$line1 = "[$I_MODEL $modelName] $ctxStr | $timeStr [$sessionCount $sessionLabel]"
}
# ---------- Compose line 2 (current session only) ----------
# 只顯示當前 session 的標題與 short id，其他 session 的數量由 line 1 的
# `[N sessions]` 標示，細節不列。
$line2 = $null
if ($currentSession) {    
    $line2 = "$left $I_DOT $($currentSession.SessionId)"
}

# ---------- Output ----------
if ($line2) {
    [Console]::Out.Write("$line1`n$line2")
} else {
    [Console]::Out.Write($line1)
}
