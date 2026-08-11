# Fan Manager: Especificação de Requisitos

## 1. Visão geral

Plugin OpenGamepadUI para monitorar e controlar a curva de ventoinha do
dispositivo, acessível pela OGUI Overlay. Deve suportar múltiplos
hardwares, cada um com suas particularidades de sensor/controle.

## 2. Requisitos funcionais

### 2.1 Suporte a múltiplos dispositivos / detecção de hardware

- O plugin deve detectar automaticamente o hardware em que está rodando
  (ex: modelo de APU/placa, presente em `/sys/class/dmi/id/product_name`
  ou equivalente) e selecionar o **driver/backend** apropriado para
  aquele hardware.
- A arquitetura deve separar:
  - **Interface genérica de controle de fan** (contrato comum: listar
    fans, ler curva atual, ler/escrever modo, ler/escrever curva
    customizada, aplicar).
  - **Backends específicos por hardware**, que implementam essa
    interface usando o mecanismo real do dispositivo (ex: `hwmon`
    padrão via `pwm*`/`temp*_input`, EC específico de um fabricante,
    ferramenta de terceiros, etc).
- Se nenhum backend reconhecer o hardware, o plugin deve cair em um
  backend genérico baseado em `hwmon` (quando disponível) ou, na
  ausência de qualquer controle utilizável, desabilitar a edição de
  curva customizada e informar isso na UI.
- Deve ser possível adicionar suporte a um novo hardware sem alterar a
  UI ou a lógica de persistência: apenas implementando um novo
  backend e registrando-o no seletor de hardware.
- **Caso conhecido: ASUS ROG Ally (driver `asus-wmi`)**: diferente do
  hwmon genérico (que só aceita escrever um valor de duty cycle por
  vez, exigindo polling por software), o `asus-wmi` expõe um
  dispositivo hwmon `asus_custom_fan_curve` que aceita a curva inteira
  no hardware via `pwm1_auto_point<N>_temp`/`pwm1_auto_point<N>_pwm`
  (N de 1 a 8): o EC passa a seguir a curva sozinho, sem polling.
  `pwm1_enable` tem 3 valores (`1`=custom, `2`/`3`=devolve controle ao
  firmware), mas só `1` e `2` são usados: não existe um valor
  distinto para "modo dirigido pelo SO" nessa interface, então esse
  backend não oferece OS Mode (ver `tasks/11-backend-asus-wmi-rog-ally.md`
  para o porquê). Limitação: o hardware só aceita até **8 pontos**,
  contra os 10 pontos fixos da UI (§2.3): decisão: o backend mantém
  sempre os 8 pontos mais quentes da curva (descarta os 2 mais frios,
  que tendem a ficar perto de 0% de qualquer forma) antes de enviar ao
  hardware.

### 2.2 Modos de operação

Ao abrir o plugin pela OGUI Overlay, a tela principal exibe um
**select box** com três opções:

1. **BIOS Mode**: usa a fan curve definida pela BIOS/firmware do
   dispositivo (o plugin não interfere; qualquer controle customizado
   é desativado/revertido).
2. **OS Mode**: usa a fan curve definida pelo sistema operacional
   (serviço/driver de sistema), quando existir tal mecanismo no
   hardware detectado. Se o hardware não expõe um "OS mode" distinto
   de BIOS/custom, essa opção deve ser ocultada ou desabilitada com
   indicação de indisponibilidade.
3. **Custom Mode**: usa a fan curve definida pelo usuário (ver 2.3).

O modo selecionado deve ser persistido e reaplicado automaticamente
(ex: após reboot ou wake) sem exigir reabertura do plugin.

### 2.3 Custom Mode: edição da fan curve

Ao selecionar **Custom Mode**:

- Se já existe uma fan curve customizada salva para o hardware atual,
  ela deve ser carregada e exibida.
- Se não existe **nenhum perfil** salvo ainda para o hardware atual
  (primeira vez entrando em Custom Mode), o plugin cria automaticamente
  um perfil chamado **"Default"** com uma curva balanceada pré-definida
  (não lida da BIOS/hardware: um valor fixo, sensato, embutido no
  plugin) e o usa como ponto de partida. Esse perfil "Default" fica
  salvo e editável como qualquer outro.
- Na primeiríssima vez que o plugin roda num hardware (nenhum arquivo
  de config ainda existe), **nada é escrito** no controle de modo do
  hardware (`pwm1_enable` ou equivalente): o plugin só lê o modo que
  já está configurado e reflete isso na UI, sem impor BIOS Mode como
  padrão.

A UI de edição deve conter:

- Pontos de temperatura fixos de **10 a 100 °C, em passos de 10 °C**
  (10, 20, 30, ..., 100: 10 pontos no total).
- Para cada ponto de temperatura, um **slider de 0% a 100%**
  representando a velocidade da ventoinha (duty cycle) naquela
  temperatura.
- Ao mover qualquer slider, o novo valor atualiza a curva de trabalho
  em memória e o preview visual imediatamente (incluindo o empurrão de
  outros sliders pela regra de monotonicidade), mas **não** é aplicado
  ao hardware nem salvo em disco automaticamente. A escrita real (no
  hardware e no perfil) só acontece quando o usuário clica em
  "Save current profile": arrastar sliders continuamente nunca gera
  escrita nenhuma até esse momento.
- A curva deve ser monotônica não decrescente por padrão (ou pelo menos
  avisar visualmente se o usuário configurar uma curva "invertida"),
  mas não deve bloquear a edição.
- Regra de monotonicidade bidirecional: ao mover o slider de uma
  temperatura T para um valor V,
  - toda temperatura T' > T com valor atual **menor** que V sobe para V
    (empurra os sliders acima para cima);
  - toda temperatura T' < T com valor atual **maior** que V desce para V
    (empurra os sliders abaixo para baixo);
  - isso garante paridade nos dois sentidos e impede qualquer curva
    decrescente, não só ao subir um valor.
- o usuario pode escolher salvar a atual custom fan curve em um perfil. ao salvar e colocar um nome, essa nova fan curve aparece no select box e muda automaticamente a fancuve com os valores salvos

### 2.4 Troca de modo

Ao mudar a opção no select box (BIOS → OS → Custom ou qualquer
combinação):

- O modo anterior deve ser desaplicado/parado de forma limpa antes de
  aplicar o novo.
- A troca deve refletir imediatamente no hardware (sem exigir restart
  do OGUI ou do jogo em execução).
- A UI dos sliders de Custom Mode só é exibida quando "Custom Mode"
  está selecionado; nos outros modos, a área de edição fica oculta ou
  desabilitada.

## 3. Persistência

- Cada fan curve customizada é salva por **hardware detectado** (não
  global), permitindo múltiplos perfis se o plugin rodar em máquinas
  diferentes ou o usuário trocar de dispositivo.
- Estrutura de dados sugerida:

```json
{
  "hardware_id": "string (identificador único do hardware detectado)",
  "mode": "bios | os | custom",
  "custom_name": "nome do custom profile salvo como perfil de fan",
  "custom_curve": {
    "10": 0,
    "20": 0,
    "30": 20,
    "40": 35,
    "50": 50,
    "60": 65,
    "70": 80,
    "80": 90,
    "90": 100,
    "100": 100
  }
}
```

- Persistência via mecanismo padrão de settings do OGUI
  (`SettingsManager`) ou arquivo próprio em `user://data/fan-manager/`,
  a definir na implementação.

## 4. Requisitos não funcionais

- Leitura/escrita de temperatura e PWM não deve bloquear a thread
  principal (usar polling assíncrono/timer, não leitura síncrona a
  cada frame).
- Falhas de leitura/escrita (permissão negada, dispositivo ausente)
  devem ser logadas e refletidas na UI (ex: mensagem de erro/estado
  desabilitado), sem crashar o plugin.
- A aplicação de curva customizada deve reagir a mudanças de
  temperatura com um intervalo de polling configurável (valor padrão
  sugerido: 2s).
- deve ter um log robusto e funcional que ajude a identificar problemas, principalmente em metodos críticos do sistema

## 5. Fora de escopo (v1)

- ~~Perfis por jogo/aplicação (aplicar curva diferente por título)~~:
  planejado como v2, ver `tasks/12-fancurve-por-jogo.md` (toggle
  "Enable per game config", configs por contexto criadas
  automaticamente, sem UI de associação manual nem troca forçada de
  modo).
- Curvas não-lineares desenhadas livremente (fora dos 10 pontos fixos).
- ~~Suporte a múltiplas ventoinhas independentes no mesmo dispositivo~~
 : implementado para `AsusWmiFanBackend` (confirmado no ROG Ally: 2
  canais, CPU + GPU, cada um com curva própria), ver
  `tasks/14-suporte-multiplas-fans.md`. `HwmonFanBackend` (fallback
  genérico) continua assumindo uma ventoinha só por dispositivo: não
  há convenção confiável entre fabricantes para parear canais extras
  num hwmon genérico.
