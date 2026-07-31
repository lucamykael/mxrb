# OQL, visão SQL e banco local

O MXRB só expõe OQL quando o modelo nativo realmente contém OQL. A descoberta
abrange fontes OQL de datasets e consultas de view entities; um aplicativo sem
OQL retorna uma coleção vazia e não recebe documentos de consulta artificiais.

## Inspeção estática

```ruby
Mxrb.open("Shop.mpr") do |project|
  next unless project.oql?

  project.oql_queries.each do |query|
    puts query.qualified_name
    puts query.oql
    puts query.parameters
  end

  project.oql_sql_views(dialect: :postgresql).each do |view|
    puts view.sql if view.supported?
    warn view.warnings.join("\n")
  end
end
```

A CLI fornece o mesmo resultado tipado:

```sh
bundle exec mxrb oql Shop.mpr
bundle exec mxrb oql Shop.mpr --dialect ansi
bundle exec mxrb oql Shop.mpr --dialect sql_server --json
```

A visão SQL é estritamente de leitura. Parâmetros como `$Customer` viram binds
nomeados como `:Customer`; valores nunca são interpolados. Literais de texto e
comentários permanecem opacos. Múltiplas instruções e operações OQL de escrita
são recusadas.

O SQL gerado tem confiança `logical`. As visões PostgreSQL e SQL Server usam a
forma convencional de tabela `module$entity`; ANSI preserva `Module.Entity`.
Os nomes físicos devem ser conferidos no banco criado pelo Runtime Mendix
exato. Joins por caminho de associação são declarados não suportados enquanto
os metadados de armazenamento do Runtime não puderem provar o join correto.

## Análise dialect-aware

`Oql::Analyzer` encontra padrões de custo e portabilidade na fonte original,
preserva o fragmento para highlight e devolve sugestões para PostgreSQL, SQL
Server e ANSI:

```ruby
report = Mxrb::Oql::Analyzer.new(dialect: :postgresql)
                            .analyze_source("SELECT * FROM Sales.Order")
report.findings.each { puts "#{_1.rule}: #{_1.suggestions[:postgresql]}" }

reports = Mxrb.open("Shop.mpr") { _1.oql_analysis(dialect: :postgresql) }
```

As regras cobrem wildcard inicial, wildcard dos dois lados, busca por prefixo,
`LOWER`/`UPPER`/`CAST` no `WHERE`, produto cartesiano e `SELECT *`. Findings
são `hint`, `warning` ou `error`; `clean?` indica ausência de erros.

O CLI analisa OQL nativo e fontes ad-hoc tanto OQL quanto SQL:

```sh
bundle exec mxrb analyze Shop.mpr --dialect postgresql
bundle exec mxrb analyze --oql "SELECT * FROM Sales.Order"
bundle exec mxrb analyze --sql "SELECT * FROM sales$order" --json
```

## PostgreSQL local materializado

O MPR contém o modelo da aplicação, não um snapshot dos dados. O Runtime Mendix
é responsável pelo esquema do banco e por sincronizá-lo a partir do modelo. O
MXRB pode compilar o Runtime portátil exato, iniciar um PostgreSQL isolado,
permitir essa sincronização e expor acesso SQL:

```sh
bundle exec mxrb db up Shop.mpr
bundle exec mxrb db status Shop.mpr
bundle exec mxrb db sql Shop.mpr \
  'SELECT * FROM "sales$order" LIMIT 20'
bundle exec mxrb db shell Shop.mpr
```

Depois de alterar o MPR, recompile e sincronize preservando os dados:

```sh
bundle exec mxrb db sync Shop.mpr
bundle exec mxrb db down Shop.mpr
```

`db down` para os containers, mas preserva o volume PostgreSQL. Um novo
`db up` reutiliza o pacote em cache e os dados. A porta padrão é
`127.0.0.1:55432` e pode ser alterada com `--port`.

Para ferramentas locais, o mesmo workspace pode ser exposto como JSON HTTP:

```sh
bundle exec mxrb serve Shop.mpr --port 4567
curl -X POST http://127.0.0.1:4567/query \
  -H 'Content-Type: application/json' \
  -d '{"sql":"SELECT * FROM \"sales$order\" LIMIT 20"}'
```

O corpo aceita exatamente um campo `sql` ou `oql`. OQL ad-hoc passa pelo
tradutor PostgreSQL seguro; consultas parametrizadas e qualquer instrução que
não seja um único `SELECT`/`WITH` são rejeitadas. A resposta inclui `rows`,
`row_count`, `elapsed_ms`, avisos ou um erro estruturado. O servidor escuta
somente em loopback, usa `mxrb_reader` e prepara o workspace por padrão;
`--no-up` reutiliza um workspace já ativo.

A limpeza permanente é deliberadamente explícita:

```sh
bundle exec mxrb db destroy Shop.mpr --yes
```

Ela remove apenas recursos com o rótulo de propriedade correspondente do MXRB.

## Fronteira de segurança

- O PostgreSQL só escuta na interface de loopback.
- Cada caminho absoluto de MPR recebe containers, rede, volume e estado
  separados.
- Credenciais aleatórias ficam no diretório de estado XDG do usuário, fora do
  repositório e com modo `0600`.
- `db sql`, `db shell` e `db url` usam `mxrb_reader`, cujas transações e
  configuração do papel são somente leitura.
- `--write` seleciona explicitamente o papel proprietário do Runtime. Escritas
  diretas podem violar invariantes Mendix e devem ser excepcionais.
- O MXRB nunca conecta esse fluxo a um banco remoto já existente.

O toolchain Mendix exato e o daemon Docker precisam estar disponíveis.
Sincronizações de esquema podem alterar ou rejeitar dados existentes quando o
modelo muda; faça backup de volumes locais valiosos antes de migrações de risco.

Consulte a documentação oficial sobre
[OQL](https://docs.mendix.com/refguide/oql/),
[armazenamento de dados](https://docs.mendix.com/refguide/data-storage/) e
[configuração do Runtime](https://docs.mendix.com/refguide/custom-settings/).
