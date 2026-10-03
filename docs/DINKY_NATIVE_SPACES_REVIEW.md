# Dinky: fluxo de Spaces aproveitável no WinMuxX

Revisão em 2026-10-03 do commit
[`e05ae28f3e814bbae1cf171567be14e0dcba6548`](https://github.com/mikker/Dinky/tree/e05ae28f3e814bbae1cf171567be14e0dcba6548).
O código foi baixado em diretório temporário, sem executar o app ou suas operações
de criação, remoção e movimentação. Este estudo complementa e corrige limitações
da [investigação inicial](NATIVE_SPACES_FEASIBILITY.md).

## Descoberta que altera a recomendação

O Dinky possui criação e remoção de Spaces por operações privadas bridged, sem
injetar código no Dock. Portanto, a dependência de scripting addition encontrada
no yabai não demonstra que criar/remover Spaces com SIP ativo seja impossível.
Continua não sendo uma interface pública ou uma garantia entre versões.

`spaces.m` cria `SLSBridgedSpaceCreateOperation`, com tipo de desktop e UUID do
display, e usa um dispatcher síncrono interno que devolve o ID. A remoção cria
`SLSBridgedSpaceDestroyOperation` e chama `performWithWMBridgeDelegate`.
O código observa que o processo precisa de AppKit para a remoção. A confirmação
de conclusão ocorre no chamador, consultando novamente os Spaces.

Fonte: [spaces.m](https://github.com/mikker/Dinky/blob/e05ae28f3e814bbae1cf171567be14e0dcba6548/Sources/DinkyPrivate/spaces.m).

## O fluxo real e a diferença para nosso produto

O Dinky mantém números globais vinculados a IDs de Spaces. A configuração define
o display de cada workspace; os demais usam o principal. Ao conectar/desconectar
monitores, planeja um passo, executa e observa o resultado antes de planejar o
seguinte. Para migrar um workspace, move suas janelas e árvore a outro Space;
não transporta necessariamente o desktop físico. Mantém um desktop em displays
sem workspaces e conserva desktops excedentes que ainda tenham janelas.

Isso é uma base próxima do que precisamos, mas o destino é regido pela configuração.
Para WinMuxX, o destino também precisa vir da ativação solicitada pelo usuário.
Copiar a política `homes()` integralmente faria uma reconciliação devolver os
workspaces aos monitores configurados e desfazer a mobilidade desejada.

Fonte: [WorkspacePlan.swift](https://github.com/mikker/Dinky/blob/e05ae28f3e814bbae1cf171567be14e0dcba6548/Sources/DinkyConfig/WorkspacePlan.swift).

## Componentes aproveitáveis

| Componente | Uso no WinMuxX | Adaptação necessária |
| --- | --- | --- |
| `DinkyPrivate/spaces.m`, `move.m`, `skylight.m` | Criar/remover desktop, mover lotes, resolver símbolos internos | Isolar em backend com capacidades por versão e fallback |
| `DinkyConfig/WorkspacePlan.swift` | Planejamento puro, uma ação por snapshot, destino vazio | Identidade `WorkspaceId`, projetos e destino dinâmico por viewport |
| `dinky/WorkspaceNumbers.swift` | Reconciliação, espera pela topologia, memória de origem das janelas | Integrar à persistência existente e confirmar cada janela transferida |
| `dinky/SpaceSwitching.swift` | Uma troca em andamento por display, retarget e confirmação de chegada | Coordenar com o bloqueio dos displays envolvidos numa transferência |
| `dinky/Coordinator.swift`, `moveTree` | Layout acompanha o workspace na migração | Preservar a árvore própria, grupos de abas, floating e foco |

Fontes: [move.m](https://github.com/mikker/Dinky/blob/e05ae28f3e814bbae1cf171567be14e0dcba6548/Sources/DinkyPrivate/move.m),
[skylight.m](https://github.com/mikker/Dinky/blob/e05ae28f3e814bbae1cf171567be14e0dcba6548/Sources/DinkyPrivate/skylight.m),
[WorkspaceNumbers.swift](https://github.com/mikker/Dinky/blob/e05ae28f3e814bbae1cf171567be14e0dcba6548/Sources/dinky/WorkspaceNumbers.swift),
[SpaceSwitching.swift](https://github.com/mikker/Dinky/blob/e05ae28f3e814bbae1cf171567be14e0dcba6548/Sources/dinky/SpaceSwitching.swift),
[Coordinator.swift](https://github.com/mikker/Dinky/blob/e05ae28f3e814bbae1cf171567be14e0dcba6548/Sources/dinky/Coordinator.swift).

## Como atender o compartilhamento e swap

O backend deve manter separadamente a identidade global do workspace, seu Space
atual e o monitor que o exibe. Seleção comum continua focando o monitor atual;
summon/override aplicam a política de transferência do WinMuxX.

Para trazer C oculto a outro display, preparar um desktop próprio vazio no destino,
transferir as janelas de C, confirmar associação, vincular C ao novo Space e ativar.
O workspace antes exibido continua intacto. Só então considerar a remoção do
desktop antigo de C, quando vazio e dispensável.

Para trocar A e B entre monitores, uma proposta conservadora é usar T como Space
temporário vazio: A→T, B→antigo Space de A, A de T→antigo Space de B. Confirmar
cada etapa e publicar os novos vínculos/históricos conjuntamente ao fim. O destino
temporário evita pedir que `moveTree`, que exige destino vazio, sobrescreva uma
árvore ocupada. A árvore lógica do WinMuxX deve continuar vinculada ao workspace.
Essa sequência é proposta nossa, não um recurso de swap entregue pelo Dinky.

Outra opção é a troca direta de listas de janelas, como no yabai, com snapshots
dos dois conjuntos. O protótipo deve comparar custo visual, quantidade de passos
e recuperação de falhas. Criar/remover T em toda troca pode ser mais lento; uma
reserva reutilizável consome um desktop e também precisa de política explícita.

Nenhuma das opções comprova movimentação do Space físico. Propriedades desse
desktop, como wallpaper, continuam exigindo tratamento separado.

## Crítica e limites que não devemos copiar

- `arrange()` e `waitUntil()` fazem polling com bloqueio da thread principal.
  Para a sidebar interativa, preferir máquina de estados assíncrona e cancelamento
  controlado; ignorar o resultado de um pedido antigo não pode abandonar uma
  movimentação que já começou no sistema.
- `dinky_move_windows_to_space()` retorna que despachou o pedido. Isso não prova
  chegada. Verificar a associação individual das janelas, sobretudo com falha
  parcial, minimizadas, auxiliares e aplicações encerrando.
- A recuperação de migração inverte `moveTree` em falha, mas não é um rollback
  transacional de cada janela. O nosso journal deve registrar progresso real.
- A memória `homes` usa amostras periódicas de janelas normais não minimizadas.
  É útil para desconexões, mas não substitui o modelo persistido do WinMuxX nem
  cobre automaticamente todas as categorias de janela.
- O planner remove Spaces vazios não vinculados. No WinMuxX, rastrear propriedade
  e preservar desktops criados pelo usuário, mesmo vazios.
- Os testes do planner simulam docking, undocking, destinos ocupados e redocking.
  Não comprovam as chamadas privadas nem o swap global entre dois monitores.

Fonte de testes: [WorkspacePlanTests.swift](https://github.com/mikker/Dinky/blob/e05ae28f3e814bbae1cf171567be14e0dcba6548/Tests/DinkyConfigTests/WorkspacePlanTests.swift).

## Verificação local

Compilei uma ferramenta temporária somente de leitura com o resolvedor Mach-O
do Dinky, ligada a AppKit. No macOS 27.2 desta sessão, com SIP ativo, encontrou:

```text
dispatcher síncrono bridged: disponível
dispatcher assíncrono bridged: disponível
SLSBridgedSpaceCreateOperation: disponível
SLSBridgedSpaceDestroyOperation: disponível
SLSBridgedMoveWindowsToManagedSpaceOperation: disponível
```

Isso resolve a dúvida da busca inicial por `dlsym`: os símbolos internos existem
e são encontrados pelo método adequado. Não invoquei os dispatchers nem instanciei
operações. Presença de símbolo/classe não comprova permissão, efeitos ou sucesso.

A documentação do Dinky declara experiência com macOS 27.0 em Apple Silicon e
validação adequada de apenas um display. A estimativa publicada de cerca de
70 ms não foi medida neste Mac e não deve ser prometida pelo WinMuxX.
[Limites documentados](https://github.com/mikker/Dinky/blob/e05ae28f3e814bbae1cf171567be14e0dcba6548/docs/index.md).

## Decisão revisada

O Dinky é uma referência melhor para o ciclo de vida sem desligar SIP do que a
implementação do yabai estudada inicialmente. Vale aproveitar a ponte nativa,
o planner incremental, confirmação de troca e tratamento de desconexão. Adaptar
a política para workspaces globais móveis e projetar recuperação de swap antes
de migrar o app inteiro. Criação/remoção automática agora é candidata ao protótipo;
a reserva manual passa a ser fallback de compatibilidade.

A licença é MIT. Ao incorporar código, incluir o aviso de copyright/licença e
preservar atribuições das partes provenientes de mimi, yabai e outras referências.
Nesta revisão nenhum código externo foi incorporado ao WinMuxX.
[Licença](https://github.com/mikker/Dinky/blob/e05ae28f3e814bbae1cf171567be14e0dcba6548/LICENSE).
