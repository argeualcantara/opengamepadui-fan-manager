# Plano de Atividades: Fan Manager

Este plano quebra [REQUIREMENTS.md](../REQUIREMENTS.md) em atividades
executáveis. Cada atividade tem seu próprio arquivo nesta pasta, com
escopo, critérios de aceite e dependências.

## Ordem sugerida / dependências

```
01-arquitetura-backends        (base: nada depende de código, só define contrato)
        │
        ├──► 02-backend-hwmon-generico
        │
        └──► 03-modelo-dados-persistencia
                    │
        ┌───────────┴───────────┐
        ▼                       ▼
04-gerenciador-modos     05-motor-curva-customizada
        │                       │
        └───────────┬───────────┘
                     ▼
        06-ui-select-modo-overlay
                     │
                     ▼
        07-ui-editor-curva-sliders
                     │
                     ▼
        08-ui-perfis-salvar-carregar
                     
09-logging          (transversal: aplica-se a todas as atividades acima)
10-testes-validacao (fecha o ciclo: depende de 01 a 08)

11-backend-asus-wmi-rog-ally (aditiva: só depende de 01; pode ser
                               feita a qualquer momento em paralelo,
                               não bloqueia nem é bloqueada pelo resto)

12-fancurve-por-jogo (v2: depende de 04, 05, 08; fora do escopo
                       original do REQUIREMENTS.md §5, planejada
                       separadamente)

13-revisao-primeiro-uso-e-salvamento (revisão: toca 04/05/07/08/11;
                                       feita depois de todas já
                                       implementadas)

14-suporte-multiplas-fans (revisão: toca praticamente todas as
                            camadas: 01/02/03/04/05/07/08/11; motivada
                            por verificação em hardware real, ROG Ally
                            tem 2 fans, não 1)

15-picker-de-perfil-e-save-no-editor (revisão de UI: toca 07/08/14;
                                       feedback do usuário sobre
                                       confusão no fluxo de salvar)

16-quick-bar-em-vez-de-overlay (revisão: toca 06; achado em teste real
                                 no ROG Ally: add_overlay() não
                                 funciona em --overlay-mode)

17-fix-class-name-resolution-em-plugin-empacotado (correção
                                                     transversal: toca
                                                     quase todo arquivo
                                                     .gd; class_name
                                                     não resolve em
                                                     plugin carregado
                                                     via zip)
```

## Resumo das atividades

| # | Atividade | Requisito de origem |
|---|-----------|----------------------|
| 01 | Arquitetura de backends e detecção de hardware | REQUIREMENTS §2.1 |
| 02 | Backend genérico `hwmon` | REQUIREMENTS §2.1 |
| 03 | Modelo de dados e persistência (perfis) | REQUIREMENTS §3, §2.3 (perfis) |
| 04 | Gerenciador de modos (BIOS/OS/Custom) | REQUIREMENTS §2.2, §2.4 |
| 05 | Motor da curva customizada (aplicação, monotonicidade, polling) | REQUIREMENTS §2.3, §4 |
| 06 | UI: select box de modo na Overlay | REQUIREMENTS §2.2, §2.4 |
| 07 | UI: editor de curva com sliders | REQUIREMENTS §2.3 |
| 08 | UI: salvar/carregar perfis customizados | REQUIREMENTS §2.3 (linha 76) |
| 09 | Logging robusto | REQUIREMENTS §4 (linha 133) |
| 10 | Testes e validação multi-hardware | Transversal |
| 11 | Backend específico ASUS ROG Ally (`asus-wmi`) | REQUIREMENTS §2.1 (caso conhecido) |
| 12 | Fan curve por jogo (v2) | REQUIREMENTS §5 (fora de escopo v1) |
| 13 | Revisão: primeiro uso, perfil Default, salvamento explícito | Pedido do usuário, pós-12 |
| 14 | Suporte a múltiplas ventoinhas independentes (ROG Ally: CPU+GPU) | Verificação em hardware real, pós-13 |
| 15 | Picker de perfil acima das curvas + Save na região das fans | Feedback do usuário, pós-14 |
| 16 | Quick Bar em vez de OverlayProvider (mais crash ao desabilitar) | Teste em hardware real, pós-15 |
| 17 | class_name não resolve em plugin carregado via zip | Teste em hardware real, pós-16 |

## Convenção: protótipo HTML antes da UI Godot

Toda atividade que envolve criar/alterar uma tela do plugin (06, 07,
08) deve começar por um **protótipo em HTML puro** (sem frameworks,
um único arquivo estático) representando o layout, estados e fluxo de
interação daquela tela, para validação antes de implementar em Godot.
O protótipo fica em `tasks/prototypes/<numero-da-atividade>-*.html` e
só depois de aprovado a atividade segue para a implementação real
(`.gd`/`.tscn`).

## Fora deste plano (v1)

Ver REQUIREMENTS.md §5: curvas livres fora dos 10 pontos fixos,
múltiplas ventoinhas independentes. Perfis por jogo deixou de ser
"fora de escopo" sem plano: ver
[tasks/12-fancurve-por-jogo.md](12-fancurve-por-jogo.md).
