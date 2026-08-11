# 14: Suporte a múltiplas ventoinhas independentes (ROG Ally: CPU + GPU)

**Origem:** verificação em hardware real pelo usuário: no ROG Ally,
o device hwmon `asus_custom_fan_curve` (`hwmon8`) tem
`pwm1_enable`/`pwm2_enable` e 8 pontos de curva (temp/pwm) por canal;
um device hwmon separado (`hwmon7`) expõe `fan1_input`/`fan2_input` e
`fan1_label`/`fan2_label` = `cpu`/`gpu` pros mesmos dois fans. Supera
a suposição de "fan único" documentada na atividade 11 e o "fora de
escopo" do REQUIREMENTS.md §5. Números de hwmon variam entre boots/
kernels: o que importa é o `name` (`asus_custom_fan_curve`) pro
device de controle, e a busca por `fan<canal>_label` em qualquer
device hwmon pro nome (ver `get_fan_label()` abaixo).
**Depende de:** 01, 02, 03, 04, 05, 07, 08, 11 (todas já
implementadas: esta é uma extensão que toca todas elas).

## Decisão do usuário

Curvas **independentes** por fan (não espelhar a mesma curva nos
dois): CPU e GPU cada um com sua própria curva de 10 pontos,
editável separadamente. Navegação por **abas** (uma por fan) na UI.
Nome do fan: lido de `fan<N>_label` quando existir (`cpu`/`gpu` no
Ally), com fallback `"Fan 1"`, `"Fan 2"`, `"Fan 3"`... quando não
existir.

## Decisão de escopo: só `AsusWmiFanBackend` ganha múltiplas fans

`HwmonFanBackend` (fallback genérico) continua assumindo um fan só
por dispositivo hwmon: não há convenção confiável entre fabricantes
pra parear `pwm2`/`fan2_label` com o mesmo controle térmico do
`pwm1` num hwmon genérico qualquer. A arquitetura abaixo suporta
`list_fans()` retornar 1 ou N fans de qualquer backend, então
`HwmonFanBackend` simplesmente continua retornando 1.

## Modelo de dados: perfis viram um pacote por fan

Antes, um perfil era um dict `{temp: percent}`. Agora, um perfil é um
dict **por fan**: `{fan_id: {temp: percent}}`. Um perfil nomeado
("Silencioso") continua sendo **uma coisa só** que o usuário salva/
seleciona: mas guarda a curva de cada fan junto, não perfis
separados por fan. Isso é uma escolha deliberada: editar as duas fans
e salvar como "Silencioso" de uma vez é mais natural do que ter que
salvar/selecionar cada fan independentemente toda vez.

```json
{
  "hardware_id": "...",
  "active_mode": "custom",
  "active_profile": "Silencioso",
  "profiles": {
    "Silencioso": {
      "hwmon8#1": { "10": 0, "20": 0, "...": "...", "100": 100 },
      "hwmon8#2": { "10": 0, "20": 10, "...": "...", "100": 100 }
    }
  },
  "per_game_enabled": false,
  "game_curves": {
    "elden ring": {
      "mode": "custom",
      "active_profile": "Silencioso",
      "curve": { "hwmon8#1": {"...": "..."}, "hwmon8#2": {"...": "..."} }
    }
  }
}
```

`FanCurveStore` não muda: ele só guarda `Dictionary`s opacas; a
mudança de forma (flat → aninhado por fan) é só nos dados que os
chamadores passam pra ele.

**Sem migração de dados antigos.** O plugin ainda não tem usuários
reais; perfis salvos no formato antigo (flat) ficam invisíveis/
incompatíveis após essa mudança: aceitável nesta fase.

## `fan_id`: formato novo

Antes, `fan_id` era o path do device hwmon inteiro (`/sys/class/hwmon/hwmon7`),
assumindo um canal só. Agora, pra `AsusWmiFanBackend`, `fan_id` inclui
o canal: `"<device_path>#<canal>"`, ex: `"/sys/class/hwmon/hwmon8#1"`.
Métodos internos fazem `fan_id.split("#")` pra reconstruir o path base
e o número do canal, e montam `pwm<canal>`, `pwm<canal>_enable`,
`pwm<canal>_auto_point<N>_temp/pwm`, `fan<canal>_label` a partir
disso.

## Implementação

Seguiu o plano abaixo à risca, com um componente novo não previsto
originalmente: `core/ui/components/fan_tab_button.{gd,tscn}` (mesmo
padrão de foco/highlight do `ModeOptionCard`, simplificado pra um
único label + barra indicadora). `mode_select_overlay.tscn` perdeu a
instância estática de `CurveEditor`: virou um `FanTabsBar`
(`HBoxContainer`, oculto quando só há 1 fan) e um `EditorsContainer`
vazio, ambos populados em runtime por
`ModeSelectOverlay._ensure_fan_editors()`, que instancia um
`CustomCurveEditor`/`FanTabButton` por `fan_id` de
`backend.list_fans()`.

## Mudanças por arquivo

### `core/backends/fan_backend.gd` (interface)

Novo método:
```gdscript
## Human-readable label for the given fan_id (e.g. "CPU", "GPU"),
## used by the UI's fan tabs. Falls back to a generic "Fan N" when the
## backend has no better name.
func get_fan_label(_fan_id: String) -> String:
	return "Fan"
```

### `core/backends/asus_wmi_fan_backend.gd`

- `_get_or_discover_fans()`: pra cada device hwmon com `name ==
  "asus_custom_fan_curve"`, verifica quais canais existem (`pwm1`,
  `pwm2`, ...) e retorna um `fan_id` `"<device>#<n>"` por canal
  encontrado, não um por device.
- `get_fan_label(fan_id)`: lê `fan<canal>_label` (existe no Ally:
  `cpu`/`gpu`); se o arquivo não existir, devolve `"Fan <canal>"`.
  **Correção pós-verificação em hardware real**: o label não fica no
  mesmo device que os registradores de curva: no Ally, o device
  `asus_custom_fan_curve` (`pwm1_enable`/`pwm2_enable`/
  `pwm<N>_auto_point*`) é `hwmon8`, mas `fan1_label`/`fan2_label` só
  existem em `hwmon7`, outro device do mesmo driver. `get_fan_label()`
  primeiro tenta o mesmo device do curve control e, se não achar, varre
  todos os devices hwmon procurando `fan<canal>_label`: assume que o
  *número* do canal é o vínculo entre os dois devices (CPU=1/GPU=2 em
  ambos), já que não há outra referência cruzada exposta pelo driver.
- `set_mode()`, `apply_custom_curve()`, `_ensure_manual_mode()`,
  `read_temperature()`, `read_fan_percent()`, `get_bios_curve()`:
  passam a operar **por canal**: recebem um `fan_id` específico
  (`"...#1"` ou `"...#2"`) e usam o canal certo, não mais hardcoded
  `pwm1`.
- Helper novo `_split_fan_id(fan_id) -> Dictionary` (`{device, channel}`)
  reutilizado por todos os métodos acima.

### `core/modes/fan_mode_manager.gd`

Antes tinha **um** `curve_engine: CustomCurveEngine` injetado no
construtor. Agora `FanModeManager` **cria e possui um
`CustomCurveEngine` por fan_id**, dinamicamente, assim que o backend é
detectado:

```gdscript
var curve_engines: Dictionary = {}  # fan_id -> CustomCurveEngine

func get_curve_engine(fan_id: String) -> CustomCurveEngine
func get_all_curve_engines() -> Dictionary  # fan_id -> CustomCurveEngine
```

`_init(registry, store)`: **não recebe mais `curve_engine` de fora**
(não dá pra saber quantos fans existem antes de detectar o backend).
`_start_custom_mode()` garante um engine por `fan_id` em
`backend.list_fans()` (cria + `add_child()` se não existir), e chama
`.start()`/`load_curve()` em cada um com a fatia daquele fan dentro do
perfil/curva aplicada.

`_persist_active_profile`/leitura de perfil/Default: o valor salvo
sob `profiles[nome]` passa a ser `{fan_id: curve}`: cada engine
recebe só a sua fatia.

### `core/engine/custom_curve_engine.gd`

**Sem mudanças de código**: continua controlando um fan só. A
independência entre fans vem de ter uma instância por fan (composição
em `FanModeManager`), não de ensinar o engine a lidar com múltiplos
fans internamente.

### UI: abas por fan

Nova área acima do editor de curva, dentro do painel de Custom Mode:
uma aba por fan (`FanTabButton`, pequeno, focável, mesmo padrão visual
de foco dos outros componentes), rotulada com `backend.get_fan_label()`.
Cada aba tem seu próprio `CustomCurveEditor` (uma instância por fan,
existente desde a atividade 07: reaproveitada sem mudanças internas,
só instanciada N vezes), alternando visibilidade: só o editor da aba
selecionada fica visível. Se só existe 1 fan (`HwmonFanBackend`), as
abas ficam ocultas (não faz sentido mostrar 1 aba só).

### `core/ui/components/profile_manager_panel.gd`

- `refresh()` ganha uma nova referência: `Dictionary` de todos os
  `curve_engine`s (`mode_manager.get_all_curve_engines()`), não mais
  um único `curve_engine`.
- `_commit_save()`: monta `{fan_id: engine.get_curve()}` iterando
  todos os engines, salva isso como o valor do perfil, e chama
  `commit_draft()` em **cada** engine (aplica todas as fans de uma vez
  ao salvar: consistente com a decisão da atividade 13 de só aplicar
  ao hardware no clique de Salvar).
- `apply_profile(name)`: pra cada `fan_id` no perfil salvo, chama
  `load_curve()` no engine correspondente.
- Rastreio de "dirty": passa a escutar `curve_changed` de **todos** os
  engines (qualquer um sujo marca o painel inteiro como "não salvo").

### `core/modes/game_curve_manager.gd`

`_snapshot_and_save()` monta `curve` como `{fan_id: engine.get_curve()}`
pra todos os engines, em vez de um dict só. `_apply_context()` também
passa a percorrer `saved["curve"]` por `fan_id`.

### `plugin.gd`

Não cria mais um `CustomCurveEngine` solto: `FanModeManager` cuida
disso internamente agora. Remove `curve_engine` de `plugin.gd`.

## Critérios de aceite

- [x] No ROG Ally, `list_fans()` retorna 2 entradas (`hwmon8#1`,
      `hwmon8#2`), rotuladas "CPU" e "GPU" via `fan1_label`/`fan2_label`.
      → `AsusWmiFanBackend._get_or_discover_fans()`/`get_fan_label()`,
      testado (sem hardware real disponível) em
      `asus_wmi_fan_backend_test.gd::test_split_fan_id_*` /
      `test_get_fan_label_falls_back_to_generic_name_when_unreadable`.
      Validação em hardware real ainda pendente (mesma ressalva já
      registrada na atividade 11).
- [x] Trocar pra Custom Mode aplica o `pwm1_enable`/`pwm2_enable` dos
      dois canais (não só o primeiro).
      → `AsusWmiFanBackend.set_mode()` itera `_get_or_discover_fans()`
      inteiro; `FanModeManager._start_custom_mode()` itera
      `backend.list_fans()` e inicia um engine por fan_id.
- [x] O editor mostra abas "CPU"/"GPU"; cada uma edita uma curva
      independente, sem afetar a outra.
      → `FanTabButton` + `ModeSelectOverlay._ensure_fan_editors()`/
      `_select_fan_tab()`, uma instância de `CustomCurveEditor` por
      fan_id, cada uma ligada (`bind_engine`) ao seu próprio
      `CustomCurveEngine`.
- [x] Salvar um perfil grava a curva das duas fans juntas sob o mesmo
      nome; selecionar o perfil aplica as duas de volta.
      → `ProfileManagerPanel._commit_save()`/`apply_profile()`,
      testado em `profile_manager_panel_test.gd::
      test_saving_bundles_curves_from_every_fan_engine`.
- [x] Um hardware com um fan só (`HwmonFanBackend`) não mostra abas:
      comportamento idêntico ao de antes desta atividade.
      → `ModeSelectOverlay._ensure_fan_editors()`:
      `fan_tabs_bar.visible = fans.size() > 1`.
- [x] Perfil por jogo (atividade 12) captura e restaura o estado das
      duas fans, não só uma.
      → `GameCurveManager._snapshot_and_save()`/`_apply_context()`,
      testado em `game_curve_manager_test.gd::
      test_snapshot_bundles_curves_from_every_fan_engine`.
- [x] Fan sem `fan<N>_label` cai pro nome genérico "Fan N", sem
      quebrar nada.
      → `AsusWmiFanBackend.get_fan_label()`, testado em
      `test_get_fan_label_falls_back_to_generic_name_when_unreadable`.
