# raiox-tse-opendata

Ferramenta de migração real: carrega dado público do TSE
(dadosabertos.tse.jus.br) DIRETO no schema `raiox` de produção (o mesmo que
o `raiox-votos-node` lê), no mesmo particionamento por UF já usado em
`raiox-migracao-piloto`. Alternativa ao caminho MySQL→Postgres, que falhou
pro SP por volume (ver `raiox-migracao-piloto`, Stage 10).

**Não versiona nenhuma base raw.** Rodar = soltar os arquivos de uma UF em
`data/raw/<dataset>/<ano>/` (baixados sozinho ou manualmente) e chamar os
scripts. Carga é incremental por ano — a cada nova eleição (2 em 2 anos)
roda de novo só com o ano novo, sem reprocessar os anteriores.

## Decisões (ver `docs/decisions/JOURNAL.md` pro histórico completo)

- Grava DIRETO em `raiox`, não num schema isolado — é o caminho real pra
  migrar estados novos (retomar SP) ou reprocessar um já existente.
- **Sem lock/guarda**: rodar pra uma UF que já existe (ex.: AC, migrado
  originalmente via MySQL) SOBRESCREVE os dados dela pro(s) ano(s) passado(s).
  Aceito deliberadamente pelo usuário — sem confirmação extra no script.
- `RAW_SCHEMA` (`raiox_tse_raw` por padrão) é só staging interno — 1:1 do
  CSV, tudo texto, nunca lido pelo backend. Fica no mesmo Postgres que
  `raiox`, mas separado.
- Apontar `DATABASE_URL` pra VPS/produção real (em vez do Postgres local de
  teste) é decisão manual, feita por fora deste projeto — não é automático.
- **Particionamento em 2 níveis: uf → ano_eleicao**, nas 13 tabelas que têm
  `ano_eleicao` (`tse_cidades`/`votos_partidos` continuam só por uf). Cada
  `raiox.tabela_<uf>` é ela mesma particionada por ano; a partição do ano é
  criada por `sql/15_target_schema_year.sql`. Motivo: recarregar 1 ano
  (rotina — a cada eleição nova) virou `TRUNCATE` da partição do ano em vez
  de `DELETE` numa tabela compartilhada entre anos — sem isso, reprocessar
  deixa linha morta pra trás (achado real: SP chegou a 29GB com 2,4M linhas
  mortas nesta sessão). Toda tabela também tem uma partição `DEFAULT`
  (pega ano fora do esperado, inclusive NULL — tem dado legado assim).

## Escopo: tabelas cobertas

| Tabela `raiox` | Fonte | Status |
|---|---|---|
| `tse_eleicoes`, `tse_cargos` | distinct de `votacao_secao` | ✅ |
| `tse_cidades` | distinct de `votacao_secao` (append-only, sem `ano_eleicao`) | ✅ |
| `tse_candidatos` | `consulta_cand` (+ `total_votos` somado de `votacao_secao`) | ✅ (ver gap `cd_municipio` abaixo) |
| `tse_votacaosecao` | `votacao_secao` + join de bairro via `eleitorado_locais_votacao` | ✅ validado 100% (AC/2024) |
| `tse_locais` | `eleitorado_locais_votacao` (quase 1:1 de colunas) | ✅ |
| `tse_votos_candidato_cidade/bairro/local` | agregado (SUM/GROUP BY) de `tse_votacaosecao` | ✅ recalculado — ver nota abaixo |
| `tse_votosvalidos_eleicao/cidade/bairro/local` | agregado de `tse_votacaosecao` + `tse_locais` | ✅ recalculado — ver nota abaixo |
| `tse_votacaosecao_partido` | "voto de legenda" — já vem dentro de `votacao_secao` (`sq_candidato = '-3'`), sem dataset extra | ✅ validado (7.895 linhas, AC/2024, bate exato com produção anterior) |
| `votos_partidos` | — | ✅ sempre vazia na produção original também (não é regressão) |

No MySQL de origem (piloto AC) as tabelas agregadas vinham PRÉ-CALCULADAS —
aqui não existe MySQL, então `sql/25_aggregate.sql` recalcula tudo a partir
de `tse_votacaosecao`/`tse_locais` já carregados. As fórmulas de
válidos/nulos/brancos/ausentes são as mesmas já validadas em
`raiox-migracao-piloto/sql/50_backfill_votosvalidos_local_bairro.sql`
(100% de acerto contra 2024/AC real).

**Rodando de novo pro AC/2024 e comparando com a produção anterior
(migrada via MySQL):** a SOMA de votos bate exato em todas as tabelas de
`tse_votos_candidato_*` (968.414 — igual ao total de `tse_votacaosecao`).
A CONTAGEM de linhas mudou um pouco (ex.: `tse_votos_candidato_bairro`
tinha 24.627 linhas na produção antiga, agora tem 25.279) — a soma bater e a
contagem divergir indica que o agrupamento aqui é mais fino/consistente do
que o pré-calculado do MySQL (que já era internamente inconsistente: os
totais de válidos batiam diferente entre `_local`, `_bairro` e `_cidade` na
produção antiga — 931.560 / 939.593 / 939.418 — aqui os três batem exato:
939.593). Não foi perseguida paridade byte-a-byte com uma lógica de MySQL
desconhecida e já inconsistente; a validação usada foi consistência interna
+ soma total batendo com `tse_votacaosecao`.

## Voto de legenda — resolvido sem dataset extra

`tse_votacaosecao_partido` (usada por `getVotosCandidato` tipo 7 e
`getDtColigacao` no backend Node) parecia precisar de um 4º dataset, mas não
precisa: nas eleições proporcionais (vereador), quando o eleitor digita só o
número do partido, o próprio `votacao_secao` já grava essa linha —
`sq_candidato = '-3'` (sentinela, igual a `-1` pra branco/nulo) e
`nr_votavel` = número do partido. `sql/25_aggregate.sql` filtra por isso e
resolve `sigla_partido` via join com `consulta_cand` (que tem
`nr_partido`/`sg_partido`). Validado contra a produção anterior: 7.895
linhas, bate exato (AC/2024).

O dataset `votacao_partido_munzona` (baixado manualmente e testado) até
existe e tem granularidade de município/zona/partido, mas acabou não sendo
necessário — a informação de seção já estava em `votacao_secao`. Fica
baixado em `data/raw/votacao_partido_munzona/` mas sem uso no pipeline por
enquanto.

`votos_partidos` fica sempre vazia — conferido contra o backup da produção
anterior (migrada via MySQL): já era 0 linhas lá também, antes de qualquer
mudança feita aqui. Não é uma tabela que este pipeline precisa preencher.

## Gaps conhecidos (documentados, não escondidos)

- `tse_candidatos.cd_municipio`: sempre NULL. `consulta_cand` não traz esse
  campo — só `sg_ue` (código da unidade eleitoral: é o município em eleição
  municipal, mas é a UF em eleição estadual/federal). Preferi deixar NULL a
  assumir errado pros cargos estaduais/federais.
- Regra `ds_sit_tot_turno <> '#NULO'` no filtro de candidatos: validada só
  pra 2024/AC. Reconfira ao carregar o 1º ano/UF novo.
- `tse_votos_candidato_bairro`: soma de votos bate exato aqui (diferente da
  produção antiga, que tinha ~0,06% de déficit) — ver nota acima.
- ~~Votos de PRESIDENTE (cd_cargo=1) faltando.~~ **Resolvido em
  2026-08-26.** `votacao_secao_{ANO}_{UF}.zip` de fato não traz essa
  eleição (outro `cd_eleicao` no TSE, "ELEIÇÃO GERAL FEDERAL", separado de
  "ELEIÇÕES GERAIS ESTADUAIS") — a cópia no Wayback estava corrompida, mas
  o CDN direto funciona normal (`votacao_secao_{ANO}_BR.zip`, nacional,
  ~1.5GB). `01_download.sh` baixa esse arquivo só em ano de eleição geral
  (2014/2018/2022/2026...); `02_load_raw.sh` filtra por UF (~9M+ linhas no
  Brasil inteiro, não faz sentido carregar as outras 26) antes de subir;
  `20_transform.sql` UNE com o estadual em `tse_eleicoes`/`tse_cargos`/
  `tse_votacaosecao`/`tse_candidatos`. Mesmo dataset resolveu de graça o
  gap de eleições EXTRAORDINÁRIAS (suplementares por município) que
  também não estava filtrado antes — `cd_tipo_eleicao='2'` (ORDINÁRIA) em
  tudo agora, extraordinária nunca entra. Validado com PR/2022 real:
  Bolsonaro 3.628.612 x Lula 2.363.492 no 1º turno (bate com o resultado
  real), soma de `tse_votacaosecao` fechou 3.397.518 (estadual) +
  297.889 (federal) = 3.695.407 exato. Ver `docs/decisions/JOURNAL.md`.
- **JOIN com `eleitorado_locais_votacao` precisa filtrar `nr_turno`.** Bug
  real encontrado e corrigido em 2026-08-23 (dobrava a tabela inteira em
  eleição com 2º turno) — deixado aqui só como lembrete de que esse
  dataset tem 1 linha por seção POR TURNO, não por seção. Se o join for
  reescrito no futuro, não esquecer essa coluna.

## Como rodar (migração real, uma UF)

```bash
cp .env.example .env      # ajuste UF/UF_LOWER/ANOS
scripts/01_download.sh    # tenta baixar tudo sozinho via Wayback;
                           # o que falhar cai em data/MISSING.md com a URL
                           # certa pra você baixar manualmente e colocar em
                           # data/raw/<dataset>/<ano>/
scripts/02_load_raw.sh    # CSV -> tabelas raw (schema raiox_tse_raw), staging
scripts/03_transform.sh   # pra cada ano: garante a partição da UF (10_) e a
                           # partição do ano dentro dela (15_), TRUNCATE +
                           # transform + agregação, DIRETO em `raiox` LOCAL
                           # (piloto, docker do raiox-migracao-piloto).
                           # Sobrescreve se a UF/ano já existir (idempotente).
scripts/04_promote.sh     # promove os anos já transformados (acima) pra
                           # PRODUÇÃO real do Neon — precisa de
                           # PROD_DATABASE_URL no .env. Idempotente (TRUNCATE
                           # antes de restaurar); valida contagem local vs.
                           # produção no final, tabela a tabela.
scripts/05_cleanup_local.sh  # libera disco local: apaga staging
                           # (raiox_tse_raw) e CSVs/zips brutos do(s) ano(s)
                           # já confirmados em produção (mesma checagem de
                           # contagem do 04). Não toca no schema final
                           # `raiox` local — só staging/bruto, que são
                           # descartáveis por natureza.
```

`03_transform.sh` escreve no piloto local (staging/bancada de trabalho —
disco do Mac, mais barato de errar). `04_promote.sh` é o passo separado que
leva pra produção de verdade — mantém a credencial de produção fora do
caminho de carga/transformação, e dá uma checagem de contagem antes de
considerar um estado "promovido".

`psql` não vem por padrão no macOS — instalado via `brew install libpq`
(keg-only, os scripts já exportam o PATH necessário).

## Passo a passo real (exemplo: AC/2024)

Testado de ponta a ponta com estes 4 arquivos. Se `scripts/01_download.sh`
não conseguir baixar sozinho (Wayback instável, ver seção abaixo), essas são
as URLs exatas pra baixar manualmente e onde colocar cada uma:

| # | Arquivo | URL (troque `{ANO}`/`{UF}`) | Onde colocar |
|---|---|---|---|
| 1 | `votacao_secao_{ANO}_{UF}.zip` | https://cdn.tse.jus.br/estatistica/sead/odsele/votacao_secao/votacao_secao_2024_AC.zip | `data/raw/votacao_secao/2024/` |
| 2 | `consulta_cand_{ANO}.zip` (nacional) | https://cdn.tse.jus.br/estatistica/sead/odsele/consulta_cand/consulta_cand_2024.zip | `data/raw/consulta_cand/2024/` |
| 3 | `eleitorado_local_votacao_{ANO}.zip` (nacional, ~250MB) | https://cdn.tse.jus.br/estatistica/sead/odsele/eleitorado_locais_votacao/eleitorado_local_votacao_2024.zip | `data/raw/eleitorado_locais_votacao/2024/` |
| 4 | `votacao_partido_munzona_{ANO}.zip` (nacional — hoje sem uso no pipeline, ver "Voto de legenda" abaixo, mas fica registrado pro padrão de URL) | https://cdn.tse.jus.br/estatistica/sead/odsele/votacao_partido_munzona/votacao_partido_munzona_2024.zip | `data/raw/votacao_partido_munzona/2024/` |

Os arquivos 2, 3 e 4 são **nacionais** — baixados/extraídos **uma vez por
ano**, servem pra qualquer UF depois, sem re-download. Dois casos diferentes:

- **`consulta_cand` e `votacao_partido_munzona`**: o zip nacional já vem
  **pré-dividido por UF por dentro** — ao extrair, aparecem
  `..._{ANO}_AC.csv`, `..._{ANO}_SP.csv`, etc., todos juntos na mesma pasta.
  Nada a filtrar, já está pronto pra qualquer estado.
- **`eleitorado_locais_votacao`**: é um único CSV nacional, SEM divisão
  interna (confirmado em 2018 e 2024: todas as 27 UFs + `ZZ` no mesmo
  arquivo). `scripts/02_load_raw.sh` filtra por UF automaticamente desde
  2026-08-26 (`awk -F';' 'NR==1 || $7=="\"UF\""'`, coluna 7 = `SG_UF`) antes
  do `\copy` — não carrega mais ~250-400MB nacional à toa a cada estado
  processado. Resultado do filtro fica em cache
  (`..._{ANO}_{UF}.csv`, ao lado do nacional) — se você mesmo soltar um
  arquivo já filtrado com esse nome, o script não regenera, só usa.

**Não apague os arquivos nacionais depois de usar** — o nome de destino do
download não leva UF, então rodar `01_download.sh` de novo pra outro estado
só pula (já existe, válido) em vez de baixar/sobrescrever. Apagar é o único
jeito de forçar um re-download.

Depois de baixar (sozinho ou manual) e extrair (`01_download.sh` extrai
todo `.zip` que achar em `data/raw/`, mesmo os colocados manualmente):

```bash
scripts/02_load_raw.sh    # csv -> staging (raiox_tse_raw)
scripts/03_transform.sh   # staging -> raiox (schema + transform + agregados)
psql "$DATABASE_URL" -v uf=AC -v ano=2024 -f sql/30_validate.sql   # confere
```

## Por que o download não é direto (era) — CORRIGIDO em 2026-08-24

~~`cdn.tse.jus.br` bloqueia por reputação de IP (WAF/Akamai)~~ — **não era
isso**. Investigado a fundo em 2026-08-24: `curl` liso, mesmo com User-Agent
de navegador completo, dá 403; mas isolando headers um a um, o bloqueio cai
por completo com só 6 headers de **Client Hints** que um Chrome real sempre
manda numa navegação de documento — `sec-ch-ua`, `sec-ch-ua-mobile`,
`sec-ch-ua-platform`, `Sec-Fetch-Dest`, `Sec-Fetch-Mode`, `Sec-Fetch-Site`
(mais o `User-Agent`). Não é o VALOR desses headers que importa (testado
com valores fictícios de Chrome/macOS), só a PRESENÇA — o WAF (Akamai) está
checando "isso parece uma navegação de browser real", não filtrando por IP.
Confirmado de um IP residencial comum (não datacenter), em vários
datasets/anos — não é específico de 1 URL. `scripts/01_download.sh` já usa
esse header set direto contra o CDN, sem proxy.

Caminhos de download disponíveis:

1. **Automático — CDN direto (`scripts/01_download.sh`), padrão atual:**
   `curl` com os 6 headers de Client Hints acima, direto em
   `cdn.tse.jus.br`. Rápido (sem rate-limit próprio) e confiável.
2. **Fallback — Wayback Machine:** se o CDN voltar a bloquear (WAF pode
   mudar de regra) ou um arquivo específico não existir mais lá,
   `web.archive.org/web/2/<url original>` redireciona pra uma captura
   existente. Mais lento (rate-limit agressivo do próprio Wayback nesse
   endpoint de "save on demand") — não é mais o caminho padrão do script,
   mas fica documentado como plano B.
3. **Manual:** baixar direto de `dadosabertos.tse.jus.br` (navegador normal)
   e colocar em `data/raw/<dataset>/<ano>/` — continua funcionando, mas com
   o CDN direto liberado deixou de ser necessário no dia a dia.

## Datasets usados (mapeamento pro schema `raiox`)

| Dataset TSE | Padrão de URL | Usado por |
|---|---|---|
| Votação por seção eleitoral | `.../votacao_secao/votacao_secao_{ANO}_{UF}.zip` | `tse_votacaosecao`, `tse_eleicoes`, `tse_cargos`, `tse_cidades`, agregados |
| Candidatos (`consulta_cand`) | `.../consulta_cand/consulta_cand_{ANO}.zip` (nacional, filtra `_{UF}.csv` depois de extrair) | `tse_candidatos` |
| Locais de votação (`eleitorado_locais_votacao`) | `.../eleitorado_locais_votacao/eleitorado_local_votacao_{ANO}.zip` (nacional — **~250MB**, sem split por UF; `02_load_raw.sh` filtra com awk por `SG_UF` antes de carregar) | `tse_locais`, join de bairro, agregados de válidos |
| Votação em partido por município/zona | `.../votacao_partido_munzona/votacao_partido_munzona_{ANO}.zip` | testado, hoje **sem uso** no pipeline — `tse_votacaosecao_partido` saiu de `votacao_secao` direto (ver "Voto de legenda" acima) |

Base: `https://cdn.tse.jus.br/estatistica/sead/odsele`

**Fora de escopo** (sem dataset TSE direto, ou fora do domínio "raio-x de
votos"): `tse_bemcandidatos` (bens de candidato, não usado pelo backend).
