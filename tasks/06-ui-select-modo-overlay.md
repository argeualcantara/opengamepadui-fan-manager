# 06: UI: select box de modo na Overlay

**Origem:** REQUIREMENTS.md §2.2, §2.4
**Depende de:** 04-gerenciador-modos

## Objetivo

Tela principal do plugin ao ser aberto pela OGUI Overlay: select box
com BIOS Mode / OS Mode / Custom Mode.

## Escopo

- **Antes de implementar em Godot**: criar protótipo em HTML puro
  (`tasks/prototypes/06-select-modo.html`) cobrindo os estados: modo
  BIOS ativo, modo OS ativo, modo Custom ativo, hardware sem suporte a
  OS Mode (item ausente), e falha ao trocar de modo. Validar com o
  usuário antes de seguir.
- Registrar a UI do plugin como `OverlayProvider`
  (`Plugin.add_overlay()`), conforme a API já mapeada em
  `core/systems/overlay/overlay_provider.gd`.
  **Superseded pela atividade 16**: `add_overlay()`/`OverlayContainer`
  não é visível em sessões `--overlay-mode` (o modo usado em produção
  no ROG Ally): a UI foi movida para o Quick Bar
  (`Plugin.add_to_quick_bar()`), e a cena deixou de ser um
  `OverlayProvider`.
- `OptionButton`/select box com as 3 opções; `OS Mode` só aparece se
  `backend.supports_os_mode()` for verdadeiro (REQUIREMENTS §2.2:
  ocultar/desabilitar quando indisponível).
- Ao selecionar uma opção, chamar `FanModeManager.set_mode()`
  (atividade 04) e refletir o resultado:
  - sucesso: opção fica selecionada, área de edição (atividade 07)
    aparece/some conforme o modo.
  - falha: reverte a seleção visual e mostra mensagem de erro.
- Na inicialização do plugin deve ler o active_mode, se nao tiver, lê o que está persistido no sistema e faz a UI refletir a informação.

## Critérios de aceite

- [x] Abrir a Overlay mostra o modo atualmente ativo pré-selecionado.
      → `_select_card_for_mode(mode_manager.current_mode)` em
      `mode_select_overlay.gd`, chamado no `_ready()`.
- [x] Selecionar cada modo aciona a troca real no hardware (via
      atividade 04) e a UI não fica dessincronizada do estado real.
      → `_on_card_pressed()` chama `mode_manager.set_mode()`; a
      seleção visual só muda depois do retorno (sem update otimista),
      então nunca mostra um estado que o hardware não confirmou.
- [x] `OS Mode` some da lista em hardware que não suporta.
      → `os_card.visible = mode_manager.backend.supports_os_mode()`.
- [x] Painel de edição de curva (atividade 07) só é visível quando `Custom Mode` está ativo.
      → `CustomEditorSlot` (placeholder, real editor vem na atividade
      07), visibilidade controlada em `_select_card_for_mode()`.
- [x] Na inicialização do plugin deve ler o active_mode, se nao tiver, lê o que está persistido no sistema e faz a UI refletir a informação.
      → já resolvido na atividade 04: `FanModeManager._ready()` lê
      `active_mode` do `FanCurveStore` e chama `set_mode()`; a overlay
      só lê `mode_manager.current_mode`, que já reflete isso quando a
      overlay é construída (mesmo `_ready()` do plugin, ordem
      garantida).
- [ ] Navegação completa por gamepad (D-pad + botão A) validada em
      hardware/emulador real: usa `FocusGroup` + `ui_up`/`ui_down`/
      `ui_accept` nativos do Godot (mesmo mecanismo do resto da OGUI
      Overlay), mas não há como validar isso automaticamente sem rodar
      o Godot; fica para a atividade 10.

## Implementação

Protótipo HTML aprovado antes de seguir (ver `tasks/prototypes/06-select-modo.html`).

- `core/ui/components/mode_option_card.gd`/`.tscn`: item de lista
  focável (nome + descrição + checkmark), construído do zero em vez de
  reaproveitar `CardButton` diretamente: `CardButton` só suporta um
  label único centralizado, e nosso item precisa de nome+descrição+
  estado "selecionado". Reaproveita o mesmo padrão de foco/tween de
  `card_button.gd` (highlight gradiente roxo→rosa do tema Dracula) e o
  mesmo tratamento de `ui_accept` para confirmar.
- `core/ui/mode_select_overlay.gd`/`.tscn`: (na época) `extends
  OverlayProvider`, 3 `ModeOptionCard` dentro de um `VBoxContainer` com
  um `FocusGroup` (`res://core/systems/input/focus_group.tscn`), que já
  vem com `ui_up`/`ui_down` mapeados para D-pad e stick esquerdo no
  `project.godot` do OGUI: nenhum input customizado foi necessário.
  Estado "sem hardware suportado" (nenhum backend detectado) também
  tratado: esconde a lista e mostra uma mensagem.
- `plugin.gd` instancia a overlay, injeta `mode_manager` e chama
  `add_overlay()`: fiação real, não só nos testes.
  Ambos os pontos acima foram revisados na atividade 16 (ver nota de
  supersessão acima).
