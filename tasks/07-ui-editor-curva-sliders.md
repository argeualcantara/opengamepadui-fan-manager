# 07: UI: editor de curva com sliders

**Origem:** REQUIREMENTS.md §2.3
**Depende de:** 05-motor-curva-customizada, 06-ui-select-modo-overlay

## Objetivo

Painel de edição da fan curve customizada, visível apenas em Custom
Mode.

## Escopo

- **Antes de implementar em Godot**: criar protótipo em HTML puro
  (`tasks/prototypes/07-editor-curva.html`) com os 10 sliders, os
  labels de temperatura/%, e a interação de "empurrar" sliders acima
  ao arrastar um deles (pode ser feito com JS simples, sem framework).
  Validar com o usuário antes de seguir.
- 10 linhas, uma por temperatura fixa (10, 20, ..., 100 °C: passos de
  10, REQUIREMENTS §2.3): label da temperatura + indicador de valor
  (0–100%, step 1) + label do valor atual.
- Navegação: `ui_up`/`ui_down` movem o foco entre as linhas;
  `ui_left`/`ui_right` ajustam o valor da linha focada. **Decisão
  tomada na implementação**: a ideia original era usar `HSlider` nativo
  (que já trata `ui_left`/`ui_right` de fábrica): mas `FocusGroup`
  (usado na atividade 06) só encadeia `ui_up`/`ui_down` entre filhos
  *diretos* de um `VBoxContainer`, e nossa linha precisa de
  label+valor+indicador juntos, não cabe ser só um `HSlider` puro como
  filho direto. Solução: a linha inteira (`PanelContainer`) é o
  elemento focável, com um indicador de valor desenhado por script (não
  um `HSlider` real), e `_gui_input()` trata `ui_left`/`ui_right`
  manualmente; o encadeamento `ui_up`/`ui_down` entre as 10 linhas é
  feito à mão (mesmo mecanismo que o `FocusGroup` usa por baixo dos
  panos), não via `FocusGroup`.
- Ao entrar em Custom Mode sem perfil salvo, os sliders carregam os
  valores do perfil "Default": criado automaticamente com uma curva
  balanceada pré-definida na primeira vez (revisado na atividade 12;
  não lê mais da BIOS); com outro perfil salvo/ativo, carregam os
  valores desse perfil.
- `value_changed` de cada slider chama a lógica de monotonicidade do
  `CustomCurveEngine` (atividade 05) e atualiza a curva de trabalho em
  memória (draft): **revisado (atividade 12)**: nem a persistência em
  disco nem a aplicação ao hardware são automáticas; as duas só
  acontecem juntas ao clicar "Save current profile" (atividade 08).
- Escuta o sinal `curve_changed` do engine para re-renderizar sliders
  que foram "empurrados" automaticamente por causa da regra de
  monotonicidade, sem recursão infinita (o slider que originou a
  mudança não deve re-disparar `value_changed` ao ser re-setado
  programaticamente).
- Indicar visualmente (ex: cor/texto) quando a curva atual difere de
  um perfil salvo (estado "não salvo"), já preparando o gancho da
  atividade 08.

## Critérios de aceite

- [x] Os 10 sliders são gerados dinamicamente a partir da constante de
      pontos de temperatura (não hardcoded 10 nós na cena).
      → `CustomCurveEditor.FIXED_TEMPERATURE_POINTS` +
      `ROW_SCENE.instantiate()` em loop, `_ready()`.
- [x] Arrastar um slider move visualmente os sliders acima **e abaixo**
      dele quando a regra de monotonicidade (agora bidirecional, ver
      REQUIREMENTS §2.3) se aplica, sem loop infinito de sinais.
      → `CustomCurveEditor._on_curve_changed()` resincroniza todas as
      linhas via `set_percent_silently()`, guardado por
      `_syncing_from_engine` para não re-disparar `engine.set_point()`.
- [x] Trocar de Custom para outro modo e voltar preserva a curva de
      trabalho em memória (não reseta para BIOS a cada troca, só na
      primeira vez sem perfil salvo).
      → corrigido em `FanModeManager._start_custom_mode()`: reusa
      `curve_engine.get_curve()` se não estiver vazio, antes de cair
      pra perfil/BIOS. Testado em
      `test_custom_mode_preserves_in_memory_edits_across_mode_switches`.
- [x] Layout permanece navegável via gamepad (D-pad/analógico),
      consistente com o resto da OGUI Overlay.
      → validação real em hardware fica pra atividade 10, como nas
      demais tarefas de UI.
- [x] `ui_left`/`ui_right` ajustam o valor do slider da linha com foco
      atual; `ui_up`/`ui_down` continuam movendo o foco entre linhas
      sem interferência entre os dois esquemas.
      → `TemperatureSliderRow._gui_input()` trata `ui_left`/`ui_right`
      com `accept_event()`; `ui_up`/`ui_down` não são interceptados
      pela linha, seguem pro sistema de foco padrão do Godot via
      `focus_neighbor_top`/`bottom` (wireados em
      `CustomCurveEditor._wire_focus_neighbors()`).

## Correção relacionada (fora do escopo original, encontrada ao implementar)

`FanModeManager._start_custom_mode()` (atividade 04/11) pulava o
`CustomCurveEngine` inteiramente para backends com
`requires_software_polling() == false` (ex: `AsusWmiFanBackend`),
chamando `backend.apply_custom_curve()` direto. Isso quebraria o editor
desta atividade nesse backend: sem o engine inicializado, os sliders
não teriam de onde ler a curva nem como aplicar edições. Corrigido: o
engine agora **sempre** é iniciado (é a fonte de verdade única da
curva, usada pelo editor); `requires_software_polling()` só decide se
o `_poll_timer` de reaplicação periódica roda ou não: a lógica movida
para dentro de `CustomCurveEngine.start()`. Ver nota na atividade 11.
