# 01: Arquitetura de backends e detecção de hardware

**Origem:** REQUIREMENTS.md §2.1

## Objetivo

Definir o contrato genérico de controle de fan e o mecanismo de
detecção/seleção de hardware, de forma que novos hardwares possam ser
suportados sem tocar em UI ou persistência.

## Escopo

- Criar classe base `FanBackend` (`extends RefCounted` ou `Node`) com
  interface mínima:
  - `is_supported() -> bool`: o backend reconhece o hardware atual?
  - `get_hardware_id() -> String`: identificador estável do hardware
    (usado como chave de persistência).
  - `list_fans() -> Array[String]`: fans/dispositivos controláveis.
  - `get_bios_curve(fan_id: String) -> Dictionary`: curva atual da
    BIOS (temperatura → %).
  - `supports_os_mode() -> bool`
  - `set_mode(mode: String) -> bool` (`"bios" | "os" | "custom"`)
  - `apply_custom_curve(fan_id: String, curve: Dictionary) -> bool`
  - `read_temperature(fan_id: String) -> float`
  - `read_fan_percent(fan_id: String) -> float`
- Criar `FanBackendRegistry`: varre backends conhecidos em ordem de
  prioridade (mais específico → genérico), retorna o primeiro cujo
  `is_supported()` seja verdadeiro.
- Se nenhum backend específico reconhecer o hardware, cair no backend
  genérico `hwmon` (atividade 02); se nem esse funcionar, registrar
  estado "sem controle disponível" para a UI consumir.

## Critérios de aceite

- [x] Interface `FanBackend` documentada e versionada.
      → `core/backends/fan_backend.gd`
- [x] `FanBackendRegistry` seleciona corretamente o backend certo dado
      um hardware simulado/mockado.
      → `core/backends/fan_backend_registry.gd` +
      `core/backends/fan_backend_registry_test.gd` (GUT)
- [x] Adicionar um novo backend não exige alterar `FanManager`, UI ou
      código de persistência: apenas registrar a classe no registry.
      → garantido pelo desenho da interface; backends futuros só
      precisam estender `FanBackend` e ser passados a
      `FanBackendRegistry.register()`.
- [x] Estado "sem hardware suportado" é distinguível de "erro
      temporário de leitura".
      → `detect()` retorna `null` e loga um `warn` quando nenhum
      backend suporta o hardware; erros de leitura são tratados
      individualmente por cada backend (ver atividade 02), não pelo
      registry.

## Notas de design

- Reaproveitar `core/fan_manager.gd` existente como ponto de
  descoberta `hwmon`, mas extrair a lógica de descoberta hoje
  hard-coded para dentro do backend genérico (atividade 02).
- `get_hardware_id()` deve ser estável entre reboots (ex: baseado em
  `/sys/class/dmi/id/product_name` + `board_name`, não em paths de
  `hwmon` que podem mudar de índice).
