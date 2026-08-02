# Compilador nativo, Runtime e formato MDA

O pipeline funcional do MXRB não executa `mx`, `mxbuild`, `mxcli`, Studio Pro
ou Model SDK. Esses programas podem continuar sendo usados como gates externos
de compatibilidade, mas não são dependências do build, do banco ou dos testes
funcionais.

## Build do zero

`DeploymentMaterializer` cria um `deployment/` inexistente a partir dos
templates da versão instalada e executa 12 estágios: segurança, constantes,
domain model, artefatos, traduções, textos de sistema, filas de sistema, modelo
cliente, actions, settings, microflows e índice de projeto/módulos. Ele também
gera `metadata.json`, dependências e o `model.mdp` em ordem BSON aceita pelo
Runtime.

O bootstrap possui seeds e catálogos auditados para 6.10.8, 7.5.0, 7.17.0,
9.6.1.29396 e 11.12.1. As famílias 6.x, 7.x, 9.x e 11.x selecionam o seed
compatível; 5.x, 8.x e 10.x falham fechadas por ainda não terem seed auditado.
Esse agrupamento vale para o schema do compilador. A Runtime deve sempre ter o
mesmo patch exato do MPR.

`ProjectJarBuilder` encontra o JDK por `MXRB_JAVA_HOME`, `JAVA_HOME`, asdf ou
mise, compila `javasource/**/*.java` com as bibliotecas do Runtime e do projeto
e escreve um `project.jar` OSGi determinístico. No VetClinic foram compilados
183 fontes em 249 classes.

`WebBundleBuilder` seleciona Dojo em 6/7, Dojo com React wrapper em 9 e React
em 11. No React, gera entrypoint e módulos, expande `.mpk` e chama diretamente
o Node/Rspack da versão. O Data Grid 2 é compilado no subconjunto com
fonte XPath e colunas de atributo, incluindo `operations.json`, datasource e
tipos dos atributos. Tipos ou combinações ainda não traduzidos recebem um
fallback DOM e ficam registrados em `web/mxrb-pages.json`; o manifesto do
VetClinic ficou vazio.

O compilador React também materializa containers, textos e títulos, grids
responsivos, colunas e botões de abertura/criação. O bootstrap injeta
`theme.compiled.css`, manifest e assets `themesource/*/public`; portanto uma
homepage com `LayoutGrid` não fica vazia. Para adicionar conteúdo em Ruby:

Formulários `DataView` ligados a parâmetros agora renderizam campos `TextBox`
editáveis e ações Save/Cancel. Create passa o GUID do novo objeto por
`openForm2`; as operações commit/rollback são registradas com os user roles do
projeto derivados dos module roles permitidos pela página. A autorização da
Runtime é preservada, sem contorno de segurança.

O caminho React também compila a Gallery oficial com listas XPath e microflow,
conteúdo de item por template, seleção e atributos dinâmicos formatados. Fontes
e ações nanoflow usam os contratos `NanoflowObjectListProperty`,
`NanoflowObjectProperty` e `ActionProperty` do cliente Mendix. O MXRB emite
programas cliente reais `{ name, instructions }` para o subconjunto linear
auditado: retorno, criação de variável, criação de objeto e chamadas de
nanoflow. Fluxos ausentes, parâmetros sem mapeamento seguro, decisões, ações
JavaScript, chamadas de microflow e demais instruções não traduzidas falham
fechado e permanecem achados no manifesto de suporte.

Nas sessões locais da Runtime em modo developer, o mxrb também versiona imports
dinâmicos de páginas, aplica hash de conteúdo ao chunk corrigido do React Client
e dá à autoimportação do Rspack o mesmo token do entrypoint. Isso impede que as
respostas estáticas de longa duração do Mendix restaurem uma página branca
obsoleta depois de um rebuild nativo. O shell gerado também fornece um adaptador
limitado de `openForm` sobre `openForm2`; assim, handlers antigos em cache
navegam em vez de terminar silenciosamente sem disparar request.

```ruby
Mxrb.define("App.mpr") do
  mendix_version "11.12.1"
  self.module(:App) do
    layout :Shell
    page(:Home) do
      layout "App.Shell"
      title "Minha aplicação"
      container(:main, class_name: "container") do
        text :welcome, caption: "Conteúdo criado com mxrb"
      end
    end
  end
end
```

Projetos existentes podem ser exportados, alterados na DSL e regenerados. Os
widgets fora do subconjunto continuam no manifesto, sem descarte silencioso.

No Dojo, o Data Grid 1 cobre fontes database, XPath e microflow, pesquisa,
ordenação, paginação, seleção e botões auditados. Outros widgets visuais são
registrados por página em `web/mxrb-legacy-pages.json`; não são declarados como
renderizados. Esse manifesto evita que XML servido seja confundido com página
visualmente completa.

## MDA e pacote portátil

```bash
mxrb pack Clinic.mpr --output build/Clinic.mda
mxrb mda inspect build/Clinic.mda
mxrb portable Clinic.mpr --output build/runtime.zip
```

O MDA e o ZIP portátil são determinísticos. O pacote portátil combina o
deployment nativo com o Runtime instalado da mesma versão, configurações,
constantes e scripts. Somente as raízes oficiais entram no MDA; diretórios de
trabalho como `data`, `log`, `run`, `build` e `.gradle` são excluídos.

## Evidência de regressão

```bash
script/runtime_boot_regression App.mpr /caminho/inexistente/deployment \
  ~/.local/share/mendix/11.12.1
```

O teste trabalha em diretório temporário, cria o deployment, compila Java e
web, empacota, inicia o Runtime e exige HTTP 200 para `/`, `dist/index.js` e
cada bundle de página. Também verifica shutdown limpo. O transcript e o SHA-256
ficam em `tmp/runtime-boot-evidence.log`. Quando Chromium está instalado, o
teste importa todos os módulos e instancia os factories que não exigem sessão.
O bundle do Data Grid é importado e avaliado; seu factory consulta a sessão do
cliente e, por isso, exige um teste autenticado para ser instanciado.

Em 1º de agosto de 2026, o VetClinic 11.12.1 partiu de deployment inexistente,
executou 675 comandos de sincronização de banco, ativou as filas `System`,
agendou `VetClinic.Cleanup`, respondeu 200 nos quatro bundles de página e
encerrou limpo. O teste funcional `ACT Create Animal` passou em seguida.

## Limites explícitos

- os 12 estágios e a geração web limpa foram validados em 6.10.8, 7.5.0,
  7.17.0, 9.6.1.29396 e 11.12.1;
- o boot nativo exato foi provado em 11.12.1. As distribuições 6/7/9 instaladas
  têm os bundles exatos, mas não PAD/launcher; `db up` falha fechado em vez de
  substituir pelo launcher Java 21 da versão 11;
- Data Grid 1 está coberto, mas os demais widgets Dojo continuam explicitamente
  pendentes no manifesto legado;
- Data Grid 2 está coberto para datasource XPath e colunas de atributo. Gallery
  cobre XPath/microflow e o subconjunto auditado de instruções nanoflow. Os
  formulários React cobrem DataView/TextBox por parâmetro ou nanoflow suportado
  e Save/Cancel; outros widgets e instruções cliente usam o fallback do manifesto;
- bundles web nativos são gerados; o pipeline React Native ainda depende dos
  assets de template/projeto existentes;
- `mx` e `mxbuild` não são fallbacks. Um recurso sem compilador produz erro ou
  entrada no manifesto de suporte.
