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

## Conversão segura de SQL para OQL

O caminho inverso aceita um subconjunto de `SELECT` em PostgreSQL, SQL Server
ou ANSI e produz OQL lógico. Informar o projeto permite recuperar exatamente a
capitalização dos módulos, entidades e atributos:

```ruby
projection = Mxrb.open("Shop.mpr") do |project|
  project.sql_to_oql(
    'SELECT p."name" FROM "shop$product" p WHERE p."name" = :Name',
    dialect: :postgresql
  )
end

puts projection.oql if projection.supported?
# SELECT p/Name FROM Shop.Product p WHERE p/Name = $Name
```

O comando unificado `query` converte nas duas direções; `--input -` lê de stdin
e `--json` retorna o resultado tipado:

```sh
bundle exec mxrb query \
  'SELECT p."name" FROM "shop$product" p WHERE p."name" = :Name' \
  --from sql --to oql --project Shop.mpr --dialect postgresql
bundle exec mxrb query 'SELECT p/Name FROM Shop.Product p' \
  --from oql --to sql --dialect sql_server
bundle exec mxrb query --input query.sql --from sql --dialect sql_server --json
```

O subconjunto inclui aliases, joins explícitos, fontes separadas por vírgula,
`WHERE`, `GROUP BY`, `HAVING`, `UNION`, `ORDER BY`, `LIMIT`/`OFFSET`, funções
OQL conhecidas e parâmetros nomeados (`:Name`, `@Name` ou `$Name`). Tabelas
físicas `module$entity` viram `Module.Entity`; sem `--project`, a capitalização
é inferida e o resultado recebe confiança `inferred`.

Escritas, múltiplas instruções, CTEs, subconsultas em `FROM`/`JOIN`, parâmetros
posicionais, funções desconhecidas e extensões sem equivalente OQL seguro, como `ILIKE`,
`DISTINCT ON`, `TOP`, `::` e concatenação `||`, retornam `supported? == false`
com uma explicação em `warnings`.

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

## Plano real e performance do banco

A análise estática não prova qual caminho o otimizador escolherá. No workspace
PostgreSQL materializado, o MXRB também consulta o planner real em JSON e cruza
as relações do plano com `pg_indexes`:

```sh
bundle exec mxrb db explain Shop.mpr \
  "SELECT * FROM \"sales$order\" WHERE status = 'Open'"
bundle exec mxrb db explain Shop.mpr \
  "SELECT * FROM \"sales$order\" WHERE status = 'Open'" --analyze --json
```

O modo padrão usa `EXPLAIN` e não executa a consulta. `--analyze` é explícito
porque usa `EXPLAIN ANALYZE`; a consulta é executada com o papel read-only e
inclui tempos e buffers. O relatório distingue scans sequenciais pequenos, que
podem ser ótimos, de scans grandes; também sinaliza muitas linhas descartadas
pelo filtro, estimativa de cardinalidade divergente, nested loops volumosos e
sorts que foram para disco. Índices existentes são mostrados como evidência,
mas o MXRB não inventa `CREATE INDEX` sem conhecer seletividade e workload.

O workload cumulativo do PostgreSQL também pode ser inspecionado:

```sh
bundle exec mxrb db workload Shop.mpr --limit 50
bundle exec mxrb db workload Shop.mpr --limit 50 --json
bundle exec mxrb db workload Shop.mpr --save .mxrb/workload.json
bundle exec mxrb db workload Shop.mpr --compare .mxrb/workload.json
bundle exec mxrb db indexes Shop.mpr --limit 50
```

O workspace habilita `pg_stat_statements` e `track_io_timing`. O relatório
ordena fingerprints por custo acumulado e analisa latência média, cache hit,
I/O, blocos temporários e linhas por chamada. Estatísticas de tabelas revelam
pressão de scans sequenciais; índices não únicos grandes e sem scans observados
também são sinalizados. Como essas métricas são cumulativas desde o reset, uma
remoção de índice nunca é sugerida sem confirmar janela e workload reais.
O baseline permite comparar custo acumulado e latência entre execuções; o
advisor cruza queries, filtros, estatísticas de tabelas e índices existentes.
Ele retorna candidatos com evidência e confiança, além de sobreposições, mas
não aplica DDL automaticamente.

Para um deployment SQL Server, a conexão é explícita e usa `sqlcmd`:

```sh
export MXRB_SQLSERVER_PASSWORD='segredo'
bundle exec mxrb db explain Shop.mpr \
  "SELECT * FROM dbo.[Order] WHERE Status = 'Open'" \
  --engine sql_server --server db.example:1433 \
  --database Shop --user mxrb_analyst --json
bundle exec mxrb db workload Shop.mpr --engine sql_server \
  --server db.example:1433 --database Shop --user mxrb_analyst --limit 50
```

O modo estimado usa `SHOWPLAN_XML`; `--analyze` usa `STATISTICS XML` e executa
somente um `SELECT`/`WITH`. O parser detecta table/clustered scans grandes,
nested loops volumosos, spills para tempdb, divergência de cardinalidade e
hints de missing index. Esses hints permanecem hipóteses do otimizador, não
DDL automático. A senha vai em `SQLCMDPASSWORD`, nunca em argv. O engine não é
inferido do MPR porque pertence à configuração do deployment.

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

As credenciais do administrador do Runtime já criado podem ser consultadas sem
imprimir a senha por padrão:

```sh
bundle exec mxrb db credentials Shop.mpr
bundle exec mxrb db credentials Shop.mpr --copy
bundle exec mxrb db credentials Shop.mpr --json
bundle exec mxrb db credentials Shop.mpr --show-password
```

`--copy` envia a senha ao clipboard por stdin, sem colocá-la nos argumentos do
processo. `--show-password` é a única forma de imprimi-la; no JSON, `password`
permanece `null` sem essa opção. `--copy` e `--show-password` são mutuamente
exclusivos. O comando apenas lê o workspace existente: não cria nem gira
credenciais e orienta executar `db up` quando o estado ainda não existe. Essas
são as credenciais do administrador da aplicação Mendix, distintas dos papéis
PostgreSQL `mxrb_reader` e proprietário do Runtime.

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
- `mxrb_reader` recebe `pg_read_all_stats` no workspace isolado para correlacionar
  fingerprints do Runtime; isso não concede escrita em dados da aplicação.
- `--write` seleciona explicitamente o papel proprietário do Runtime. Escritas
  diretas podem violar invariantes Mendix e devem ser excepcionais.
- O workspace PostgreSQL nunca aponta para banco remoto existente. A análise
  SQL Server é uma conexão de deployment separada e explícita; use um login
  somente leitura com permissão de SHOWPLAN. A senha fica em variável de
  ambiente e keywords de mutação são rejeitadas, inclusive em CTEs.

O toolchain Mendix exato e o daemon Docker precisam estar disponíveis.
Para planos SQL Server, `sqlcmd` precisa estar instalado.
Sincronizações de esquema podem alterar ou rejeitar dados existentes quando o
modelo muda; faça backup de volumes locais valiosos antes de migrações de risco.

Consulte a documentação oficial sobre
[OQL](https://docs.mendix.com/refguide/oql/),
[armazenamento de dados](https://docs.mendix.com/refguide/data-storage/) e
[configuração do Runtime](https://docs.mendix.com/refguide/custom-settings/).
