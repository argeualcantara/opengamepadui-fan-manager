# 04: Gerenciador de modos (BIOS / OS / Custom)

**Origem:** REQUIREMENTS.md §2.2, §2.4
**Depende de:** 01-arquitetura-backends, 03-modelo-dados-persistencia

## Objetivo

Orquestrar a troca entre os três modos de operação, garantindo que o
modo anterior seja desaplicado de forma limpa antes de aplicar o novo,
e que o modo ativo seja persistido e reaplicado automaticamente.

## Escopo

- Classe `FanModeManager` (Node), dona do backend ativo
  (`FanBackendRegistry`) e do modo atual.
- `set_mode(mode: String) -> bool`:
  - `bios`: chama `backend.set_mode("bios")`; para qualquer timer de
    polling/aplicação de curva customizada.
  - `os`: só permitido se `backend.supports_os_mode()`; caso
    contrário, rejeita e a UI não deve nem oferecer a opção
    (atividade 06).
  - `custom`: inicia o motor de curva customizada (atividade 05) com
    o perfil ativo (ou o ponto de partida da BIOS, se nenhum perfil
    existir ainda).
- Ao trocar de modo, persistir `active_mode` via `FanCurveStore`
  (atividade 03).
- Na inicialização do plugin (`_ready`), ler `active_mode` persistido
  e reaplicar automaticamente: sem exigir que o usuário reabra o
  plugin (REQUIREMENTS §2.2, última frase).

## Critérios de aceite

- [x] Trocar de Custom → BIOS para o polling de curva customizada e
      devolve o controle à BIOS.
      → `set_mode()` chama `curve_engine.stop()` antes de qualquer
      troca, e `backend.set_mode("bios")` devolve o pwm ao automático.
      Testado em `test_switching_from_custom_to_bios_stops_the_curve_engine`.
- [x] Trocar de BIOS → OS falha graciosamente (retorna `false` e loga)
      se o backend não suporta OS mode.
      → `test_os_mode_rejected_when_unsupported`.
- [x] Reabrir o OGUI (simulando reinício do plugin) reaplica o último
      modo salvo automaticamente.
      → `_ready()` lê `active_mode` do `FanCurveStore` e chama
      `set_mode()`. Testado em `test_reopening_reapplies_last_saved_mode`
      (instancia um segundo `FanModeManager` sobre o mesmo store).
- [x] Nenhum estado de um modo "vaza" para o outro (ex: polling de
      custom continuando rodando após trocar para BIOS).
      → `curve_engine.stop()` é chamado incondicionalmente no início
      de todo `set_mode()`, não só na transição custom→outro.

## Nota de implementação

Implementada junto com a atividade 05: `set_mode("custom")` precisa
iniciar o `CustomCurveEngine`, então as duas ficaram acopladas por
construção. Ver `core/modes/fan_mode_manager.gd` +
`core/modes/fan_mode_manager_test.gd`.

**Fiação real fechada**: `plugin.gd` agora instancia
`FanBackendRegistry` + `HwmonFanBackend` + `FanCurveStore` +
`CustomCurveEngine` + `FanModeManager` de verdade (antes só existiam
testes com injeção de dependência). O `fan_manager.gd`/`.tscn` do
esqueleto inicial (atividade 0, pré-planejamento) foi removido por
estar completamente substituído. Quando a atividade 11
(`AsusWmiFanBackend`) for implementada, basta adicionar
`registry.register(AsusWmiFanBackend.new())` **antes** do
`registry.register(HwmonFanBackend.new())` em `plugin.gd`: nenhuma
outra mudança necessária, graças à arquitetura de backends da
atividade 01.

**Revisão (pós-atividade 12)**: `_ready()` não chama mais
`set_mode("bios")` como padrão na primeiríssima execução: agora
verifica `store.exists(hardware_id)`; se não existe nenhum arquivo de
config ainda, chama `_adopt_current_hardware_mode()`, que **lê**
`backend.get_current_mode()` e só reflete isso no estado do plugin,
sem escrever `pwm1_enable`. `FanBackend` ganhou o método
`get_current_mode()` (implementado em `HwmonFanBackend` e
`AsusWmiFanBackend`) especificamente para isso. Ver
`FanModeManager._adopt_current_hardware_mode()`/
`_adopt_current_custom_curve()`.
