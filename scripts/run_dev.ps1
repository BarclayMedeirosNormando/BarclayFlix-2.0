<#
.SYNOPSIS
    Roda "flutter run" injetando automaticamente
    --dart-define=APPS_SCRIPT_URL=... a partir do .env local, para nao
    precisar digitar o valor toda vez.

.DESCRIPTION
    Como rodar (a partir da raiz do projeto, ou de dentro de scripts/):

        ./scripts/run_dev.ps1
        ./scripts/run_dev.ps1 -Device windows
        ./scripts/run_dev.ps1 -Device chrome
        ./scripts/run_dev.ps1 -Device <device_id_android_ou_android_tv>

    Pre-requisito: rodar scripts/setup_env.ps1 pelo menos uma vez antes,
    para gerar o .env local (nunca commitado -- ja esta no .gitignore).

.NOTES
    O valor de APPS_SCRIPT_URL NUNCA e impresso no console por este
    script -- so a confirmacao de que foi carregado com sucesso. Evita
    vazamento acidental em prints de tela/gravacoes.
#>

param(
    [string]$Device
)

$ErrorActionPreference = 'Stop'

# Raiz do projeto = pasta pai de scripts/ (onde este arquivo mora) --
# funciona independente de onde o script e chamado a partir.
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

function Write-Step($message) {
    Write-Host "`n== $message ==" -ForegroundColor Cyan
}

# 1. .env precisa existir -- gerado por scripts/setup_env.ps1.
$envPath = Join-Path $root '.env'
if (-not (Test-Path $envPath)) {
    Write-Host "Nao encontrei .env em $envPath" -ForegroundColor Red
    Write-Host "Rode scripts/setup_env.ps1 primeiro." -ForegroundColor Yellow
    exit 1
}

# 2. Le a linha APPS_SCRIPT_URL=... do .env -- parse simples via regex,
# sem dependencia externa.
$appsScriptUrl = $null
foreach ($line in Get-Content -Path $envPath) {
    if ($line -match '^\s*APPS_SCRIPT_URL\s*=\s*(.+?)\s*$') {
        $appsScriptUrl = $matches[1]
        break
    }
}

if ([string]::IsNullOrWhiteSpace($appsScriptUrl)) {
    Write-Host "Nao encontrei APPS_SCRIPT_URL (ou esta vazia) em .env." -ForegroundColor Red
    Write-Host "Rode scripts/setup_env.ps1 para reconfigurar." -ForegroundColor Yellow
    exit 1
}

# NUNCA imprime $appsScriptUrl -- so a confirmacao de que carregou.
Write-Host "URL carregada do .env com sucesso." -ForegroundColor Green

# 3. Monta e roda o flutter run, repassando -Device (-d) se informado.
Write-Step 'flutter run'
$flutterArgs = @('run', "--dart-define=APPS_SCRIPT_URL=$appsScriptUrl")
if ($Device) {
    $flutterArgs += @('-d', $Device)
}

flutter @flutterArgs
exit $LASTEXITCODE
