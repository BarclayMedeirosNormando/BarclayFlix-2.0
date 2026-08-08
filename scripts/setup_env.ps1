<#
.SYNOPSIS
    Cria o arquivo .env na raiz do projeto com o valor de APPS_SCRIPT_URL,
    usado por scripts/run_dev.ps1 para rodar o app localmente sem expor a
    URL real no codigo ou no Git.

.DESCRIPTION
    Como rodar (a partir da raiz do projeto, ou de dentro de scripts/):

        ./scripts/setup_env.ps1

    O que o script faz, em ordem:
      1. Se .env ja existir na raiz, pergunta se quer sobrescrever (s/N,
         default N -- responder qualquer coisa diferente de "s"/"S"
         cancela sem alterar nada).
      2. Pede o valor de APPS_SCRIPT_URL (precisa comecar com
         "https://script.google.com/"), repetindo a pergunta ate um valor
         valido ou ate o usuario digitar "cancelar". Mostra o valor
         digitado e pede confirmacao antes de salvar.
      3. Escreve .env na raiz no formato APPS_SCRIPT_URL=<valor>.
      4. Confirma no console que o arquivo foi criado.

.NOTES
    .env nunca deve ir para o Git -- ja esta em .gitignore (ver tambem
    .env.example, que documenta a estrutura esperada sem valor real).
    Use scripts/run_dev.ps1 depois deste script para rodar o app.
#>

$ErrorActionPreference = 'Stop'

# Raiz do projeto = pasta pai de scripts/ (onde este arquivo mora) --
# funciona independente de onde o script e chamado a partir.
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

function Write-Step($message) {
    Write-Host "`n== $message ==" -ForegroundColor Cyan
}

$envPath = Join-Path $root '.env'

# 1. Se .env ja existe, confirma sobrescrita (default: nao).
if (Test-Path $envPath) {
    Write-Host ".env ja existe em $envPath" -ForegroundColor Yellow
    $overwrite = Read-Host "Sobrescrever? (s/N)"
    if ($overwrite -notmatch '^[sS]$') {
        Write-Host "Nada foi alterado." -ForegroundColor Cyan
        exit 0
    }
}

# 2. Pede a URL, validando o prefixo esperado, ate valida ou "cancelar".
Write-Step 'Configuracao do APPS_SCRIPT_URL'
$prefix = 'https://script.google.com/'
$appsScriptUrl = $null
while (-not $appsScriptUrl) {
    $typed = Read-Host "Cole a URL do Apps Script (ou 'cancelar' para sair)"

    if ($typed -eq 'cancelar') {
        Write-Host "Operacao cancelada. Nenhum arquivo foi criado/alterado." -ForegroundColor Yellow
        exit 0
    }

    if (-not $typed.StartsWith($prefix)) {
        Write-Host "Valor invalido -- precisa comecar com '$prefix'. Tente de novo." -ForegroundColor Red
        continue
    }

    # Mostra o valor digitado para o usuario confirmar antes de salvar --
    # aqui e seguro exibir (e o proprio usuario digitando, na hora).
    Write-Host "`nValor digitado:" -ForegroundColor Cyan
    Write-Host "APPS_SCRIPT_URL=$typed"
    $confirm = Read-Host "Confirma? (S/n)"
    if ($confirm -match '^[nN]$') {
        Write-Host "Ok, vamos tentar de novo." -ForegroundColor Yellow
        continue
    }

    $appsScriptUrl = $typed
}

# 3. Escreve o .env. -Encoding utf8 evita depender do codepage ANSI do
# sistema (ver nota sobre Set-Content no restante do projeto).
Set-Content -Path $envPath -Value "APPS_SCRIPT_URL=$appsScriptUrl" -Encoding utf8 -NoNewline

# 4. Confirmacao final.
Write-Host "`n.env criado com sucesso. Nunca commite este arquivo (ja esta no .gitignore)." -ForegroundColor Green
