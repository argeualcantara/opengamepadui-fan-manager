# 12: Fan curve por jogo

**Origem:** conversa com o usuário (2026): v2, além do escopo original
do `REQUIREMENTS.md` §5 ("Perfis por jogo/aplicação" estava listado
como fora de escopo da v1; esta atividade define como isso funciona
quando for implementado).
**Depende de:** 04-gerenciador-modos, 05-motor-curva-customizada,
08-ui-perfis-salvar-carregar

## Contexto / pesquisa

O OGUI já rastreia jogos em execução via um singleton global
`LaunchManager` (`core/global/launch_manager.gd`, `extends Resource`,
instanciado em `core/global/launch_manager.tres`):

```gdscript
signal app_launched(app: RunningApp)
signal app_stopped(app: RunningApp)
signal app_switched(from: RunningApp, to: RunningApp)
signal all_apps_stopped()

func get_current_app() -> RunningApp
```

`app_switched` dispara sempre que o app **focado** muda: inclusive
quando o foco volta pro OGUI (`to == null`, ou seja, "voltou pra tela
inicial do Steam/OGUI"). Isso cobre tanto "trocou de jogo" quanto
"fechou o jogo e voltou pra home" com o mesmo sinal, sem precisar de
lógica separada para cada caso.

`RunningApp.launch_item: LibraryLaunchItem` tem `.name: String`. O
padrão já usado no código-base do OGUI para guardar configuração por
jogo (perfil de gamepad, em `launch_manager.gd`) é usar
`launch_item.name.to_lower()` como chave: não um hash nem o `_id`
interno (que pode vir vazio para apps detectados automaticamente).
`PerformanceManager` (`core/systems/performance/performance_manager.gd`)
já faz algo equivalente para perfis de TDP por jogo: mesmo padrão de
conectar em `app_switched`/`all_apps_stopped`, mas usa hash porque
salva **um arquivo por jogo**; nosso caso guarda tudo num único JSON
por hardware (`FanCurveStore`), então o nome em minúsculas direto como
chave é mais simples e mais debugável (dá pra olhar o JSON e entender
na hora).

## Comportamento definido (decisão do usuário)

- Novo toggle **"Enable per game config"**, na `mode_select_overlay`,
  logo abaixo da lista de modos (BIOS/OS/Custom) e **antes** da seção
  "Perfis salvos" (atividade 08). **Desligado por padrão. Sempre
  visível** (não só dentro do painel de Custom Mode): como o
  recurso agora pode restaurar o **modo** salvo, faz sentido ele ser
  acionável independente do modo atual (diferente do rascunho inicial
  desta task, que assumia visibilidade só em Custom Mode).
- Com o toggle **ligado**, a config salva por contexto (jogo, ou a
  tela inicial do Steam) guarda o **estado completo**: modo
  (`bios`/`os`/`custom`), perfil customizado ativo (se o modo for
  `custom` e houver um perfil nomeado selecionado) e a curva de
  trabalho em si.
- Ao trocar de contexto (lançar um jogo, trocar de jogo, ou voltar
  pra tela inicial do Steam):
  - **Se já existe config salva para esse contexto** → aplica o
    estado **por completo**: troca de modo inclusa, mesmo que isso
    signifique sair do modo atual (ex: sair de Custom Mode e ir para
    BIOS Mode, ou vice-versa, se foi isso que ficou salvo para aquele
    jogo).
  - **Se não existe** → não mexe em nada, o estado atual continua
    como está.
- **Salvamento contínuo**: enquanto o toggle está ligado e há um
  contexto ativo (jogo rodando ou tela inicial), qualquer mudança de
  estado relevante (trocar de modo, trocar de perfil customizado,
  editar um slider) atualiza a config **daquele contexto** com o
  estado completo atual. É assim que uma config passa a existir para
  um jogo: não há criação/associação manual: se o usuário nunca muda
  nada enquanto joga determinado jogo, nenhuma config chega a ser
  criada para ele (consistente com "se não existe, fica como está":
  nada é forçado nos dois sentidos).
- A **tela inicial do Steam** (nenhum jogo rodando) é só **mais um
  contexto** nesse mesmo mapa, com o mesmo comportamento: não existe
  conceito de "snapshot antes de lançar o jogo" para reverter depois.
- Com o toggle **desligado**, nada disso acontece: comportamento
  idêntico ao que já existe hoje (atividade 08).

## Modelo de dados

Novo campo no documento por hardware já existente
(`core/persistence/fan_curve_store.gd`), **separado** do sistema de
perfis nomeados da atividade 08 (`game_curves` referencia perfis pelo
nome quando aplicável, mas não duplica a lista de perfis em si):

```json
{
  "hardware_id": "...",
  "active_mode": "custom",
  "active_profile": "...",
  "profiles": { "Silencioso": {}, "Performance": {} },
  "per_game_enabled": false,
  "active_game_context": "elden ring",
  "game_curves": {
    "__steam_home__": {
      "mode": "bios",
      "active_profile": null,
      "curve": {}
    },
    "elden ring": {
      "mode": "custom",
      "active_profile": "Performance",
      "curve": { "10": 0, "20": 20, "...": "..." }
    },
    "cyberpunk 2077": {
      "mode": "custom",
      "active_profile": null,
      "curve": { "10": 10, "20": 30, "...": "..." }
    }
  }
}
```

- Chave do contexto: `launch_item.name.to_lower()`, ou a constante
  `GameCurveManager.STEAM_HOME_KEY = "__steam_home__"` quando
  `to == null`.
- `curve` é sempre a curva de trabalho no momento do salvamento
  (mesmo quando `mode != "custom"`, por continuidade/histórico: não
  é usada para aplicar nada fora do modo `custom`).
- `active_profile` só é significativo quando `mode == "custom"`; pode
  ser `null` (curva customizada sem perfil nomeado, "não salva").
- `active_game_context` é guardado para saber em qual entrada de
  `game_curves` o próximo salvamento contínuo deve escrever.

## Escopo

- **Novo componente** `GameCurveManager` (Node,
  `core/modes/game_curve_manager.gd`), análogo ao `FanModeManager`:
  - Recebe referências a `LaunchManager`, `FanCurveStore`,
    `FanModeManager` (para trocar de modo e acessar `curve_engine`),
    `ProfileManagerPanel` (ou equivalente, para aplicar um perfil
    nomeado), `hardware_id`.
  - Conecta em `launch_manager.app_switched(from, to)`,
    `mode_manager.mode_changed(mode)`, `curve_engine.curve_changed(curve)`
    e um novo sinal `profile_manager_panel.active_profile_changed(name)`
    (ver "Mudança necessária na atividade 08" abaixo): juntos, esses
    quatro sinais cobrem **toda** mudança de estado possível enquanto
    um contexto está ativo: trocar de modo, editar a curva, e
    selecionar/salvar/sobrescrever/deletar um perfil nomeado.
  - `_on_app_switched(_from, to)`:
    1. Calcula `context_key` (`to.launch_item.name.to_lower()` ou
       `STEAM_HOME_KEY`).
    2. Atualiza e persiste `active_game_context = context_key`
       (sempre, independente do toggle: assim, se o toggle for
       ligado no meio de uma sessão, já sabe em qual contexto está).
    3. Se `per_game_enabled == false`: para por aqui.
    4. Se `game_curves.has(context_key)`: aplica o estado salvo por
       completo (ver "Aplicar um contexto salvo" abaixo).
    5. Senão: não faz nada: o estado atual permanece, e passa a ser
       capturado pelos hooks de salvamento contínuo a partir de
       qualquer mudança futura.
  - Ao **ligar o toggle** com um jogo já em execução: roda o passo 4
    (ou 5) imediatamente usando `launch_manager.get_current_app()`,
    em vez de esperar o próximo `app_switched`.
  - **Aplicar um contexto salvo** (`_apply_context(context_key)`):
    ```gdscript
    var saved: Dictionary = data["game_curves"][context_key]
    mode_manager.set_mode(saved["mode"])
    if saved["mode"] == "custom":
        var profile_name = saved["active_profile"]
        if profile_name != null and store.load(hardware_id)["profiles"].has(profile_name):
            # equivalente a selecionar aquele perfil no painel
            profiles_panel.apply_profile(profile_name)
        else:
            curve_engine.load_curve(saved["curve"])
    ```
    Se `saved["mode"]` não for mais válido para o backend atual (ex:
    `"os"` salvo, mas o hardware atual não suporta OS Mode: pode
    acontecer se o usuário trocou de dispositivo), `set_mode()` já
    retorna `false` e loga: nesse caso, não tenta mais nada e
    mantém o modo atual (fallback seguro, sem crash).
  - **Salvamento contínuo** (`_snapshot_and_save()`), chamado pelos
    quatro listeners acima quando `per_game_enabled == true` e
    `active_game_context` não é vazio:
    ```gdscript
    var data := store.load(hardware_id)
    var game_curves: Dictionary = data.get("game_curves", {})
    game_curves[active_game_context] = {
        "mode": mode_manager.current_mode,
        "active_profile": data.get("active_profile"),
        "curve": curve_engine.get_curve(),
    }
    data["game_curves"] = game_curves
    store.save(hardware_id, data)
    ```
- **UI**: `CheckBox`/toggle "Enable per game config" em
  `mode_select_overlay.tscn`, entre `ModeList` e `ProfilesSlot`;
  persiste em `per_game_enabled` via `FanCurveStore`.
- **Sem UI dedicada de associação manual**: a config por jogo é
  100% capturada automaticamente a partir de mudanças de estado. Não
  há botão "associar perfil a este jogo" nem tela de lista de jogos
  nesta atividade.

## Mudança necessária na atividade 08

`ProfileManagerPanel` precisa de um novo sinal
`active_profile_changed(name: String)` (nome vazio/`""` quando o
perfil ativo é limpo), emitido em **todos** os pontos que hoje já
atualizam `_active_profile`/persistem `active_profile` no store, mas
não avisam mais ninguém:

- `_on_row_selected()`: selecionar um perfil existente.
- `_commit_save()`: salvar um perfil novo **ou** sobrescrever um
  existente (hoje só atualiza `_active_profile` internamente; sem
  isso, salvar um perfil novo enquanto um jogo está rodando não
  atualizaria a config daquele jogo, que é exatamente o problema que
  motivou esta seção).
- `_on_row_delete_requested()`: quando o perfil deletado era o
  ativo (`_active_profile` volta a `""`).

Também precisa de um método público `apply_profile(name: String) ->
void` (extraído da lógica que já existe em `_on_row_selected()`) para
que `GameCurveManager` possa reaplicar um perfil nomeado sem duplicar
essa lógica.

## Critérios de aceite

- [x] Toggle "Enable per game config" persiste por hardware, vem
      desligado por padrão.
      → `GameCurveManager.per_game_enabled` setter +
      `_persist_enabled()`; `test_disabled_by_default`,
      `test_disabling_toggle_persists`.
- [x] Com o toggle ligado, lançar um jogo com config salva restaura o
      modo, o perfil (se houver) e a curva salvos por completo:
      inclusive trocando de modo se necessário.
      → `_apply_context()`; `test_applying_saved_context_restores_mode_and_curve`,
      `test_applying_saved_context_selects_named_profile`.
- [x] Lançar um jogo sem config salva não altera nada; a config só
      passa a existir a partir da primeira mudança de estado feita
      enquanto esse jogo está em foco.
      → `test_switching_context_without_saved_config_leaves_state_untouched`.
- [x] Trocar de modo, trocar de perfil, editar um slider, salvar um
      perfil novo, sobrescrever um perfil, ou deletar o perfil ativo
     : qualquer uma dessas mudanças, feita com um contexto ativo e o
      toggle ligado, atualiza a config completa daquele contexto (não
      só a curva). Nenhuma mudança de estado fica de fora.
      → `ProfileManagerPanel.active_profile_changed` (nova, emitida em
      selecionar/salvar/sobrescrever/deletar) +
      `mode_manager.mode_changed` + `curve_engine.curve_changed`, todos
      conectados a `_on_state_changed()`/`_on_curve_changed()` →
      `_snapshot_and_save()`. Testado em
      `test_mode_change_with_toggle_on_saves_full_state_for_active_context`
      e `test_curve_edit_with_toggle_on_saves_config_for_active_context`.
- [x] Voltar pra tela inicial do Steam é tratado igual a trocar de
      jogo: mesmo contexto, mesma lógica.
      → `test_null_app_maps_to_steam_home_context`.
- [x] Trocar direto de um jogo pra outro aplica a config do novo jogo
      (ou não faz nada, se não existir) imediatamente.
      → mesma `_apply_or_track()` chamada em todo `app_switched`,
      independente da origem.
- [x] Ligar o toggle com um jogo já em execução aplica a lógica na
      hora, sem esperar o próximo `app_switched`.
      → setter de `per_game_enabled` chama `_apply_or_track()` direto;
      `test_enabling_toggle_with_game_already_running_applies_immediately`.
- [x] Com o toggle desligado, o comportamento é idêntico ao da
      atividade 08: nenhuma interferência.
      → `test_state_change_with_toggle_off_does_not_save_a_config`.
- [x] Aplicar um modo salvo que não é mais suportado pelo backend
      atual (ex: `"os"` sem suporte) falha graciosamente: loga e
      mantém o modo atual, sem travar o plugin.
      → `test_applying_saved_mode_no_longer_supported_falls_back_gracefully`.

## Fora de escopo desta atividade

- Tela/UI dedicada para listar todos os jogos conhecidos e ver/editar
  suas configs sem estar jogando.
- Deletar a config de um jogo específico pela UI (por ora só existe
  criação/atualização automática).
- Múltiplas configs por jogo (ex: uma pra cada modo de energia do
  próprio jogo): é uma config por contexto, ponto.
- Limite/limpeza de `game_curves` para usuários com muitos jogos
  diferentes: decisão explícita de deixar sem limite por agora (cada
  entrada é pequena; ver conversa da atividade).

## Implementação

- `core/modes/game_curve_manager.gd` (novo): orquestra tudo, descrito
  acima. `launch_manager` é tipado frouxamente de propósito (duck
  typing) para não depender da classe `LaunchManager` real do OGUI nos
  testes (que é um `Resource` singleton com inicialização própria,
  arriscada de instanciar fora do app real).
- `core/ui/components/profile_manager_panel.gd`: novo sinal
  `active_profile_changed(name)`, emitido em `apply_profile()`
  (renomeado de `_on_row_selected`, agora público),
  `_commit_save()` e `_on_row_delete_requested()`.
- `core/ui/mode_select_overlay.tscn`/`.gd`: novo `CheckBox`
  "PerGameToggle", sempre visível; `bind_game_curve_manager()` liga o
  toggle ao `GameCurveManager` (precisa ser injetado depois que a
  overlay já existe, já que `GameCurveManager` precisa de
  `mode_select_overlay.profiles_panel`).
- `plugin.gd`: fiação real: cria `GameCurveManager` depois da
  overlay (ordem de dependência), usando
  `load("res://core/global/launch_manager.tres") as LaunchManager`
  como a instância real em produção.

Testes: `game_curve_manager_test.gd` (13 casos) +
`profile_manager_panel_test.gd` (4 casos novos para
`active_profile_changed`). Sem Godot instalado neste ambiente para
rodar de fato: recomendo `make test` antes de validar em hardware
real (atividade 10).
