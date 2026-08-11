# 10: Testes e validação multi-hardware

**Depende de:** 01 a 08 (fecha o ciclo)

## Objetivo

Garantir que a arquitetura de backends realmente funciona em mais de
um hardware e que a lógica de negócio (monotonicidade, persistência,
troca de modo) está coberta por testes automatizados, já que o OGUI
usa o framework GUT (`addons/gut`).

## Escopo

- Testes unitários (GUT) para lógica pura, sem depender de hardware
  real:
  - `CustomCurveEngine`: interpolação entre pontos e regra de
    monotonicidade (empurrar sliders acima).
  - `FanCurveStore`: salvar/carregar/deletar perfil, isolamento por
    `hardware_id`.
  - `FanBackendRegistry`: seleção do backend correto dado um conjunto
    de backends mockados com `is_supported()` variando.
- Testes de integração manuais (checklist, não automatizado) para
  rodar em hardware real:
  - Handheld/APU com `hwmon` padrão (backend genérico).
  - Pelo menos um segundo hardware com particularidades conhecidas
    (ex: EC específico), para validar que a arquitetura de backend
    plugável realmente isola as diferenças.
  - Sem nenhum hwmon com pwm disponível → plugin não trava, UI indica
    "sem controle disponível" (REQUIREMENTS §2.1).
- Validação de UX via gamepad: navegação completa do fluxo (abrir
  Overlay → trocar modo → editar curva → salvar perfil → trocar de
  perfil) sem precisar de mouse/teclado.

## Critérios de aceite

- [ ] Suíte GUT roda via `make test` (ou equivalente do projeto) e
      cobre monotonicidade, persistência e seleção de backend.
- [ ] Checklist manual de multi-hardware documentado e executado em ao
      menos 2 hardwares diferentes antes do release v1.
- [ ] Cenário "sem hardware suportado" testado explicitamente: não é
      só a ausência de teste, é um caso coberto.
