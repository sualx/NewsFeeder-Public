# NewsFeeder — security news reader + URL-change watcher. Tray app with top-right popups.
# Design: docs/PHASE0-RESEARCH.md. House rules: feeds are hostile input (text-only, no DTD,
# no active content), polite fetching (honest UA, conditional requests, interval floors),
# no silent failures, cannot destroy user data (writes only its own state files, atomically).

param(
    [switch]$SelfTest,
    [switch]$Installed
)

$ErrorActionPreference = 'Stop'

$script:AppName   = 'NewsFeeder'
$script:BaseDir   = $PSScriptRoot
$script:DataDir   = if ($Installed) { Join-Path $env:LOCALAPPDATA $script:AppName } else { Join-Path $PSScriptRoot 'data' }
$script:UserAgent = 'NewsFeeder/1.0 (personal Windows desktop news reader)'
$script:MinFeedIntervalMin = 15   # polite floor for news feeds
$script:MinUrlIntervalMin  = 5    # polite floor for watched URLs

# ---------- state files (all app-owned, written atomically) ----------

function Read-JsonFile([string]$Path, $Default) {
    if (-not (Test-Path $Path)) { return $Default }
    try { return Get-Content $Path -Raw | ConvertFrom-Json -AsHashtable }
    catch { return $Default }   # corrupt state file: start fresh rather than crash
}

function Save-JsonFile([string]$Path, $Object) {
    # temp-then-replace so a crash mid-write can never destroy the previous state
    $tmp = "$Path.tmp"
    $Object | ConvertTo-Json -Depth 8 | Set-Content $tmp -Encoding UTF8
    Move-Item $tmp $Path -Force
}

function Get-DefaultSettings {
    $allIds = @($script:Catalog | ForEach-Object { $_.id })
    @{
        enabledFeeds        = $allIds
        enabledModes        = @('security', 'goodnews', 'science')
        feedMode            = 'all'   # retained for migration from versions before multi-mode
        feedIntervalMinutes = 30
        startWithWindows    = $false
        startMinimized      = $false
        showPopups          = $true
        playSound           = $true
        watchedUrls         = @()   # each: @{ url = ...; intervalMinutes = ...; category = ... }
    }
}

function Load-AllState {
    if (-not (Test-Path $script:DataDir)) { New-Item $script:DataDir -ItemType Directory | Out-Null }

    $catalogPath = Join-Path $script:BaseDir 'feeds.json'
    if (-not (Test-Path $catalogPath)) { throw "feeds.json is missing next to NewsFeeder.ps1" }
    $script:Catalog = @((Get-Content $catalogPath -Raw | ConvertFrom-Json).feeds)

    $script:Settings = Read-JsonFile (Join-Path $script:DataDir 'settings.json') (Get-DefaultSettings)
    $hadEnabledModes = $script:Settings.ContainsKey('enabledModes')
    foreach ($k in (Get-DefaultSettings).Keys) {   # fill any keys missing from older files
        if (-not $script:Settings.ContainsKey($k)) { $script:Settings[$k] = (Get-DefaultSettings)[$k] }
    }
    if (-not $hadEnabledModes) {
        $script:Settings.enabledModes = switch ([string]$script:Settings.feedMode) {
            'security' { @('security') }
            'goodnews' { @('goodnews') }
            'science'  { @('science') }
            default    { @('security', 'goodnews', 'science') }
        }
    }
    $validModes = @('security', 'goodnews', 'science')
    $script:Settings.enabledModes = @($script:Settings.enabledModes | Where-Object { $_ -in $validModes } | Select-Object -Unique)
    if ($script:Settings.enabledModes.Count -eq 0) { $script:Settings.enabledModes = $validModes }
    if (@($script:Settings.enabledFeeds).Count -eq 0) {
        $script:Settings.enabledFeeds = @($script:Catalog | ForEach-Object { $_.id })
        Save-JsonFile (Join-Path $script:DataDir 'settings.json') $script:Settings
    }
    $script:Seen     = Read-JsonFile (Join-Path $script:DataDir 'seen.json')     @{}
    $script:UrlState = Read-JsonFile (Join-Path $script:DataDir 'urlstate.json') @{}
    $script:History  = @(Read-JsonFile (Join-Path $script:DataDir 'history.json') @())
}

function Save-Settings { Save-JsonFile (Join-Path $script:DataDir 'settings.json') $script:Settings }
function Save-Seen     { Save-JsonFile (Join-Path $script:DataDir 'seen.json')     $script:Seen }
function Save-UrlState { Save-JsonFile (Join-Path $script:DataDir 'urlstate.json') $script:UrlState }
function Save-History  { Save-JsonFile (Join-Path $script:DataDir 'history.json')  $script:History }

# ---------- text helpers (feeds are hostile input: reduce everything to plain text) ----------

function ConvertTo-PlainText([string]$Html) {
    if ([string]::IsNullOrWhiteSpace($Html)) { return '' }
    $t = $Html -replace '(?s)<script.*?</script>', '' -replace '(?s)<style.*?</style>', ''
    $t = $t -replace '<[^>]+>', ' '
    $t = [System.Net.WebUtility]::HtmlDecode($t)
    return ($t -replace '\s+', ' ').Trim()
}

function Get-NormalizedPageHash([string]$Html) {
    # strip markup, collapse whitespace, hash — so timestamps in markup/ads don't count,
    # but any visible text change does
    $text = ConvertTo-PlainText $Html
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return [Convert]::ToHexString($sha.ComputeHash($bytes)) } finally { $sha.Dispose() }
}

# ---------- defensive feed parsing (RSS 2.0 + Atom; DTD prohibited, no resolver = no XXE) ----------

function Parse-Feed([string]$Xml) {
    $rs = New-Object System.Xml.XmlReaderSettings
    $rs.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit
    $rs.XmlResolver = $null
    $rs.MaxCharactersInDocument = 20MB
    $reader = [System.Xml.XmlReader]::Create((New-Object System.IO.StringReader($Xml)), $rs)
    $doc = New-Object System.Xml.XmlDocument
    try { $doc.Load($reader) } finally { $reader.Dispose() }

    $items = @()
    $nodes = $doc.GetElementsByTagName('item')                       # RSS
    if ($nodes.Count -eq 0) { $nodes = $doc.GetElementsByTagName('entry') }  # Atom
    foreach ($n in $nodes) {
        $title = ''; $link = ''; $id = ''; $date = ''; $cats = @()
        foreach ($c in $n.ChildNodes) {
            switch ($c.LocalName) {
                'title'    { $title = ConvertTo-PlainText $c.InnerText }
                'link'     {
                    if ($c.Attributes -and $c.Attributes['href']) {
                        $rel = if ($c.Attributes['rel']) { $c.Attributes['rel'].Value } else { 'alternate' }
                        if ($rel -eq 'alternate' -or -not $link) { $link = $c.Attributes['href'].Value }
                    } elseif (-not $link) { $link = $c.InnerText.Trim() }
                }
                'guid'     { $id = $c.InnerText.Trim() }
                'id'       { $id = $c.InnerText.Trim() }
                'pubDate'  { $date = $c.InnerText.Trim() }
                'updated'  { if (-not $date) { $date = $c.InnerText.Trim() } }
                'published'{ $date = $c.InnerText.Trim() }
                'category' {
                    $catText = if ($c.Attributes -and $c.Attributes['term']) { $c.Attributes['term'].Value } else { $c.InnerText }
                    $catText = (ConvertTo-PlainText $catText)
                    if ($catText) { $cats += $catText }
                }
            }
        }
        if (-not $id) { $id = $link }
        if (-not $title -and -not $link) { continue }   # ignore junk entries
        $items += [pscustomobject]@{
            Title    = $title
            Link     = $link.Trim()
            Id       = $id
            Date     = $date
            Category = (($cats | Select-Object -First 2) -join ', ')
        }
    }
    return @($items)
}

# ---------- HTTP (single client, honest UA, size cap, decompression) ----------

function New-HttpClient {
    $handler = New-Object System.Net.Http.SocketsHttpHandler
    $handler.AutomaticDecompression = [System.Net.DecompressionMethods]::All
    $handler.AllowAutoRedirect = $true
    $handler.MaxAutomaticRedirections = 5
    $client = New-Object System.Net.Http.HttpClient($handler)
    $client.Timeout = [TimeSpan]::FromSeconds(25)
    $client.MaxResponseContentBufferSize = 10MB
    $client.DefaultRequestHeaders.UserAgent.ParseAdd($script:UserAgent) | Out-Null
    return $client
}

function Start-Fetch($Source) {
    # returns the async task; conditional headers make unchanged checks nearly free for the site
    $req = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Get, $Source.Url)
    if ($Source.Kind -eq 'url') {
        $st = $script:UrlState[$Source.Url]
        if ($st) {
            if ($st.etag)         { $req.Headers.TryAddWithoutValidation('If-None-Match', $st.etag) | Out-Null }
            if ($st.lastModified) { $req.Headers.TryAddWithoutValidation('If-Modified-Since', $st.lastModified) | Out-Null }
        }
    }
    return $script:Http.SendAsync($req, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead)
}

# ---------- scheduler sources ----------

function Rebuild-Sources {
    $now = Get-Date
    $old = @{}
    if ($script:Sources) { foreach ($s in $script:Sources) { $old[$s.Key] = $s } }
    $list = [System.Collections.ArrayList]::new()

    $activeModes = @($script:Settings.enabledModes)
    foreach ($f in $script:Catalog) {
        if ($script:Settings.enabledFeeds -notcontains $f.id) { continue }
        $grp = [string]$f.group
        if ($activeModes -notcontains $grp) { continue }
        $key = "feed|$($f.id)"
        $due = if ($old[$key]) { $old[$key].NextDue } else { $now }
        [void]$list.Add([pscustomobject]@{
            Key = $key; Kind = 'feed'; Id = $f.id; Name = $f.name; Url = $f.url
            IntervalMin = [math]::Max($script:MinFeedIntervalMin, [int]$script:Settings.feedIntervalMinutes)
            NextDue = $due; InFlight = $false; LastError = ''
        })
    }
    foreach ($w in @($script:Settings.watchedUrls)) {
        $key = "url|$($w.url)"
        $due = if ($old[$key]) { $old[$key].NextDue } else { $now }
        [void]$list.Add([pscustomobject]@{
            Key = $key; Kind = 'url'; Id = $w.url; Name = $w.url; Url = $w.url
            Category = [string]$w.category
            IntervalMin = [math]::Max($script:MinUrlIntervalMin, [int]$w.intervalMinutes)
            NextDue = $due; InFlight = $false; LastError = ''
        })
    }
    $script:Sources = $list
}

# ---------- event recording ----------

function Add-Event([string]$Kind, [string]$SourceName, [string]$Title, [string]$Link, [string]$Category, [bool]$Notify) {
    $ev = @{
        time     = (Get-Date).ToString('yyyy-MM-dd HH:mm')
        kind     = $Kind          # 'news' | 'change' | 'info' | 'error'
        source   = $SourceName
        title    = $Title
        link     = $Link
        category = $Category
    }
    $script:History = @($ev) + $script:History
    if ($script:History.Count -gt 2000) { $script:History = $script:History[0..1999] }
    if ($script:ListView) { Add-EventToList $ev $true }
    if ($Notify -and $script:Settings.showPopups) { $script:PopupQueue.Enqueue($ev) }
}

# ---------- result processing ----------

function Process-FeedResult($Source, [string]$Body) {
    $items = Parse-Feed $Body
    if ($items.Count -eq 0) { throw "feed returned no readable items" }

    $prefix = "$($Source.Id)|"
    $baseline = -not ($script:Seen.Keys | Where-Object { $_.StartsWith($prefix) } | Select-Object -First 1)
    $newCount = 0
    # oldest first so history/popups come out in natural order
    foreach ($it in ($items[($items.Count-1)..0])) {
        $key = $prefix + $(if ($it.Id) { $it.Id } else { $it.Title })
        if ($script:Seen.ContainsKey($key)) { continue }
        $script:Seen[$key] = (Get-Date).ToString('s')
        $newCount++
        Add-Event 'news' $Source.Name $it.Title $it.Link $it.Category (-not $baseline)
    }
    if ($newCount -gt 0) {
        # prune seen store so it can't grow forever
        if ($script:Seen.Count -gt 8000) {
            $drop = $script:Seen.GetEnumerator() | Sort-Object Value | Select-Object -First ($script:Seen.Count - 6000)
            foreach ($d in $drop) { $script:Seen.Remove($d.Key) }
        }
        Save-Seen; Save-History
    }
    return $newCount
}

function Process-UrlResult($Source, $Response) {
    $url = $Source.Url
    $st = $script:UrlState[$url]
    if (-not $st) { $st = @{}; $script:UrlState[$url] = $st }

    if ([int]$Response.StatusCode -eq 304) { return 0 }   # server says: unchanged

    $body = $Response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    $hash = Get-NormalizedPageHash $body
    $et = $Response.Headers.ETag
    $st.etag = if ($et) { $et.ToString() } else { $null }
    $lm = $Response.Content.Headers.LastModified   # PS unwraps the nullable: DateTimeOffset or $null
    $st.lastModified = if ($lm) { $lm.ToString('R') } else { $null }

    $changed = 0
    $cat = [string]$Source.Category
    if (-not $st.hash) {
        Add-Event 'info' $url 'Now watching this page for changes' $url $cat $false
    } elseif ($st.hash -ne $hash) {
        $st.lastChanged = (Get-Date).ToString('s')
        Add-Event 'change' $url 'Page content changed' $url $cat $true
        $changed = 1
    }
    $saveHist = ($changed -or -not $st.lastChecked)   # first check or a real change
    $st.hash = $hash
    $st.lastChecked = (Get-Date).ToString('s')
    Save-UrlState
    if ($saveHist) { Save-History }
    return $changed
}

function Complete-Fetch($Pending) {
    $src = $Pending.Source
    $src.InFlight = $false
    $t = $Pending.Task
    try {
        if ($t.IsFaulted) {
            $inner = $t.Exception.InnerException
            $msg = if ($inner) { $inner.Message } else { $t.Exception.Message }
            throw ("network problem: " + $msg)
        }
        $resp = $t.Result
        try {
            $status = [int]$resp.StatusCode
            if ($src.Kind -eq 'url') {
                if ($status -ne 304 -and -not $resp.IsSuccessStatusCode) { throw "HTTP $status" }
                [void](Process-UrlResult $src $resp)
            } else {
                if (-not $resp.IsSuccessStatusCode) { throw "HTTP $status" }
                $body = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
                [void](Process-FeedResult $src $body)
            }
            if ($src.LastError) {   # recovered: say so, once
                Add-Event 'info' $src.Name 'Source is reachable again' $src.Url '' $false
                Save-History
            }
            $src.LastError = ''
        } finally { $resp.Dispose() }
    } catch {
        $err = "$_"
        if ($src.LastError -ne $err) {   # report each distinct problem once, not every cycle
            $src.LastError = $err
            Add-Event 'error' $src.Name "Could not check: $err" $src.Url '' $false
            Save-History
        }
    }
    $src.NextDue = (Get-Date).AddMinutes($src.IntervalMin)
}

# ---------- self-test mode (runs in console, no GUI) ----------

if ($SelfTest) {
    Load-AllState
    $script:Http = New-HttpClient
    Write-Host '== feed mode selection test =='
    $savedModes = @($script:Settings.enabledModes)
    $modeCombinations = @('security', 'goodnews', 'science', 'security,goodnews', 'security,science', 'goodnews,science', 'security,goodnews,science')
    foreach ($combination in $modeCombinations) {
        $modes = @($combination -split ',')
        $script:Settings.enabledModes = @($modes)
        Rebuild-Sources
        $expected = @($script:Catalog | Where-Object group -in $modes).Count
        $actual = @($script:Sources | Where-Object Kind -eq 'feed').Count
        $label = $modes -join ' + '
        if ($actual -ne $expected) { throw "Feed modes '$label' selected $actual sources; expected $expected" }
        Write-Host ("  OK   {0,-31} {1,2} feeds" -f $label, $actual)
    }
    $script:Settings.enabledModes = $savedModes

    Write-Host "== fetch/parse test: all $($script:Catalog.Count) catalog feeds =="
    foreach ($f in $script:Catalog) {
        try {
            $resp = $script:Http.GetAsync($f.url).GetAwaiter().GetResult()
            $items = Parse-Feed ($resp.Content.ReadAsStringAsync().GetAwaiter().GetResult())
            $first = ($items | Select-Object -First 1).Title
            Write-Host ("  OK   {0,-28} HTTP {1}  {2,3} items  e.g. {3}" -f $f.name, [int]$resp.StatusCode, $items.Count, $first)
        } catch {
            Write-Host ("  FAIL {0,-28} {1}" -f $f.name, $_)
        }
    }

    Write-Host "`n== URL normalize/hash test: example.com =="
    $resp2 = $script:Http.GetAsync('https://example.com/').GetAwaiter().GetResult()
    $body2 = $resp2.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    $h1 = Get-NormalizedPageHash $body2
    $h2 = Get-NormalizedPageHash ($body2 -replace 'href="[^"]*"', 'href="x"')  # markup-only change
    Write-Host "hash: $($h1.Substring(0,16))…  markup-only change alters hash: $($h1 -ne $h2) (want False)"
    $h3 = Get-NormalizedPageHash ($body2 -replace 'Example', 'Changed')
    Write-Host "visible-text change alters hash: $($h1 -ne $h3) (want True)"
    exit 0
}

# ---------- GUI from here on ----------

# Hide our own console (launcher starts it minimized; -WindowStyle Hidden would hide the app too)
Add-Type -Name Win -Namespace Native -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
[DllImport("user32.dll")]   public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
[DllImport("user32.dll")]   public static extern IntPtr GetWindowLongPtr(IntPtr hWnd, int nIndex);
[DllImport("user32.dll")]   public static extern IntPtr SetWindowLongPtr(IntPtr hWnd, int nIndex, IntPtr dwNewLong);
[DllImport("shell32.dll", CharSet=CharSet.Unicode)] public static extern uint ExtractIconExW(string lpszFile, int nIconIndex, out IntPtr phiconLarge, out IntPtr phiconSmall, uint nIcons);
[DllImport("user32.dll", SetLastError=true)] public static extern bool SystemParametersInfo(uint uiAction, uint uiParam, ref bool pvParam, uint fWinIni);
[DllImport("user32.dll", SetLastError=true)] public static extern IntPtr OpenInputDesktop(uint dwFlags, bool fInherit, uint dwDesiredAccess);
[DllImport("user32.dll", SetLastError=true)] public static extern bool CloseDesktop(IntPtr hDesktop);
'@
[Native.Win]::ShowWindow([Native.Win]::GetConsoleWindow(), 0) | Out-Null

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
try { [System.Windows.Forms.Application]::SetHighDpiMode([System.Windows.Forms.HighDpiMode]::SystemAware) | Out-Null } catch {}
[System.Windows.Forms.Application]::EnableVisualStyles()

# no silent failures, and no raw .NET crash box either: log the detail, tell the user plainly
function Write-ErrorLog([string]$Where, $Problem) {
    try {
        if (-not (Test-Path $script:DataDir)) { New-Item $script:DataDir -ItemType Directory | Out-Null }
        $detail = if ($Problem -is [System.Management.Automation.ErrorRecord]) {
            "$($Problem.Exception.GetType().Name): $($Problem.Exception.Message)`n$($Problem.ScriptStackTrace)`nat $($Problem.InvocationInfo.PositionMessage)"
        } else { "$Problem" }
        Add-Content (Join-Path $script:DataDir 'errors.log') "[$(Get-Date -Format 's')] $Where`n$detail`n"
    } catch {}
}

[System.Windows.Forms.Application]::add_ThreadException({
    param($sender, $e)
    Write-ErrorLog 'UI thread' $e.Exception
    [System.Windows.Forms.MessageBox]::Show(
        "NewsFeeder hit a problem but is still running.`n`n$($e.Exception.Message)`n`nDetails were written to data\errors.log.",
        'NewsFeeder — problem', 'OK', 'Warning') | Out-Null
})
[System.Windows.Forms.Application]::SetUnhandledExceptionMode([System.Windows.Forms.UnhandledExceptionMode]::CatchException)


# one icon everywhere, extracted from the Windows shell icon library (#244)
$script:AppIcon = $null
try {
    $hLarge = [IntPtr]::Zero; $hSmall = [IntPtr]::Zero
    if ([Native.Win]::ExtractIconExW("$env:windir\System32\SHELL32.dll", 244, [ref]$hLarge, [ref]$hSmall, 1) -gt 0 -and $hLarge -ne [IntPtr]::Zero) {
        $script:AppIcon = [System.Drawing.Icon]::FromHandle($hLarge)
    }
} catch {}
if (-not $script:AppIcon) { $script:AppIcon = [System.Drawing.SystemIcons]::Information }

# single instance: launching again while running (even hidden in tray) surfaces the
# existing window instead of starting a rival copy that fights over the state files
$script:InstanceMutex = New-Object System.Threading.Mutex($false, 'Local\NewsFeederSingleInstance')
if (-not $script:InstanceMutex.WaitOne(0)) {
    Add-Type -Name Win2 -Namespace Native -MemberDefinition '
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
[DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr FindWindowW(string cls, string title);'
    $h = [Native.Win2]::FindWindowW($null, "$script:AppName — news & watched pages")
    if ($h -ne [IntPtr]::Zero) {
        [Native.Win]::ShowWindow($h, 9) | Out-Null   # SW_RESTORE
        [Native.Win2]::SetForegroundWindow($h) | Out-Null
    }
    exit 0
}

Load-AllState
$script:Http = New-HttpClient
$script:Pending = [System.Collections.ArrayList]::new()
$script:PopupQueue = [System.Collections.Queue]::new()
$script:Popups = [System.Collections.ArrayList]::new()
$script:ExitRequested = $false
Rebuild-Sources

# ---------- top-right popup (custom window: the one route that guarantees position) ----------

$WS_EX_NOACTIVATE_TOOLWINDOW = 0x08000080
$SW_SHOWNOACTIVATE = 4

function Open-Link([string]$Url) {
    # http/https only: feeds are hostile input, never hand anything else to the shell
    if ($Url -match '^https?://') { Start-Process $Url }
}

function Show-Popup([string]$Caption, [string]$Body, [string]$Link) {
    $f = New-Object System.Windows.Forms.Form
    $f.Font = New-Object System.Drawing.Font('Segoe UI', 9.5)
    $f.FormBorderStyle = 'None'; $f.ShowInTaskbar = $false; $f.TopMost = $true
    $f.StartPosition = 'Manual'
    $f.BackColor = [System.Drawing.Color]::FromArgb(32, 36, 44)

    # sizes derived from the real rendered text, so nothing clips at any display scaling
    $line = [System.Windows.Forms.TextRenderer]::MeasureText('Ag', $f.Font).Height
    $m = [int]($line * 0.8)                     # margin
    $wide = [int]($line * 24)                   # popup width

    $capFont = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    $lblCap = New-Object System.Windows.Forms.Label
    $lblCap.Text = $Caption; $lblCap.ForeColor = [System.Drawing.Color]::FromArgb(120, 190, 255)
    $lblCap.Font = $capFont
    $lblCap.AutoEllipsis = $true; $lblCap.AutoSize = $false
    $capH = [System.Windows.Forms.TextRenderer]::MeasureText('Ag', $capFont).Height + 2
    $lblCap.Location = New-Object System.Drawing.Point($m, $m)
    $lblCap.Size = New-Object System.Drawing.Size(($wide - 2 * $m - $line), $capH)
    $f.Controls.Add($lblCap)

    $lblBody = New-Object System.Windows.Forms.Label
    $lblBody.Text = $Body; $lblBody.ForeColor = [System.Drawing.Color]::White
    $lblBody.AutoEllipsis = $true; $lblBody.AutoSize = $false
    $lblBody.Location = New-Object System.Drawing.Point($m, ($lblCap.Bottom + [int]($m / 2)))
    $lblBody.Size = New-Object System.Drawing.Size(($wide - 2 * $m), (3 * $line))
    $f.Controls.Add($lblBody)

    $hasLink = $Link -match '^https?://'
    if ($hasLink) {
        $lblBody.ForeColor = [System.Drawing.Color]::FromArgb(150, 210, 255)
        $lblBody.Font = New-Object System.Drawing.Font($f.Font, [System.Drawing.FontStyle]::Underline)
        $lblBody.Cursor = [System.Windows.Forms.Cursors]::Hand
    }

    $f.ClientSize = New-Object System.Drawing.Size($wide, ($lblBody.Bottom + $m))

    $btnX = New-Object System.Windows.Forms.Label
    $btnX.Text = [char]0x2715; $btnX.ForeColor = [System.Drawing.Color]::Gray
    $btnX.AutoSize = $false; $btnX.TextAlign = 'MiddleCenter'
    $btnX.Size = New-Object System.Drawing.Size($line, $line)
    $btnX.Location = New-Object System.Drawing.Point(($wide - $line - [int]($m / 2)), [int]($m / 2))
    $f.Controls.Add($btnX)
    $btnX.BringToFront()

    $openApp = { Show-MainWindow; $f.Close() }.GetNewClosure()
    $f.Add_Click($openApp); $lblCap.Add_Click($openApp)
    if ($hasLink) {
        $url = $Link
        $lblBody.Add_Click({ Open-Link $url; $f.Close() }.GetNewClosure())
    } else {
        $lblBody.Add_Click($openApp)
    }
    $btnX.Add_Click({ $f.Close() }.GetNewClosure())

    # always the main screen: following the mouse put popups on the 100%-scaled monitor,
    # where coordinates from this 150%-scaled process land in the wrong place
    $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $idx = $script:Popups.Count
    $f.Location = New-Object System.Drawing.Point(
        ($wa.Right - $f.Width - $m),
        ($wa.Top + $m + $idx * ($f.Height + [int]($m / 2))))
    [void]$script:Popups.Add($f)
    # capture a local handle: $script: variables resolve to null inside GetNewClosure() closures
    $popupList = $script:Popups
    $f.Add_FormClosed({ [void]$popupList.Remove($f) }.GetNewClosure())

    # show WITHOUT stealing focus: no-activate window styles + SW_SHOWNOACTIVATE
    $h = $f.Handle
    $ex = [long][Native.Win]::GetWindowLongPtr($h, -20)
    [Native.Win]::SetWindowLongPtr($h, -20, [IntPtr]($ex -bor $WS_EX_NOACTIVATE_TOOLWINDOW)) | Out-Null
    [Native.Win]::ShowWindow($h, $SW_SHOWNOACTIVATE) | Out-Null

    $t = New-Object System.Windows.Forms.Timer
    $t.Interval = 240000   # 240 seconds (4 minutes)
    $t.Add_Tick({ $t.Stop(); $t.Dispose(); if (-not $f.IsDisposed) { $f.Close() } }.GetNewClosure())
    $t.Start()
}

# friendly built-in chime; falls back gracefully if a Windows install lacks the file
$script:NotifyWav = @(
    "$env:windir\Media\Windows Notify Messaging.wav",
    "$env:windir\Media\Windows Notify System Generic.wav",
    "$env:windir\Media\notify.wav"
) | Where-Object { Test-Path $_ } | Select-Object -First 1
$script:SoundPlayer = if ($script:NotifyWav) { New-Object System.Media.SoundPlayer($script:NotifyWav) } else { $null }

function Test-IsMutedForScreensaverOrLock {
    try {
        # 1. SPI_GETSCREENSAVERRUNNING (114): returns true if screensaver is actively running
        $ssRunning = $false
        [Native.Win]::SystemParametersInfo(114, 0, [ref]$ssRunning, 0) | Out-Null
        if ($ssRunning) { return $true }

        # 2. OpenInputDesktop: returns null handle (0) if screen is locked or on a secure desktop
        $hDesk = [Native.Win]::OpenInputDesktop(0, $false, 1)
        if ($hDesk -eq [IntPtr]::Zero) { return $true }
        [Native.Win]::CloseDesktop($hDesk) | Out-Null
        return $false
    } catch {
        return $false
    }
}

function Play-NotifySound {
    if (-not $script:Settings.playSound) { return }
    if (Test-IsMutedForScreensaverOrLock) { return }   # stay silent while screensaver/lock is active
    try {
        if ($script:SoundPlayer) { $script:SoundPlayer.Play() }   # async, non-blocking
        else { [System.Media.SystemSounds]::Asterisk.Play() }
    } catch {}   # sound is a nicety; a broken audio device must never break notifications
}

function Drain-PopupQueue {
    if ($script:PopupQueue.Count -eq 0) { return }
    Play-NotifySound   # once per batch, so bursts don't machine-gun the speakers
    if ($script:PopupQueue.Count -gt 3) {
        # burst: one summary popup instead of a popup storm
        $n = $script:PopupQueue.Count
        $sources = @($script:PopupQueue | ForEach-Object { $_.source } | Select-Object -Unique)
        $script:PopupQueue.Clear()
        Show-Popup "$script:AppName — $n new items" ($sources -join ', ') ''
    } else {
        while ($script:PopupQueue.Count -gt 0 -and $script:Popups.Count -lt 5) {
            $ev = $script:PopupQueue.Dequeue()
            # keep captions short: long ones used to wrap and disappear at high DPI
            if ($ev.kind -eq 'change') { $cap = 'Page changed'; $body = $ev.source }
            else { $cap = $ev.source; $body = $ev.title }
            if ($ev.category) { $cap = "[$($ev.category)] $cap" }
            Show-Popup $cap $body ([string]$ev.link)
        }
    }
}

# ---------- main window ----------

$script:Form = New-Object System.Windows.Forms.Form
$script:Form.Text = "$script:AppName — news & watched pages"
$script:Form.Icon = $script:AppIcon
$script:Form.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$script:Form.StartPosition = 'CenterScreen'

# everything below is measured from the real rendered font, so nothing clips at any scaling
$mwLine = [System.Windows.Forms.TextRenderer]::MeasureText('Ag', $script:Form.Font).Height
$mwK = [math]::Max(1.0, $mwLine / 15.0)
$MW = { param([double]$u) [int][math]::Round($u * $mwK) }
$script:Form.Size = New-Object System.Drawing.Size((& $MW 1125), (& $MW 700))
$script:Form.MinimumSize = New-Object System.Drawing.Size((& $MW 700), (& $MW 400))

function New-ToolbarButton([string]$Text, [int]$X, [int]$Y, [int]$H) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $Text
    # width from the measured text, never a guessed constant
    $b.Width = [System.Windows.Forms.TextRenderer]::MeasureText($Text, $b.Font).Width + $H
    $b.Location = New-Object System.Drawing.Point($X, $Y)
    $b.Height = $H
    return $b
}

$btnH = & $MW 30
$gapMW = & $MW 8
$toolbar = New-Object System.Windows.Forms.Panel
$toolbar.Dock = 'Top'; $toolbar.Height = 2 * $btnH + 3 * $gapMW

$btnCheck = New-ToolbarButton 'Check now' $gapMW $gapMW $btnH
$toolbar.Controls.Add($btnCheck)

$btnSettings = New-ToolbarButton 'Settings…' ($btnCheck.Right + $gapMW) $gapMW $btnH
$toolbar.Controls.Add($btnSettings)

$lblHint = New-Object System.Windows.Forms.Label
$lblHint.Text = 'Double-click an item to open it in your browser.'
$lblHint.AutoSize = $true
$lblHint.ForeColor = [System.Drawing.Color]::DimGray
$toolbar.Controls.Add($lblHint)
$lblHint.Location = New-Object System.Drawing.Point(
    ($btnSettings.Right + 2 * $gapMW),
    ($gapMW + [int](($btnH - $lblHint.Height) / 2)))

$filterY = 2 * $gapMW + $btnH
$lblModes = New-Object System.Windows.Forms.Label
$lblModes.Text = 'Show:'; $lblModes.AutoSize = $true
$toolbar.Controls.Add($lblModes)
$lblModes.Location = New-Object System.Drawing.Point($gapMW, ($filterY + [int](($btnH - $lblModes.Height) / 2)))

$chkSecurityMode = New-Object System.Windows.Forms.CheckBox
$chkSecurityMode.Text = 'Security'; $chkSecurityMode.AutoSize = $true
$chkSecurityMode.Checked = $script:Settings.enabledModes -contains 'security'
$chkSecurityMode.Location = New-Object System.Drawing.Point(($lblModes.Right + $gapMW), ($filterY + (& $MW 5)))
$toolbar.Controls.Add($chkSecurityMode)

$chkGoodNewsMode = New-Object System.Windows.Forms.CheckBox
$chkGoodNewsMode.Text = 'Good News'; $chkGoodNewsMode.AutoSize = $true
$chkGoodNewsMode.Checked = $script:Settings.enabledModes -contains 'goodnews'
$chkGoodNewsMode.Location = New-Object System.Drawing.Point(($chkSecurityMode.Right + $gapMW), ($filterY + (& $MW 5)))
$toolbar.Controls.Add($chkGoodNewsMode)

$chkScienceMode = New-Object System.Windows.Forms.CheckBox
$chkScienceMode.Text = 'Science'; $chkScienceMode.AutoSize = $true
$chkScienceMode.Checked = $script:Settings.enabledModes -contains 'science'
$chkScienceMode.Location = New-Object System.Drawing.Point(($chkGoodNewsMode.Right + $gapMW), ($filterY + (& $MW 5)))
$toolbar.Controls.Add($chkScienceMode)

$lblSearch = New-Object System.Windows.Forms.Label
$lblSearch.Text = 'Search:'; $lblSearch.AutoSize = $true
$toolbar.Controls.Add($lblSearch)
$lblSearch.Location = New-Object System.Drawing.Point(($chkScienceMode.Right + 2 * $gapMW), ($filterY + [int](($btnH - $lblSearch.Height) / 2)))

$txtSearch = New-Object System.Windows.Forms.TextBox
$txtSearch.PlaceholderText = 'Search downloaded news'
$txtSearch.Location = New-Object System.Drawing.Point(($lblSearch.Right + $gapMW), ($filterY + (& $MW 2)))
$txtSearch.Anchor = 'Top, Left, Right'
$toolbar.Controls.Add($txtSearch)
$resizeSearch = {
    $txtSearch.Width = [math]::Max((& $MW 140), $toolbar.ClientSize.Width - $txtSearch.Left - $gapMW)
}.GetNewClosure()
$toolbar.Add_Resize($resizeSearch)
& $resizeSearch

$script:ListView = New-Object System.Windows.Forms.ListView
$script:ListView.View = 'Details'; $script:ListView.FullRowSelect = $true
$script:ListView.Dock = 'Fill'; $script:ListView.HideSelection = $false
# Time column sized to the widest real timestamp so the date is never truncated
$timeW = [System.Windows.Forms.TextRenderer]::MeasureText('2026-08-13 09:99', $script:ListView.Font).Width + (& $MW 18)
[void]$script:ListView.Columns.Add('Time', $timeW)
[void]$script:ListView.Columns.Add('Source', (& $MW 190))
[void]$script:ListView.Columns.Add('Type', (& $MW 70))
[void]$script:ListView.Columns.Add('Mode', (& $MW 90))
[void]$script:ListView.Columns.Add('Title', (& $MW 460))
[void]$script:ListView.Columns.Add('Category', (& $MW 130))

$script:StatusBar = New-Object System.Windows.Forms.StatusStrip
$script:StatusLabel = New-Object System.Windows.Forms.ToolStripStatusLabel
$script:StatusLabel.Text = 'Starting…'
[void]$script:StatusBar.Items.Add($script:StatusLabel)

$script:Form.Controls.Add($script:ListView)
$script:Form.Controls.Add($toolbar)
$script:Form.Controls.Add($script:StatusBar)

function Get-FeedGroup([string]$SourceName) {
    $f = $script:Catalog | Where-Object { $_.name -eq $SourceName -or $_.id -eq $SourceName } | Select-Object -First 1
    if ($f) { return [string]$f.group }
    return ''
}

function Test-EventVisible($Ev) {
    $grp = if ($Ev.group) { [string]$Ev.group } else { Get-FeedGroup $Ev.source }
    if ($grp -and $script:Settings.enabledModes -notcontains $grp) { return $false }
    $query = $txtSearch.Text.Trim()
    if (-not $query) { return $true }
    if ($Ev.kind -ne 'news') { return $false }
    $text = @($Ev.source, $Ev.title, $Ev.category) -join ' '
    return $text.IndexOf($query, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
}

function Add-EventToList($Ev, [bool]$AtTop) {
    if (-not (Test-EventVisible $Ev)) { return }
    $li = New-Object System.Windows.Forms.ListViewItem($Ev.time)
    [void]$li.SubItems.Add([string]$Ev.source)
    [void]$li.SubItems.Add([string]$Ev.kind)
    $grp = if ($Ev.group) { [string]$Ev.group } else { Get-FeedGroup $Ev.source }
    $modeText = switch ($grp) { 'security' { 'Security' } 'goodnews' { 'Good News' } 'science' { 'Science' } default { '' } }
    [void]$li.SubItems.Add($modeText)
    [void]$li.SubItems.Add([string]$Ev.title)
    [void]$li.SubItems.Add([string]$Ev.category)
    $li.Tag = $Ev
    switch ($Ev.kind) {
        'change' { $li.ForeColor = [System.Drawing.Color]::DarkOrange }
        'error'  { $li.ForeColor = [System.Drawing.Color]::Firebrick }
        'info'   { $li.ForeColor = [System.Drawing.Color]::Gray }
    }
    if ($AtTop) { $script:ListView.Items.Insert(0, $li) } else { [void]$script:ListView.Items.Add($li) }
}

function Refresh-HistoryView {
    $script:ListView.BeginUpdate()
    try {
        $script:ListView.Items.Clear()
        foreach ($ev in $script:History) { Add-EventToList $ev $false }
    } finally { $script:ListView.EndUpdate() }
}

function Set-ActiveModesFromChecks($ChangedCheckBox) {
    $modes = @()
    if ($chkSecurityMode.Checked) { $modes += 'security' }
    if ($chkGoodNewsMode.Checked) { $modes += 'goodnews' }
    if ($chkScienceMode.Checked) { $modes += 'science' }
    if ($modes.Count -eq 0) {
        $ChangedCheckBox.Checked = $true
        return
    }
    $script:Settings.enabledModes = $modes
    $script:Settings.feedMode = if ($modes.Count -eq 1) { $modes[0] } else { 'all' }
    Save-Settings
    Rebuild-Sources
    Request-CheckNow
    Refresh-HistoryView
    Update-Status
}

$chkSecurityMode.Add_CheckedChanged({ Set-ActiveModesFromChecks $this })
$chkGoodNewsMode.Add_CheckedChanged({ Set-ActiveModesFromChecks $this })
$chkScienceMode.Add_CheckedChanged({ Set-ActiveModesFromChecks $this })
$txtSearch.Add_TextChanged({ Refresh-HistoryView; Update-Status })
Refresh-HistoryView

$script:ListView.Add_DoubleClick({
    if ($script:ListView.SelectedItems.Count -eq 0) { return }
    $link = [string]$script:ListView.SelectedItems[0].Tag.link
    if ($link -match '^https?://') { Start-Process $link }   # browser only, never execute
})

function Show-MainWindow {
    $script:Form.Show()
    if ($script:Form.WindowState -eq 'Minimized') { $script:Form.WindowState = 'Normal' }
    $script:Form.Activate()
}

# close button hides to tray; real exit only via tray menu
$script:Form.Add_FormClosing({
    param($s, $e)
    if (-not $script:ExitRequested -and $e.CloseReason -eq 'UserClosing') {
        $e.Cancel = $true
        $script:Form.Hide()
    }
})

# ---------- tray icon ----------

$script:Tray = New-Object System.Windows.Forms.NotifyIcon
$script:Tray.Icon = $script:AppIcon
$script:Tray.Text = $script:AppName
$script:Tray.Visible = $true

$trayMenu = New-Object System.Windows.Forms.ContextMenuStrip
[void]$trayMenu.Items.Add('Open NewsFeeder', $null, { Show-MainWindow })
[void]$trayMenu.Items.Add('Check now', $null, { Request-CheckNow })
[void]$trayMenu.Items.Add('Settings…', $null, { Show-SettingsDialog })
[void]$trayMenu.Items.Add('-')
[void]$trayMenu.Items.Add('Exit', $null, {
    $script:ExitRequested = $true
    $script:Tray.Visible = $false
    Save-History; Save-Seen; Save-UrlState
    [System.Windows.Forms.Application]::Exit()
})
$script:Tray.ContextMenuStrip = $trayMenu
$script:Tray.Add_DoubleClick({ Show-MainWindow })

# ---------- startup-with-Windows toggle (HKCU Run — no admin needed) ----------

$script:RunKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'

function Set-StartupEntry([bool]$Enable) {
    $vbsPath = Join-Path $script:BaseDir 'NewsFeeder.vbs'
    if ($Enable) {
        Set-ItemProperty -Path $script:RunKey -Name $script:AppName -Value "wscript.exe `"$vbsPath`""
    } else {
        Remove-ItemProperty -Path $script:RunKey -Name $script:AppName -ErrorAction SilentlyContinue
    }
}

# ---------- settings dialog ----------

function Show-SettingsDialog {
    $appName = $script:AppName   # closures below can't see $script: variables
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = "$script:AppName — Settings"
    $dlg.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    # WinForms auto-scaling proved unreliable in this PS-hosted context (fonts scaled,
    # positions didn't). So: measure the real rendered font and place everything
    # relative to actual control bottoms — overlap-proof at any display scaling.
    $dlg.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None
    $dlg.FormBorderStyle = 'FixedDialog'; $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false
    $dlg.StartPosition = 'CenterParent'

    $lineH = [System.Windows.Forms.TextRenderer]::MeasureText('Ag', $dlg.Font).Height
    $k = [math]::Max(1.0, $lineH / 15.0)          # 1.0 at 100% scaling, ~1.5 at 150%
    $S = { param([double]$u) [int][math]::Round($u * $k) }.GetNewClosure()
    $pad = & $S 12
    $w   = & $S 536

    $lbl1 = New-Object System.Windows.Forms.Label
    $lbl1.Text = 'Edit sources for:'
    $lbl1.AutoSize = $true; $lbl1.Location = New-Object System.Drawing.Point($pad, (& $S 12))
    $dlg.Controls.Add($lbl1)

    $cboMode = New-Object System.Windows.Forms.ComboBox
    $cboMode.DropDownStyle = 'DropDownList'
    [void]$cboMode.Items.Add('Security — cyber threats & advisories')
    [void]$cboMode.Items.Add('Good News — kittens & uplifting')
    [void]$cboMode.Items.Add('Science — discoveries & breakthroughs')
    [void]$cboMode.Items.Add('All — everything')
    $modeMap = @('security', 'goodnews', 'science', 'all')
    $curMode = @($script:Settings.enabledModes)[0]
    $cboMode.SelectedIndex = [math]::Max(0, [array]::IndexOf($modeMap, $curMode))
    $cboMode.Location = New-Object System.Drawing.Point(($lbl1.Right + (& $S 8)), ($lbl1.Top - 2))
    $cboMode.Width = $w - $lbl1.Width - (& $S 8)
    $dlg.Controls.Add($cboMode)

    $lblSrc = New-Object System.Windows.Forms.Label
    $lblSrc.Text = 'Sources for this mode (tick the ones you want):'
    $lblSrc.AutoSize = $true; $lblSrc.Location = New-Object System.Drawing.Point($pad, ($cboMode.Bottom + (& $S 10)))
    $dlg.Controls.Add($lblSrc)

    $clb = New-Object System.Windows.Forms.CheckedListBox
    $clb.Location = New-Object System.Drawing.Point($pad, ($lblSrc.Bottom + (& $S 6)))
    $clb.Size = New-Object System.Drawing.Size($w, (& $S 165)); $clb.CheckOnClick = $true
    $clb.IntegralHeight = $false

    $dialogState = @{
        displayedMode = $curMode
        enabledFeeds = [System.Collections.ArrayList]@($script:Settings.enabledFeeds)
    }

    $saveDisplayedChecks = {
        $displayedFeeds = @($script:Catalog | Where-Object {
            ($dialogState.displayedMode -eq 'all') -or ([string]$_.group -eq $dialogState.displayedMode)
        })
        foreach ($f in $displayedFeeds) { [void]$dialogState.enabledFeeds.Remove($f.id) }
        for ($i = 0; $i -lt [math]::Min($clb.Items.Count, $displayedFeeds.Count); $i++) {
            if ($clb.GetItemChecked($i)) { [void]$dialogState.enabledFeeds.Add($displayedFeeds[$i].id) }
        }
    }.GetNewClosure()

    $populateClb = {
        $clb.Items.Clear()
        $selMode = $modeMap[$cboMode.SelectedIndex]
        $dialogState.displayedMode = $selMode
        foreach ($f in $script:Catalog) {
            $grp = [string]$f.group
            if ($selMode -ne 'all' -and $grp -ne $selMode) { continue }
            $suffix = if ($f.categories) { '' } else { '  (no topic tags)' }
            $checked = $dialogState.enabledFeeds -contains $f.id
            [void]$clb.Items.Add("$($f.name)$suffix", $checked)
        }
    }.GetNewClosure()
    & $populateClb
    $cboMode.Add_SelectedIndexChanged({ & $saveDisplayedChecks; & $populateClb }.GetNewClosure())
    $dlg.Controls.Add($clb)

    $numFeed = New-Object System.Windows.Forms.NumericUpDown
    $numFeed.Width = (& $S 70)
    $numFeed.Location = New-Object System.Drawing.Point(($pad + $w - $numFeed.Width), ($clb.Bottom + (& $S 12)))
    $numFeed.Minimum = $script:MinFeedIntervalMin; $numFeed.Maximum = 1440
    $numFeed.Value = [math]::Max($script:MinFeedIntervalMin, [int]$script:Settings.feedIntervalMinutes)
    $dlg.Controls.Add($numFeed)
    $lbl2 = New-Object System.Windows.Forms.Label
    $lbl2.Text = "Check news every (minutes, min $($script:MinFeedIntervalMin)):"
    $lbl2.AutoSize = $true
    $dlg.Controls.Add($lbl2)
    $lbl2.Location = New-Object System.Drawing.Point($pad, ($numFeed.Top + [int](($numFeed.Height - $lbl2.Height) / 2)))

    $lbl3 = New-Object System.Windows.Forms.Label
    $lbl3.Text = 'Watched pages (get notified when the page text changes):'
    $lbl3.AutoSize = $true
    $lbl3.Location = New-Object System.Drawing.Point($pad, ($numFeed.Bottom + (& $S 14)))
    $dlg.Controls.Add($lbl3)

    $lstUrls = New-Object System.Windows.Forms.ListView
    $lstUrls.Location = New-Object System.Drawing.Point($pad, ($lbl3.Bottom + (& $S 6)))
    $lstUrls.Size = New-Object System.Drawing.Size($w, (& $S 110))
    $lstUrls.View = 'Details'; $lstUrls.FullRowSelect = $true; $lstUrls.HideSelection = $false
    $lstUrls.MultiSelect = $false
    [void]$lstUrls.Columns.Add('Web address', ($w - (& $S 150) - (& $S 70)))
    [void]$lstUrls.Columns.Add('Category', (& $S 150))
    [void]$lstUrls.Columns.Add('Every', (& $S 66))
    $dlgUrls = [System.Collections.ArrayList]::new()

    function Add-UrlRow($Entry) {
        $li = New-Object System.Windows.Forms.ListViewItem([string]$Entry.url)
        [void]$li.SubItems.Add([string]$Entry.category)
        [void]$li.SubItems.Add("$($Entry.intervalMinutes) min")
        [void]$lstUrls.Items.Add($li)
    }

    foreach ($wu in @($script:Settings.watchedUrls)) {
        $e = @{ url = $wu.url; intervalMinutes = $wu.intervalMinutes; category = [string]$wu.category }
        [void]$dlgUrls.Add($e)
        Add-UrlRow $e
    }
    $dlg.Controls.Add($lstUrls)

    # add-URL row: URL box takes whatever width the fixed-size controls leave over
    $rowY = $lstUrls.Bottom + (& $S 10)
    $gap = & $S 8
    $catW = & $S 130; $numW = & $S 64; $addW = & $S 64; $delW = & $S 80
    $txtW = $w - $catW - $numW - $addW - $delW - 4 * $gap
    $txtUrl = New-Object System.Windows.Forms.TextBox
    $txtUrl.Location = New-Object System.Drawing.Point($pad, $rowY)
    $txtUrl.Width = $txtW
    $txtUrl.PlaceholderText = 'https://…'
    $dlg.Controls.Add($txtUrl)

    # editable dropdown: pick a category you've used before, or just type a new one
    $cboCat = New-Object System.Windows.Forms.ComboBox
    $cboCat.Location = New-Object System.Drawing.Point(($pad + $txtW + $gap), $rowY)
    $cboCat.Width = $catW
    $cboCat.DropDownStyle = 'DropDown'
    $cboCat.AutoCompleteMode = 'SuggestAppend'; $cboCat.AutoCompleteSource = 'ListItems'
    foreach ($c in @('Security', 'News', 'Shopping', 'Work', 'Personal')) { [void]$cboCat.Items.Add($c) }
    foreach ($c in @($dlgUrls | ForEach-Object { $_.category } | Where-Object { $_ } | Select-Object -Unique)) {
        if (-not $cboCat.Items.Contains($c)) { [void]$cboCat.Items.Add($c) }
    }
    $dlg.Controls.Add($cboCat)

    $numUrl = New-Object System.Windows.Forms.NumericUpDown
    $numUrl.Location = New-Object System.Drawing.Point(($cboCat.Right + $gap), $rowY)
    $numUrl.Width = $numW
    $numUrl.Minimum = $script:MinUrlIntervalMin; $numUrl.Maximum = 1440; $numUrl.Value = 60
    $dlg.Controls.Add($numUrl)
    $btnAdd = New-Object System.Windows.Forms.Button
    $btnAdd.Text = 'Add'
    $btnAdd.Location = New-Object System.Drawing.Point(($numUrl.Right + $gap), ($rowY - 1))
    $btnAdd.Size = New-Object System.Drawing.Size($addW, ($txtUrl.Height + 2))
    $dlg.Controls.Add($btnAdd)
    $btnDel = New-Object System.Windows.Forms.Button
    $btnDel.Text = 'Remove'
    $btnDel.Location = New-Object System.Drawing.Point(($btnAdd.Right + $gap), ($rowY - 1))
    $btnDel.Size = New-Object System.Drawing.Size($delW, ($txtUrl.Height + 2))
    $dlg.Controls.Add($btnDel)

    $lblAddHint = New-Object System.Windows.Forms.Label
    $lblAddHint.Text = "Category is optional — pick one or type your own. Click a row to edit it."
    $lblAddHint.AutoSize = $false
    $lblAddHint.Location = New-Object System.Drawing.Point($pad, ($btnDel.Bottom + (& $S 8)))
    $lblAddHint.Size = New-Object System.Drawing.Size($w, (& $S 20))
    $lblAddHint.ForeColor = [System.Drawing.Color]::DimGray
    $dlg.Controls.Add($lblAddHint)

    $btnAdd.Add_Click({
        $u = $txtUrl.Text.Trim()
        if ($u -notmatch '^https?://\S+$') {
            [System.Windows.Forms.MessageBox]::Show('Please enter a full web address starting with http:// or https://', $appName) | Out-Null
            return
        }
        $cat = $cboCat.Text.Trim()
        if ($cat.Length -gt 40) { $cat = $cat.Substring(0, 40) }
        $existing = -1
        for ($j = 0; $j -lt $dlgUrls.Count; $j++) { if ($dlgUrls[$j].url -eq $u) { $existing = $j; break } }
        if ($existing -ge 0) {   # same address: update it rather than refusing silently
            $dlgUrls[$existing].category = $cat
            $dlgUrls[$existing].intervalMinutes = [int]$numUrl.Value
            $lstUrls.Items[$existing].SubItems[1].Text = $cat
            $lstUrls.Items[$existing].SubItems[2].Text = "$([int]$numUrl.Value) min"
        } else {
            $entry = @{ url = $u; intervalMinutes = [int]$numUrl.Value; category = $cat }
            [void]$dlgUrls.Add($entry)
            Add-UrlRow $entry
        }
        if ($cat -and -not $cboCat.Items.Contains($cat)) { [void]$cboCat.Items.Add($cat) }
        $txtUrl.Clear(); $cboCat.Text = ''
    }.GetNewClosure())

    $btnDel.Add_Click({
        if ($lstUrls.SelectedIndices.Count -eq 0) { return }
        $i = $lstUrls.SelectedIndices[0]
        $dlgUrls.RemoveAt($i); $lstUrls.Items.RemoveAt($i)
    }.GetNewClosure())

    # click a row to load it back into the edit boxes; Add re-saves it under the same address
    $lstUrls.Add_SelectedIndexChanged({
        if ($lstUrls.SelectedIndices.Count -eq 0) { return }
        $e = $dlgUrls[$lstUrls.SelectedIndices[0]]
        $txtUrl.Text = $e.url; $cboCat.Text = [string]$e.category
        $numUrl.Value = [math]::Min($numUrl.Maximum, [math]::Max($numUrl.Minimum, [int]$e.intervalMinutes))
    }.GetNewClosure())

    $chkStartup = New-Object System.Windows.Forms.CheckBox
    $chkStartup.Text = 'Start NewsFeeder when Windows starts'
    $chkStartup.AutoSize = $true
    $chkStartup.Location = New-Object System.Drawing.Point($pad, ($lblAddHint.Bottom + (& $S 12)))
    $chkStartup.Checked = [bool]$script:Settings.startWithWindows
    $dlg.Controls.Add($chkStartup)

    $chkMin = New-Object System.Windows.Forms.CheckBox
    $chkMin.Text = 'Start minimized to the tray (no window until you ask)'
    $chkMin.AutoSize = $true
    $chkMin.Location = New-Object System.Drawing.Point($pad, ($chkStartup.Bottom + (& $S 6)))
    $chkMin.Checked = [bool]$script:Settings.startMinimized
    $dlg.Controls.Add($chkMin)

    $chkPop = New-Object System.Windows.Forms.CheckBox
    $chkPop.Text = 'Show a popup (top-right) for every new item'
    $chkPop.AutoSize = $true
    $chkPop.Location = New-Object System.Drawing.Point($pad, ($chkMin.Bottom + (& $S 6)))
    $chkPop.Checked = [bool]$script:Settings.showPopups
    $dlg.Controls.Add($chkPop)

    $chkSound = New-Object System.Windows.Forms.CheckBox
    $chkSound.Text = 'Play a gentle sound with each popup'
    $chkSound.AutoSize = $true
    $chkSound.Location = New-Object System.Drawing.Point($pad, ($chkPop.Bottom + (& $S 6)))
    $chkSound.Checked = [bool]$script:Settings.playSound
    $dlg.Controls.Add($chkSound)

    $btnY = $chkSound.Bottom + (& $S 16)
    $btnW = & $S 80; $btnH = & $S 30
    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = 'Cancel'; $btnCancel.DialogResult = 'Cancel'
    $btnCancel.Location = New-Object System.Drawing.Point(($pad + $w - $btnW), $btnY)
    $btnCancel.Size = New-Object System.Drawing.Size($btnW, $btnH)
    $dlg.Controls.Add($btnCancel)
    $btnOk = New-Object System.Windows.Forms.Button
    $btnOk.Text = 'Save'; $btnOk.DialogResult = 'OK'
    $btnOk.Location = New-Object System.Drawing.Point(($btnCancel.Left - $gap - $btnW), $btnY)
    $btnOk.Size = New-Object System.Drawing.Size($btnW, $btnH)
    $dlg.Controls.Add($btnOk)
    $dlg.AcceptButton = $btnOk; $dlg.CancelButton = $btnCancel

    # window sized to the measured content, never the other way around
    $dlg.ClientSize = New-Object System.Drawing.Size((2 * $pad + $w), ($btnCancel.Bottom + $pad))

    if ($dlg.ShowDialog() -ne 'OK') { $dlg.Dispose(); return }

    & $saveDisplayedChecks
    $enabled = $dialogState.enabledFeeds
    if ($enabled.Count -eq 0) {
        foreach ($f in $script:Catalog) { [void]$enabled.Add($f.id) }
    }
    $script:Settings.enabledFeeds = @($enabled)
    $script:Settings.feedIntervalMinutes = [int]$numFeed.Value
    $script:Settings.watchedUrls = @($dlgUrls)
    $script:Settings.startMinimized = $chkMin.Checked
    $script:Settings.showPopups = $chkPop.Checked
    $script:Settings.playSound = $chkSound.Checked

    $wantStartup = $chkStartup.Checked
    try {
        Set-StartupEntry $wantStartup
        $script:Settings.startWithWindows = $wantStartup
    } catch {
        [System.Windows.Forms.MessageBox]::Show("Could not update the Windows startup entry:`n$_", $script:AppName, 'OK', 'Warning') | Out-Null
    }

    Save-Settings
    Rebuild-Sources
    Update-Status
    $dlg.Dispose()
}

# ---------- scheduler tick ----------

function Request-CheckNow {
    $now = Get-Date
    foreach ($s in $script:Sources) { $s.NextDue = $now }
}

function Update-Status {
    $feeds = @($script:Sources | Where-Object Kind -eq 'feed')
    $urls  = @($script:Sources | Where-Object Kind -eq 'url')
    $errs  = @($script:Sources | Where-Object { $_.LastError })
    $modeLabels = foreach ($mode in @($script:Settings.enabledModes)) {
        switch ($mode) { 'security' { 'Security' } 'goodnews' { 'Good News' } 'science' { 'Science' } }
    }
    $shown = $script:ListView.Items.Count
    $txt = "[$($modeLabels -join ' + ')] $($feeds.Count) sources, $($urls.Count) watched pages · $shown shown of $($script:History.Count)"
    if ($errs.Count -gt 0) { $txt += " · ⚠ $($errs.Count) failing" }
    if ($script:LastActivity) { $txt += " · last check $($script:LastActivity.ToString('HH:mm:ss'))" }
    $script:StatusLabel.Text = $txt
}

$script:MainTimer = New-Object System.Windows.Forms.Timer
$script:MainTimer.Interval = 2000
$script:MainTimer.Add_Tick({
  try {
    # 0. safety valve: clear stale pending fetches (> 30s) so dead connections cannot clog the queue forever
    $now = Get-Date
    $stale = @($script:Pending | Where-Object { $_.StartTime -and ($now - $_.StartTime).TotalSeconds -gt 30 })
    foreach ($p in $stale) {
        $script:Pending.Remove($p)
        $p.Source.InFlight = $false
        $p.Source.NextDue = $now.AddMinutes($p.Source.IntervalMin)
        if ($p.Source.LastError -ne 'timed out (30s limit)') {
            $p.Source.LastError = 'timed out (30s limit)'
            Add-Event 'error' $p.Source.Name 'Could not check: connection timed out' $p.Source.Url '' $false
        }
    }

    # 1. harvest finished fetches
    $done = @($script:Pending | Where-Object { $_.Task.IsCompleted })
    foreach ($p in $done) {
        $script:Pending.Remove($p)
        Complete-Fetch $p
        $script:LastActivity = Get-Date
    }
    # 2. start due fetches (max 3 in flight — politeness and responsiveness)
    if ($script:Pending.Count -lt 3) {
        $now = Get-Date
        foreach ($s in $script:Sources) {
            if ($script:Pending.Count -ge 3) { break }
            if ($s.InFlight -or $s.NextDue -gt $now) { continue }
            $s.InFlight = $true
            try {
                [void]$script:Pending.Add(@{ Source = $s; Task = (Start-Fetch $s); StartTime = $now })
            } catch {
                $s.InFlight = $false
                $s.NextDue = $now.AddMinutes($s.IntervalMin)
                if ($s.LastError -ne "$_") { $s.LastError = "$_"; Add-Event 'error' $s.Name "Could not check: $_" $s.Url '' $false }
            }
        }
    }
    # 3. show queued popups
    Drain-PopupQueue
    if ($done.Count -gt 0) { Update-Status }
  } catch {
    # one bad event must never take the whole app down; record it and keep checking
    Write-ErrorLog 'check cycle' $_
    $script:StatusLabel.Text = "A check failed unexpectedly — details in data\errors.log"
  }
})

$btnCheck.Add_Click({ Request-CheckNow; $script:StatusLabel.Text = 'Checking all sources now…' })
$btnSettings.Add_Click({ Show-SettingsDialog })

# ---------- run ----------

Update-Status
$script:MainTimer.Start()
if (-not $script:Settings.startMinimized) { Show-MainWindow }

$ctx = New-Object System.Windows.Forms.ApplicationContext
[System.Windows.Forms.Application]::Run($ctx)

# cleanup after exit
$script:MainTimer.Stop()
$script:Tray.Dispose()
Save-History; Save-Seen; Save-UrlState; Save-Settings
