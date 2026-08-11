# 08: UI: salvar/carregar perfis customizados

**Origem:** REQUIREMENTS.md §2.3 (linha 76)
**Depende de:** 03-modelo-dados-persistencia, 07-ui-editor-curva-sliders

## Objetivo

Permitir nomear e salvar a curva customizada atual como perfil, e
disponibilizá-la no select box principal para seleção rápida.

## Escopo

- **Antes de implementar em Godot**: criar protótipo em HTML puro
  (`tasks/prototypes/08-perfis.html`) com o fluxo de salvar/nomear,
  a lista de perfis, sobrescrita de nome duplicado e exclusão de
  perfil: **mostrando a tela inteira** (modo + perfis + sliders
  juntos, não só o painel de perfis isolado). Validado com o usuário
  antes de seguir.
- **Decisão de layout** (resolvida no protótipo, não no select box de
  modo): os perfis aparecem numa seção própria ("Perfis salvos")
  dentro do painel de Custom Mode, **entre** a lista de modos e o
  editor de curva: não misturados no select box de BIOS/OS/Custom.
  Botão "Salvar perfil atual" no mesmo painel, abre um campo de texto
  para nome.
  **Superseded pela atividade 15**: a lista sempre-expandida virou um
  picker tipo `<select>` (clica pra abrir/escolher), posicionado acima
  do editor de curva em vez de abaixo, e o botão de salvar migrou para
  a própria região das fans, salvando automaticamente no perfil ativo.
- Ao confirmar, chama `FanCurveStore.save_profile()` (atividade 03)
  com a curva de trabalho atual (`CustomCurveEngine.get_curve()`).
- Selecionar um perfil salvo:
  - carrega e aplica os valores desse perfil imediatamente
    (REQUIREMENTS §2.3, linha 76): já estamos em Custom Mode nesse
    ponto (a seção só é visível nesse modo), então não há troca de
    modo envolvida.
- Nome de perfil duplicado: sobrescreve com confirmação, não cria
  duas entradas com o mesmo nome.
- Permitir deletar um perfil salvo (usa `FanCurveStore.delete_profile`
  da atividade 03); se o perfil deletado era o ativo, cai para o
  último estado custom em memória (não persiste automaticamente um
  novo perfil).
- Badge "Não salvo" no cabeçalho do painel (gancho deixado pela
  atividade 07): aparece quando a curva de trabalho muda
  (`CustomCurveEngine.curve_changed`) e some ao selecionar ou salvar
  um perfil.

## Decisão de implementação: exclusão só por mouse (v1)

Cada linha de perfil é um único ponto de foco (D-pad seleciona o
perfil, `ui_accept` carrega). O botão de excluir é um ícone pequeno
dentro da linha com `focus_mode = FOCUS_NONE`: **não navegável por
gamepad na v1**. Motivo: dar foco separado ao botão de excluir
duplicaria os pontos de foco por linha (nome vs. excluir), complicando
a navegação `ui_up`/`ui_down` entre um número variável de perfis; os
critérios de aceite desta atividade não exigem exclusão via gamepad.
Registrado como limitação conhecida, não como bug.

## Critérios de aceite

- [x] Salvar um perfil com nome novo faz ele aparecer imediatamente no
      select box, sem reabrir o plugin.
      → `ProfileManagerPanel._commit_save()` chama `_rebuild_rows()`
      logo após salvar.
- [x] Selecionar um perfil salvo aplica a curva correta ao hardware.
      → `apply_profile()` (`_on_row_selected` renomeado pra público na
      atividade 12) → `CustomCurveEngine.load_curve()` → aplica
      imediatamente via `_apply_now()`. Selecionar um perfil já salvo
      continua aplicando na hora: só a edição de sliders (`set_point`)
      deixou de aplicar automaticamente, ver atividade 05/12.
- [x] Sobrescrever um perfil existente atualiza o valor sem duplicar
      entrada no select box.
      → fluxo de confirmação (`_try_save()` → `overwrite_box` →
      `_confirm_overwrite()`); testado em
      `test_confirming_overwrite_replaces_profile_without_duplicating`.
- [x] Deletar o perfil ativo não deixa a UI em estado inconsistente
      (curva continua aplicada, só o perfil nomeado deixa de existir).
      → `_on_row_delete_requested()`; testado em
      `test_deleting_active_profile_keeps_curve_but_clears_active_marker`.

## Implementação

- `core/engine/custom_curve_engine.gd`: novo método `load_curve()`,
  reaplica o backend/fan_id já anexados com uma curva diferente (usado
  ao selecionar um perfil).
- `core/ui/components/profile_row.gd`/`.tscn`: linha de perfil focável
  (nome + indicador ativo + botão excluir só-mouse).
- `core/ui/components/profile_manager_panel.gd`/`.tscn`: orquestra
  listar/salvar/sobrescrever/selecionar/deletar e o rastreio de
  "não salvo", usando `FanCurveStore` (atividade 03) diretamente.
- `core/ui/mode_select_overlay.gd`/`.tscn`: integra o painel de
  perfis entre a lista de modos e o editor de curva (`ProfilesSlot`),
  e o badge "Não salvo" no cabeçalho (`DirtyBadge`).

Testes: `custom_curve_engine_test.gd` (`load_curve`),
`profile_manager_panel_test.gd` (fluxo completo salvar/sobrescrever/
selecionar/deletar/dirty).

**Pendência de validação visual**: aumentei a caixa fixa do painel da
overlay (`MarginContainer` em `mode_select_overlay.tscn`) de 650px
para 740px de altura para caber a nova seção de perfis, mas não há
como confirmar visualmente se cabe bem em telas reais (Deck/Ally ~800px
de altura) sem abrir o editor Godot: verificar na atividade 10.

**Revisão (pós-atividade 12)**: quando não existe nenhum perfil salvo,
`FanModeManager` não seed mais a curva a partir de
`backend.get_bios_curve()`: cria automaticamente um perfil chamado
**"Default"** (`FanCurveUtils.DEFAULT_PROFILE_NAME`/
`DEFAULT_BALANCED_CURVE`) e o usa/salva como ponto de partida. Esse
"Default" aparece na lista de perfis deste painel como qualquer outro:
editável, sobrescrevível, deletável.
