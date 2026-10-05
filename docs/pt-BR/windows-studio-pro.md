# Validação Windows e Studio Pro com Omarchy

A rodada adicional passou dez builds: contratos, apresentação, widgets core,
validações e compatibilidade, cada um na origem e após round-trip Ruby. Dez
casos de regras e strings passaram no Runtime de cada pacote de compatibilidade.
O oráculo revelou e permitiu corrigir a legenda não textual de decisões por regra
e a codificação URL (espaço `%20`, asterisco `%2A`, til `~`). Veja a
[evidência de compatibilidade](../evidence/compatibility-2026-10-05.json).


## Estado verificado em 5 de outubro de 2026

A VM Windows existente no HD USB foi reutilizada, com Studio Pro 11.12.1 já
instalado. Não é necessário reinstalar ou formatar o disco. A sessão RDP foi
aberta em um servidor Xvfb dedicado (`DISPLAY=:97`), sem usar ou modificar as
telas físicas do usuário. Credenciais ficam fora dos comandos e relatórios.
Copie os projetos para um diretório local da VM antes de abrir no Studio Pro;
a conversão e gravação de units sobre uma pasta RDP compartilhada pode falhar.

Seis builds passaram: origem e round-trip Ruby dos fixtures de contratos,
apresentação nativa e widgets core. O runtime nativo respondeu HTTP 200,
renderizou a página e passou create/read/update/delete pelo cliente Mendix em
Edge headless. Os testes GUI verificaram parâmetros e contexto compartilhado de
popups, fechamento de duas janelas e conclusão assíncrona. VetClinic também
passou build, renderização com tema e CRUD pela API do cliente. Isso não equivale
a testar todos os formulários, temas e layouts móveis.

O [relatório versionado](../evidence/native-2026-10-05.json) delimita essas provas.

## Execução reproduzível

Gere um destino novo no Linux e transporte a pasta inteira para Windows.
Ajuste os caminhos de instalação nos comandos abaixo:

```bash
bundle exec ruby script/studio_pro_batch /tmp/native-batch
```

```powershell
./script/studio_pro_gate.ps1 -BatchDirectory C:\incoming\native-batch `
  -WorkspaceRoot C:\mxrb-projects -StudioVersion 11.12.1
./script/studio_pro_runtime.ps1 `
  -Package C:\incoming\native-batch\results\core-widgets-roundtrip\core-widgets-roundtrip.mda `
  -ToolRoot C:\Mendix\11.12.1 -JavaHome C:\Java\jdk-21 `
  -EvidenceDirectory C:\incoming\runtime-evidence
```

O gate confere a versão e assinatura dos executáveis, os hashes de todos os
arquivos, o proprietário de `mprcontents` e a quantidade física de `.mxunit`.
Ele constrói cópias locais e verifica novamente as entradas após o build.
Destinos existentes são recusados. Uma unit adulterada foi rejeitada antes do
build. `summary.json`, logs, erros e pacotes ficam em `results`; o teste do
runtime acrescenta `runtime.json` e uma captura de página, encerrando apenas
os processos que iniciou. O banco HSQLDB e o perfil Edge são descartáveis.

## CI

[Windows native certification](../../.github/workflows/studio-pro.yml) executa
semanalmente, manualmente e em PRs relevantes. O runner Windows hospedado usa o
arquivo oficial MxBuild 11.12.1 fixado por SHA-256, JDK 21 e Edge headless. A matriz atual
valida dez builds e inicia o Runtime nos pacotes core, validação e compatibilidade,
originais e reconstruídos.
Os artefatos de evidência ficam disponíveis por 14 dias. O job não instala a
GUI Studio Pro; a certificação visual continua registrada separadamente.

Não reduzir os gates Ruby (100% linhas e branches), frontend ou Chromium para
acomodar diferenças do oráculo. A VM existente pode ser iniciada pelos comandos
Omarchy instalados; use uma sessão virtual separada para novas verificações GUI.

## Status derivado das evidências

`script/acceptance_status` gera JSON a partir dos manifests e relatórios atuais.
As opções podem ser repetidas. O catálogo de declarações aparece separado dos
checks executados; um manifesto sozinho não certifica runtime. Lotes vazios,
falhas de inicialização e cobertura incompleta não recebem status aprovado.
O código de saída é 1 para evidência reprovada e 2 para entrada inválida.

```bash
bundle exec ruby script/acceptance_status \
  --manifest /tmp/app/.mxrb/ruby-app.json \
  --coverage coverage/coverage.json \
  --native /tmp/native-evidence/summary.json \
  --runtime /tmp/native-evidence/runtime-core-widgets-roundtrip/runtime.json \
  > /tmp/acceptance-status.json
```
