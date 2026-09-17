# Journal de decisões

Rascunho cronológico de decisões tomadas durante sessões de trabalho neste
projeto. Não é aprovado, não é imutável — se corrigir depois, tudo bem.
Decisões com `reverter: caro` são candidatas a virar ADR.

---

- 2026-08-29 | DF quebrou o pipeline (processando DF/2012): DF não é
  dividido em municípios (Art. 32 CF/88) — não existe prefeito/vereador lá,
  então em ano de eleição MUNICIPAL (%4==0) o TSE não publica
  `votacao_secao_{ano}_DF.zip` (404 real). `02_load_raw.sh` já lidava bem
  com o CSV ausente (só não cria a tabela raw), mas `03_transform.sh`
  chamava `20_transform.sql` incondicionalmente, que assume
  `raiox_tse_raw.votacao_secao_:ano` sempre existe — quebrou com "relation
  does not exist" no primeiro INSERT (tse_eleicoes), antes de gravar
  qualquer linha (sem dado sujo pra limpar).
  Fix em 3 pontos: (1) `01_download.sh` pula o download de
  `votacao_secao_{ano}_DF` quando `ano%4==0` (evita 3 tentativas +
  MISSING.md falso); (2) `02_load_raw.sh` só ganhou um echo explicando o
  skip (comportamento já estava certo); (3) `03_transform.sh` detecta via
  `to_regclass('raiox_tse_raw.votacao_secao_$ano')` se a tabela raw existe
  antes de chamar `20_transform.sql`/`25_aggregate.sql` — se não existir,
  pula os dois mas AINDA roda `15_target_schema_year.sql` (partição vazia),
  senão `04_promote.sh` quebra depois tentando referenciar uma tabela-folha
  inexistente no `pg_dump -t`.
  Checagem em (3) é genérica (existência da tabela), não hardcoded
  `UF=DF` — cobre qualquer UF/ano sem eleição no futuro, não só esse caso.
  alternativas: hardcode `if [ "$UF" = "DF" ]` também em 03_transform.sh
  (rejeitado — replica a mesma lógica em 2 lugares por 2 motivos
  diferentes; a checagem de existência já cobre o caso geral sem precisar
  saber PORQUE o dado falta).
  reverter: barato (só a condição de skip nos 3 scripts; nenhum dado
  gravado incorretamente em nenhum ambiente).

- 2026-08-26 | Bug relatado pelo usuário em produção (PR): (a) Presidente só
  aparecia em 2022, não em 2014/2018; (b) `ds_cargo`/`ds_eleicao` de
  Presidente salvos "PRESIDENTE" tudo maiúsculo, destoando de "Governador"/
  "Senador" no mesmo seletor.
  Causa de (a): NÃO é bug de lógica — é reprocessamento pendente. Só
  2022/PR foi promovido pra produção com o fix de Presidente (rodada manual
  de validação); 2014/2018/PR nunca tiveram o zip `_BR` baixado
  localmente (`01_download.sh` roda certo, só ainda não rodou pra esses
  anos). Confirmado direto no Neon: `tse_cargos`/`tse_votacaosecao` de
  PR só têm `cd_cargo=1` em 2022.
  Causa de (b): o CSV nacional (`votacao_secao_*_BR.csv`, único que tem
  Presidente) vem com `ds_cargo`/`ds_eleicao` TODO EM MAIÚSCULAS
  ("PRESIDENTE", "ELEIÇÃO GERAL FEDERAL 2022"); o CSV estadual usa Title
  Case ("Governador"). Inconsistência do próprio TSE entre os dois
  datasets.
  Fix de (b) em `20_transform.sql`: `CASE WHEN col = upper(col) THEN
  initcap(col) ELSE col END` em `tse_cargos.ds_cargo` e
  `tse_eleicoes.ds_eleicao` (antes de concatenar o turno). `INITCAP` sem
  condição foi cogitado e descartado: testado contra produção real, quebra
  nomes de eleição suplementar já existentes (ex.: "Eleição Suplementar
  São Tomé/PR" -> "...São Tomé/Pr", destrói a sigla da UF; capitalizaria
  "de"/"do" em "Suplementar de Cruzeiro do Iguaçu/PR"). A condição
  `= upper()` isola exatamente o caso do arquivo federal (mais alguns
  cargos antigos de outras UF/anos também em CAPS) sem tocar em texto que
  já está correto ou tem formato irregular.
  Validado contra os textos reais de produção (todas as 16 variações de
  `ds_cargo` e as 20 de `ds_eleicao` distintas hoje) — resultado bate com o
  esperado em cada uma, sem regressão nas suplementares.
  Pendente: rodar 2014/2018/PR (e reprocessar 2022 já promovido, pra
  aplicar o fix de caixa) — fix só entra em produção na próxima promoção
  desses anos.
  alternativas: normalizar no backend (Node) na leitura em vez do SQL de
  carga (rejeitado — mesma inconsistência afetaria qualquer outro
  consumidor futuro do schema `raiox`, melhor corrigir na origem).
  reverter: barato (é só a expressão de SELECT no transform; reprocessar
  um ano já é rotina do pipeline).

- 2026-08-26 | `02_load_raw.sh` filtra `eleitorado_locais_votacao` por UF
  (awk em `SG_UF`, coluna 7) ANTES do `\copy`, mesmo padrão já usado no
  fix de Presidente acima. Esse dataset é nacional sem split por UF dentro
  do zip (só `consulta_cand`/`votacao_partido_munzona` vêm pré-divididos)
  — o `02_load_raw.sh` de antes carregava o Brasil inteiro (~250-400MB,
  1-2M linhas) pro staging TODA VEZ que processava uma UF, e só filtrava
  depois, no `WHERE l.sg_uf = :uf` de `20_transform.sql` (que continua lá,
  agora só cinto-e-suspensório). O próprio README já documentava esse
  filtro como recomendação MANUAL pro usuário rodar antes do script —
  motivo de ter automatizado agora: usuário perguntou se os datasets
  nacionais já eram economizados, essa era a única exceção real.
  Validado com PR/2022 real: filtro deu exatamente 51.750 linhas, igual ao
  `tse_locais` de antes (quando ainda filtrava só depois, no transform).
  reverter: barato (só o load muda, resultado final idêntico).

- 2026-08-26 | Dois bugs de escopo achados a partir de um relato do usuário
  no `getEleicoes` de PR (comparado linha a linha com o formato do MySQL
  legado): (1) `tse_eleicoes` trazia uma linha por eleição EXTRAORDINÁRIA
  (suplementar por município — 13 em PR/2016 sozinho) poluindo o seletor
  do app; (2) Presidente/Vice (cd_cargo 1/2) sumidos em TODO ano de
  eleição geral, inclusive **SP/2018 já em produção** (cargos eram
  `{3,5,6,7}`, sem o `1`).
  Causa raiz de (2): TSE não publica a votação federal no zip por UF
  (`votacao_secao_{ano}_{UF}.zip`, só abrangência E) — sai num arquivo
  NACIONAL à parte (`votacao_secao_{ano}_BR.zip`, ~1.5GB, todas as UFs
  misturadas, `sg_uf` linha a linha). Confirmado testando o CDN direto
  (funciona — a entrada antiga no README achava que só existia via Wayback,
  que estava corrompido).
  Causa raiz de (1): campo `cd_tipo_eleicao` do TSE ('2'=ORDINÁRIA,
  '1'=EXTRAORDINÁRIA) nunca era filtrado.
  Fix: `01_download.sh` baixa o BR só em ano%4==2 (anos de eleição geral);
  `02_load_raw.sh` filtra o CSV nacional por UF via awk ANTES do `\copy`
  (tabela federal fica vazia — `LIKE` da tabela estadual — em ano
  municipal, pra `20_transform.sql` poder sempre fazer UNION ALL sem
  condicional); `20_transform.sql` UNE estadual+federal em
  `tse_eleicoes`/`tse_cargos`/`tse_votacaosecao`/`tse_candidatos`,
  filtrando `cd_tipo_eleicao='2'` em tudo. Candidato federal casa por
  `cand.sg_uf IN (v.sg_uf, 'BR')` no join (consulta_cand registra
  Presidente com sg_uf='BR', não a UF de quem votou).
  Validado com dado real (PR/2022, não teste sintético): tse_eleicoes deu
  2 linhas (turno 1 texto estadual, turno 2 só federal — bate com o
  padrão do MySQL legado), tse_cargos com PRESIDENTE nos 2 turnos,
  Bolsonaro 3.628.612 x Lula 2.363.492 no 1º turno (resultado real de
  2022 no PR), soma de tse_votacaosecao fechou exato (3.397.518 +
  297.889 = 3.695.407). `25_aggregate.sql` rodou sem mudança nenhuma —
  já esperava cd_cargo IN (1,2) pra "federal" desde sempre.
  AC não precisa de reprocessamento (pipeline antigo, herdado do MySQL,
  já não tinha nenhum dos dois bugs). SP/2018 e PR (todos os anos) em
  produção precisam de reprocessamento pra pegar o fix — decisão do
  usuário: refazer os dois do zero (01→05) em vez de só os anos gerais.
  alternativas: filtrar só string "suplementar" em ds_eleicao pro bug (1)
  em vez de cd_tipo_eleicao (mais frágil, texto livre em português) |
  ignorar Presidente/Vice de vez (fora de escopo, o usuário pediu
  explicitamente pra ter esse cargo)
  reverter: barato pro código (só filtro + UNION, sem mudança de schema);
  caro pra já ter promovido SP com esse gap pra produção sem perceber
  antes — motivo de ter validado com dado real antes de liberar pro
  usuário rodar em massa.

- 2026-08-25 | Fotos de candidato (`nome_foto`, hoje NULL em toda
  `raiox.tse_candidatos`): decidido usar leitura direta do MySQL legado
  como fonte, não o pipeline de listagem dos ZIPs do TSE. Confirmado em
  `raiox-api/Models/Votos.php:685-695` que `nome_foto` mora em
  `tse_candidatos` (tabela por candidatura — milhares de linhas por
  UF/ano), não replicado nos milhões de registros de voto/seção — então é
  um SELECT + UPDATE trivial casando por `sq_candidato`, não um download
  de ZIP de centenas de MB por estado. Cobre só o que o sistema legado já
  tinha migrado pro MySQL; estados/anos que nunca passaram por lá ainda
  vão precisar do fallback do ZIP do TSE (proposto, não implementado).
  BLOQUEADO: sem credenciais MySQL disponíveis agora (vazias em
  `raiox-migracao-piloto/.env`); usuário vai pegar acesso a todas as
  bases amanhã pra fazer o update.
  alternativas: listar ZIPs de foto do TSE por UF/ano (`cdn.tse.jus.br/.../
  foto_cand{ANO}_{UF}_div.zip`), extrair só nome de arquivo sem baixar
  imagem (mais trabalho, mas cobre estados fora do MySQL legado também)
  reverter: barato (é só popular uma coluna já existente, sem migração de
  schema)

- 2026-08-26 | Novo índice em `tse_votacaosecao`: `(ano_eleicao, nr_turno,
  sq_candidato, cd_municipio)`. Achado investigando uma chamada real de
  produção (getVotosCandidato tipo 6, candidato+cidade específica, sem
  zona/seção) que levou 4,9s no banco (confirmado via log estruturado do
  Cloud Run — não era cold start, container já estava quente há 5min). O
  índice existente de `(ano, sq_candidato)` resolvia pelo candidato
  primeiro, varrendo o voto dele no ESTADO INTEIRO (candidato a Deputado
  Estadual concorre em várias cidades) pra só depois filtrar a cidade
  pedida — 67 mil linhas lidas, 42 mil descartadas. Índice dedicado
  filtra os dois de uma vez: 250ms (~19x mais rápido). Aplicado no
  `10_target_schema.sql` (propaga sozinho pras partições de ano, atuais e
  futuras) e criado direto nos 3 estados já em produção (SP/AC/PR) + local
  (PR).
  Confirmado à parte, não relacionado a esse caso: Cloud Run realmente
  escala a zero (min-instances não configurado) — houve 2 ciclos de
  suspensão nas últimas 3h. Não corrigido ainda — mesmo trade-off custo/
  latência do scale-to-zero do Neon, decisão em aberto do usuário.
  reverter: barato (índice puro, sem efeito em dado).

- 2026-08-26 | Dois bugs achados rodando PR/2014 (eleição GERAL — o fix de
  `sg_ue` do dia anterior era só validado pra eleição MUNICIPAL, PR/2024):
  (1) O `AND cand.sg_ue = v.sg_ue` do fix de ontem quebrou TODOS os cargos
  de abrangência estadual (Presidente/Governador/Senador/Deputados) — em
  `consulta_cand`, esses cargos têm `sg_ue = sigla da UF` ("PR", candidato
  registrado pro estado inteiro), mas em `votacao_secao` o mesmo campo é
  sempre o código do município de onde o voto foi registrado ("74012") —
  nunca bate. Corrigido: `AND (v.cd_cargo NOT IN ('11','13') OR cand.sg_ue
  = v.sg_ue)` — só exige `sg_ue` pra Prefeito/Vereador (os únicos cargos
  municipais), cd_cargo é o campo estável do TSE pra decidir isso
  (`tp_abrangencia` teria servido mas a codificação diverge entre os dois
  datasets nesse ano — "F" vs "FEDERAL").
  (2) Sobrou uma fração pequena (8.366 de 2,68M linhas, 0,3%) sem match
  nem em candidato nem em partido — número votável de 5 dígitos (formato
  de candidato) pra Deputado Estadual sem contrapartida em nenhum dos
  dois arquivos do TSE (candidatura removida da lista mas voto ficou
  registrado — inconsistência real do dado fonte, não da query). Criado
  sentinela `sq_candidato = '-2'` pra esse caso, ao lado de `-1`
  (branco/nulo) e `-3` (legenda) já existentes — `25_aggregate.sql` não
  precisou de ajuste, os agregados principais já somam por sq_candidato
  sem excluir nenhum sentinela, e o bloco específico de legenda já é
  escopado só pra `-3`.
  Ambos testados rodando PR/2014 de verdade (2.678.185 linhas, 1m28s
  transform + 57s aggregate, sem erro).
  reverter: barato (mais uma condição no JOIN + um branch a mais no
  COALESCE; nenhum dado promovido pra produção com o bug).

- 2026-08-26 | **Bug real de duplicação achado em PR/2024** (não era só
  lentidão de CPU do achado anterior): o JOIN de `tse_votacaosecao` com
  `consulta_cand` casava só por `(nr_candidato, cd_cargo, sg_uf)` — em
  eleição GERAL isso é único no estado (SP/2018, já validado), mas em
  eleição MUNICIPAL o mesmo número de urna se repete em cidades
  diferentes (confirmado: nº 55123/vereador batia com 333 candidatos
  diferentes em PR, um por cidade). Cada voto casava com TODOS eles — fan-
  out gigante, tabela chegou a **29GB** pra um resultado que devia ficar
  ~1GB. O próprio comentário do código já previa esse cenário exato ("se
  algum ano tiver corrida municipal sem sq_candidato nativo, reconfira se
  precisa também de cd_municipio no join") — só que a coluna certa não é
  `cd_municipio` (não existe em `consulta_cand`), é `sg_ue` (Unidade
  Eleitoral — mesmo campo que `votacao_secao` já usa pra município em
  eleição municipal). Adicionado `AND cand.sg_ue = v.sg_ue` ao join;
  testado manualmente que resolve pra 1 candidato só.
  Query em andamento foi cancelada (`pg_cancel_backend`) depois de 48min
  gerando dado errado — TRUNCATE (não vacuum) usado pra recuperar os 29GB
  na hora, sem depender do autovacuum limpar aos poucos.
  reverter: barato (mais uma condição no JOIN; dado errado nunca chegou a
  ser promovido pra produção, foi pego ainda local).

- 2026-08-26 | `20_transform.sql` (INSERT em `tse_votacaosecao`) parou de
  chamar `to_jsonb(v)` 4x por linha — agora calcula 1x numa CTE (`WITH src
  AS (SELECT v.*, to_jsonb(v) AS v_json FROM ...)`) e reusa. Achado
  rodando PR/2024 (2,2M linhas): `INSERT` preso em 100% CPU por 16+min,
  sem espera de I/O nem lock (`wait_event` vazio em `pg_stat_activity`) —
  não era o SSD novo nem plano de query ruim (estatística do planner já
  batia com a contagem real, autoanalyze tinha rodado). `to_jsonb()` numa
  linha com dezenas de colunas de texto não é barato, e o Postgres não
  faz eliminação de subexpressão comum pra chamadas soltas no SELECT list
  — 4 chamadas por linha em vez de 1 é 4x o custo à toa. Não testado
  rodando de verdade ainda (evitado por não competir com a carga do PR já
  em andamento) — validar contagem antes de confiar de olhos fechados na
  próxima UF.
  reverter: barato (é só reorganizar a mesma lógica numa CTE; não muda
  resultado, só onde o cálculo acontece).

- 2026-08-26 | `ds_eleicao` em `20_transform.sql` (`tse_eleicoes`) passou a
  concatenar `| Nº turno` no texto original do TSE. O TSE não varia o
  texto por turno (ex.: "ELEIÇÕES GERAIS ESTADUAIS 2018" idêntico pros
  dois turnos de SP) — sem o turno na frente, o app não conseguia
  distinguir as duas linhas no campo de seleção (usa `ds_eleicao` como
  rótulo), impedindo escolher o turno certo. Achado comparando com o AC
  (migrado pelo pipeline antigo, que já concatenava "Eleições YYYY | Nº
  turno" — mesmo padrão replicado aqui). Corrigido também o dado já
  carregado em produção (SP/2018, `UPDATE` direto, guardado por
  `ds_eleicao NOT LIKE '%turno'` pra não rodar em cima de novo por engano).
  Nomes originais preservados — só o turno concatenado na frente, como
  pedido.
  reverter: barato (é só concatenação de texto na query; dado já corrigido
  em produção, e o transform daqui pra frente já nasce certo).

- 2026-08-24 | Novo `scripts/05_cleanup_local.sh` — passo seguinte ao
  `04_promote.sh`. Libera disco local (staging `raiox_tse_raw` + CSVs/zips
  brutos) de anos já confirmados em produção, comparando contagem local vs.
  produção antes de apagar qualquer coisa (pula sem apagar se não bater).
  Motivo: disco de 256GB travou de novo rodando só o ano de 2012 de SP —
  investigação (sem alterar nada, a pedido) achou que o causador real não
  era o dado de 2012 em si (~7GB), mas o disco de VM do Docker Desktop
  (`Docker.raw`) inchado a ~115GB reais por um dia inteiro de ciclos de
  crash+recuperação, que não desincha sozinho. Conta feita: processar 1 ano
  de SP por vez (raw+staging+schema final coexistindo) usa ~15-18GB; os 6
  anos de uma vez (comportamento padrão do `03_transform.sh` sem argumento)
  soma ~90-108GB, sem margem nenhuma pra WAL/checkpoint — por isso o plano
  agora é sempre ano a ano, com esse script limpando entre um e outro.
  Não toca no schema final `raiox` local de propósito — é o maior
  consumidor (~7-9GB/ano), mas mantê-lo serve de conferência rápida sem
  depender de rede; truncar isso também fica manual, decisão explícita do
  usuário, não automatizada.
  alternativas: aumentar o disco do Mac (fora de controle do software) |
  automatizar também o truncate do schema final local (rejeitado por ora —
  é mais destrutivo, melhor deixar manual até o processo ano-a-ano provar
  estável).
  reverter: barato (script novo, isolado; só apaga staging/bruto, sempre
  regenerável a partir do TSE).

- 2026-08-24 | Novo `scripts/04_promote.sh` — passo seguinte ao
  `03_transform.sh` na cadeia da pipeline: promove os anos de uma UF já
  transformados no piloto local (`raiox`) pra PRODUÇÃO real do Neon.
  Motivo: piloto local (disco do Mac) estourou espaço durante o transform
  de SP 2012-2024, travando o Docker inteiro (ver JOURNAL do
  `raiox-migracao-piloto`, entradas do dia). Decisão: local continua sendo
  bancada de trabalho (download+load+transform), produção passa a receber
  cada UF assim que ela termina localmente — não acumula os 27 estados
  local antes de promover.
  Trata as 2 categorias de tabela separadamente (`sql/10_target_schema.sql`):
  `tse_cidades`/`votos_partidos` são só por UF (promovidas 1x, fora do loop
  de ano), as outras 12 são por UF+ano_eleicao (promovidas por ano).
  Cache de IA (`candidato_resumo`/`pergunta_resposta_cache`) fica de fora
  de propósito — são tabelas globais, não particionadas por UF, promoção
  cega arriscaria colidir com o que já existe em produção pra outros
  estados. Idempotente: `TRUNCATE` nas tabelas-folha de produção antes de
  restaurar (mesma lição do `pg_restore` duplicando dado sem PK, já
  documentada no JOURNAL do `raiox-migracao-piloto`) — reexecutar depois de
  uma falha parcial não duplica nada. Validação de contagem local vs.
  produção, tabela a tabela, no final.
  alternativas: apontar `DATABASE_URL` direto pra produção e rodar
  `03_transform.sh` nela (rejeitado — staging `raiox_tse_raw` não devia
  existir em produção, e perde a checagem de "validei local antes de
  promover") | acumular tudo local e só promover no final, todos os
  estados de uma vez (rejeitado pelo usuário — foi exatamente isso que
  causou o crash de disco).
  reverter: barato (script novo, isolado; não altera `01`/`02`/`03`).

- 2026-08-24 | `scripts/01_download.sh` reescrito pra baixar direto do CDN
  (`cdn.tse.jus.br`), sem passar pelo Wayback Machine. Causa raiz do 403 do
  CDN investigada a fundo (bisecção de headers, não suposição): não é
  bloqueio de IP nem TLS fingerprinting como o README dizia antes — é o WAF
  (Akamai) exigindo a PRESENÇA de 6 headers de Client Hints que um Chrome
  real sempre manda numa navegação de documento (`sec-ch-ua`,
  `sec-ch-ua-mobile`, `sec-ch-ua-platform`, `Sec-Fetch-Dest`,
  `Sec-Fetch-Mode`, `Sec-Fetch-Site`), não o valor deles. Confirmado com
  download real de 476MB (`votacao_secao_2024_SP.zip`, ZIP válido) de um IP
  residencial comum, e replicado em outro dataset/ano (`consulta_cand_2022`)
  — não é específico de 1 URL. Motivado por SP 2012-2024 ser um volume
  grande demais pra depender do rate-limit do Wayback (8s entre cada
  request + backoff, ~24 downloads só pra esses 6 anos).
  alternativas: manter o Wayback como caminho principal (mais lento, sujeito
  a "sem captura arquivada" pra arquivo específico — fica registrado como
  fallback, não removido) | pedir pro usuário baixar manual sempre
  (inviável pra 27 estados × múltiplos anos).
  reverter: barato (é só header no curl; Wayback continua documentado como
  plano B se o WAF mudar de regra).

- 2026-08-21 | Validado que dá pra reconstruir `raiox.tse_votacaosecao_ac` e
  `raiox.tse_candidatos_ac` (AC, ano 2024) 100% a partir de dado público do
  TSE (dadosabertos.tse.jus.br), sem depender do MySQL de produção. Piloto
  restrito a 1 ano pra validar rápido antes de rodar os outros 6
  (2012–2022). Contagens e soma de `qt_votos` bateram exato contra o schema
  `raiox` já migrado. Dois ajustes de ETL descobertos e documentados em
  `sql/20_transform.sql`: (1) cast de tipo no join de `cd_municipio` pra
  trazer `nm_bairro` (texto com zero à esquerda vs sem); (2) excluir
  candidatos com `ds_sit_tot_turno = '#NULO'` (não entraram na apuração) —
  fechou 2311 → 2195, batendo com produção.
  alternativas: validar direto com os 7 anos de uma vez (rejeitado — mais
  lento pra achar bug, e achamos 2 bugs de ETL que só apareceram comparando
  com número conhecido; melhor achar isso num recorte pequeno primeiro).
  reverter: barato (schema `raiox_tse` isolado, mesmo Postgres do piloto
  MySQL; dropar schema não afeta nada em produção nem no piloto original).

- 2026-08-22 | `tse_votacaosecao_partido` (voto de legenda) resolvida SEM
  dataset novo: descoberto que já vem dentro de `votacao_secao` (linhas com
  `sq_candidato = '-3'`, sentinela igual ao `-1` de branco/nulo; `nr_votavel`
  = número do partido). `sigla_partido` resolvida via join com
  `consulta_cand` (`nr_partido`/`sg_partido`). Validado contra a produção
  anterior (backup em `raiox-migracao-piloto/data/raiox_schema.dump`,
  restaurado só essa tabela pra comparar): 7.895 linhas, bate exato.
  `votos_partidos` conferida no mesmo backup — sempre foi 0 linhas, mesmo
  antes de qualquer mudança feita aqui; não é uma tabela que este pipeline
  precisa preencher. Teste completo rodado com o schema `raiox` zerado do
  zero (truncate pedido pelo usuário pra validar limpo) — tudo bateu.
  alternativas: usar o dataset `votacao_partido_munzona` (baixado e
  inspecionado) pra essa tabela — rejeitado porque é só município/zona, não
  tem a granularidade de seção que a tabela pede; o dado que já estava
  carregado é mais completo.
  reverter: barato (é só um filtro sobre dado já carregado, sem dataset
  extra pra gerenciar).

- 2026-08-24 | **Particionamento em 2 níveis: uf → ano_eleicao**, nas 13
  tabelas com `ano_eleicao` (tse_cidades e votos_partidos ficam só com
  partição por uf, não têm essa coluna). Decisão do usuário, motivada por
  uma pergunta direta: "não corre risco de ficar lento incluindo mais anos,
  já que não tem partição por ano?". Resposta tinha duas partes — consulta
  de 1 ano não desacelera com mais anos entrando (índice com `ano_eleicao`
  líder já resolve isso, custo logarítmico); mas o padrão real de operação
  (recarregar 1 ano inteiro a cada eleição nova, e sempre que um bug pede
  reprocessar) sim tinha problema: `DELETE+INSERT` numa tabela compartilhada
  entre anos deixa linha morta pra trás. Achado concreto durante a
  investigação: SP (só 2018 carregado) já estava em 29GB com 2,4M linhas
  mortas por causa dos vários reprocessamentos desta sessão — uma query que
  rodava em ~6s foi pra 18s só por causa disso.
  Fix: cada `X_:uf_lower` (que antes era a partição-folha) virou ela mesma
  `PARTITION BY LIST (ano_eleicao)`, com a folha de verdade criada por um
  novo `sql/15_target_schema_year.sql` (roda por uf+ano, dentro do loop de
  `scripts/03_transform.sh`). `DELETE` nos 13 `TRUNCATE`s de
  `20_transform.sql`/`25_aggregate.sql` virou `TRUNCATE` na partição-folha
  do ano — instantâneo, zero linha morta.
  Migração do dado já carregado: 3 PKs (`tse_eleicoes`, `tse_cargos`,
  `tse_candidatos`) precisaram incluir `ano_eleicao` — Postgres exige que
  toda coluna de particionamento esteja na constraint única de uma tabela
  particionada. Adicionada também uma partição `DEFAULT` por tabela (pega
  ano fora do esperado, inclusive NULL — achado restaurando o AC: uma linha
  de `tse_votos_candidato_bairro` tinha `ano_eleicao` NULL de verdade, dado
  legado incompleto). AC restaurado do backup MySQL direto na nova
  estrutura (Postgres roteia sozinho pras partições certas); SP recarregado
  via `raiox-tse-opendata` (não tem backup MySQL, só o pipeline TSE).
  alternativas: manter só índice, sem particionar por ano (rejeitado — não
  resolve o inchaço do padrão de recarga, só a leitura); particionar por
  RANGE em vez de LIST em ano_eleicao (rejeitado — LIST é mais simples e
  cada ano já é um valor discreto conhecido, não uma faixa contínua).
  reverter: caro (mexe em constraint/estrutura de 13 tabelas; reverter
  exigiria a mesma cirurgia de novo, ao contrário).

- 2026-08-23 | **Bug crítico encontrado e corrigido**: `sql/20_transform.sql`
  fazia JOIN com `eleitorado_locais_votacao` sem filtrar por `nr_turno`.
  Esse dataset tem 1 linha por seção POR TURNO — em eleição com 2º turno
  (SP/2018 teve, governador), toda linha de `votacao_secao` casava com as
  2 linhas de turno e DUPLICAVA a tabela inteira. `tse_votacaosecao` do SP
  chegou a 36.467.648 linhas quando o real (comparado contra o MySQL de
  produção, host 177.73.235.209, tabela `tse_votacaosecao_2018`) é
  17.834.220 (do dado que baixei) + 1.486.640 de presidente (não baixado,
  ver próxima entrada) = 19.320.860. AC/2024 nunca expôs isso porque só
  tinha 1 turno (eleição municipal). Fix: adicionado `AND l.nr_turno = v.
  nr_turno` no JOIN. SP/2018 sendo recarregado do zero com o fix (mesmo
  `DELETE ... WHERE uf+ano` idempotente de sempre resolve, sem precisar de
  truncate manual).
  Descoberto comparando contagens contra o MySQL de produção (acesso
  cedido pelo usuário especificamente pra essa investigação) — reforça o
  valor de manter esse tipo de comparação como parte do processo de
  validar uma UF nova, não só rodar e assumir que bateu.
  alternativas: nenhuma — é um bug de JOIN, não uma escolha de design.
  reverter: caro (dado já escrito em `raiox` de produção local antes da
  correção; mitigado por já estar sendo recarregado).

- 2026-08-23 | Mesma classe de bug, achada na recarga seguinte: o JOIN com
  `consulta_cand` (pra resolver `sq_candidato` em anos sem essa coluna
  nativa) também não filtrava `nr_turno` — candidato que vai pro 2º turno
  tem 1 linha por turno lá também (mesmo `sq_candidato`, status diferente:
  "2º TURNO" na linha do turno 1, "ELEITO"/final na do turno 2). Sobravam
  399.604 linhas extras mesmo depois do fix anterior. Corrigido com `AND
  cand.nr_turno = v.nr_turno`. Restou ainda uma sobra menor (14.341
  linhas): colisão de número de urna entre candidato real e candidatura
  invalidada (`#NULO#`) — resolvido excluindo `#NULO%` do JOIN também (não
  só do filtro final de `tse_candidatos`, que já existia mas usava
  `<> '#NULO'` exato — não pegava a variante com `#` no final que SP/2018
  usa; 2024/AC usa sem o `#`. Os dois agora usam `NOT ILIKE '#NULO%'`).
  Com os 3 fixes, contagem bate exato com o raw baixado: 17.834.220.
  Validado que nenhuma linha fica com `sq_candidato` NULL antes de rodar
  de verdade (simulação via SELECT, sem tocar o banco).
  reverter: caro (mesma razão da entrada anterior).

- 2026-08-23 | Último ajuste da mesma investigação: `tse_candidatos.
  total_votos` estava somando os 2 turnos juntos pra quem foi a 2º turno
  (número sem sentido). Conferido contra produção: o valor certo é só do
  1º turno — mesmo assim nas duas linhas de `tse_candidatos` (1 por
  turno), igual à produção faz. Fix: `AND nr_turno = 1` na subquery de
  soma. Não precisou reprocessar `tse_votacaosecao`/agregados (só
  `tse_candidatos` lê esse valor) — rodado à parte, sem repetir a carga de
  2,5h. Validação final (`sql/30_validate.sql`) bateu limpo: 17.834.220
  linhas em `tse_votacaosecao`, soma 155.444.062 idêntica nos 3 níveis de
  `tse_votos_candidato_*`, 0 `sq_candidato` nulo, 0 sem bairro.
  reverter: barato (é só a subquery de total_votos, isolada).

- 2026-08-23 | Descoberto que votos de PRESIDENTE (cd_cargo=1) não vêm no
  dataset `votacao_secao_{ANO}_{UF}.zip` que uso — é uma eleição separada
  no TSE (`cd_eleicao` diferente: "ELEIÇÃO GERAL FEDERAL" vs "ELEIÇÕES
  GERAIS ESTADUAIS", mesmo ano/dia de votação). O TSE publica presidente
  num arquivo nacional à parte: `votacao_secao_{ANO}_BR.zip` (não por UF,
  já que é eleição nacional). Confirmado o padrão da URL; tentativa de
  baixar via Wayback falhou (cópia arquivada trunca sempre nos mesmos
  ~39MB de ~123MB esperados — corrompida na origem, não é instabilidade
  de rede). Pendente: download manual do arquivo pelo usuário. Sem esse
  dado, `tse_candidatos`/`tse_votacaosecao` do SP/2018 nunca vão ter
  candidatos a presidente — gap conhecido, não é bug do pipeline.
  reverter: barato (é só um dataset a mais pra somar depois; não afeta o
  que já está correto pros outros cargos).

- 2026-08-22 | `sql/10_target_schema.sql` ganhou um índice composto novo em
  `tse_votacaosecao` — `(ano_eleicao, nr_turno, cd_cargo, cd_municipio,
  nr_zona, nr_secao)` — achado investigando lentidão real em produção com
  SP carregado (endpoints de `getVotosCandidato` filtrando por
  turno+cargo+município(+zona+seção) caíam em Seq Scan/Bitmap Scan lendo
  milhões de linhas). Detalhe da mudança e números em
  raiox-votos-node/docs/decisions/JOURNAL.md — aqui só o registro de que o
  schema-base passou a incluir esse índice pra qualquer UF nova.
  reverter: barato (índice, sem efeito em dado; dropar não perde nada).

- 2026-08-22 | Projeto virou ferramenta de migração real (não mais piloto
  isolado): grava DIRETO no schema `raiox` de produção, mesmo particionamento
  por UF de `raiox-migracao-piloto/sql/10_target_schema_draft.sql`. Sem
  lock/guarda contra reprocessar uma UF já existente (ex.: AC) — usuário
  confirmou explicitamente que sobrescrever é aceitável. `sql/10_target_
  schema.sql`, `sql/20_transform.sql` e novo `sql/25_aggregate.sql` agora são
  parametrizados por `:uf`/`:uf_lower`/`:ano` (não mais hardcoded `_ac`).
  alternativas: manter schema isolado `raiox_tse` e promover pra `raiox` como
  passo manual separado depois (rejeitado — usuário quer o pipeline já ser o
  caminho real, sem etapa de promoção extra).
  reverter: caro (uma vez rodado contra produção real, sobrescreve dado que
  não tem outra cópia fácil — mitigado pelo dump `raiox-migracao-piloto/data/
  raiox_schema.dump`, feito antes de qualquer escrita real).

- 2026-08-22 | Escopo ampliado pra cobrir as tabelas agregadas
  (`tse_votos_candidato_cidade/bairro/local`, `tse_votosvalidos_eleicao/
  cidade/bairro/local`) — antes ficavam de fora por não terem dataset TSE
  direto. Solução: recalcular via SQL a partir de `tse_votacaosecao`/
  `tse_locais` já carregados (mesma fórmula já validada em
  `raiox-migracao-piloto/sql/50_backfill_votosvalidos_local_bairro.sql`).
  Rodado contra AC/2024 e comparado com a produção anterior (migrada via
  MySQL): soma de votos bate exato em todas; contagem de linhas diverge um
  pouco porque o agrupamento daqui é mais consistente que o pré-calculado do
  MySQL, que já tinha inconsistência interna entre granularidades (ver
  README pra números). `votos_partidos`/`tse_votacaosecao_partido` (voto de
  legenda) ficaram de fora — dataset candidato (`votacao_partido_munzona`)
  identificado mas não baixado (Wayback falhou); aguardando arquivo manual
  do usuário antes de confirmar o mapeamento de colunas.
  alternativas: perseguir paridade exata de contagem com o MySQL antigo
  (rejeitado — lógica original desconhecida e comprovadamente já
  inconsistente entre tabelas; validar por soma total + consistência interna
  é mais confiável que replicar um bug não documentado).
  reverter: barato (schema de agregados pode ser recalculado a qualquer
  momento a partir de tse_votacaosecao/tse_locais, sem perda de informação).

- 2026-08-21 | Download direto de `cdn.tse.jus.br`/`dadosabertos.tse.jus.br`
  não funciona deste tipo de ambiente (403, WAF/Akamai — confirmado com
  curl liso, com UA de navegador, e via wget). Caminho alternativo
  automático: Wayback Machine como proxy (`web.archive.org/web/2/<url>`).
  Funciona mas tem rate-limit próprio agressivo no endpoint de "save on
  demand" — script com pacing/backoff, mesmo assim uma fração falha. Pro
  teste de 2024 usado aqui, o usuário baixou manualmente (mais rápido).
  alternativas: mirror do Brasil.IO (`data.brasil.io/mirror/eleicoes-brasil`)
  — não testado ainda, fica como opção se o Wayback continuar instável pros
  anos que faltam.
  reverter: barato (é só mecanismo de download, não afeta o dado já
  carregado).
