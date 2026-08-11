# 05: Motor da curva customizada

**Origem:** REQUIREMENTS.md §2.3, §4
**Depende de:** 01-arquitetura-backends, 03-modelo-dados-persistencia

## Objetivo

Aplicar continuamente a curva customizada ativa ao hardware, com
polling assíncrono, e impor a regra de monotonicidade ao editar
sliders.

## Escopo

- Classe `CustomCurveEngine` (Node), ativa somente quando o modo atual
  é `custom` (ver atividade 04).
- Loop de polling via `Timer` (intervalo padrão 2s, configurável:
  REQUIREMENTS §4):
  - Lê temperatura atual via `backend.read_temperature()`.
  - Interpola o % de fan entre os dois pontos da curva mais próximos
    da temperatura lida (curva definida apenas nos 10 pontos fixos de
    10 em 10 °C: REQUIREMENTS §2.3).
  - Aplica via `backend.apply_custom_curve()`/equivalente de baixo
    nível, com debounce para não escrever se o valor não mudou.
- Regra de monotonicidade bidirecional (REQUIREMENTS §2.3, atualizada):
  ao alterar o slider de uma temperatura T para um valor V,
  - para toda temperatura T' > T com valor atual < V, elevar o valor
    de T' para V também (empurra os sliders acima para cima);
  - para toda temperatura T' < T com valor atual > V, baixar o valor
    de T' para V também (empurra os sliders abaixo para baixo): regra
    simétrica, adicionada após a implementação inicial (que só
    empurrava para cima) para impedir curva decrescente também ao
    abaixar um valor.
- **Revisado (pós-atividade 12)**: cada alteração de slider fica só na
  curva de trabalho em memória (draft): nem a gravação em disco nem a
  aplicação ao hardware acontecem automaticamente. As duas só
  acontecem juntas, explicitamente, ao clicar "Save current profile"
  (atividade 08). Antes desta revisão, a aplicação ao hardware era
  imediata (com debounce); trocado por decisão do usuário para evitar
  qualquer mudança física no fan antes de um salvamento deliberado.

## Critérios de aceite

- [x] Interpolação entre pontos fixos produz valores razoáveis (ex:
      35°C com pontos 30→20% e 40→35% deve dar ~27-28%).
      → já coberto na atividade 02 (`HwmonFanBackend._interpolate_curve`,
      chamada de dentro de `apply_custom_curve()`); o engine não
      duplica essa lógica, só decide quando chamar o backend.
- [x] Mover um slider de temperatura intermediária para um valor maior
      que os sliders de temperaturas acima ajusta esses
      automaticamente para o mesmo valor (não permite curva
      decrescente).
      → `CustomCurveEngine.set_point()`,
      `test_set_point_pushes_higher_points_up_when_exceeded`.
- [x] ~~Mover um slider para um valor menor que os de temperaturas
      abaixo NÃO altera os sliders abaixo~~: **revisado**: agora
      empurra para baixo os sliders de temperatura *menor* que
      estiverem *acima* do novo valor (regra bidirecional, ver Escopo).
      Sliders abaixo que já estão *dentro* do limite (≤ novo valor)
      continuam intocados.
      → `test_set_point_pulls_lower_points_down_when_undercut`,
      `test_set_point_does_not_raise_lower_points_already_below_the_new_value`,
      `test_set_point_does_not_lower_upper_points_when_undercutting_below`.
- [x] ~~Escrita no hardware é debounced~~: **revisado (pós-atividade
      12)**: em vez de debounce por tempo, `set_point()` agora **nunca**
      escreve no hardware: só atualiza a curva de trabalho (draft) em
      memória e emite `curve_changed` pro preview visual. A escrita
      real só acontece em `commit_draft()`, chamado ao clicar "Save
      current profile" (`ProfileManagerPanel._commit_save()`). Arrastar
      um slider continuamente nunca gera escrita nenhuma até salvar.
      → `test_set_point_does_not_write_to_hardware`,
      `test_commit_draft_applies_the_edited_curve_to_hardware`.
- [x] Falha de leitura/escrita durante o polling não derruba o timer;
      é logada e tentada novamente no próximo ciclo.
      → `_apply_now()` apenas loga `warn` em falha; `_poll_timer`
      continua rodando (`one_shot = false`) e tenta de novo no próximo
      tick.

## Nota de implementação

Implementada junto com a atividade 04: ver nota lá. Arquivos:
`core/engine/custom_curve_engine.gd` +
`core/engine/custom_curve_engine_test.gd`. O comportamento dos timers
em si (tempo real de debounce/polling) é validado manualmente na
atividade 10; os testes GUT cobrem a lógica pura de `set_point()`
chamando o engine sem adicioná-lo à scene tree.

## Notas de UX

- O empurrar de sliders acima deve ser refletido visualmente em tempo
  real na UI (atividade 07), não só no valor salvo: a UI escuta um
  sinal `curve_changed(curve: Dictionary)` emitido pelo engine.
