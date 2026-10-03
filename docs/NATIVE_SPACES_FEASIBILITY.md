# Viabilidade de workspaces sobre Spaces nativos

Investigação em 2026-10-03. Escopo interpretado: preservar o fluxo atual de
projetos, workspaces, sidebar, layouts, grupos de abas e monitores independentes,
substituindo a emulação de workspaces por desktops do Mission Control.
Revisão complementar: o [estudo do Dinky](DINKY_NATIVE_SPACES_REVIEW.md) encontrou
caminhos privados para criar/remover Spaces com SIP ativo e confirmou a presença
dos dispatchers neste Mac. Isso amplia a evidência inicial baseada no yabai.

**Escopo atual definido pelo usuário:** desconsiderar agrupamento em abas.
Concentrar a investigação na coordenação de Spaces por monitor para simular
workspaces globais do WinMux. As observações sobre abas abaixo são histórico da
análise anterior e não são critérios de aceitação deste cenário.

## Coordenação proposta: workspaces globais sobre Spaces locais

Separar três objetos: `WorkspaceId` identifica o conjunto de janelas e seu layout;
`SpaceId` identifica o desktop nativo que o hospeda naquele momento; display é o
viewport que pode exibir um workspace. Manter mapas inversos workspace→Space e
Space→workspace, associação Space→display observada no sistema e workspace ativo
por viewport. Um workspace só pode ocupar um Space e estar ativo em um monitor
por vez. A associação ao monitor é mutável, salvo restrição configurada.

Cada workspace materializado ocupa um Space próprio, mesmo quando oculto.
Um único Space por monitor seria insuficiente: reunir janelas de vários workspaces
no mesmo desktop exigiria reintroduzir ocultação virtual. A lista da sidebar é
global e vem dos workspaces lógicos; as barras nativas continuam locais.

### Regras de ativação

- **Já está no monitor solicitado:** ativar seu Space e confirmar chegada.
- **Visível em outro monitor, seleção comum:** focar o monitor que o exibe,
  preservando a semântica atual. Uma ação explícita de trazer/override inicia
  transferência, não mera seleção.
- **Oculto em outro monitor:** preparar um Space próprio vazio no destino,
  transferir as janelas, confirmar associação e atualizar o vínculo. Ativá-lo;
  o workspace antes exibido no destino permanece no seu Space, agora oculto.
  Coletar o antigo Space da origem somente após confirmar vazio e propriedade.
- **Trazer um workspace visível, sem swap:** preparar e ativar um fallback na
  origem, então transferir o solicitado. O workspace substituído no destino
  continua disponível. A origem não pode perder seu viewport válido.
- **Override/swap entre dois visíveis:** registrar os dois conjuntos e trocar
  as janelas entre seus Spaces, preservando as árvores lógicas e alterando os
  vínculos. Os dois desktops físicos podem permanecer ativos; ao fim, cada um
  hospeda o outro workspace. Ajustar os frames aos displays de destino e restaurar
  o foco escolhido. Uma reserva temporária é alternativa a validar, não requisito
  obrigatório para a troca direta de listas.

Exemplo: A→Space 11 no monitor 1 e B→Space 22 no monitor 2. Após swap de conteúdo,
A→Space 22 no monitor 2 e B→Space 11 no monitor 1. A e B mantêm suas identidades;
11 e 22 mantêm sua localização física. Isso implementa a troca lógica sem precisar
transportar o Space inteiro. Movimentação física permanece capacidade distinta,
sem caminho sem SIP comprovado nesta investigação.

### Protocolo de transferência

1. Reservar ambos os monitores, workspaces e Spaces envolvidos. Registrar origem,
   destino, janelas, layout, foco e histórico antes de iniciar efeitos no sistema.
2. Validar capacidades, topologia, tipos de Spaces e restrições de atribuição.
   Preparar destinos/fallbacks sem apropriar-se de desktop externo ocupado.
3. Congelar apenas a reconciliação/layout que conflita com essa transferência.
   Registrar eventos recebidos; não deixar que o refresh reclassifique as janelas
   parcialmente movidas como uma alteração manual do usuário.
4. Despachar movimentos em lote, consultar a associação real de cada janela e
   tratar janelas que fecharam, novas janelas e diálogos surgidos durante a operação.
5. Confirmar vínculos, aplicar layout no destino e confirmar ativação quando houver.
   Publicar conjuntamente os viewports/históricos resultantes. Sidebar pode mostrar
   uma operação pendente, mas não afirmar que ela terminou antes da confirmação.
6. Coletar Spaces próprios vazios dispensáveis. Em falha parcial, restaurar o que
   for possível; se a restauração falhar, reconciliar os locais observados e manter
   informação de recuperação. Não fingir sucesso ou atomicidade visual.

### Eventos que vêm do macOS

Reconsultar quando houver swipe manual, mudança de Space, criação/destruição,
reordenação, fullscreen, wake e topologia. Um swipe para Space conhecido muda
o workspace ativo daquele viewport; não transfere por si só um workspace global.
Space externo não vinculado precisa de política de adoção ou indicação de desktop
externo, sem coletá-lo automaticamente. Após desconexão, usar a memória lógica
de associação das janelas para reconstruir os conjuntos, em vez de aceitar como
identidade definitiva o desktop em que o macOS as reuniu.

Para navegação global, next/prev e sidebar escolhem o workspace lógico e usam as
regras acima. Swipes nativos continuam navegando a lista física local. Igualar os
dois exige um projeto adicional de gestos; não é necessário para provar a
coordenação global por sidebar/atalhos.

### Vazios e configuração do sistema

N+1 é um workspace transitório: materializar ao ativar, promover quando receber
conteúdo e coletar ao sair sem conteúdo, preservando as exceções atuais do fork.
Cada monitor ainda precisa de um desktop válido; logo ausência absoluta de
desktops físicos vazios não é uma promessa possível para monitor sem conteúdo.
Não confundir esse desktop técnico com uma coleção de workspaces reservados.

Hipótese inicial: Spaces separados por display para permitir viewports
independentes; o conjunto global é fornecido pelo WinMux acima dessa separação.
Consultar a opção e validar a hipótese em dois monitores antes de estabelecer
um requisito de instalação. Não alterar preferências durante a investigação.

**Prova funcional mínima:** dois displays com A, B e C; ativação local de A;
trazer C oculto ao outro monitor sem perder B; seleção comum de A visível em
outro monitor; summon com fallback; swap A↔B; coleta do N+1; swipe manual;
desconexão durante transferência; recuperação de uma janela que não chegou.
Abas ficam fora desse teste por decisão explícita do usuário.

É viável implementar um modo nativo com restrições. Não há evidência suficiente
para prometer equivalência completa, estabilidade entre versões ou migração
transparente. Recomendo um backend experimental opcional com SIP ativado,
incluindo mobilidade entre monitores e validação das operações de ciclo de vida,
antes de substituir o mecanismo atual.

## Evidência no projeto

### Critérios de produto reforçados pelo usuário

O objetivo não é apenas usar desktops reais. É preservar o modelo do WinMux:
workspace como conjunto global de janelas, monitor como viewport, descarte de
vazios, localização clara na sidebar, abas entre aplicativos e configuração pela
GUI. O backend nativo só deve ser considerado bem-sucedido se sustentar esse fluxo.

| Problema que o WinMux resolve | O que preservar | O que Spaces nativos mudam |
| --- | --- | --- |
| Workspaces presos a monitores | Qualquer viewport acessa qualquer workspace; summon e swap mantêm identidade | Migrar conteúdo/vínculos quando o Space de destino está em outro display |
| Perda de orientação | Identidade, projeto, labels e ordem lógica independentes do monitor | IDs/índices físicos são detalhes do backend; reordenação do sistema não renumera a sidebar |
| Não saber onde estão as janelas | Sidebar integrada, incluindo grupos e janelas ocultas | Modelo único no app, snapshot observado do sistema e operações pendentes explícitas |
| Acúmulo de vazios | Descartar workspaces sem conteúdo e oferecer N+1 transitório | Criar ao ativar; coletar após sair e confirmar vazio; desktops técnicos mínimos ainda podem existir |
| Stacks invisíveis | Abas visíveis e navegáveis entre aplicativos | Espaços reais não fornecem abas entre aplicativos; controle de visibilidade continua próprio |
| Configuração trabalhosa | GUI e defaults; sem exigir edição de TOML, scripts ou SIP desligado | Ajustes de Mission Control e capacidade por versão precisam de tratamento integrado |

**Limite conceitual:** um backend nativo pode preservar a experiência do WinMux,
mas isso não transforma Mission Control numa lista global de workspaces. A barra
do sistema ainda organiza os desktops físicos e pode expor desktops transitórios
de transferência, fullscreen e o desktop mínimo de um monitor sem conteúdo.
Ocultar esses desktops apenas na sidebar não os torna inexistentes no sistema.

Não manter uma reserva grande de Spaces vazios como arquitetura final. O N+1
pode começar como affordance da sidebar, materializar seu Space na ativação e ser
coletado quando dispensável. Um desktop temporário para swap deve ter duração
limitada; preferir investigar transferência direta que dispense essa reserva.
O conjunto de workspaces deve ser global; a posição física do Space não é uma
atribuição permanente de propriedade ao monitor.

**Gestos precisam de uma decisão de produto:** usar o swipe nativo sem mediação
percorre a organização física dos Spaces. Não equivale automaticamente a
`workspace next/prev` na ordem global do WinMux. Oferecer navegação global exige
planejar também as migrações necessárias, medir a latência e preservar gestos
manuais sem disputar controle com o usuário. Isso é uma hipótese para o protótipo,
não uma capacidade já demonstrada.

**Spaces separados por display:** para dois viewports exibirem workspaces
independentes, a hipótese de backend é usar a separação física do macOS e abstrair
o vínculo no WinMux, não supor que desligar a opção produz o conjunto global
independente. A configuração precisa ser detectada e ambos os modos testados.
A Apple documenta a opção e oferece `NSScreen.screensHaveSeparateSpaces` para
consultá-la; não alterei a preferência nesta investigação.
[API pública](https://developer.apple.com/documentation/appkit/nsscreen/screenshaveseparatespaces),
[configurações de Mission Control](https://support.apple.com/en-za/guide/mac-help/-mchlp1119/mac).

**Reordenação:** a ordem da sidebar vem do modelo lógico, não dos índices do
Mission Control. Reconsultar IDs e displays depois de mudanças manuais. Para que
a organização nativa também seja previsível, avaliar no onboarding o ajuste de
reordenação automática; a existência desse ajuste não elimina por si só todas
as mudanças produzidas por desconexão, fullscreen e exclusão de desktops.

**Abas:** a ocultação em cantos dos workspaces inativos pode desaparecer, mas a
das abas inativas não é resolvida pela migração. Avaliar sobreposição/ordem de
janelas como alternativa exige testar foco, apps que se trazem à frente, diálogos,
Mission Control e mínimos diferentes. Criar um Space por aba contradiz o objetivo
de reduzir espaços e perde a troca local de abas; não adotar esse desenho.

**Coleta e identidade:** número exibido é posição, `WorkspaceId` é identidade.
Quando o último conteúdo sai, selecionar fallback e atualizar labels/histórico
antes de coletar o Space próprio confirmado vazio. Não excluir desktops externos
vazios automaticamente. O limite físico documentado de Spaces precisa de uma
resposta integrada quando a materialização falhar, inclusive somando projetos;
criação dinâmica não torna a capacidade ilimitada.

O texto de produto descreve apenas o vazio N+1. O fork atual também preserva
workspaces visíveis, configurados persistentes, com janelas minimizadas, o último
de um projeto e determinados vazios retidos por escopo. A migração deve manter
esses comportamentos existentes, sem impor uma regra mais estrita como efeito
colateral. Referências: `WorkspaceLifecycle.swift`, `WorkspaceRetainedEmptySlot.swift`.

### Critérios de aceitação para o protótipo

1. A e B são workspaces globais: qualquer monitor pode solicitá-los; swap não
   duplica conteúdo nem perde projeto, layout, abas ou histórico.
2. Fechar/mover a última janela faz o workspace desaparecer conforme o ciclo de
   vida atual; sair do N+1 sem abrir janela não acumula desktops próprios.
3. Sidebar acompanha abertura, fechamento, transferência, foco e mudanças manuais
   do sistema. Durante operações, distinguir destino solicitado e estado observado;
   não publicar chegada antes da confirmação.
4. Ordem lógica sobrevive a mudanças do Mission Control, dock/undock e fullscreen.
5. Abas continuam visíveis, clicáveis e arrastáveis; uma aba inativa não aparece
   indevidamente por cima da ativa nem gera um desktop individual.
6. Uso diário e configuração acontecem pela GUI com SIP ativo. Sem scripts externos
   ou configuração manual obrigatória para manter a experiência principal.
7. Medir custo de trocar um workspace local, trazer de outro monitor, realizar swap
   e criar/coletar N+1. A integração não pode comprometer a resposta da sidebar.

Se a exigência for que Mission Control também reflita exatamente a hierarquia
global, a ausência estrita de vazios e abas entre apps, a evidência atual não
sustenta equivalência. Se for usar Spaces reais como isolamento mantendo o modelo
e a interface do WinMux, o caminho é plausível e merece o protótipo acima.

- `tree/WinMuxWorkspaceState.swift`: projetos e workspaces têm identidades próprias;
  cada monitor mantém workspace ativo, anterior e último workspace por projeto.
- `tree/WorkspaceLifecycle.swift`: trocar projeto pode criar um workspace vazio;
  exclusão transfere seu conteúdo para um fallback; reconciliação remove vazios
  dispensáveis. A ativação de um workspace visível em outro monitor o foca lá.
- `layout/refresh.swift`, `layoutWorkspaces()`: restaura janelas dos workspaces
  visíveis e chama `MacWindow.hideInCorner()` para as dos invisíveis.
- `tree/MacWindow.swift:188`: a ocultação desloca a janela por Accessibility e
  registra sua posição para restauração. Não muda sua associação a um Space.
- `GlobalObserver.swift:142`: já observa `activeSpaceDidChangeNotification`, mas
  encaminha o evento ao refresh genérico; não mantém um mapa de Spaces nativos.
- `ui/sidebar/WorkspaceSidebarPanelController.swift:70`: a sidebar já usa
  `.canJoinAllSpaces` e `.fullScreenAuxiliary`.
- `layout/layoutRecursive.swift`: abas inativas e janelas ocultadas dentro do
  workspace também usam `hideInCorner()`. Esse caso exige uma solução própria
  mesmo quando cada workspace passa a ocupar um Space real.

Os caminhos acima são relativos a `Sources/AppBundle/`.

## O que as fontes externas permitem concluir

A Apple documenta criação pelo Mission Control, navegação por gestos/atalhos,
movimentação individual de janelas e até 16 Spaces. Documenta também que excluir
um Space redistribui suas janelas. Não detalha nesse artigo o limite por display,
portanto esse aspecto não foi assumido. A associação feita pelo Dock é de
aplicativo: não substitui o vínculo individual das janelas de um mesmo aplicativo
a diferentes workspaces. Fullscreen e Split View aparecem na barra de Spaces.
[Manual da Apple](https://support.apple.com/guide/mac-help/work-in-multiple-spaces-mh14112/mac).

A notificação pública de troca existe, mas não constitui uma interface completa
para enumerar, criar, ativar e mover desktops de outros aplicativos. Não encontrei
uma API pública documentada que forneça esse conjunto de operações.
[NSWorkspace.activeSpaceDidChangeNotification](https://developer.apple.com/documentation/appkit/nsworkspace/activespacedidchangenotification).

A evidência mais relevante é o yabai atual:

- A versão 7.1.19, de 2026-04-18, introduziu foco de Spaces com SIP ativado.
  O código sintetiza gestos de alta velocidade, incluindo campos de eventos
  não documentados. Não é uma nova API pública de ativação.
- A versão 7.1.25, de 2026-05-08, restaurou movimentação de janelas entre Spaces
  com SIP ativado. Há confirmação do mantenedor para Tahoe 26.4 e relato para
  26.4.1; isso não comprova todas as versões suportadas pelo WinMuxX.
- A implementação procura uma função interna de SkyLight pelo símbolo C++ no
  Mach-O (`macho_find_symbol`), cria uma
  `SLSBridgedMoveWindowsToManagedSpaceOperation` e solicita a operação assíncrona.
- Criação, destruição, reordenação e movimentação de um Space inteiro entre
  displays ainda usam a scripting addition nesse código. A documentação do
  projeto exige SIP parcialmente desativado para essa integração com o Dock.

Fontes: [changelog](https://github.com/asmvik/yabai/blob/master/CHANGELOG.md),
[troca com SIP ativo](https://github.com/asmvik/yabai/issues/2780),
[movimentação com SIP ativo](https://github.com/asmvik/yabai/issues/2788),
[operações de Spaces](https://github.com/asmvik/yabai/blob/master/src/space_manager.c),
[resolução de símbolos](https://github.com/asmvik/yabai/blob/master/src/yabai.c),
[requisitos de SIP](https://github.com/asmvik/yabai/wiki/Disabling-System-Integrity-Protection).
Essas referências apontam para código mutável consultado na data da investigação.

## Matriz de viabilidade

| Comportamento | Avaliação | Consequência para o WinMuxX |
| --- | --- | --- |
| Sidebar, nomes e projetos | Reaproveitáveis no app | Hierarquia e labels continuam sendo metadados próprios; Spaces não oferecem uma hierarquia equivalente |
| Dwindle, floating e gaps | Reaproveitáveis em grande parte | Layout deve atuar sobre janelas do Space visível, respeitando transições |
| Consultar Spaces e associação de janelas | Viável por APIs privadas | Adaptador isolado, detecção de capacidades e reconciliação |
| Trocar Space existente com SIP ativo | Evidência no yabai | Gestos sintetizados; confirmar destino real antes de atualizar foco/histórico |
| Mover janela para Space existente com SIP ativo | Evidência em Tahoe recente | Compatibilidade por versão e confirmação de operação assíncrona |
| Criar e coletar automaticamente workspaces vazios | Caminho privado sem scripting addition encontrado no Dinky | Validar criação/remoção bridged; excluir apenas Spaces próprios e vazios |
| Mover workspace inteiro entre monitores | Limitado | Mover um Space usa scripting addition; mover suas janelas a outro Space é uma operação diferente, com falhas parciais |
| Grupos de abas | Exigem tratamento adicional | Spaces isolam desktops, mas não escondem abas inativas dentro do mesmo desktop |
| Restaurar após reinício/topologia diferente | Exige reconciliação | Não persistir número visual ou ID do sistema como identidade definitiva do workspace |

## Crítica das alternativas

### Workspaces globais ativáveis em qualquer monitor

Requisito reforçado pelo usuário: preservar o conjunto compartilhado de
workspaces; ativar um workspace pode exigir transportá-lo para outro monitor;
no swap, devolver o workspace substituído ao monitor de origem. Uma implementação
que simplesmente prende cada workspace a um Space/display não atende esse fluxo.

O projeto já distingue três ações em `WorkspaceMonitorAssignment.swift`:
seleção comum acompanha o workspace já visível; summon/move prepara um fallback
na origem; override usa `swapActiveWorkspaces` para trocar os dois viewports.
O estado lógico publica a troca dos monitores conjuntamente. O backend nativo
precisa manter essas distinções e as restrições de atribuição de ambos os lados.

Há duas estratégias:

1. **Transportar os Spaces reais.** Com A no monitor 1 e B no monitor 2, mover
   Space A para o monitor 2, mover Space B para o monitor 1 e ativar ambos.
   Preserva a associação workspace–Space, inclusive propriedades do desktop.
   No código do yabai, mover um Space entre displays depende da scripting addition
   e rejeita o último Space de usuário do display de origem. Logo, a sequência
   precisa de um desktop de reserva em cada monitor, previamente criado ou
   criado pelo backend habilitado. Esse é um desenho proposto, ainda não testado;
   não há evidência de uma operação pública e atômica que faça os dois movimentos.
2. **Transportar o conteúdo e trocar os vínculos.** Manter os Spaces físicos nos
   monitores, enviar as janelas de A ao Space de B e as de B ao Space de A, depois
   trocar `WorkspaceId → SpaceId`. Layout, projeto e histórico acompanham o
   workspace lógico. O yabai já faz precisamente esse tipo de troca entre
   displays em `space_manager_swap_space_with_space_on_display`: troca views e
   labels e move as listas de janelas. É evidência forte de viabilidade arquitetural
   com o caminho recente de movimentação sem desligar SIP, mas não é uma garantia
   de execução bem-sucedida de todos os lotes neste ambiente.

A segunda estratégia preserva o fluxo de workspaces compartilhados, porém
wallpaper, posição no Mission Control e associação de aplicativos pelo Dock
continuam vinculados aos Spaces físicos, salvo tratamento adicional. Janelas
minimizadas, diálogos e sticky/fullscreen exigem políticas explícitas. Não basta
mover somente as folhas atualmente visíveis da árvore.

Para ativar um workspace **oculto** em outro monitor, a troca de conteúdo precisa
de um Space de reserva livre no destino: mover as janelas do solicitado a esse
Space, ativá-lo e liberar seu antigo vínculo após confirmação. O workspace antes
visível no destino deve continuar disponível e intacto. Usar seu próprio Space
como destino misturaria dois workspaces. Reutilizar slots permite um conjunto
global flexível, mas não elimina a capacidade finita de desktops.

Cada transferência deve registrar snapshot, origem/destino de cada janela e
vínculos anteriores; bloquear novos comandos conflitantes; confirmar associação
no WindowServer; então publicar viewports e histórico. Em falha parcial, tentar
restaurar o estado anterior e reconciliar com o estado real se a restauração
também falhar. Não prometer atomicidade visual: macOS pode exibir estados
intermediários mesmo quando o app publica seu estado lógico conjuntamente.

**Preferência para o protótipo:** testar primeiro troca de conteúdo/vínculos com
SIP ativo, incluindo A↔B em dois monitores e ativação de C oculto em outro display.
Oferecer transporte físico dos Spaces apenas como capacidade separada, se sua
dependência adicional for aceita. O primeiro protótipo funcional precisa incluir
essa mobilidade; uma sidebar sobre desktops fixos seria insuficiente.

**Um Space por workspace** é a correspondência mais direta. Dá ao Mission Control
o conjunto real de janelas e preserva gestos nativos. Porém, todos os projetos
compartilham a barra de desktops; filtrar um projeto na sidebar não esconde seus
Spaces no Mission Control. O crescimento e a coleta de workspaces passam a
depender de operações do sistema. A seleção de um workspace oculto em outro
monitor precisa de uma política explícita, pois o modelo atual permite ativá-lo
no monitor solicitado.

**Um Space por projeto** reduz a quantidade de desktops, mas mantém workspaces
virtuais e ocultação dentro do projeto. É uma integração parcial e precisa de
estado separado para cada Space/monitor. Pode ser útil se a necessidade principal
for alternar projetos pelo trackpad, mas não entrega desktops reais para cada
workspace nem resolve o comportamento das abas.

**Automatizar a interface do Mission Control** pode criar e excluir desktops sem
injetar código no Dock. Entretanto, fica sujeito a mudanças de árvore AX,
animação, posição de thumbnails, concorrência com o usuário e ações incompletas.
Não recomendo esse caminho para coleta automática de vazios no uso cotidiano.

**Usar o yabai como serviço de Spaces** acelera uma prova de conceito, mas exige
desabilitar seu gerenciamento concorrente de layouts e foco. O próprio fork
documenta evitar dois gerenciadores simultâneos. Para uma implementação integrada,
prefiro um adaptador próprio. Se houver reutilização de código, conferir licença
e atribuição antes de incorporá-lo.

É incorreto concluir que toda integração com Spaces exige desligar SIP: há
evidência recente em contrário. Também seria incorreto concluir que SIP ativo
torna as operações públicas, estáveis ou compatíveis com todos os macOS.

## Verificação local e limites

O ambiente informou macOS **27.2, build 26B5091g**, com **SIP ativado**.
Executei uma consulta somente de leitura em Swift carregando SkyLight:

```text
SLSMainConnectionID: disponível via dlsym
SLSCopyManagedDisplaySpaces: disponível via dlsym
SLSCopySpacesForWindows: disponível via dlsym
SLSCopyManagedDisplaySpaces: 1 display, 1 Space de tipo 0
```

Isso comprova a enumeração básica nesta sessão. A presença de
`SLSCopySpacesForWindows` não comprova sua execução: não a invoquei.

Uma busca inicial via `dlsym` pelo nome simples da função bridged não a encontrou.
Ao revisar o inicializador do yabai, confirmei que ele procura um símbolo interno
com nome C++ no Mach-O. Portanto, esse resultado **não prova indisponibilidade**
da movimentação neste Mac. A localização desse símbolo interno e a execução da
operação ainda precisam ser validadas.

Não criei/excluí desktops, não troquei Spaces e não movi janelas da sessão.
O ambiente possui só um Space visível na consulta, portanto não forneceu um
cenário local para verificar essas operações ou independência entre monitores.
Não executei testes do app: esta mudança contém somente documentação e a consulta
não alterou seu código. A arquitetura foi verificada por leitura das funções
citadas; a equivalência funcional ainda depende de protótipo.

## Implementação proposta e critérios para continuar

1. Introduzir `WorkspaceBackend`, preservando o backend virtual. O backend nativo
   expõe snapshot de displays/Spaces/janelas e capacidades separadas para consulta,
   ativação, movimentação de janela e operações de ciclo de vida.
2. Vincular `WorkspaceId` a um Space validado na sessão, com identidade de display
   e metadados para reconciliação. Índices do Mission Control são posições,
   não identidades. Reconsultar após mudança manual, fullscreen, wake e topologia.
3. Validar os caminhos de criação/remoção com SIP ativo encontrados no Dinky.
   Manter uma reserva manual quando indisponíveis. Excluir somente Spaces próprios,
   vazios e confirmados; não reutilizar um Space ocupado silenciosamente.
4. Serializar pedidos e observar o resultado real. Aplicar foco, layout e histórico
   após confirmação; timeout ou falha mantém o estado anterior ou dispara
   reconciliação. Evitar que um refresh virtual estacione janelas do modo nativo.
5. Distinguir movimento de janela, grupo e workspace inteiro. Para operações em
   lote, registrar progresso e definir recuperação de falhas parciais.
6. Resolver separadamente abas inativas, fullscreen, janelas em todos os desktops,
   diálogos e aplicativos com várias janelas distribuídas entre Spaces.

A primeira validação funcional deve demonstrar: trocar repetidamente entre dois
Spaces sem perder foco; mover uma janela com SIP ativo e confirmar associação;
manter dois displays independentes; absorver mudanças manuais pelo Mission
Control; recuperar após reiniciar o app e desconectar um display; preservar abas
e lidar com fullscreen sem misturar projetos. Medir latência e falhas, sem fixar
uma promessa de troca instantânea antes desses testes.

**Decisão recomendada:** avançar com um protótipo limitado e opcional. A evidência
justifica investigar Spaces reais com SIP ativo. Substituir todo o backend agora
seria prematuro, especialmente pelo ciclo de vida dinâmico, movimentação entre
monitores e ocultação de abas que fazem parte do fluxo existente.
