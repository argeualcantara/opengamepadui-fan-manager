# 02: Backend genérico hwmon

**Origem:** REQUIREMENTS.md §2.1
**Depende de:** 01-arquitetura-backends

## Objetivo

Implementar `FanBackend` de fallback baseado em `/sys/class/hwmon`,
usado quando nenhum backend específico de fabricante reconhece o
hardware.

## Escopo

- Migrar/expandir a lógica já existente em `core/fan_manager.gd`
  (`discover_fan_devices`, `get_fan_speed`, `set_fan_speed`) para uma
  classe `HwmonFanBackend extends FanBackend`.
- `is_supported()`: verdadeiro se existir ao menos um device em
  `/sys/class/hwmon` com `pwm1` e `temp1_input` (ou equivalente)
  legível.
- Mapear leitura de temperatura (`temp*_input`, em milicelsius) e
  conversão de PWM (0–255) para porcentagem (0–100%) e vice-versa.
- Detectar se o driver aceita escrita em `pwm1_enable` (necessário
  para alternar entre modo automático do kernel/BIOS e modo manual
  antes de aplicar curva customizada).
- Tratar ausência de permissão de escrita (arquivo não gravável pelo
  usuário) como erro recuperável, não fatal: reportado à UI conforme
  REQUIREMENTS §4.

## Critérios de aceite

- [x] `is_supported()` retorna corretamente em uma máquina com hwmon
      padrão e em uma sem nenhum hwmon com pwm.
      → `core/backends/hwmon_fan_backend.gd`, `_get_or_discover_fans()`
      só considera devices com `pwm1` **e** `temp1_input` presentes;
      `is_supported()` reflete isso. Validação em hardware real fica
      para a atividade 10 (não é testável via GUT puro).
- [x] Leitura de temperatura e percentual de fan corresponde aos
      valores reportados por `sensors` (lm-sensors) na mesma máquina.
      → conversão implementada em `read_temperature()` (milicelsius →
      °C) e `read_fan_percent()`/`_pwm_to_percent()` (0-255 → 0-100%);
      comparação real com `sensors` é validação manual, atividade 10.
- [x] Escrita em `pwm1` e `pwm1_enable` funciona quando o usuário tem
      permissão (ex: via regra udev), e falha de forma controlada
      quando não tem.
      → `_write_text()` retorna `false` e loga `error` em vez de
      lançar exceção quando `FileAccess.open` falha; usado por
      `set_mode()` (escreve `pwm1_enable`) e `apply_custom_curve()`
      (escreve `pwm1`).
- [x] Erros de I/O são logados (ver atividade 09) com o path do
      arquivo e a operação tentada.
      → todo `warn`/`error` inclui o path completo do arquivo sysfs.
- [x] Testes unitários (GUT) para a lógica pura (interpolação de
      curva, conversão PWM↔percentual, rejeição de modos inválidos).
      → `core/backends/hwmon_fan_backend_test.gd`

## Revisão de código

Revisão pós-implementação encontrou e corrigiu 4 problemas:

1. `apply_custom_curve()` escrevia `pwm1` sem garantir `pwm1_enable=1`
   antes: corrigido com `_ensure_manual_mode()`, chamado no início do
   método.
2. `_interpolate_curve()` assumia chaves `int`, mas o formato JSON de
   persistência (REQUIREMENTS §3) usa chaves `String`: corrigido com
   `_normalize_curve_keys()`, testado com chaves string em
   `hwmon_fan_backend_test.gd`.
3. `_get_or_discover_fans()` cacheava um resultado vazio
   permanentemente se consultado antes do hwmon estar populado:
   corrigido para só cachear quando encontra ao menos um fan,
   tentando de novo nas chamadas seguintes até achar algo.
4. `set_mode()` perdia a informação de qual fan específico falhou ao
   trocar de modo: corrigido para logar a lista exata de fans que
   falharam.

## Notas

- Permissões de escrita em `hwmon` normalmente exigem regra `udev`
  fora do escopo deste plugin: documentar isso no README como
  pré-requisito de instalação, não implementar escalonamento de
  privilégio dentro do plugin.
- ~~`core/fan_manager.gd` (o `Node` do esqueleto inicial) ainda não foi
  substituído por este backend~~: feito: `core/fan_manager.gd`/`.tscn`
  foram removidos e `plugin.gd` agora registra `HwmonFanBackend` no
  `FanBackendRegistry` de verdade (fiação fechada junto com a
  atividade 04, ver nota lá).
