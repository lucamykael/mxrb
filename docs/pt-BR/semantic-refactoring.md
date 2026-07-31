# Refatoração semântica

**Português** · [English](../en-US/semantic-refactoring.md) · [Deutsch](../de-DE/semantic-refactoring.md)

O índice semântico combina artefatos tipados e referências BSON.
`Project.Navigation` participa de impacto, rename e segurança de remoção.

```ruby
Mxrb.open("Shop.mpr", readonly: false) do |project|
  plan = project.plan_rename("Sales.Home", to: "Landing")
  plan.changes.each { puts _1.inspect }
  plan.apply!
end
```

Todo refactoring segue plano, preview e `apply!`. Um rename atualiza BSON e
`_MxrbArchitecture` na mesma transação. Remove bloqueia referências e unidades
filhas; move, extract, inline e mutações de domínio expõem mudanças antes de
gravar.

O analyzer encontra alvos ausentes, perfis sem home, nomes duplicados, user
roles desconhecidas, homes sem acesso, tokens não resolvidos e contraste
insuficiente. O cache semântico usa fingerprint das unidades; `mxrb cache
status`, `warm` e `clear` expõem métricas e manutenção.

`project.semantic_search_artifacts("criar pedido", limit: 5)` oferece ranking
determinístico em Ruby. A gem opcional `sqlite-vec` acelera a busca em MPRs
graváveis com um índice KNN identificado por backend, dimensão e fingerprint
do modelo. A primeira busca preenche os vetores antes de registrar o índice
como pronto; projetos somente leitura e plataformas sem a extensão mantêm a
mesma API em memória. A adaptação legada é
`mxrb find app.mpr "criar pedido" --semantic`. O comando dedicado também
expõe backend, limite e distância cosseno:

```sh
bundle exec mxrb search "pagamento" App.mpr
bundle exec mxrb search "criar pedido" App.mpr --backend onnx --limit 5
```

O resultado tabular contém rank, distância, nome qualificado e tipo; `--json`
oferece a mesma informação para automação.

Para desenvolvimento ONNX local, use `BUNDLE_WITH=onnx bundle install`.
`backend: :onnx` e o backend automático passam a usar o pipeline documentado
`embedding` do Informers com `sentence-transformers/all-MiniLM-L6-v2`. Um job
dedicado do CI ativa `MXRB_ONNX=1` e executa smoke test real de 384 dimensões;
a instalação e a suíte comuns não baixam o modelo.

O smoke test nativo do sqlite-vec usa um arquivo de dependências próprio para
plataformas suportadas: `BUNDLE_GEMFILE=Gemfile.sqlite-vec bundle install` e
depois `MXRB_SQLITE_VEC=1 BUNDLE_GEMFILE=Gemfile.sqlite-vec bundle exec rspec
spec/semantic_search_spec.rb`. Assim o lockfile principal continua portátil,
mas o CI testa a extensão real.

[Voltar ao índice](README.md)
