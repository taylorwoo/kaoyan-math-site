#Requires -Version 5.1
<#
  Sync the Obsidian vault into Quartz content/ and publish via GitHub Actions.

  Usage:
    .\scripts\sync-vault.ps1
    .\scripts\sync-vault.ps1 -VaultPath 'E:\...' -NoPush
#>
[CmdletBinding()]
param(
    [string] $VaultPath,
    [string] $Message,
    [switch] $NoPush
)

$ErrorActionPreference = 'Stop'

$siteRoot   = Split-Path -Parent $PSScriptRoot
$contentDir = Join-Path $siteRoot 'content'
$index      = Join-Path $contentDir 'index.md'
$utf8NoBom  = New-Object System.Text.UTF8Encoding($false)

if (-not (Test-Path -LiteralPath $contentDir)) {
    throw "content/ not found under $siteRoot — run this script from the Quartz repo."
}

# --- resolve the vault from Obsidian's own config unless told otherwise ---
if (-not $VaultPath) {
    $cfg = Join-Path $env:APPDATA 'obsidian\obsidian.json'
    if (-not (Test-Path -LiteralPath $cfg)) {
        throw "Obsidian config not found at $cfg. Pass -VaultPath explicitly."
    }
    # obsidian.json is UTF-8; without -Encoding UTF8, Windows PowerShell decodes it as GBK
    # and the Chinese vault path silently becomes an unreachable string.
    $vaults = (Get-Content -LiteralPath $cfg -Raw -Encoding UTF8 | ConvertFrom-Json).vaults
    $props  = @($vaults.PSObject.Properties)
    $pick   = @($props | Where-Object { $_.Value.open }) | Select-Object -First 1
    if (-not $pick) { $pick = $props | Select-Object -First 1 }
    if (-not $pick) { throw "No vaults listed in $cfg" }
    if ($props.Count -gt 1 -and -not $pick.Value.open) {
        Write-Warning "Multiple vaults found; using $($pick.Value.path). Pass -VaultPath to be sure."
    }
    $VaultPath = $pick.Value.path
}

if (-not (Test-Path -LiteralPath $VaultPath)) {
    throw "Vault path is not reachable: $VaultPath"
}

$src = @(Get-ChildItem -LiteralPath $VaultPath -Filter '*.md' -File)
if ($src.Count -eq 0) { throw "No .md files in $VaultPath — refusing to wipe the site." }

Write-Host "Vault : $VaultPath"
Write-Host "Site  : $siteRoot"
Write-Host "Notes : $($src.Count) markdown file(s)"

# --- keep the hand-written frontmatter of the current home page ---
$fm = ''
if (Test-Path -LiteralPath $index) {
    $existing = Get-Content -LiteralPath $index -Raw -Encoding UTF8
    if ($existing -match '(?s)\A(---\r?\n.*?\r?\n---)') { $fm = $Matches[1] }
}

# --- replace content ---
Get-ChildItem -LiteralPath $contentDir -Filter '*.md' -File | Remove-Item -Force
foreach ($f in $src) { Copy-Item -LiteralPath $f.FullName -Destination $contentDir -Force }

# The vault's table of contents is named 00-*.md; promote it to index.md so it serves at /.
$toc = @(Get-ChildItem -LiteralPath $contentDir -Filter '00-*.md' -File)
if ($toc.Count -gt 0) {
    if ($toc.Count -gt 1) { Write-Warning "Multiple 00-*.md files; promoting $($toc[0].Name)" }
    Move-Item -LiteralPath $toc[0].FullName -Destination $index -Force
    if ($fm) {
        $body = Get-Content -LiteralPath $index -Raw -Encoding UTF8
        if ($body -notmatch '\A---\r?\n') {
            # Blank line between the closing --- and the body is part of the frontmatter block,
            # so re-add it here or the heading ends up glued to the delimiter.
            [System.IO.File]::WriteAllText($index, ($fm + "`n`n" + $body), $utf8NoBom)
        }
    } else {
        Write-Warning 'index.md has no frontmatter — the home page will be titled "index". Add a title: line.'
    }
} else {
    Write-Warning 'No 00-*.md table of contents found; the site will have no home page at /.'
}

# --- commit and push ---
Push-Location $siteRoot
try {
    git add -- content | Out-Null
    if (-not (git status --porcelain -- content)) {
        Write-Host 'No note changes to publish.'
        return
    }

    if (-not $Message) {
        $Message = "sync: update notes from Obsidian vault ($((Get-Date).ToString('yyyy-MM-dd HH:mm')))"
    }
    git commit -m $Message | Out-Null

    if ($NoPush) {
        Write-Host 'Committed locally. Skipped push (-NoPush).'
        return
    }

    git push origin HEAD | Out-Null
    Write-Host 'Pushed. GitHub Actions is now rebuilding the site.'

    $slug = ''
    $remoteUrl = (git remote get-url origin 2>$null)
    if ($remoteUrl -match 'github\.com[:/](?<owner>[^/]+)/(?<repo>[^/]+?)(?:\.git)?/?$') {
        $slug = "$($Matches.owner)/$($Matches.repo)"
    }
    if (-not $slug) { Write-Host 'Cannot parse the origin URL; check Actions manually.'; return }

    Write-Host "https://github.com/$slug/actions"

    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        # PowerShell windows opened before gh was installed never picked up the new PATH entry.
        $ghDir = Join-Path ${env:ProgramFiles} 'GitHub CLI'
        if (Test-Path -LiteralPath (Join-Path $ghDir 'gh.exe')) {
            $env:Path = "$env:Path;$ghDir"
        }
    }
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        Write-Host 'gh CLI not found on PATH — open the URL above to follow the build.'
        return
    }

    for ($i = 0; $i -lt 40; $i++) {
        Start-Sleep -Seconds 15
        $runs = @(gh run list --repo $slug --event push --limit 1 --json status,conclusion,url 2>$null | ConvertFrom-Json)
        $run  = $runs | Select-Object -First 1
        if (-not $run) { continue }
        Write-Host "  [$([int]($i * 15))s] $($run.status) $($run.conclusion)"
        if ($run.status -eq 'completed') {
            if ($run.conclusion -eq 'success') {
                Write-Host 'Deploy succeeded. Hard-refresh (Ctrl+Shift+R) to see the new notes.'
            } else {
                Write-Host "Deploy did not succeed ($($run.conclusion)). Open $($run.url) and read the failing step." -ForegroundColor Yellow
            }
            return
        }
    }
    Write-Host 'Still building after 10 minutes — check the Actions page.' -ForegroundColor Yellow
}
finally {
    Pop-Location
}
