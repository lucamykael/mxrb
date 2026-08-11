# Migrações do schema do runtime Ruby

`Mxrb::Runtime::SchemaMigrator` identifica entidades, atributos e associações pelo GUID de
armazenamento Mendix. Renomear um artefato mantendo o GUID preserva a tabela ou coluna e os
dados existentes.

## Política segura

- Criação de tabela e adição de atributo opcional são automáticas e idempotentes.
- Atributos `required` são criados como `NOT NULL`.
- Tornar um atributo existente obrigatório reconstrói a tabela dentro de uma transação. Se
  houver `NULL`, a migração usa o valor default declarado; sem default, ela é recusada.
- Adicionar um atributo obrigatório a uma tabela populada exige default. Em tabela vazia, a
  migração pode reconstruir o schema sem backfill.
- Alterações compatíveis preservam os dados e as linhas das associações.
- Remover entidade, atributo ou associação é considerado destrutivo. Por padrão a migração
  lança `Mxrb::Runtime::UnsafeSchemaMigrationError`, com os itens em `error.changes`, e não
  altera o banco.
- Depois de backup e revisão do plano, a limpeza pode ser autorizada explicitamente com
  `allow_destructive: true`. Somente tabelas e colunas registradas nos metadados do MXRB são
  removidas; tabelas externas não são inferidas nem apagadas.

Aplicações Ruby exportadas mantêm essa opção desligada. Para uma execução controlada após o
backup, configure `MXRB_ALLOW_DESTRUCTIVE_MIGRATIONS=true` no perfil de ambiente. Qualquer
outro valor, inclusive variável ausente, mantém o modo fail-closed.

```ruby
database = SQLite3::Database.new('runtime.sqlite3')
migrator = Mxrb::Runtime::SchemaMigrator.new(
  project,
  database: database,
  allow_destructive: true
)
result = migrator.migrate!
puts migrator.migration_plan.changes
```

DDL, cópia de dados, atualização dos metadados e limpeza destrutiva pertencem à mesma
transação SQLite. Qualquer violação de `NOT NULL`, unicidade ou outro erro reverte a migração
inteira.
