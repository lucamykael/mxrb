# Teste manual Ruby-first com VetClinic e Fly Me to the Moon

Este roteiro parte diretamente de um projeto Mendix real, diferente do
Sudoku. A implementação nova nasce nas classes Ruby, é materializada como
documentos Mendix nativos e volta para Ruby/TypeScript sem perder IDs.

O cenário validado é:

```text
Home existente → microflow novo
Página nova → nanoflow TypeScript → microflow Ruby/Mendix → mensagem na página
```

O MPR real permanece em `~/Personal_Projects/mxrb-projects`; todo checkout e
artefato de teste fica sob um único diretório de `/tmp`.

## 1. Preparar a sessão descartável

Use a mesma sessão de shell durante todo o teste:

```bash
export MXRB_PROJECTS_ROOT="$HOME/Personal_Projects"
export MXRB_ROOT="$MXRB_PROJECTS_ROOT/mxrb"
export MXRB_SOURCE="$MXRB_PROJECTS_ROOT/mxrb-projects/certification/vetclinic/VetClinic.mpr"
export MXRB_WORK="$(mktemp -d /tmp/mxrb-vetclinic-manual.XXXXXX)"
export MXRB_RUBY="$MXRB_WORK/vetclinic-ruby"
export MXRB_RUNTIME="$MXRB_WORK/vetclinic-runtime"
export MXRB_COMPILED="$MXRB_WORK/VetClinic-ruby-native.mpr"
export MXRB_SOURCE_SHA256="$(sha256sum "$MXRB_SOURCE" | cut -d ' ' -f1)"

test -f "$MXRB_SOURCE"
test -x "$MXRB_ROOT/bin/mxrb"
printf 'Workspace: %s\n' "$MXRB_WORK"
```

Anote `MXRB_WORK`. Se abrir outro terminal, exporte novamente as variáveis com
o caminho anotado.

## 2. Exportar diretamente em modo Ruby

```bash
cd "$MXRB_ROOT"

bundle exec ruby bin/mxrb export \
  "$MXRB_SOURCE" \
  "$MXRB_RUBY" \
  --mode ruby \
  --flymetothemoon
```

Confira o projeto:

```bash
jq '.modules[] | select(.name == "VetClinic") | .module_roles' \
  "$MXRB_RUBY/.mxrb/ruby-app.json"

jq '.navigation.profiles[] | {name, home_page, items}' \
  "$MXRB_RUBY/.mxrb/ruby-app.json"

find "$MXRB_RUBY/app" -type f | sort | less
```

Para testar alterações ainda não publicadas da sua cópia local do MXRB, edite
`$MXRB_RUBY/Gemfile` e troque:

```ruby
gem 'mxrb'
```

por:

```ruby
gem 'mxrb', path: ENV.fetch('MXRB_ROOT')
```

Esse caminho fica apenas no projeto descartável; não deve ser commitado num
projeto compartilhado.

## 3. Abrir no LazyVim e criar os arquivos

```bash
cd "$MXRB_RUBY"
mkdir -p app/services/vet_clinic app/pages/vet_clinic build
nvim .
```

No LazyVim, use `<leader>ff` para abrir arquivos e `<leader>e` para manter o
explorer visível.

### 3.1 Microflow chamado pela Home existente

Crie `app/services/vet_clinic/act_record_home_access.rb`:

```ruby
# frozen_string_literal: true

module VetClinic
  class ActRecordHomeAccess < Mxrb::RubyApp::Service
    mendix_name 'VetClinic.ACT_RecordHomeAccess'

    native :microflow do
      allowed_roles 'VetClinic.User', 'VetClinic.Administrator'
      log_message 'VetClinic home readiness check completed',
                  level: :info, node: "'VetClinic'"
      show_message 'Clinic workflow is ready', type: :information
    end
  end
end
```

`native :microflow` é Ruby executável pelo DSL tipado e também a definição que
será compilada para o documento `Microflows$Microflow`. Um método `call`
arbitrário pode customizar o runtime Ruby, mas não é traduzido automaticamente
para Mendix; o bloco `native` é o contrato portátil.

### 3.2 Alterar a Home que já existe

Abra `app/pages/vet_clinic/home_page.rb`. Preserve a classe e substitua o
`configure` por este conteúdo. O ID explícito pode ser mantido; o exemplo usa o
nome como chave e o compilador preserva o ID nativo existente:

```ruby
# frozen_string_literal: true

module VetClinic
  class HomePage < Mxrb::RubyApp::Page
    mendix_name 'VetClinic.Home'

    native do
      layout 'VetClinic.ApplicationLayout'
      title 'VetClinic Operations'
      allowed_roles 'VetClinic.User', 'VetClinic.Administrator'

      container :pageHeader, class_name: 'mxrb-page-header' do
        text :pageTitle, caption: 'VetClinic Operations'
        text :pageSubtitle,
             caption: 'Care operations, appointments and animal records in one place.'
      end

      container :quickActions, class_name: 'mxrb-card' do
        text :statusTitle, caption: 'Daily readiness'
        text :statusHelp,
             caption: 'Confirm that the clinic workflow is ready for use.'
        button :checkClinicStatus, caption: 'Check clinic status' do
          on_click microflow: 'VetClinic.ACT_RecordHomeAccess'
        end
      end
    end
  end
end
```

Uma página existente só é reescrita quando declara `native`. Páginas
exportadas que continuam apenas com `configure` permanecem intocadas.

### 3.3 Microflow com retorno

Crie `app/services/vet_clinic/act_refresh_appointment_board.rb`:

```ruby
# frozen_string_literal: true

module VetClinic
  class ActRefreshAppointmentBoard < Mxrb::RubyApp::Service
    mendix_name 'VetClinic.ACT_RefreshAppointmentBoard'

    native :microflow do
      allowed_roles 'VetClinic.User', 'VetClinic.Administrator'
      return_type :String
      log_message 'Appointment Board refreshed',
                  level: :info, node: "'VetClinic'"
      return_value "'Appointment Board refreshed'"
    end
  end
end
```

### 3.4 Nanoflow que chama o backend e volta à página

Crie `app/services/vet_clinic/nan_refresh_appointment_board.rb`:

```ruby
# frozen_string_literal: true

module VetClinic
  class NanRefreshAppointmentBoard < Mxrb::RubyApp::Service
    mendix_name 'VetClinic.NAN_RefreshAppointmentBoard'

    native :nanoflow do
      allowed_roles 'VetClinic.User', 'VetClinic.Administrator'
      call_microflow 'VetClinic.ACT_RefreshAppointmentBoard', as: :message
      show_message '{1}', type: :information, parameters: ['$message']
      return_value :message
    end
  end
end
```

`{1}` recebe o primeiro item de `parameters`. Na projeção TypeScript isso é
resolvido com `runtime.string('$message')`, portanto a página mostra o valor
retornado pelo microflow em vez do texto literal `$message`.

### 3.5 Página nova e item de navegação

Crie `app/pages/vet_clinic/appointment_board_page.rb`:

```ruby
# frozen_string_literal: true

module VetClinic
  class AppointmentBoardPage < Mxrb::RubyApp::Page
    mendix_name 'VetClinic.AppointmentBoard'

    native do
      layout 'VetClinic.ApplicationLayout'
      title 'Appointment Board'
      allowed_roles 'VetClinic.User', 'VetClinic.Administrator'

      container :pageHeader, class_name: 'mxrb-page-header' do
        text :pageTitle, caption: 'Appointment Board'
        text :pageSubtitle, caption: 'Daily appointment operations'
      end

      container :refreshCard, class_name: 'mxrb-card' do
        text :status,
             caption: 'Synchronize the board through the browser and Ruby backend.'
        button :refresh, caption: 'Refresh' do
          on_click nanoflow: 'VetClinic.NAN_RefreshAppointmentBoard'
        end
      end
    end

    navigation caption: 'Appointment Board',
               profile: 'Responsive', icon: 'calendar'
  end
end
```

O item é acrescentado ou atualizado pelo destino da página. Outros itens do
menu nativo não são substituídos. Use `home: true` somente se desejar tornar a
página a Home do perfil.

## 4. Compilar Ruby para Mendix e validar

```bash
cd "$MXRB_RUBY"
export MXRB_ROOT

bundle install
bundle exec mxrb generate project.rb "$MXRB_COMPILED"

bundle exec mxrb validate "$MXRB_COMPILED"
bundle exec mxrb find "$MXRB_COMPILED" 'VetClinic.AppointmentBoard'
bundle exec mxrb find "$MXRB_COMPILED" 'VetClinic.ACT_RecordHomeAccess'
bundle exec mxrb find "$MXRB_COMPILED" 'VetClinic.NAN_RefreshAppointmentBoard'
bundle exec mxrb find "$MXRB_COMPILED" 'VetClinic.ACT_RefreshAppointmentBoard'
```

Resultado esperado:

```text
[mxrb] OK
VetClinic.AppointmentBoard               page
VetClinic.ACT_RecordHomeAccess           microflow
VetClinic.NAN_RefreshAppointmentBoard    nanoflow
VetClinic.ACT_RefreshAppointmentBoard    microflow
```

IDs novos são determinísticos. Documentos existentes são localizados pelo nome
qualificado e conservam seus IDs. Repetir o comando não cria cópias.

## 5. Fazer o round-trip e gerar o TypeScript atualizado

```bash
cd "$MXRB_ROOT"

bundle exec ruby bin/mxrb export \
  "$MXRB_COMPILED" \
  "$MXRB_RUNTIME" \
  --mode ruby \
  --flymetothemoon
```

Confira a preservação das fontes Ruby e a geração do nanoflow:

```bash
cmp \
  "$MXRB_RUBY/app/services/vet_clinic/act_record_home_access.rb" \
  "$MXRB_RUNTIME/app/services/vet_clinic/act_record_home_access.rb"

cmp \
  "$MXRB_RUBY/app/pages/vet_clinic/appointment_board_page.rb" \
  "$MXRB_RUNTIME/app/pages/vet_clinic/appointment_board_page.rb"

rg -n 'callMicroflow|showMessage|runtime.string' \
  "$MXRB_RUNTIME/frontend/src/nanoflows/vet_clinic/nan_refresh_appointment_board.ts"
```

`cmp` sem saída confirma preservação byte a byte. Projeções TypeScript de uma
classe com `native` são regeneradas; outros `.tsx` customizados pelo usuário
continuam restaurados do MPR.

## 6. Executar os gates Ruby e frontend

```bash
cd "$MXRB_RUNTIME"
export MXRB_ROOT

bundle install
npm install --prefix frontend
bundle exec rspec
npm run typecheck --prefix frontend
npm run build --prefix frontend
```

## 7. Configurar autenticação sem versionar senha

```bash
read -rsp 'Senha temporária do usuário tester: ' MXRB_TEST_PASSWORD
printf '\n'

export MXRB_USERS_JSON="$(
  ruby -rjson -rdigest -e '
    digest = Digest::SHA256.hexdigest(ARGV.fetch(0))
    print JSON.generate(
      "tester" => {
        "password_digest" => "sha256$#{digest}",
        "roles" => ["User"]
      }
    )
  ' "$MXRB_TEST_PASSWORD"
)"

unset MXRB_TEST_PASSWORD
```

O bloco acima usa apenas uma senha descartável digitada no terminal. Em projetos
reais, use o secret manager do ambiente. Nunca coloque senha em scripts,
`.env.example`, documentação ou commits.

## 8. Subir Ruby + React e testar manualmente

```bash
cd "$MXRB_RUNTIME"
export MXRB_ROOT

bundle exec mxrb run . \
  --server-port 9292 \
  --client-port 5173
```

Abra `http://127.0.0.1:5173`, entre como `tester` e faça:

1. confirme o título `VetClinic Operations`;
2. clique em `Check clinic status`;
3. confirme `Clinic workflow is ready`;
4. abra `Appointment Board` pelo menu;
5. clique em `Refresh`;
6. confirme `Appointment Board refreshed`;
7. verifique que não há erro no console do navegador.

O segundo botão executa no browser:

```text
NAN_RefreshAppointmentBoard (TypeScript)
  → POST ACT_RefreshAppointmentBoard (Ruby/Mendix)
  → resultado salvo em $message
  → show_message {1}
  → aviso renderizado na página
```

Finalize com `Ctrl-C` e limpe a credencial da sessão:

```bash
unset MXRB_USERS_JSON
```

## 9. Confirmar recompilação e integridade do original

```bash
cd "$MXRB_RUNTIME"
export MXRB_ROOT

bundle exec mxrb generate project.rb "$MXRB_WORK/VetClinic-second-pass.mpr"
bundle exec mxrb validate "$MXRB_WORK/VetClinic-second-pass.mpr"

test "$(sha256sum "$MXRB_SOURCE" | cut -d ' ' -f1)" = \
  "$MXRB_SOURCE_SHA256"
```

## 10. Atalhos úteis do LazyVim

No padrão do LazyVim, `<leader>` é espaço.

| Atalho | Uso neste roteiro |
|---|---|
| `<leader>e` | abrir ou focar o explorer |
| `<leader>ff` | localizar arquivo pelo nome |
| `<leader>/` ou `<leader>sg` | procurar texto no projeto |
| `<leader>sr` | busca e substituição no projeto |
| `<leader>ft` | abrir terminal na raiz |
| `<C-/>` | alternar terminal |
| `<C-h/j/k/l>` | mover entre janelas |
| `<S-h>` / `<S-l>` | buffer anterior/próximo |
| `<leader>bd` | fechar buffer |
| `<leader>cf` | formatar arquivo ou seleção |
| `gd` | ir para definição |
| `gr` | listar referências |
| `K` | documentação/hover |
| `<leader>ca` | code actions |
| `<leader>cr` | renomear pelo LSP |
| `]d` / `[d` | diagnóstico seguinte/anterior |
| `<leader>xx` | diagnósticos no Trouble |

Pressione apenas `<leader>` e aguarde o menu do which-key quando esquecer uma
sequência.

## 11. Checklist de aceite

- [ ] o MPR original manteve o mesmo SHA-256;
- [ ] todo o experimento ficou num diretório único de `/tmp`;
- [ ] Home existente e documentos novos foram declarados nas classes Ruby;
- [ ] `mxrb validate` aprovou os dois MPRs compilados;
- [ ] IDs permaneceram estáveis após o round-trip;
- [ ] RSpec passou;
- [ ] TypeScript e Vite passaram;
- [ ] a Home chamou o microflow novo;
- [ ] a página nova apareceu no menu;
- [ ] nanoflow chamou microflow e mostrou o retorno na página;
- [ ] não houve erro no console do navegador;
- [ ] as fontes Ruby sobreviveram byte a byte à reexportação.

## Correções do MXRB exercitadas por este roteiro

- materialização incremental de páginas, microflows e nanoflows declarados em
  classes Ruby;
- IDs determinísticos para documentos novos e preservação dos existentes;
- item de navegação incremental sem substituir o restante do menu;
- round-trip Ruby → Mendix → Ruby para fontes novas;
- geração TypeScript do nanoflow novo;
- passagem de parâmetros de template do retorno do microflow para
  `show_message` no browser;
- regeneração seletiva de `.tsx` quando a classe Ruby `native` é a fonte
  autoritativa, preservando as demais customizações TypeScript;
- autenticação e efeitos de backend integrados ao frontend Fly Me to the Moon.

O diretório pode ser deixado em `/tmp` para o próximo reboot ou removido após o
teste. Nenhuma etapa exige apagar ou modificar o projeto real armazenado em
`~/Personal_Projects/mxrb-projects`.
