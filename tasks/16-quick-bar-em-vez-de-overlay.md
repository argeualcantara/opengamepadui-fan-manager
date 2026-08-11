# 16: Quick Bar em vez de OverlayProvider

**Origem:** teste em hardware real pelo usuário (ROG Ally, sessão
`ogui-overlay-mode.service`): o plugin era detectado e podia ser
habilitado na tela de Plugins, mas nunca aparecia em lugar nenhum
navegável, só "Quick Settings" e "Performance".
**Depende de:** 06-ui-select-modo-overlay (revisa a decisão original
de registrar a UI via `OverlayProvider`).

## Diagnóstico

Dois problemas empilhados, achados via log real (`journalctl`):

### 1. O plugin nunca era inicializado em sessões `--overlay-mode`

`core/ui/card_ui_overlay_mode/card_ui_overlay_mode.gd` (a cena que
`ogui-overlay-mode.service` carrega, usada em produção no Ally)
registra um filtro de plugins:

```gdscript
var filters : Array[Callable] = [plugin_loader.filter_by_tag.bind("quick-bar")]
plugin_loader.set_plugin_filters(filters)
```

`PluginLoader._init_plugins()`, quando há filtros registrados, só
inicializa plugins que passam em pelo menos um filtro: `plugin.gd`
nunca chegava a rodar `_ready()`. Confirmado pelo log:

```
[DEBUG] [PluginLoader] Filtering by tag: quick-bar
[DEBUG] [PluginLoader] fan-manager will not be loaded. ["hardware", "fan", "cooling"]
```

**Fix:** adicionar `"quick-bar"` a `store.tags` em `plugin.json`. Sem
essa tag, o plugin literalmente não roda em `--overlay-mode`,
independente de qualquer código em `plugin.gd`.

### 2. `add_overlay()` não tem onde se registrar em `--overlay-mode`

Mesmo corrigindo (1), `Plugin.add_overlay()`
(`core/systems/plugin/plugin.gd` do OGUI) procura um nó no grupo
`"overlay"` (`OverlayContainer`, dentro de `AlwaysVisibleContent` em
`card_ui.tscn`, a cena da OGUI Overlay **normal**, fora de
`--overlay-mode`). `card_ui_overlay_mode.tscn` (a cena real usada no
Ally) **não tem nenhum `OverlayContainer`**: só um `QuickBarMenu`
(grupo `"quick-bar"`). Ou seja: `add_overlay()` é o mecanismo certo
pra uma OGUI Overlay "normal" (biblioteca/Big Picture), mas não existe
em sessões `--overlay-mode`, que é como o plugin roda de verdade no
Ally.

O que existe em `--overlay-mode`, e é onde "Quick Settings" e
"Performance" (as duas opções que o usuário via) estão registradas: o
**Quick Bar** (`QuickBarMenu`, grupo `"quick-bar"`), via
`Plugin.add_to_quick_bar(qb_item, icon)`, que empacota `qb_item` (um
`Control` qualquer) dentro de um `QuickBarCard` (accordion expansível,
igual "Quick Settings"/"Performance") e adiciona à lista.

## Mudanças

- `plugin.json`: `store.tags` ganha `"quick-bar"`.
- `plugin.gd`: troca `add_overlay(mode_select_overlay)` por
  `add_to_quick_bar(mode_select_overlay, null)`.
- `core/ui/mode_select_overlay.gd`: deixa de `extends OverlayProvider`
  e passa a `extends VBoxContainer` diretamente (remove `provider_id`,
  não usado mais). Motivo: `OverlayProvider` força
  `anchors_preset = PRESET_FULL_RECT` e a cena original usava um
  `MarginContainer` com âncoras fixas (`-280..280`, `-370..370`) pra
  se centralizar sozinha no meio da tela: um truque que só funciona
  quando o pai é um `Container` "bobo" (`OverlayContainer` não tem
  lógica de layout própria, então filhos se posicionam pelas próprias
  âncoras). O Quick Bar usa `ContentContainer`, um `VBoxContainer` de
  verdade, que **ignora âncoras dos filhos e usa o tamanho mínimo
  reportado** para decidir o layout: a cena antiga ficaria com
  tamanho/posição quebrados ali dentro.
- `core/ui/mode_select_overlay.tscn`: raiz simplificada de
  `Control > MarginContainer > Panel > InnerMargin > VBoxContainer`
  pra só `VBoxContainer` (a própria raiz). O `QuickBarCard` já dá
  padding e fundo (tema `ExpandableCard`), então o `Panel`/
  `InnerMargin` extra que existia só pro modo overlay-cheio foi
  removido também: sem paineis aninhados desnecessários.
- Título do card: `QuickBarMenu.add_child_menu()` procura por um filho
  chamado literalmente `"SectionLabel"` dentro do conteúdo (convenção
  de compatibilidade retroativa do próprio OGUI: extrai o `.text` dele
  como título do card e remove o nó), então o antigo `HeaderLabel`
  ("Fan Manager") virou um nó `SectionLabel`, ao lado do `DirtyBadge`
  em `HeaderRow`. `DirtyBadge` sobrevive normalmente (só o
  `SectionLabel` é consumido/removido).

## Bug encontrado ao testar: crash ao desabilitar o plugin

Desabilitar o plugin na tela de Plugins chama
`PluginLoader.uninitialize_plugin()`, que roda `Plugin.unload()` e só
depois libera o próprio nó do plugin. O `unload()` original só fazia
`mode_select_overlay.queue_free()`: mas `add_to_quick_bar()` (OGUI)
empacota `mode_select_overlay` várias camadas dentro de um
`QuickBarCard` que ele mesmo cria e nunca devolve pra gente
(`MarginContainer/CardVBoxContainer/ContentContainer`, dentro de
`viewport` do `QuickBarMenu`). Liberar só o nosso conteúdo deixava
esse `QuickBarCard` órfão pra trás, com `FocusGroupSetter`/efeitos
(`GrowerEffect`, etc.) ainda segurando referência direta pros nós que
acabamos de liberar: a próxima vez que o Quick Bar tocasse nesse card
(fechar, perder foco), batia num nó já `queue_free()`'d.

**Fix:** `unload()` agora sobe a árvore a partir de
`mode_select_overlay` até achar o `QuickBarCard` ancestral
(`_find_ancestor_of_type()`) e libera o card inteiro, não só o nosso
conteúdo: nada fica pendurado com referência morta.

## Critérios de aceite

- [x] `plugin.json` tem a tag `"quick-bar"`.
- [x] `plugin.gd` chama `add_to_quick_bar()`, não mais `add_overlay()`.
- [x] `ModeSelectOverlay` não depende mais de `OverlayProvider`/
      `OverlayContainer`.
- [ ] Validação em hardware real (ROG Ally, `ogui-overlay-mode.service`):
      "Fan Manager" aparece como um novo card ao lado de "Quick
      Settings"/"Performance" no Quick Bar, expansível, com a lista de
      modos/abas/curvas/perfis funcionando dentro dele. Pendente:
      nenhum ambiente de desenvolvimento atual tem esse hardware.

## Notas

- `add_overlay()`/`OverlayProvider` não têm nenhum uso de referência
  dentro do próprio OGUI (`grep` por `extends OverlayProvider` no
  core não encontra nada): é um ponto de extensão exposto mas nunca
  exercitado internamente, o que ajuda a explicar por que esse
  descompasso com `--overlay-mode` não era óbvio de antemão.
- Fica registrado como referência (não é ação nossa): o próprio
  `PluginLoader.init()` conecta os sinais `plugin_installed`/
  `plugin_uninstalled` de forma não-idempotente, gerando os erros
  `Signal '...' is already connected` vistos no log do usuário quando
  os plugins são recarregados mais de uma vez na mesma sessão. Não é
  causado por este plugin nem corrigível a partir dele: é um bug do
  próprio `PluginLoader` no repositório do OGUI.
