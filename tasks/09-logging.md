# 09: Logging robusto

**Origem:** REQUIREMENTS.md §4 (linha 133)
**Transversal:** aplica-se a todas as demais atividades

## Objetivo

Garantir que métodos críticos (I/O de hardware, troca de modo,
persistência) tenham logging suficiente para diagnosticar problemas em
campo, usando o `Log`/`Logger` já usado no restante do OGUI
(`Log.get_logger(...)`).

## Escopo

- Definir um logger por componente (`FanBackendRegistry`,
  `HwmonFanBackend`, `AsusWmiFanBackend`, `FanModeManager`,
  `CustomCurveEngine`, `FanCurveStore`, `ModeSelectOverlay`,
  `ProfileManagerPanel`) em vez de um logger genérico único, para
  facilitar filtragem: já era o caso desde que cada uma dessas
  classes foi criada (atividades 01-08), não precisou de mudança
  nesta atividade.
- Pontos obrigatórios de log:
  - Detecção de hardware: qual backend foi selecionado e por quê
    (`info`), ou que nenhum foi encontrado (`warn`).
  - Toda escrita em arquivo de hardware (`pwm*`, `pwm*_enable`):
    `debug` em sucesso, `error` com path e motivo em falha.
  - Toda troca de modo: modo anterior → novo modo (`info`); falha ao
    aplicar (`error`).
  - Persistência: salvar/carregar perfil, com nome do perfil e
    hardware_id (`info`); falha de I/O em disco (`error`).
  - Ajustes de monotonicidade da curva (quando sliders são "empurrados"
    automaticamente): `debug`, útil para depurar comportamento
    inesperado reportado por usuário.
- Evitar log em nível `info`/`debug` dentro do loop de polling a cada
  ciclo (2s) quando nada mudou: logar só em mudança de estado, para
  não poluir o log em uso prolongado.

## Critérios de aceite

- [x] Todo método que toca em `/sys/class/hwmon` loga falhas com path
      e operação.
      → já coberto desde as atividades 01-02/11 (`_write_text`,
      `_get_or_discover_fans`, `read_temperature`/`read_fan_percent`
      em `HwmonFanBackend` e `AsusWmiFanBackend`).
- [x] É possível, só lendo o log, reconstruir a sequência de: hardware
      detectado → modo ativado → perfil aplicado → eventuais erros.
      → lacunas encontradas e fechadas nesta atividade:
      `FanModeManager.set_mode()` agora loga "modo anterior → novo
      modo" (antes só logava o modo novo); `_start_custom_mode()`
      agora loga qual foi a fonte da curva inicial (reuso em memória /
      perfil salvo / BIOS); `ProfileManagerPanel._on_row_selected()`
      agora loga qual perfil foi aplicado (salvar/deletar já eram
      logados desde a atividade 03/08, só faltava o "aplicar").
- [x] Log não cresce sem limite em uso normal (nada de log por frame
      ou por tick de polling sem mudança de estado).
      → bug real encontrado: `HwmonFanBackend.apply_custom_curve()`
      escrevia e logava a cada tick do polling (2s), mesmo quando o
      valor de PWM não mudava. Corrigido com `_last_written_pwm`
      (cache do último valor escrito por fan): escreve/loga só quando
      o valor realmente muda. `CustomCurveEngine.set_point()` também
      só loga o "empurrão" de monotonicidade quando algum ponto é
      realmente alterado, não a cada chamada.

## Implementação

Arquivos alterados (nenhum arquivo novo: atividade transversal,
fecha lacunas em código já existente):

- `core/backends/hwmon_fan_backend.gd`: cache `_last_written_pwm`
  (evita escrita/log redundante a cada poll), `_write_text()` loga
  `debug` em sucesso.
- `core/backends/asus_wmi_fan_backend.gd`: `_write_text()` loga
  `debug` em sucesso (mesma mudança; não tinha o problema de polling
  já que não faz polling contínuo).
- `core/engine/custom_curve_engine.gd`: `set_point()` loga `debug`
  quando algum ponto é empurrado pela regra de monotonicidade.
- `core/modes/fan_mode_manager.gd`: `set_mode()` loga modo
  anterior→novo; `_start_custom_mode()` loga a origem da curva
  inicial.
- `core/ui/components/profile_manager_panel.gd`: loga qual perfil foi
  aplicado ao ser selecionado.

Não escrevi testes GUT novos para as linhas de log em si: nenhuma
outra parte do código-base usa asserção sobre saída de log (não há
utilitário de captura de log estabelecido no projeto), então a
verificação aqui é por revisão de código, consistente com o resto do
projeto.
