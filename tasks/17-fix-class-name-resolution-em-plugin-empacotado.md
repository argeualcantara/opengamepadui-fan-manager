# 17: class_name não resolve em plugin carregado via zip

**Origem:** teste em hardware real, ROG Ally: `plugin.gd` nunca
conseguia nem ser interpretado.
**Depende de:** nenhuma (afeta praticamente todo arquivo `.gd` do
plugin: correção transversal).

## Sintoma

```
SCRIPT ERROR: Parse Error: Could not find type "FanBackendRegistry" in the current scope.
   at: GDScript::reload (res://plugins/fan-manager/plugin.gd:3)
SCRIPT ERROR: Parse Error: Could not find type "FanCurveStore" ...
SCRIPT ERROR: Parse Error: Could not find type "FanModeManager" ...
SCRIPT ERROR: Parse Error: Could not find type "ModeSelectOverlay" ...
SCRIPT ERROR: Parse Error: Could not find type "GameCurveManager" ...
ERROR: Failed to load script "res://plugins/fan-manager/plugin.gd" with error "Parse error".
```

Isso explica retroativamente **tudo** que investigamos nas atividades
15 e 16: o plugin nunca chegou a rodar `_ready()` com sucesso em
nenhum teste anterior em hardware real. Cada correção anterior (tag
`quick-bar`, `add_to_quick_bar()`, fix do `unload()`) era necessária,
mas nenhuma delas conseguiu ser exercitada de fato até agora, porque
`plugin.gd` nem carregava.

## Causa raiz

Usamos `class_name` em praticamente todo script do plugin
(`FanBackendRegistry`, `FanCurveStore`, `ModeSelectOverlay`, etc.) e
referenciamos essas classes pelo nome cru em outros arquivos (ex:
`var registry: FanBackendRegistry`). Isso só resolve se o Godot já
tiver escaneado o projeto inteiro e populado o cache global de nomes
de classe: o que acontece normalmente ao abrir o projeto no editor ou
ao exportar o binário.

O OGUI carrega plugins de um jeito diferente: via
`ProjectSettings.load_resource_pack()` (`core/global/plugin_loader.gd`
do OGUI), lendo o zip que colocamos em
`~/.local/share/opengamepadui/plugins/` **depois** que o binário já
foi exportado/compilado. Os scripts do plugin nunca passam pelo scan
que registra `class_name` globalmente: o cache já está fechado. Cada
arquivo, isolado, ainda parseia bem (a própria declaração `class_name
X` não depende de nada), mas qualquer OUTRO arquivo que tente usar `X`
como tipo falha com "Could not find type X in the current scope".

Confirmado comparando com a documentação oficial de plugins do OGUI
(`docs/documentation/plugins/tutorials/library_plugin.md`): o exemplo
deles **não usa `class_name`** nos scripts do próprio plugin: só usa
tipos do OGUI (`Library`, já registrado globalmente por fazer parte do
binário base) e carrega o script do plugin via `load()`/caminho, nunca
por nome de classe cru.

## Fix

Mecânico, aplicado em todo arquivo `.gd` de produção (não nos
`_test.gd`, que rodam dentro do editor via GUT: lá o scan de projeto
funciona normalmente e `class_name` cru resolve sem problema):

1. **Herança** (`extends OutroTipoDoPlugin`) virou
   `extends "res://plugins/fan-manager/caminho/pro/arquivo.gd"`
   (caminho literal, não depende de registro nenhum). Só dois arquivos
   precisavam disso: `hwmon_fan_backend.gd` e
   `asus_wmi_fan_backend.gd` (ambos `extends FanBackend`).
2. **Uso como tipo** (variável, parâmetro, retorno, `as X`, `X.new()`)
   ganhou um `const X = preload("res://plugins/fan-manager/.../x.gd")`
   no topo do arquivo que usa `X`, mantendo o resto do código
   idêntico: como o nome já é o mesmo usado no resto do arquivo, não
   foi preciso tocar em nenhuma outra linha além de adicionar o
   `const`.
3. `class_name` foi **mantido** em todo arquivo (não atrapalha em
   nada, e ajuda no editor via `make edit`): só paramos de confiar
   nele pra resolução de tipo *entre* arquivos.
4. Classes do próprio OGUI usadas pelo plugin (`Plugin`, `LaunchManager`,
   `QuickBarCard`, `Node`, `Control`, etc.) continuam por nome cru sem
   problema: fazem parte do binário base, compiladas normalmente,
   sempre no cache global.

### Arquivos alterados (todos ganharam `const` no topo, exceto os dois
com `extends` também trocado)

- `core/backends/fan_backend_registry.gd`: `const FanBackend`.
- `core/backends/hwmon_fan_backend.gd`: `extends` por caminho +
  `const HardwareId`, `PwmIo`, `FanCurveUtils`.
- `core/backends/asus_wmi_fan_backend.gd`: `extends` por caminho +
  `const HardwareId`, `PwmIo`, `FanCurveUtils`.
- `core/engine/custom_curve_engine.gd`: `const FanBackend`,
  `FanCurveUtils`.
- `core/ui/components/custom_curve_editor.gd`: `const
  CustomCurveEngine`, `TemperatureSliderRow`, `FanCurveUtils`.
- `core/ui/components/profile_manager_panel.gd`: `const FanCurveStore`,
  `ProfileTriggerButton`, `ProfileRow`.
- `core/modes/fan_mode_manager.gd`: `const FanBackendRegistry`,
  `FanCurveStore`, `CustomCurveEngine`, `FanBackend`, `FanCurveUtils`.
- `core/modes/game_curve_manager.gd`: `const FanCurveStore`,
  `FanModeManager`, `ProfileManagerPanel`.
- `core/ui/mode_select_overlay.gd`: `const FanModeManager`,
  `ModeOptionCard`, `ProfileManagerPanel`, `GameCurveManager`,
  `CustomCurveEditor`, `FanTabButton`.
- `plugin.gd`: `const FanBackendRegistry`, `FanCurveStore`,
  `FanModeManager`, `ModeSelectOverlay`, `GameCurveManager`,
  `AsusWmiFanBackend`, `HwmonFanBackend`.

Não precisaram de mudança (não referenciam nenhuma classe do plugin
fora da própria declaração `class_name`, só nos comentários de doc):
`core/backends/pwm_io.gd`, `core/backends/hardware_id.gd`,
`core/persistence/fan_curve_store.gd`,
`core/persistence/fan_curve_utils.gd`, `core/backends/fan_backend.gd`,
`core/ui/components/mode_option_card.gd`,
`core/ui/components/temperature_slider_row.gd`,
`core/ui/components/profile_row.gd`,
`core/ui/components/profile_trigger_button.gd`,
`core/ui/components/fan_tab_button.gd`, `core/settings_menu.gd`.
Nenhum arquivo `.tscn` precisou de mudança: `[ext_resource
type="Script" path="..."]` já usa caminho direto, nunca nome de
classe cru.

## Verificação

Escrito um script Python ad-hoc (não faz parte do repo) que varre todo
`.gd` de produção, extrai os nomes de classe do plugin usados fora de
comentários, e confirma que cada um está coberto por `class_name`
próprio ou por um `const` local antes de considerar o arquivo limpo.
Rodado até dar zero problemas restantes.

## Critérios de aceite

- [x] Nenhum arquivo `.gd` de produção referencia uma classe do
      próprio plugin por nome cru sem um `const`/`extends` por caminho
      cobrindo esse nome no mesmo arquivo (verificado por script).
- [x] Validação em hardware real (ROG Ally): confirmado por log do
      usuário que os `SCRIPT ERROR: Parse Error: Could not find type
      "..."` sumiram depois desta correção: o problema de `class_name`
      em si está resolvido. Revelou um segundo bug (ver abaixo), agora
      também corrigido; falta uma nova rodada de teste em hardware real
      pra confirmar o carregamento completo.

## Bug nº 2 encontrado no mesmo log: `load()` sombreando o global do Godot

Com o parse error de `class_name` fora do caminho, o compilador do
GDScript conseguiu avançar mais fundo e achou outro erro, dessa vez em
`core/persistence/fan_curve_store.gd`:

```
SCRIPT ERROR: Parse Error: Too many arguments for "get()" call. Expected at most 1 but received 2.
   at: GDScript::reload (res://plugins/fan-manager/core/persistence/fan_curve_store.gd:89)
SCRIPT ERROR: Parse Error: Invalid argument for "save()" function: argument 2 should be "Dictionary" but is "Resource".
   at: GDScript::reload (res://plugins/fan-manager/core/persistence/fan_curve_store.gd:93)
```

Causa: `FanCurveStore` define seu próprio método `load(hardware_id) ->
Dictionary`, mas esse nome **é igual ao da função global do Godot**
`load(path) -> Resource`. Dentro do próprio arquivo, chamadas cruas
`load(hardware_id)` (em `save_profile()`, `delete_profile()`,
`list_profiles()`) resolviam para a função **global**, não para o
método da própria classe: `data` acabava com o tipo estático inferido
como `Resource` em vez de `Dictionary`, e todo uso posterior
(`data.get("profiles", {})`, passar `data` pra `save()`) falhava a
checagem de tipo estática do compilador.

Esse bug já existia desde a atividade 03, mas nunca foi pego porque:
o parse error de `class_name` (bug nº 1) impedia o compilador de
chegar tão longe na análise antes; e os testes GUT rodam no editor,
onde aparentemente esse `load()` cru resolve diferente (ou o caminho
de teste nunca exercitou os três métodos de um jeito que expusesse a
checagem estática).

**Fix:** as três chamadas cruas viraram `self.load(hardware_id)`,
forçando resolução explícita pro método da própria classe em vez do
global. `save()`/`unload()` não têm esse problema (não são nomes de
função global do Godot).
