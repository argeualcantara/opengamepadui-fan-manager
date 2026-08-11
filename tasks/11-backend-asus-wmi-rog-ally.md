# 11: Backend específico: ASUS ROG Ally (driver `asus-wmi`)

**Origem:** REQUIREMENTS.md §2.1 (caso conhecido: ASUS ROG Ally)
**Depende de:** 01-arquitetura-backends
**Contexto:** descoberto ao pesquisar como o fan control funciona no
ROG Ally rodando Bazzite: ver resumo abaixo.

## Contexto / pesquisa

Diferente do hwmon genérico (`HwmonFanBackend`, atividade 02), que só
aceita escrever um único valor de duty cycle por vez: exigindo que
nosso `CustomCurveEngine` faça polling e reescreva o valor
continuamente: o ROG Ally usa o driver de kernel `asus-wmi`, que
expõe um dispositivo hwmon chamado `asus_custom_fan_curve` com uma
interface nativa de curva:

- `pwm1_enable`: `1` = curva customizada manual, `2` = desabilita a
  curva customizada (devolve controle ao firmware, sem mexer nos
  pontos salvos pelo driver), `3` = igual a `2` **e também** reseta os
  pontos salvos pelo driver para o padrão de fábrica.
- `pwm1_auto_point<N>_temp` / `pwm1_auto_point<N>_pwm` (N de 1 a 8):
  os pontos da curva são escritos diretamente no EC/firmware, que
  passa a segui-la sozinho: **sem necessidade de polling por
  software**.
- Não há validação de segurança da curva no kernel: fica a cargo do
  userspace (nosso plugin) garantir valores sensatos antes de
  escrever.

**Correção importante** (não estava certo numa versão anterior deste
documento): fui direto no código-fonte do `asus-wmi.c`
(`fan_curve_enable_store`) e `pwm1_enable=2` e `=3` são **funcionalmente
idênticos no fan físico**: ambos desligam a curva customizada e
devolvem o controle ao firmware; `3` só adicionalmente reseta os
pontos cacheados pelo driver para o padrão de fábrica. **Não existe
nessa interface um modo "dirigido pelo sistema operacional" de
verdade.** O mecanismo real de perfil dirigido pelo SO no Ally é outro
subsistema, `/sys/firmware/acpi/platform_profile`
(`quiet`/`balanced`/`performance`), completamente separado do
`pwm1_enable`. Decisão (ver seções "OS Mode" e "BIOS Mode" abaixo):
este backend usa `pwm1_enable=2` para **BIOS Mode** (não `3`: não
descarta o cache de pontos do driver à toa) e **não oferece OS Mode**
por enquanto (`supports_os_mode() == false`), em vez de mapear os dois
de forma enganosa para o mesmo comportamento físico.

Também vale registrar: apesar do campo interno do driver se chamar
`data->percents[]`, o valor que o *userspace* escreve em
`pwm1_auto_pointN_pwm` é o duty cycle bruto de **0 a 255** (igual ao
`pwm1` padrão): é o driver que converte para 0-100% internamente
antes de mandar pro firmware. E `pwm1_auto_pointN_temp` é um inteiro
**Celsius puro** (`45` = 45°C), **não** milicelsius como o
`temp1_input` padrão: confirmado lendo o `kstrtou8`/`sysfs_emit` da
função de leitura/escrita, sem nenhuma conversão aplicada.

(Nota: Handheld Daemon (HHD) foi descontinuado a partir do Bazzite 44
e não deve ser considerado como possível dono concorrente desse
recurso: a interface `asus-wmi` fica disponível diretamente para o
userspace.)

### Detalhes de hardware/kernel que afetam a implementação

- **Caminho real no sysfs**: o dispositivo hwmon fica em
  `/sys/devices/platform/asus-nb-wmi/hwmon/hwmon<N>/`, também acessível
  via o symlink genérico `/sys/class/hwmon/hwmon<N>/` (que é o que o
  `HwmonFanBackend` já escaneia). `is_supported()` não precisa
  conhecer o caminho `asus-nb-wmi` específico: basta ler o arquivo
  `name` de cada device em `/sys/class/hwmon/` e comparar com
  `"asus_custom_fan_curve"`, igual já é feito para o backend genérico.
- **Requer kernel ≥ 5.17** para os atributos `pwm1_auto_point*` (o
  suporte a curva customizada via `asus-wmi` foi mergeado nessa
  versão). Qualquer kernel usado por uma Bazzite atual atende isso
  com folga.
- **Driver `asus-armoury` (Linux 6.19+, dez/2025)**: é uma
  reformulação da API de *atributos de BIOS* do `asus-wmi` (MUX de
  GPU, limites de PPT, brilho automático, etc: via `fw_attributes`),
  **não** da interface hwmon de curva de fan. A interface
  `pwm1_enable`/`pwm1_auto_point*` usada aqui continua vindo do
  `asus-wmi` normalmente; o `asus-armoury` é ortogonal a este backend
  e não exige nenhuma mudança de abordagem: só vale registrar que é
  uma área do kernel em movimento, caso apareça alguma migração
  futura da própria interface de fan curve.
- **Número de fans**: o driver expõe `pwm1` (fan CPU) e,
  condicionalmente, `pwm2` (fan GPU) em notebooks com dois fans.
  **Correção (verificação em hardware real, ver
  `tasks/14-suporte-multiplas-fans.md`): o ROG Ally também tem 2 fans
  físicos**, não 1 como assumido aqui originalmente: `hwmon7` expõe
  `pwm1_enable`/`pwm2_enable`, `fan1_input`/`fan2_input`, e
  `fan1_label`/`fan2_label` = `cpu`/`gpu`. `AsusWmiFanBackend` agora
  descobre e opera cada canal (`pwm<N>`) independentemente: o
  `fan_id` passou a ser `"<device>#<canal>"` em vez do path do device
  sozinho. `list_fans()` retorna um `fan_id` por canal encontrado.

### OS Mode: não oferecido por este backend

Ficou definido (ver correção acima): `supports_os_mode()` retorna
`false` no `AsusWmiFanBackend`, igual ao `HwmonFanBackend`. Motivo:
`pwm1_enable` não tem um valor que represente "curva dirigida pelo
SO": só "custom" (1) e "desligado, controle do firmware" (2 ou 3). O
mecanismo real que se qualificaria como OS Mode
(`platform_profile`) é um subsistema ACPI separado, fora do escopo
desta atividade: se quisermos oferecer OS Mode de verdade no Ally no
futuro, é uma atividade nova, não uma extensão trivial desta.

### BIOS Mode: `pwm1_enable=2`, não `=3`: decisão final

Entre `2` (desliga a curva custom, sem mexer nos registradores de
pontos cacheados pelo driver) e `3` (mesma coisa, mas também reseta
esses registradores para os valores de fábrica), a decisão foi usar
**`2`**. Motivo: nenhum perfil salvo pelo nosso plugin (`FanCurveStore`,
atividade 03) é afetado de nenhuma forma por essa escolha: aqueles
vivem em JSON próprio, independentes do cache do driver. `3` fica de
fora por enquanto, para nunca descartar dado nenhum sem necessidade,
mesmo que esse dado seja só o cache interno do driver.

**Efeito colateral aceito**: `get_bios_curve()` lê exatamente esses
registradores (`pwm1_auto_point*_temp`/`_pwm`). Como `2` nunca os
reseta, depois que uma curva customizada for aplicada ao menos uma vez
nesta sessão, `get_bios_curve()` passa a devolver *essa* curva, não
necessariamente a curva de fábrica original do hardware. Isso só é
observável na prática se o usuário entrar em Custom Mode sem nenhum
perfil salvo (ex: deletou o único perfil) depois de já ter usado
Custom Mode antes: um caso de borda raro, mas real, registrado como
item de validação manual na atividade 10.

## Decisão de design: 8 pontos de hardware vs 10 pontos da UI

A UI (REQUIREMENTS §2.3) é fixa em 10 pontos (10-100°C, passo 10). O
`asus-wmi` só aceita até 8. Decisão: **o backend reduz os 10 pontos da
UI para 8 antes de enviar ao hardware** (a UI continua igual para
todos os backends; a redução é um detalhe interno deste backend
específico).

**Decisão (revisada)**: manter sempre os **8 pontos mais quentes**,
descartando os 2 mais frios (10°C e 20°C nos 10 pontos padrão da UI).
Motivo: os pontos mais frios tendem a ficar em ~0% de qualquer forma
(fan parado/idle), então carregam menos informação de forma da curva;
a parte da curva que realmente importa gerenciar (onde o fan
efetivamente varia) é o lado quente, que essa estratégia sempre
preserva por completo. Mais simples e previsível que uma
simplificação adaptativa (tipo Ramer–Douglas–Peucker), e funciona
igual independente de quantos/quais pontos a curva de entrada tiver
(não depende de índices fixos como 30°C/80°C existirem na curva).

## Escopo

- `AsusWmiFanBackend extends FanBackend`
  (`core/backends/asus_wmi_fan_backend.gd`), registrado no
  `FanBackendRegistry` **antes** do `HwmonFanBackend` genérico (mais
  específico primeiro: REQUIREMENTS §2.1).
- `is_supported()`: verdadeiro se existir um device hwmon cujo `name`
  seja `asus_custom_fan_curve` (ler `/sys/class/hwmon/hwmon*/name`).
- `set_mode()`: escreve `pwm1_enable` (`1`=custom, `2`=bios, sem
  reset: ver seção "BIOS Mode" acima; `"os"` é rejeitado:
  `supports_os_mode()` retorna `false`, ver seção "OS Mode" acima).
- `apply_custom_curve()`: garante `pwm1_enable=1` primeiro (mesmo
  raciocínio do `HwmonFanBackend._ensure_manual_mode`: sem isso o
  driver pode ignorar a escrita nos pontos), valida/limita a curva,
  reduz de 10 para 8 pontos (ver decisão acima), e só então escreve
  cada `pwm1_auto_pointN_temp`/`pwm1_auto_pointN_pwm`. **Não** precisa
  de polling contínuo: uma escrita por alteração de curva basta, já
  que o EC segue a curva sozinho.
- `get_bios_curve()`: se o driver permitir leitura de
  `pwm1_auto_point*` mesmo fora do modo custom, usar isso para
  semear o editor; caso contrário, retornar `{}` como o backend
  genérico já faz.
- Validar os valores antes de escrever (curva monotônica, dentro de
  0-100%) já que o kernel não faz essa checagem: reaproveitar a
  regra de monotonicidade do `CustomCurveEngine` (atividade 05) como
  referência, mas a validação aqui é uma segunda camada de segurança
  no backend, não uma duplicação da UI.
- **Novo método na interface `FanBackend`** (`core/backends/fan_backend.gd`):
  `requires_software_polling() -> bool`, com implementação padrão
  `return true` na base (mantém o comportamento atual do
  `HwmonFanBackend` sem precisar tocar nele) e `return false` no
  `AsusWmiFanBackend`, já que o EC segue a curva sozinho depois de uma
  única escrita.
- **Revisado na atividade 07**: `FanModeManager._start_custom_mode()`
  sempre chama `curve_engine.start()`, para qualquer backend: o
  engine é a fonte de verdade única da curva de trabalho (é nele que o
  editor de sliders lê/escreve, atividade 07). A checagem de
  `requires_software_polling()` foi movida para **dentro** de
  `CustomCurveEngine.start()`: ele sempre aplica a curva uma vez, mas
  só inicia o `_poll_timer` de reaplicação periódica quando o backend
  precisa. (Versão anterior deste documento dizia que
  `FanModeManager` pularia o engine inteiramente para esse backend:
  isso quebraria o editor de curva, que depende do engine estar
  sempre inicializado; corrigido.)

## Critérios de aceite

- [x] `is_supported()` retorna `true` apenas em hardware com o hwmon
      `asus_custom_fan_curve` presente.
      → `AsusWmiFanBackend._get_or_discover_fans()` compara o arquivo
      `name` de cada device hwmon.
- [x] Redução de 10 para 8 pontos mantém os 8 pontos mais quentes
      (descarta os 2 mais frios), coberta por teste unitário
      (comparando curva de entrada com os 8 efetivamente enviados).
      → `_reduce_to_hardware_points()` +
      `test_reduce_to_hardware_points_drops_the_two_coldest`.
- [x] `requires_software_polling()` retorna `false` neste backend e
      `true` por padrão em `FanBackend`/`HwmonFanBackend` (sem
      alterar o comportamento já testado do backend genérico).
      → coberto em `asus_wmi_fan_backend_test.gd` e
      `hwmon_fan_backend_test.gd`.
- [x] ~~`FanModeManager` não inicia `CustomCurveEngine`~~: **revisado**:
      o `CustomCurveEngine` é sempre iniciado (é a fonte de verdade da
      curva, usada pelo editor de sliders da atividade 07); o que não
      inicia é o `_poll_timer` de reaplicação periódica, quando o
      backend ativo é o `AsusWmiFanBackend` em Custom Mode: coberto
      por teste em `fan_mode_manager_test.gd` usando um `MockBackend`
      com `requires_software_polling() = false`.
      → `test_custom_mode_attaches_engine_but_skips_polling_when_backend_needs_none`
      (e o caso inverso, `..._uses_curve_engine_when_backend_needs_polling`).
- [ ] Curva aplicada permanece ativa no hardware sem que o plugin
      precise ficar escrevendo continuamente (validação manual em
      hardware real: atividade 10).
- [x] ~~Troca para OS Mode (`pwm1_enable=2`) e BIOS Mode (`pwm1_enable=3`)
      funciona e é distinguível do Custom Mode~~: **revisado**: `os`
      e `bios` seriam fisicamente idênticos nessa interface (ver seção
      "OS Mode" acima), então `supports_os_mode()` retorna `false` e
      `set_mode("os")` é rejeitado, igual ao `HwmonFanBackend`. BIOS
      Mode (`pwm1_enable=3`) e Custom Mode (`=1`) são distinguíveis e
      testados.
- [x] Curvas com valores fora de 0-100% ou não monotônicas são
      corrigidas/rejeitadas antes da escrita no hardware.
      → `_validate_and_clamp()`, testado com clamp e com a regra de
      não-decrescente.
- [x] ~~Apenas `pwm1`/`pwm1_auto_point*` são usados (v1 de fan único);
      `pwm2`, se presente, é ignorado sem causar erro~~: **revisado**:
      verificação em hardware real mostrou que o ROG Ally tem 2 fans
      (CPU/GPU), não 1. Ver `tasks/14-suporte-multiplas-fans.md`:
      `_get_or_discover_fans()` agora enumera cada canal (`pwm1`,
      `pwm2`, ...) que existir no device e retorna um `fan_id` por
      canal, cada um operado de forma independente.

## Notas

- Requer validação em hardware real (ROG Ally rodando Bazzite) antes
  de release: nenhum dos ambientes de desenvolvimento atuais tem
  esse hardware disponível para teste automatizado.
- Requer kernel ≥ 5.17 (qualquer Bazzite atual atende). O driver
  `asus-armoury` (6.19+) não afeta este backend: ver "Detalhes de
  hardware/kernel" acima.
- Suporte a `pwm2` (e canais adicionais) passou a fazer parte do
  escopo: ver `tasks/14-suporte-multiplas-fans.md`. Continua fora de
  escopo desta atividade: leitura de `pwm<N>_auto_point*` fora do modo
  custom para `get_bios_curve()` caso o driver não permita isso: se
  a leitura falhar, o backend cai no comportamento padrão da
  interface (`{}`, como o `HwmonFanBackend` já faz).

## Correção encontrada na atividade 07 (revisão do pipeline completo)

Ao revisar o fluxo de ponta a ponta (mover slider → `CustomCurveEngine`
→ `apply_custom_curve()`), achei um problema de alinhamento:
`get_bios_curve()` deste backend devolve os pontos que o *hardware*
tem salvo, que não têm garantia nenhuma de bater com a grade fixa de
10 pontos da UI (10, 20, ..., 100°C). Sem correção, ao entrar em
Custom Mode pela primeira vez (sem perfil salvo), os sliders de
temperaturas que não batessem exatamente com um ponto salvo no
hardware mostrariam 0% incorretamente.

Corrigido em `FanCurveUtils.resample_to_fixed_points()` (nova função
compartilhada, usa a mesma interpolação linear que o
`HwmonFanBackend` já usava: extraída para `FanCurveUtils.interpolate_value()`
pra não duplicar): `FanModeManager._start_custom_mode()` reamostra
`backend.get_bios_curve()` nessa grade antes de inicializar o engine.
Perfis salvos (atividade 08) não precisam disso, já que são sempre
criados pelo próprio editor, já alinhados à grade.
