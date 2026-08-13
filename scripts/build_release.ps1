<#
.SYNOPSIS
    Gera os builds de release (Android + Windows) da versao atual do app e
    organiza os artefatos em releases/<versao>/{android,windows}/.

.DESCRIPTION
    Como rodar (a partir da raiz do projeto, ou de qualquer lugar):

        ./scripts/build_release.ps1

    O que o script faz, em ordem:
      1. Le a versao em pubspec.yaml (campo version:, parte antes do "+").
      2. Roda flutter analyze e flutter test -- aborta o script se algum dos
         dois falhar (nao builda release em cima de codigo quebrado).
      3. Cria releases/<versao>/android/ e releases/<versao>/windows/.
      4. flutter build apk --release --split-per-abi, copia CADA APK gerado
         (um por ABI -- tipicamente armeabi-v7a, arm64-v8a e x86_64) para
         releases/<versao>/android/BarclayFlix-<versao>-<abi>.apk.
      5. flutter build windows --release, copia TODO o conteudo de
         build/windows/x64/runner/Release/ (.exe + DLLs necessarias) para
         releases/<versao>/windows/.

    Build Windows NAO e fatal para o script: se falhar (ex: falta o
    componente "C++ ATL for latest v143 build tools" no Visual Studio,
    exigido por flutter_secure_storage_windows), o script captura o erro,
    reporta no resumo final, e mantem o que ja foi gerado (ex: o APK
    Android) intacto.

.NOTES
    Pre-requisitos:
    - .env na raiz do projeto, com APPS_SCRIPT_URL preenchida (gerado por
      scripts/setup_env.ps1) -- o script ABORTA se faltar. Sem essa
      variavel injetada via --dart-define, o build sai com
      AppConfig.appsScriptUrl vazia e o fluxo de ativacao por device-code
      quebra silenciosamente: a chamada HTTP falha, cai num catch
      generico, e a ActivationScreen trata isso como "ainda aguardando
      cadastro", travando pra sempre em "Aguardando ativacao..." sem
      mostrar erro nenhum -- bug real ja visto em producao (releases
      geradas por este script antes desta checagem existir), so
      descoberto testando no dispositivo. Ver scripts/run_dev.ps1, que ja
      fazia essa leitura corretamente para "flutter run".
    - android/key.properties configurado, se quiser o APK assinado com o
      keystore de producao (upload key). Sem ele, o build cai
      automaticamente no signing de debug -- ver
      android/app/build.gradle.kts. O script NAO falha por causa disso,
      so gera um APK debug-signed.
    - Para o build Windows funcionar: Visual Studio com o workload
      "Desktop development with C++" + o componente individual "C++ ATL
      for latest v143 build tools (x86 & x64)".

    CONHECIDO nesta maquina (confirmado em 2026-08-07): uma politica de
    execucao de scripts do Windows (AppLocker/WDAC -- NAO e o
    Get-ExecutionPolicy do PowerShell, que aqui esta Unrestricted/Bypass)
    bloqueia rodar este arquivo .ps1 diretamente, mesmo com
    "-ExecutionPolicy Bypass" (erro: "Falha na verificacao do
    AuthorizationManager"). Se isso acontecer, rode os mesmos passos deste
    script manualmente, um comando de cada vez (flutter analyze; flutter
    test; flutter build apk --release; flutter build windows --release;
    copiar os artefatos) em vez de invocar o arquivo.

    Tambem visto nesta sessao: se o projeto ja foi movido/renomeado de
    pasta antes (o `build/` e `.dart_tool/` guardam caminhos absolutos), o
    build Android pode falhar tentando criar um diretorio no caminho
    ANTIGO. Rodar `flutter clean` antes do build resolve.

    CORRIGIDO em 2026-08-07 (visto de novo nas releases 1.6.0 e 1.7.0 antes
    do fix): o passo "flutter build apk --release" reportava "FALHOU" com a
    mensagem "WARNING: Your app uses the following plugins that apply
    Kotlin Gradle Plugin (KGP): ..." mesmo com o APK gerado com sucesso em
    build\app\outputs\flutter-apk\. Causa raiz: $ErrorActionPreference =
    'Stop' (topo deste arquivo) faz o PowerShell 5.1 tratar QUALQUER linha
    de stderr de um processo nativo como erro terminante, e o Gradle
    escreve esse aviso (inofensivo, sobre package_info_plus/wakelock_plus)
    em stderr -- independente de como o script é invocado por fora (nao é
    um problema de "2>&1" de quem chama). Os blocos de build Android/Windows
    agora rodam com $ErrorActionPreference = 'Continue' só durante o
    comando nativo em si, decidindo sucesso via $LASTEXITCODE.
#>

$ErrorActionPreference = 'Stop'

# Raiz do projeto = pasta pai de scripts/ (onde este arquivo mora) --
# funciona independente de onde o script e chamado a partir.
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

function Write-Step($message) {
    Write-Host "`n== $message ==" -ForegroundColor Cyan
}

# 0. .env / APPS_SCRIPT_URL -- precisa estar definida ANTES de qualquer
# build, senao AppConfig.appsScriptUrl (String.fromEnvironment) sai vazia
# no binario gerado e o fluxo de ativacao por device-code quebra
# silenciosamente (ver .NOTES acima). Mesma leitura que scripts/run_dev.ps1
# ja faz para "flutter run" -- replicada aqui em vez de builda um release
# sem essa variavel e so descobrir o problema testando no dispositivo.
Write-Step 'Carregando APPS_SCRIPT_URL do .env'
$envPath = Join-Path $root '.env'
if (-not (Test-Path $envPath)) {
    throw "Nao encontrei .env em $envPath -- APPS_SCRIPT_URL nao definida. Rode scripts/setup_env.ps1 primeiro. Build de release abortado."
}

$appsScriptUrl = $null
foreach ($line in Get-Content -Path $envPath) {
    if ($line -match '^\s*APPS_SCRIPT_URL\s*=\s*(.+?)\s*$') {
        $appsScriptUrl = $matches[1]
        break
    }
}

if ([string]::IsNullOrWhiteSpace($appsScriptUrl)) {
    throw "APPS_SCRIPT_URL nao definida (ou vazia) em .env -- build de release abortado. Rode scripts/setup_env.ps1 para reconfigurar."
}

# NUNCA imprime $appsScriptUrl -- so a confirmacao de que carregou (mesmo
# cuidado de scripts/run_dev.ps1, para nao vazar a URL real em prints de
# tela/gravacoes).
Write-Host "APPS_SCRIPT_URL carregada do .env com sucesso." -ForegroundColor Green
$appsScriptUrlDefine = "--dart-define=APPS_SCRIPT_URL=$appsScriptUrl"

# 1. Versao (de "version: 1.0.0+1" extrai "1.0.0")
$pubspecPath = Join-Path $root 'pubspec.yaml'
$pubspecContent = Get-Content -Path $pubspecPath -Raw
if ($pubspecContent -notmatch '(?m)^version:\s*(\S+)\s*$') {
    throw "Nao encontrei uma linha 'version:' valida em pubspec.yaml."
}
$fullVersion = $matches[1]
$version = $fullVersion.Split('+')[0]

Write-Host "Versao detectada: $fullVersion (artefatos vao para releases/$version/)" -ForegroundColor Cyan

# 2. Analyze + test -- aborta o script se falhar (nao builda release em
# cima de codigo com problema conhecido).
Write-Step 'flutter analyze'
flutter analyze
if ($LASTEXITCODE -ne 0) {
    throw "flutter analyze falhou (exit code $LASTEXITCODE) -- build abortado."
}

Write-Step 'flutter test'
flutter test
if ($LASTEXITCODE -ne 0) {
    throw "flutter test falhou (exit code $LASTEXITCODE) -- build abortado."
}

# 3. Estrutura de pastas releases/<versao>/{android,windows}/
$releaseDir = Join-Path $root "releases\$version"
$androidDir = Join-Path $releaseDir 'android'
$windowsDir = Join-Path $releaseDir 'windows'
New-Item -ItemType Directory -Force -Path $androidDir | Out-Null
New-Item -ItemType Directory -Force -Path $windowsDir | Out-Null

# 4. Build Android -- release, split por ABI (um .apk por arquitetura em vez
# de um unico .apk universal -- reduz bastante o tamanho de cada download),
# copia e renomeia CADA .apk gerado.
Write-Step 'flutter build apk --release --split-per-abi'
$androidOk = $true
$androidError = $null
$androidApkPaths = @()
try {
    # $ErrorActionPreference = 'Stop' (topo do script) faz o PowerShell 5.1
    # tratar QUALQUER linha que o processo nativo escreva em stderr como um
    # erro TERMINANTE -- mesmo quando o processo termina com exit code 0.
    # Gradle/AGP escrevem avisos conhecidos e inofensivos em stderr (ex:
    # "Your app uses the following plugins that apply Kotlin Gradle Plugin
    # (KGP): package_info_plus, wakelock_plus"), o que abortava este bloco
    # ANTES do Copy-Item mesmo com o APK gerado com sucesso -- confirmado
    # rodando o build duas vezes seguidas em versoes diferentes: o exit code
    # real era 0 e o .apk saia perfeito em build\app\outputs\flutter-apk\,
    # só essa linha de warning disparava o catch abaixo. Por isso, só para
    # este comando nativo, o resultado é decidido 100% por $LASTEXITCODE, e
    # $ErrorActionPreference volta a 'Stop' logo em seguida.
    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    flutter build apk --release --split-per-abi $appsScriptUrlDefine
    $ErrorActionPreference = $previousErrorActionPreference
    if ($LASTEXITCODE -ne 0) {
        throw "flutter build apk --release --split-per-abi terminou com exit code $LASTEXITCODE"
    }

    # --split-per-abi gera um app-<abi>-release.apk por arquitetura em vez do
    # unico app-release.apk de antes (ex: app-armeabi-v7a-release.apk,
    # app-arm64-v8a-release.apk, app-x86_64-release.apk) -- todos assinados
    # com o MESMO signingConfig da buildType `release` (ver
    # android/app/build.gradle.kts), aplicado pelo Android Gradle Plugin a
    # cada .apk de saida da variante, nao so ao primeiro.
    $apkSourceDir = Join-Path $root 'build\app\outputs\flutter-apk'
    $apkFiles = Get-ChildItem -Path $apkSourceDir -Filter 'app-*-release.apk' | Sort-Object Name
    if ($apkFiles.Count -eq 0) {
        throw "Nenhum .apk encontrado em $apkSourceDir apos o build com --split-per-abi."
    }
    foreach ($apkFile in $apkFiles) {
        if ($apkFile.Name -match '^app-(.+)-release\.apk$') {
            $abi = $matches[1]
        } else {
            $abi = $apkFile.BaseName
        }
        $apkDest = Join-Path $androidDir "BarclayFlix-$version-$abi.apk"
        Copy-Item -Path $apkFile.FullName -Destination $apkDest -Force
        $androidApkPaths += $apkDest
        Write-Host "APK copiado para $apkDest" -ForegroundColor Green
    }
} catch {
    $ErrorActionPreference = $previousErrorActionPreference
    $androidOk = $false
    $androidError = $_.Exception.Message
    Write-Host "Build Android FALHOU: $androidError" -ForegroundColor Red
}

# 5. Build Windows -- release, copia a pasta inteira (.exe + DLLs). Falha
# aqui NAO aborta o script (ex: componente ATL do Visual Studio ausente) --
# so e reportada no resumo final.
Write-Step 'flutter build windows --release'
$windowsOk = $true
$windowsError = $null
try {
    # Mesmo raciocínio do bloco Android acima -- ver o comentário lá.
    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    flutter build windows --release $appsScriptUrlDefine
    $ErrorActionPreference = $previousErrorActionPreference
    if ($LASTEXITCODE -ne 0) {
        throw "flutter build windows --release terminou com exit code $LASTEXITCODE"
    }
    $winSource = Join-Path $root 'build\windows\x64\runner\Release'
    Copy-Item -Path (Join-Path $winSource '*') -Destination $windowsDir -Recurse -Force
    Write-Host "Executavel + DLLs copiados para $windowsDir" -ForegroundColor Green
} catch {
    $ErrorActionPreference = $previousErrorActionPreference
    $windowsOk = $false
    $windowsError = $_.Exception.Message
    Write-Host "Build Windows FALHOU: $windowsError" -ForegroundColor Yellow
    Write-Host "(causa comum: falta o componente 'C++ ATL for latest v143 build tools (x86 & x64)' no Visual Studio Installer > Modificar > Componentes individuais)" -ForegroundColor Yellow
}

# 6. Resumo final
Write-Host "`n========== RESUMO ==========" -ForegroundColor Cyan
Write-Host "Versao: $version"
if ($androidOk) {
    Write-Host "Android: OK -> $($androidApkPaths.Count) APK(s):" -ForegroundColor Green
    foreach ($apkPath in $androidApkPaths) {
        Write-Host "  - $apkPath" -ForegroundColor Green
    }
} else {
    Write-Host "Android: FALHOU -- $androidError" -ForegroundColor Red
}
if ($windowsOk) {
    Write-Host "Windows: OK -> $windowsDir" -ForegroundColor Green
} else {
    Write-Host "Windows: FALHOU -- $windowsError" -ForegroundColor Yellow
}

# Codigo de saida do SCRIPT (nao do ultimo comando nativo rodado): reflete
# se o artefato Android -- o que a tarefa considera essencial -- foi
# entregue. Falha do Windows sozinha (ex: ATL ausente) NAO deve fazer quem
# chama este script (CI, outro script) pensar que o release inteiro falhou
# -- sem este "exit" explicito, o exit code do processo herdaria o do
# ultimo comando nativo rodado (aqui, o flutter build windows que falhou),
# mesmo com o try/catch acima ja tendo tratado o erro.
if ($androidOk) {
    exit 0
} else {
    exit 1
}
