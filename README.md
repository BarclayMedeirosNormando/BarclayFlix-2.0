# BarclayFlix 2.0

Reprodutor de IPTV multiplataforma (estilo IBO Player / XCIPTV) que consome
a API padrão do **Xtream Codes**. O app funciona como um player "vazio":
não baixa nem armazena arquivos físicos, apenas faz streaming.

A ativação do dispositivo é feita via um endpoint próprio (Google Apps
Script) que vincula este dispositivo a um cliente e devolve os servidores
Xtream Codes liberados para ele — ver `DeviceAuthService` /
`DeviceIdService`.

## Plataformas suportadas

- **Android** (mobile, interface por toque)
- **Android TV** (navegação obrigatória por D-Pad/setas, via `FocusNode`)
- **Windows** (desktop — mouse, teclado, tela cheia/redimensionável)

## Stack principal

- **Flutter** + **Provider** para gerenciamento de estado
- **media_kit** / **media_kit_video** / **media_kit_libs_video** para
  reprodução de vídeo (Live TV, VOD e Séries) via libmpv, com aceleração
  de hardware nativa em Android e Windows
- **http** para comunicação com o Apps Script e a API Xtream Codes
- **flutter_secure_storage** para credenciais; **shared_preferences** para
  dados não sensíveis (ex.: progresso de "Continuar Assistindo")

## Setup do ambiente

1. Instale o [Flutter SDK](https://docs.flutter.dev/get-started/install)
   (canal stable) e confirme com `flutter doctor`.
2. Instale as dependências:

   ```
   flutter pub get
   ```
3. Configure o `.env` local (ver seção "Rodando o app" abaixo) — `.env.example`
   documenta a estrutura esperada, mas o app não lê arquivo `.env` em
   runtime: o valor é sempre injetado em tempo de build/execução via
   `--dart-define`.

## Rodando o app

A URL do endpoint de ativação (Google Apps Script) **não fica hardcoded no
código** — é injetada via `--dart-define` em `AppConfig.appsScriptUrl`
(`lib/config/app_config.dart`), consumida por `AppConstants.deviceAuthUrl`.

### Com os scripts (recomendado)

`scripts/setup_env.ps1` e `scripts/run_dev.ps1` evitam ter que digitar (ou
colar sem querer em algum print/gravação) a URL real a cada `flutter run`.
Funcionam tanto chamados da raiz do projeto quanto de dentro de `scripts/`.

```powershell
# primeira vez / trocar de painel de testes -- pede a APPS_SCRIPT_URL e
# grava em .env na raiz (arquivo local, nunca commitado — já está no
# .gitignore).
./scripts/setup_env.ps1

# roda o app normalmente, lendo a URL do .env automaticamente:
./scripts/run_dev.ps1
./scripts/run_dev.ps1 -Device windows
./scripts/run_dev.ps1 -Device chrome
./scripts/run_dev.ps1 -Device <device_id_android_ou_android_tv>
```

### Manualmente (alternativa)

Também funciona chamar `flutter run` direto, passando o `--dart-define` à mão:

```
flutter run --dart-define=APPS_SCRIPT_URL=https://script.google.com/macros/s/SEU_ID_AQUI/exec
```

Para gerar um build de release (ex.: Windows/Android), passe a mesma
variável para o comando de build:

```
flutter build windows --dart-define=APPS_SCRIPT_URL=https://script.google.com/macros/s/SEU_ID_AQUI/exec
flutter build apk --dart-define=APPS_SCRIPT_URL=https://script.google.com/macros/s/SEU_ID_AQUI/exec
```

Sem essa variável definida, `APPS_SCRIPT_URL` fica vazia e a ativação de
dispositivo falha (comportamento esperado — evita apontar builds locais
para o endpoint de produção por engano).

## Testes

```
flutter test
```

## Estrutura de branches

- **`main`** — produção. Só recebe código já testado e aprovado.
- **`teste/*`** — experimentação. Qualquer alteração pedida sob a disciplina
  **TESTE** é feita isolada aqui (arquivo novo, branch própria, ou trecho
  experimental), sem tocar no que já está implantado em `main`.
  Só quando confirmado **IMPLANTAR** o resultado testado é incorporado
  definitivamente a `main`.

## Especificação do projeto

As diretrizes de arquitetura e papel usadas para orientar o desenvolvimento
deste projeto estão versionadas em [`CLAUDE.md`](CLAUDE.md), na raiz do
repositório.
