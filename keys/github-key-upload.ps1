# =============================================================================
# Upload SSH Key to GitHub - Helper Script
# =============================================================================
# Version  : 1.0.0
# Created  : 2026-06-11
# Filename : github-key-upload.ps1
#
# Description:
#   Reads your SSH public key, copies it to the clipboard, and opens the
#   GitHub "Add new SSH key" page. Paste (Ctrl+V) into the Key field.
#
# Usage:
#   Run in PowerShell:
#     .\github-key-upload.ps1
# =============================================================================

$keyPath = "$HOME\.ssh\id_ed25519.pub"

if (-not (Test-Path $keyPath)) {
    Write-Host "No public key found at $keyPath" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Generate one first with:" -ForegroundColor Cyan
    Write-Host '  ssh-keygen -t ed25519 -C "your@email.com"'
    exit 1
}

$pubKey = Get-Content $keyPath -Raw
$pubKey = $pubKey.Trim()

# Copy to clipboard
Set-Clipboard -Value $pubKey

Write-Host "Public key copied to clipboard:" -ForegroundColor Green
Write-Host ""
Write-Host $pubKey -ForegroundColor Cyan
Write-Host ""
Write-Host "Opening GitHub 'Add new SSH key' page..." -ForegroundColor Green
Write-Host ""
Write-Host "Steps:" -ForegroundColor Yellow
Write-Host "  1. Title: give it a name (e.g. 'Windows Desktop')"
Write-Host "  2. Key type: Authentication Key"
Write-Host "  3. Key: paste with Ctrl+V (already on your clipboard)"
Write-Host "  4. Click 'Add SSH key'"
Write-Host ""

Start-Process "https://github.com/settings/ssh/new"
