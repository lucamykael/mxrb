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

[Voltar ao índice](README.md)
