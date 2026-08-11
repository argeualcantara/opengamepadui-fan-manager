# 13: Revisão: primeiro uso, perfil Default, e salvamento explícito

**Origem:** conversa com o usuário (2026), pós-atividade 12.
**Toca:** atividades 04, 05, 07, 08, 11.

Três mudanças de comportamento pedidas pelo usuário, implementadas
juntas por estarem interligadas (a segunda quase quebrou a primeira:
ver nota abaixo).

## 1. Não escrever nada no primeiro carregamento

Antes: `FanModeManager._ready()` sempre chamava `set_mode("bios")`
como padrão quando não havia nada salvo: escrevendo `pwm1_enable` em
todo primeiro uso, mesmo que o hardware já estivesse configurado de
outro jeito.

Agora: `FanCurveStore.exists(hardware_id)` distingue "primeira vez
genuína" de "já tem estado salvo pra reaplicar". Na primeira vez,
`FanModeManager._adopt_current_hardware_mode()` chama o novo
`FanBackend.get_current_mode()` (lê `pwm1_enable`, implementado em
`HwmonFanBackend` e `AsusWmiFanBackend`) e só **reflete** esse valor
na UI/estado do plugin: nunca chama `backend.set_mode()`.

## 2. Perfil "Default" com curva balanceada, em vez de ler da BIOS

Antes: sem nenhum perfil salvo, `_start_custom_mode()` chamava
`backend.get_bios_curve()` e reamostrava pra grade fixa.

Agora: `FanCurveUtils.DEFAULT_PROFILE_NAME` ("Default") +
`DEFAULT_BALANCED_CURVE` (curva fixa, embutida no plugin, não lida de
hardware nenhum). Na primeira entrada em Custom Mode sem nenhum
perfil, esse perfil é criado e salvo de verdade (aparece na lista,
editável/sobrescrevível como qualquer outro).

`FanBackend.get_bios_curve()` continua existindo na interface (não foi
removido), só não é mais chamado por esse caminho.

### Interação com o item 1 (achado durante a implementação)

Se o hardware já estiver em Custom Mode no primeiro carregamento
(caso raro), `_start_custom_mode()` teria criado o perfil Default e
**sobrescrito** a curva que já estava lá: contradizendo o item 1.
Corrigido separando os dois casos: `_adopt_current_hardware_mode()`
nunca chama `_start_custom_mode()`; se o modo detectado for "custom",
chama `_adopt_current_custom_curve()`, que lê a curva atual via
`get_bios_curve()` (sim, esse método específico) e reaplica: não cria
nem usa o perfil Default. Isso ainda reescreve os registradores da
curva (uma aproximação do que já estava lá, por causa da reamostragem),
mas **nunca toca em `pwm1_enable`**, que era a preocupação original.

## 3. Aplicar ao hardware só ao clicar "Save", não durante o arrasto

Antes: `CustomCurveEngine.set_point()` (chamado a cada movimento de
slider) agendava um `_debounce_timer` (150ms) que aplicava a curva ao
hardware automaticamente.

Agora: o engine separa curva **draft** (editada pelos sliders,
`_curve`) da curva **comprometida** (`_committed_curve`, o que
realmente está no hardware). `set_point()` só mexe no draft e emite
`curve_changed` (preview visual, incluindo o empurrão de outros
sliders): nunca escreve. Novo método `commit_draft()` promove o
draft a comprometido e aplica: chamado só em
`ProfileManagerPanel._commit_save()` (o clique em "Save current
profile"). `_debounce_timer` foi removido (ficou sem uso).

`start()`/`load_curve()` continuam aplicando imediatamente: não são
"edição em andamento", são "ativar uma curva já conhecida" (entrar em
Custom Mode, selecionar um perfil salvo), então isso ficou de fora da
mudança de propósito.

O timer de polling periódico (`_poll_timer`, para backends com
`requires_software_polling() == true`) agora reaplica
`_committed_curve`, não o draft: senão as edições não salvas
vazariam pro hardware de qualquer forma dentro de ~2s.

## Arquivos alterados

- `core/persistence/fan_curve_store.gd`: `exists()`.
- `core/backends/fan_backend.gd`: `get_current_mode()` (interface).
- `core/backends/hwmon_fan_backend.gd`,
  `core/backends/asus_wmi_fan_backend.gd`: implementações de
  `get_current_mode()`.
- `core/persistence/fan_curve_utils.gd`:
  `DEFAULT_PROFILE_NAME`/`DEFAULT_BALANCED_CURVE`.
- `core/modes/fan_mode_manager.gd`: `_adopt_current_hardware_mode()`,
  `_adopt_current_custom_curve()`, lógica de fallback pro perfil
  Default em `_start_custom_mode()`.
- `core/engine/custom_curve_engine.gd`: reescrito: draft vs.
  comprometido, `commit_draft()`, remoção do debounce timer.
- `core/ui/components/profile_manager_panel.gd`: `_commit_save()`
  chama `curve_engine.commit_draft()`.

Testes atualizados/criados em `fan_mode_manager_test.gd`,
`custom_curve_engine_test.gd`, `profile_manager_panel_test.gd`,
`fan_curve_store_test.gd`.

## Critérios de aceite

- [x] Primeiro carregamento nunca chama `backend.set_mode()`.
- [x] Primeiro carregamento com hardware já em "custom" adota isso sem
      criar/usar o perfil Default.
- [x] Primeira entrada em Custom Mode sem perfil algum cria e salva um
      perfil "Default" com curva balanceada fixa.
- [x] Entrar em Custom Mode com um "Default" já salvo reusa ele sem
      recriar.
- [x] Mover um slider não gera nenhuma escrita no backend.
- [x] `commit_draft()` (via clicar Save) aplica a curva editada ao
      backend.
- [x] O polling periódico reaplica a curva comprometida, não o draft
      não salvo.
