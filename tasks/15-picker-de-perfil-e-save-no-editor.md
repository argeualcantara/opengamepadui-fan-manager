# 15: Picker de perfil acima das curvas + Save na região das fans

**Origem:** feedback do usuário (2026): o único jeito de salvar a
curva editada era um botão dentro do painel de perfis, o que podia
confundir (não fica óbvio que editar sliders na região das fans exige
ir até outra seção pra salvar). Também foi pedido trocar a lista
sempre-expandida de perfis por um componente tipo `<select>` do HTML:
aperta pra escolher, com uma opção "Novo perfil".
**Depende de:** 07-ui-editor-curva-sliders, 08-ui-perfis-salvar-carregar,
14-suporte-multiplas-fans (supersede partes da UI dessas duas).
**Protótipo:** `tasks/prototypes/15-picker-perfil.html`, aprovado pelo
usuário antes desta implementação.

## Decisões do usuário

1. Deve haver um botão "Save" na própria região das fans (perto das
   abas/curvas), que salva automaticamente no perfil selecionado
   quando em Custom Mode: sem precisar procurar um botão de salvar em
   outro lugar da tela.
2. Perfis devem ficar **acima** das curvas, não abaixo.
3. Em vez de listar todos os perfis salvos permanentemente, usar um
   componente "aperta para escolher" (como um `<select>` HTML), com
   uma opção "Novo perfil": ao configurar as fans e clicar em Save
   nesse estado, aí sim pede o nome do perfil.

## Design resultante

### Fluxo de Save

- **Perfil nomeado já ativo** (selecionado da lista ou carregado do
  disco): clicar em Save salva direto nele, sobrescrevendo sem pedir
  confirmação (afinal é o mesmo nome, não uma sobrescrita de outro
  perfil). Isso vale pras curvas de **todas** as fans de uma vez, igual
  já era desde a atividade 14.
- **"Novo perfil" pendente** (nenhum perfil ativo: primeira vez sem
  nenhum perfil salvo, ou o usuário escolheu explicitamente "Novo
  perfil" no picker): clicar em Save abre o formulário de nome. Se o
  nome digitado colidir com um perfil existente, mesma confirmação de
  sobrescrita de sempre (atividade 08).
- Escolher "Novo perfil" no picker **não** pede nome na hora e **não**
  mexe na curva em edição: só marca o picker como pendente (ponto
  apagado, nome em itálico "New profile (unsaved)") pra que o nome só
  seja pedido no clique em Save, como pedido pelo usuário.

### Picker de perfil (substitui a lista sempre-expandida)

Novo componente `ProfileTriggerButton`
(`core/ui/components/profile_trigger_button.gd`/`.tscn`): botão único
mostrando o perfil ativo (ponto verde + nome) ou o estado pendente
(ponto apagado + "New profile (unsaved)"), com um chevron que
indica se o dropdown está aberto. Clicar nele expande/recolhe um
dropdown inline (não é popup flutuante nativo: o layout deste plugin
é um painel de tamanho fixo dentro de uma overlay de gamepad, então um
dropdown inline que empurra o conteúdo abaixo é mais simples de
navegar por D-pad do que um popup sobreposto) contendo:

- Uma `ProfileRow` (mesma da atividade 08, reaproveitada sem mudanças)
  por perfil salvo, com o mesmo botão de excluir (✕, só mouse: mesma
  limitação já registrada na atividade 08).
- Um botão "+ New profile" no final, que marca o picker como pendente
  (ver acima) e fecha o dropdown.

Selecionar uma `ProfileRow` (ou deletar a ativa) fecha o dropdown
automaticamente.

### Posição na tela

Dentro do painel de Custom Mode (`CustomEditorSlot` em
`mode_select_overlay.tscn`), a ordem agora é:

```
ProfilesPanel (picker + botão Save)
FanTabsBar (abas CPU/GPU, ocultas com 1 fan só)
EditorsContainer (CustomCurveEditor de cada fan)
```

O antigo `ProfilesSlot` (painel `InsidePanel` separado, abaixo do
editor de curva) foi removido: perfis e curvas agora dividem o mesmo
painel, com os perfis no topo, exatamente como aprovado no protótipo.

## Mudanças por arquivo

- `core/ui/components/profile_trigger_button.gd`/`.tscn`: novo
  componente (dot + nome + chevron, mesmo padrão de foco/highlight de
  `ModeOptionCard`/`FanTabButton`).
- `core/ui/components/profile_manager_panel.gd`/`.tscn`: reescrito.
  `SaveForm`/`SaveConfirmButton`/`SaveCancelButton` viraram
  `NewNameForm`/`NewNameConfirm`/`NewNameCancel` (só aparecem no
  estado pendente, não mais como o único caminho de salvar). Novo
  `Trigger` (`ProfileTriggerButton`), `Dropdown`, `NewProfileButton`.
  `SaveButton` agora decide internamente (`_on_save_pressed()`) entre
  commitar direto ou abrir o formulário de nome, dependendo se há
  perfil ativo. `_rebuild_rows()`/`apply_profile()`/
  `_on_row_delete_requested()` continuam existindo, só passam a
  chamar `_update_trigger()`/fechar o dropdown também.
- `core/ui/mode_select_overlay.gd`/`.tscn`: `ProfilesSlot` removido;
  `ProfilesPanel` movido pra dentro de `CustomEditorRoot`, antes de
  `FanTabsBar`. `profiles_slot` removido de `mode_select_overlay.gd`
  (a visibilidade de tudo já é coberta por `custom_editor_slot`).

`core/engine/custom_curve_engine.gd`, `core/modes/fan_mode_manager.gd`
e `core/modes/game_curve_manager.gd`: sem mudanças: `apply_profile()`,
`refresh()` e o formato de dados por fan (atividade 14) continuam
exatamente iguais, só a UI em volta deles mudou.

## Critérios de aceite

- [x] Botão Save aparece na região das fans (acima das abas
      CPU/GPU), não mais só dentro de uma lista de perfis separada.
      → `profile_manager_panel.tscn` (`Bar/SaveButton`), instanciado
      dentro de `CustomEditorRoot` em `mode_select_overlay.tscn`.
- [x] Com um perfil já ativo, Save salva direto nele, sem pedir nome
      nem confirmação.
      → `_on_save_pressed()`; testado em
      `test_save_button_commits_directly_when_a_profile_is_already_active`.
- [x] Sem perfil ativo ("Novo perfil"), Save abre o formulário de
      nome.
      → testado em `test_save_button_opens_name_form_when_no_profile_is_active`.
- [x] Escolher "Novo perfil" não pede nome nem altera a curva em
      edição na hora, só marca o picker como pendente.
      → testado em
      `test_picking_new_profile_marks_picker_pending_without_prompting`.
- [x] Perfis aparecem acima das curvas na tela, não abaixo.
      → ordem dos nós em `CustomEditorRoot`
      (`mode_select_overlay.tscn`).
- [x] Lista de perfis não fica mais permanentemente expandida: só
      aparece ao clicar no picker, e fecha ao selecionar um perfil ou
      "Novo perfil".
      → `_toggle_dropdown()`/`_close_dropdown()`; testado em
      `test_toggle_dropdown_flips_visibility_and_trigger_open_state`,
      `test_selecting_a_profile_closes_the_dropdown`,
      `test_picking_new_profile_closes_the_dropdown`.
- [x] Deletar o perfil ativo faz o picker voltar pro estado pendente
      (não fica travado mostrando um nome que não existe mais).
      → testado em
      `test_deleting_active_profile_keeps_curve_but_clears_active_marker`.
