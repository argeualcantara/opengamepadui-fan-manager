# 03: Modelo de dados e persistência (perfis)

**Origem:** REQUIREMENTS.md §3, §2.3 (linha 76: salvar perfil nomeado)
**Depende de:** 01-arquitetura-backends

## Objetivo

Definir e implementar o armazenamento de configuração e dos perfis de
fan curve customizados, por hardware.

## Escopo

- Estrutura de arquivo por hardware, em
  `user://data/fan-manager/<hardware_id>.json`:

```json
{
  "hardware_id": "string",
  "active_mode": "bios | os | custom",
  "active_profile": "nome do perfil custom ativo, ou null",
  "profiles": {
    "Silencioso": { "10": 0, "20": 0, "30": 20, "...": "...", "100": 100 },
    "Performance": { "10": 20, "20": 30, "...": "...", "100": 100 }
  }
}
```

- API de persistência (`FanCurveStore`):
  - `load(hardware_id: String) -> Dictionary`
  - `save(hardware_id: String, data: Dictionary) -> bool`
  - `save_profile(hardware_id: String, name: String, curve: Dictionary) -> bool`
  - `delete_profile(hardware_id: String, name: String) -> bool`
  - `list_profiles(hardware_id: String) -> Array[String]`
- Se não houver nenhum perfil salvo ao entrar em Custom Mode pela
  primeira vez, a curva de trabalho é inicializada a partir de
  `backend.get_bios_curve()` (REQUIREMENTS §2.3), mas isso só vira um
  perfil persistido quando o usuário explicitamente salvar com nome
  (linha 76).
- Perfil recém-salvo deve ficar imediatamente disponível para a UI
  popular o select box (atividade 08) sem precisar recarregar o
  plugin.

## Critérios de aceite

- [x] Salvar, listar, carregar e deletar perfis funciona
      isoladamente (testável sem UI, ex: via GUT).
      → `core/persistence/fan_curve_store.gd` +
      `core/persistence/fan_curve_store_test.gd`
- [x] Dados persistem entre reinícios do OGUI.
      → armazenado em `user://data/fan-manager/<hardware_id>.json`,
      fora do diretório do plugin (`res://`), sobrevive a
      updates/reload do plugin.
- [x] `hardware_id` diferente gera arquivo separado: nenhuma mistura
      de perfis entre hardwares distintos.
      → um arquivo por `hardware_id` sanitizado (`_sanitize_id()`),
      coberto por `test_different_hardware_ids_do_not_share_profiles`.
- [x] Escrita é atômica o suficiente para não corromper o JSON em caso
      de crash durante o `save` (ex: escrever em arquivo temporário e
      renomear).
      → `save()` escreve em `<path>.tmp`, fecha o arquivo
      explicitamente (força flush) e só então usa
      `DirAccess.rename_absolute()` para substituir o arquivo final.
