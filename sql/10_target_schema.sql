-- Schema alvo do `raiox` — copiado de
-- raiox-migracao-piloto/sql/10_target_schema_draft.sql (mesma fonte, mesmo
-- particionamento por UF) porque este projeto grava DIRETO no schema de
-- produção, não num schema isolado. Ver docs/decisions/JOURNAL.md
-- (2026-08-22) pela decisão.
--
-- Idempotente: tabelas-mãe e partições usam IF NOT EXISTS. Rodar de novo
-- para uma UF que já existe (inclusive AC, migrado originalmente via MySQL)
-- SOBRESCREVE os dados dessa UF quando 20_transform.sql/25_aggregate.sql
-- rodarem em seguida (DELETE+INSERT por uf+ano) — aceito deliberadamente
-- pelo usuário, sem lock/guarda. NUNCA usar DROP aqui — destruiria as UFs
-- já migradas.
--
-- Adição sobre o rascunho original: tse_votacaosecao_partido (visto no MySQL
-- do AC só pra 2024, ver 40_add_votacaosecao_partido.sql no piloto) — dados
-- de "voto de legenda". Fonte: já vem dentro de votacao_secao (sq_candidato
-- = '-3'), não precisa de dataset novo — ver sql/25_aggregate.sql.
--
-- PARTICIONAMENTO EM 2 NÍVEIS (uf → ano_eleicao): achado investigando
-- lentidão com SP carregado — a tabela `X_:uf_lower` de uma tabela com
-- ano_eleicao não é mais uma partição-folha, ela mesma é `PARTITION BY LIST
-- (ano_eleicao)`. A partição do ano específico é criada por
-- sql/15_target_schema_year.sql (roda por uf+ano, dentro do loop de anos —
-- este arquivo só cuida do nível uf). Motivo: recarregar 1 ano (padrão real
-- de operação — a cada eleição nova, e sempre que um bug pede reprocessar)
-- vira TRUNCATE da partição daquele ano em vez de DELETE numa tabela
-- compartilhada entre todos os anos — sem isso, DELETE+INSERT repetido
-- deixa linha morta pra trás até o autovacuum limpar (achado real: SP
-- chegou a 29GB com 2,4M linhas mortas depois de vários reprocessamentos
-- nesta sessão). Tabelas sem ano_eleicao (tse_cidades, votos_partidos)
-- continuam só com partição por uf.
--
-- Cada tabela em 2 níveis também ganha uma partição DEFAULT (X_default_
-- :uf_lower) — pega qualquer ano_eleicao sem partição específica, inclusive
-- NULL. Achado restaurando o backup do AC: uma linha de
-- tse_votos_candidato_bairro tinha ano_eleicao NULL de verdade (dado legado
-- incompleto — comentário original já avisava "reconstituído a partir do
-- nome da tabela de origem"). Sem DEFAULT, uma linha assim quebra o INSERT
-- inteiro em vez de só cair numa partição de sobra.
CREATE SCHEMA IF NOT EXISTS raiox;

-- Tabelas de referência (pequenas, sem uf/particionamento — parecem
-- catálogos, não dado eleitoral por estado. Confirme se são realmente
-- globais ou se cada estado tem sua própria cópia antes de assumir isso
-- para os outros 26 — aqui só vimos a cópia do AC.)
CREATE TABLE IF NOT EXISTS raiox.tse_eleicoes (
    uf           varchar(2)  NOT NULL,
    id           bigint      NOT NULL,
    ano_eleicao  bigint,
    nr_turno     integer,
    ds_eleicao   varchar(200) NOT NULL,
    -- PK precisa incluir ano_eleicao: Postgres exige que toda coluna de
    -- particionamento (uf E ano_eleicao, agora que a tabela é particionada
    -- em 2 níveis) esteja na constraint única. id já é único por uf+ano
    -- sozinho (esquema ano*1000000+row_number()) — ano_eleicao aqui é
    -- redundante pra unicidade, só satisfaz a exigência do Postgres.
    PRIMARY KEY (uf, ano_eleicao, id)
) PARTITION BY LIST (uf);
CREATE TABLE IF NOT EXISTS raiox.tse_eleicoes_:uf_lower PARTITION OF raiox.tse_eleicoes FOR VALUES IN (:'uf') PARTITION BY LIST (ano_eleicao);
CREATE TABLE IF NOT EXISTS raiox.tse_eleicoes_default_:uf_lower PARTITION OF raiox.tse_eleicoes_:uf_lower DEFAULT;

CREATE TABLE IF NOT EXISTS raiox.tse_cargos (
    uf           varchar(2) NOT NULL,
    id           bigint     NOT NULL,
    ano_eleicao  bigint,
    nr_turno     integer,
    cd_cargo     bigint,
    ds_cargo     varchar(100) NOT NULL,
    -- PK inclui ano_eleicao pelo mesmo motivo de tse_eleicoes acima.
    PRIMARY KEY (uf, ano_eleicao, id)
) PARTITION BY LIST (uf);
CREATE TABLE IF NOT EXISTS raiox.tse_cargos_:uf_lower PARTITION OF raiox.tse_cargos FOR VALUES IN (:'uf') PARTITION BY LIST (ano_eleicao);
CREATE TABLE IF NOT EXISTS raiox.tse_cargos_default_:uf_lower PARTITION OF raiox.tse_cargos_:uf_lower DEFAULT;

CREATE TABLE IF NOT EXISTS raiox.tse_cidades (
    uf            varchar(2) NOT NULL,
    id            bigint     NOT NULL,
    sg_uf         varchar(2),
    cd_municipio  bigint,
    nm_municipio  varchar(120),
    PRIMARY KEY (uf, id)
) PARTITION BY LIST (uf);
CREATE TABLE IF NOT EXISTS raiox.tse_cidades_:uf_lower PARTITION OF raiox.tse_cidades FOR VALUES IN (:'uf');

-- Candidatos por eleição/ano (colunas reais — bem mais rico que o palpite
-- original lido só do PHP)
CREATE TABLE IF NOT EXISTS raiox.tse_candidatos (
    uf                        varchar(2)   NOT NULL,
    id                        bigint       NOT NULL,
    sq_candidato              varchar(40),
    nome_candidato            varchar(200),
    nome_urna_candidato       varchar(200),
    numero_cand               varchar(10),
    sigla_partido             varchar(20),
    total_votos               bigint,
    cd_sit_tot_turno          bigint,
    desc_sit_cand_tot         varchar(120),
    cd_cargo                  bigint,
    descricao_cargo           varchar(100),
    sigla_uf                  varchar(2),
    cd_municipio              bigint,
    num_turno                 varchar(5),
    cd_eleicao                bigint,
    ano_eleicao               bigint,
    nome_foto                 varchar(200),
    sq_coligacao              varchar(40),
    nm_coligacao              varchar(200),
    ds_composicao_coligacao   text,
    cd_sit_candidatura        varchar(10),
    ds_sit_candidatura        varchar(120),
    rodou_rot                 boolean,
    cd_detalhe_situacao_cand  bigint,
    ds_detalhe_situacao_cand  varchar(120),
    -- PK inclui ano_eleicao pelo mesmo motivo de tse_eleicoes (ver acima).
    PRIMARY KEY (uf, ano_eleicao, id)
) PARTITION BY LIST (uf);
CREATE TABLE IF NOT EXISTS raiox.tse_candidatos_:uf_lower PARTITION OF raiox.tse_candidatos FOR VALUES IN (:'uf') PARTITION BY LIST (ano_eleicao);
CREATE TABLE IF NOT EXISTS raiox.tse_candidatos_default_:uf_lower PARTITION OF raiox.tse_candidatos_:uf_lower DEFAULT;

-- A tabela mais pesada: voto por seção/candidato. Consolida os 7 anos
-- (2012..2024) que existiam como tabelas separadas no MySQL do AC.
CREATE TABLE IF NOT EXISTS raiox.tse_votacaosecao (
    uf                          varchar(2)   NOT NULL,
    id                          bigint       NOT NULL,
    dt_geracao                  date,
    hh_geracao                  time         NOT NULL,
    ano_eleicao                 bigint       NOT NULL,
    dt_eleicao                  date,
    nr_turno                    bigint       NOT NULL,
    cd_tipo_eleicao             bigint       NOT NULL,
    nm_tipo_eleicao             varchar(60)  NOT NULL,
    cd_eleicao                  bigint       NOT NULL,
    ds_eleicao                  varchar(200) NOT NULL,
    nm_ue                       varchar(120) NOT NULL,
    nm_municipio                varchar(120) NOT NULL,
    nm_votavel                  varchar(200) NOT NULL,
    tp_abrangencia              varchar(30)  NOT NULL,
    sg_uf                       varchar(2),
    sg_ue                       bigint,
    cd_municipio                bigint,
    nr_zona                     bigint,
    nr_secao                    bigint,
    nr_local_votacao            bigint,
    cd_cargo                    bigint,
    ds_cargo                    varchar(100) NOT NULL,
    nr_votavel                  bigint,
    qt_votos                    bigint,
    sq_candidato                varchar(40)  NOT NULL,
    nm_local_votacao            varchar(200) NOT NULL,
    ds_local_votacao_endereco   varchar(300) NOT NULL,
    nm_bairro                   varchar(150),
    status                      smallint
) PARTITION BY LIST (uf);
CREATE TABLE IF NOT EXISTS raiox.tse_votacaosecao_:uf_lower PARTITION OF raiox.tse_votacaosecao FOR VALUES IN (:'uf') PARTITION BY LIST (ano_eleicao);
CREATE TABLE IF NOT EXISTS raiox.tse_votacaosecao_default_:uf_lower PARTITION OF raiox.tse_votacaosecao_:uf_lower DEFAULT;
-- CREATE INDEX IF NOT EXISTS exige nome explícito de índice (ao contrário do
-- CREATE INDEX sem IF NOT EXISTS, que auto-gera um nome) — por isso os dois
-- abaixo têm nome, diferente do padrão auto-gerado usado no resto do arquivo.
-- Nome do índice com a UF no FINAL, não no meio: psql -v faz match guloso de
-- ":var" até o próximo caractere não-identificador, então ":uf_lower_ano..."
-- vira uma variável só (inexistente) e não substitui nada — bug encontrado
-- ao rodar isto pela 1ª vez (a versão original em raiox-migracao-piloto tem
-- o mesmo problema, nunca deve ter sido executada com -v literal).
CREATE INDEX IF NOT EXISTS tse_votacaosecao_ano_sqcand_idx_:uf_lower ON raiox.tse_votacaosecao_:uf_lower (ano_eleicao, sq_candidato);
CREATE INDEX IF NOT EXISTS tse_votacaosecao_ano_municipio_idx_:uf_lower ON raiox.tse_votacaosecao_:uf_lower (ano_eleicao, cd_municipio);
-- Achado investigando lentidão real em produção (SP, 36M linhas): endpoints
-- de getVotosCandidato filtram por turno+cargo+município(+zona+seção) e não
-- tinham nenhum índice cobrindo essa combinação — caíam em Seq Scan
-- (7-8s) ou Bitmap Scan lendo milhões de linhas só pra filtrar depois
-- (4-5s). Este índice único cobre os dois casos (índice composto serve
-- prefixo also): 4,8ms com zona+seção, ~35ms só com cidade. Substitui o de
-- (ano_eleicao, cd_municipio) acima em qualquer query que também filtre
-- turno/cargo — mantido o antigo mesmo assim por retrocompatibilidade com
-- queries que filtram só ano+município.
CREATE INDEX IF NOT EXISTS tse_votacaosecao_ano_turno_cargo_mun_zona_secao_idx_:uf_lower
  ON raiox.tse_votacaosecao_:uf_lower (ano_eleicao, nr_turno, cd_cargo, cd_municipio, nr_zona, nr_secao);
-- Achado em produção (SP/2018, getVotosCandidato tipo 6/9/10 — candidato +
-- cidade específica, sem zona/seção): o índice de (ano,sq_candidato) acima
-- resolve pelo candidato primeiro, varrendo o voto DELE NO ESTADO INTEIRO
-- (candidato a Deputado Estadual concorre em várias cidades) pra só depois
-- filtrar a cidade pedida — 4,9s pra descartar 42 mil linhas de outras
-- cidades e ficar só com as 24 mil de São Paulo. Índice dedicado
-- (ano,turno,sq_candidato,cd_municipio) filtra os dois de uma vez: 250ms
-- (~19x mais rápido), sem tocar nas 42 mil linhas irrelevantes.
CREATE INDEX IF NOT EXISTS tse_votacaosecao_ano_turno_sqcand_mun_idx_:uf_lower
  ON raiox.tse_votacaosecao_:uf_lower (ano_eleicao, nr_turno, sq_candidato, cd_municipio);

-- Agregados (já vêm pré-calculados no MySQL, um valor por candidato/dimensão)
CREATE TABLE IF NOT EXISTS raiox.tse_votos_candidato_cidade (
    uf            varchar(2) NOT NULL,
    id            bigint     NOT NULL,
    ano_eleicao   bigint,
    nr_turno      bigint,
    sq_candidato  varchar(40),
    sg_uf         varchar(2),
    cd_municipio  bigint,
    nm_municipio  varchar(120),
    qt_votos      bigint
) PARTITION BY LIST (uf);
CREATE TABLE IF NOT EXISTS raiox.tse_votos_candidato_cidade_:uf_lower PARTITION OF raiox.tse_votos_candidato_cidade FOR VALUES IN (:'uf') PARTITION BY LIST (ano_eleicao);
CREATE TABLE IF NOT EXISTS raiox.tse_votos_candidato_cidade_default_:uf_lower PARTITION OF raiox.tse_votos_candidato_cidade_:uf_lower DEFAULT;

CREATE TABLE IF NOT EXISTS raiox.tse_votos_candidato_bairro (
    uf            varchar(2) NOT NULL,
    id            bigint     NOT NULL,
    ano_eleicao   bigint,          -- reconstituído a partir do nome da tabela de origem (ver Stage B)
    nr_turno      bigint,
    sq_candidato  varchar(40),
    cd_municipio  bigint,
    nr_zona       bigint,
    nm_bairro     varchar(150),
    qt_votos      bigint
) PARTITION BY LIST (uf);
CREATE TABLE IF NOT EXISTS raiox.tse_votos_candidato_bairro_:uf_lower PARTITION OF raiox.tse_votos_candidato_bairro FOR VALUES IN (:'uf') PARTITION BY LIST (ano_eleicao);
CREATE TABLE IF NOT EXISTS raiox.tse_votos_candidato_bairro_default_:uf_lower PARTITION OF raiox.tse_votos_candidato_bairro_:uf_lower DEFAULT;

CREATE TABLE IF NOT EXISTS raiox.tse_votos_candidato_local (
    uf                 varchar(2) NOT NULL,
    id                 bigint     NOT NULL,
    ano_eleicao        bigint,
    nr_turno           bigint,
    nr_zona            bigint,
    sq_candidato       varchar(40),
    cd_municipio       bigint,
    nm_bairro          varchar(150),
    nm_local_votacao   varchar(200),
    nr_local_votacao   bigint,
    qt_votos           bigint
) PARTITION BY LIST (uf);
CREATE TABLE IF NOT EXISTS raiox.tse_votos_candidato_local_:uf_lower PARTITION OF raiox.tse_votos_candidato_local FOR VALUES IN (:'uf') PARTITION BY LIST (ano_eleicao);
CREATE TABLE IF NOT EXISTS raiox.tse_votos_candidato_local_default_:uf_lower PARTITION OF raiox.tse_votos_candidato_local_:uf_lower DEFAULT;

-- Locais de votação (granularidade de seção — inclui lat/long como TEXTO na
-- origem, TSE mesmo publica assim; considerar CAST para numeric/PostGIS
-- point só depois, se a trilha de IA/mapa precisar)
CREATE TABLE IF NOT EXISTS raiox.tse_locais (
    uf                              varchar(2)    NOT NULL,
    id                              bigint        NOT NULL,
    dt_geracao                      date,
    hh_geracao                      time          NOT NULL,
    ano_eleicao                     bigint        NOT NULL,
    dt_eleicao                      date,
    cd_eleicao                      bigint,
    ds_eleicao                      varchar(200)  NOT NULL,
    nr_turno                        bigint        NOT NULL,
    sg_uf                           varchar(2)    NOT NULL,
    cd_municipio                    bigint,
    nm_municipio                    varchar(120)  NOT NULL,
    nr_zona                         bigint,
    nr_secao                        bigint,
    cd_tipo_secao_agregada          integer,
    ds_tipo_secao_agregada          varchar(60)   NOT NULL,
    nr_secao_principal              bigint,
    nr_local_votacao                bigint,
    nm_local_votacao                varchar(200)  NOT NULL,
    cd_tipo_local                   integer,
    ds_tipo_local                   varchar(60)   NOT NULL,
    ds_endereco                     varchar(300)  NOT NULL,
    nm_bairro                       varchar(150)  NOT NULL,
    nr_cep                          varchar(15)   NOT NULL,
    nr_telefone_local                varchar(30)  NOT NULL,
    nr_latitude                     varchar(30)   NOT NULL,
    nr_longitude                    varchar(30)   NOT NULL,
    cd_situ_local_votacao           integer,
    ds_situ_local_votacao           varchar(60)   NOT NULL,
    cd_situ_zona                    integer,
    ds_situ_zona                    varchar(60)   NOT NULL,
    cd_situ_secao                   integer,
    ds_situ_secao                   varchar(60)   NOT NULL,
    cd_situ_localidade              integer,
    ds_situ_localidade              varchar(60)   NOT NULL,
    cd_situ_secao_acessibilidade    integer,
    ds_situ_secao_acessibilidade    varchar(60)   NOT NULL,
    qt_eleitor_secao                bigint,
    qt_eleitor_eleicao_federal      bigint,
    qt_eleitor_eleicao_estadual     bigint,
    qt_eleitor_eleicao_municipal    bigint,
    nr_local_votacao_original       varchar(30)   NOT NULL,
    nm_local_votacao_original       varchar(200)  NOT NULL,
    ds_endereco_locvt_original      varchar(300)  NOT NULL
) PARTITION BY LIST (uf);
CREATE TABLE IF NOT EXISTS raiox.tse_locais_:uf_lower PARTITION OF raiox.tse_locais FOR VALUES IN (:'uf') PARTITION BY LIST (ano_eleicao);
CREATE TABLE IF NOT EXISTS raiox.tse_locais_default_:uf_lower PARTITION OF raiox.tse_locais_:uf_lower DEFAULT;

-- Agregados de válidos/nulos/brancos por granularidade geográfica
CREATE TABLE IF NOT EXISTS raiox.tse_votosvalidos_eleicao (
    uf                          varchar(2) NOT NULL,
    id                          bigint     NOT NULL,
    ano_eleicao                 bigint,
    nr_turno                    bigint,
    cd_cargo                    bigint,
    validos                     bigint,
    nulos                       bigint,
    brancos                     bigint,
    votantes                    bigint,
    total_eleitores_federal     bigint,
    total_eleitores_estadual    bigint,
    total_eleitores_municipal   bigint
) PARTITION BY LIST (uf);
CREATE TABLE IF NOT EXISTS raiox.tse_votosvalidos_eleicao_:uf_lower PARTITION OF raiox.tse_votosvalidos_eleicao FOR VALUES IN (:'uf') PARTITION BY LIST (ano_eleicao);
CREATE TABLE IF NOT EXISTS raiox.tse_votosvalidos_eleicao_default_:uf_lower PARTITION OF raiox.tse_votosvalidos_eleicao_:uf_lower DEFAULT;

CREATE TABLE IF NOT EXISTS raiox.tse_votosvalidos_cidade (
    uf            varchar(2) NOT NULL,
    id            bigint     NOT NULL,
    ano_eleicao   bigint,
    nr_turno      bigint,
    cd_cargo      bigint,
    cd_municipio  bigint,
    validos       bigint,
    nulos         bigint,
    brancos       bigint,
    ausentes      bigint,
    votantes      bigint
) PARTITION BY LIST (uf);
CREATE TABLE IF NOT EXISTS raiox.tse_votosvalidos_cidade_:uf_lower PARTITION OF raiox.tse_votosvalidos_cidade FOR VALUES IN (:'uf') PARTITION BY LIST (ano_eleicao);
CREATE TABLE IF NOT EXISTS raiox.tse_votosvalidos_cidade_default_:uf_lower PARTITION OF raiox.tse_votosvalidos_cidade_:uf_lower DEFAULT;

CREATE TABLE IF NOT EXISTS raiox.tse_votosvalidos_bairro (
    uf            varchar(2) NOT NULL,
    id            bigint     NOT NULL,
    ano_eleicao   bigint,
    nr_turno      bigint,
    cd_cargo      bigint,
    cd_municipio  bigint,
    nm_bairro     varchar(150),
    validos       bigint,
    nulos         bigint,
    brancos       bigint,
    ausentes      bigint,
    votantes      bigint
) PARTITION BY LIST (uf);
CREATE TABLE IF NOT EXISTS raiox.tse_votosvalidos_bairro_:uf_lower PARTITION OF raiox.tse_votosvalidos_bairro FOR VALUES IN (:'uf') PARTITION BY LIST (ano_eleicao);
CREATE TABLE IF NOT EXISTS raiox.tse_votosvalidos_bairro_default_:uf_lower PARTITION OF raiox.tse_votosvalidos_bairro_:uf_lower DEFAULT;

CREATE TABLE IF NOT EXISTS raiox.tse_votosvalidos_local (
    uf                varchar(2) NOT NULL,
    id                bigint     NOT NULL,
    ano_eleicao       bigint,
    nr_turno          bigint,
    cd_cargo          bigint,
    nr_zona           bigint,
    cd_municipio      bigint,
    nm_bairro         varchar(150),
    nm_local_votacao  varchar(200),
    nr_local_votacao  bigint,
    validos           bigint,
    nulos             bigint,
    brancos           bigint,
    ausentes          bigint,
    votantes          bigint
) PARTITION BY LIST (uf);
CREATE TABLE IF NOT EXISTS raiox.tse_votosvalidos_local_:uf_lower PARTITION OF raiox.tse_votosvalidos_local FOR VALUES IN (:'uf') PARTITION BY LIST (ano_eleicao);
CREATE TABLE IF NOT EXISTS raiox.tse_votosvalidos_local_default_:uf_lower PARTITION OF raiox.tse_votosvalidos_local_:uf_lower DEFAULT;

-- votos_partidos: não era ano-sufixada no AC (tabela única) — confirme se
-- isso também vale nos outros estados antes de assumir.
CREATE TABLE IF NOT EXISTS raiox.votos_partidos (
    uf                   varchar(2) NOT NULL,
    id                   bigint     NOT NULL,
    nome_urna_candidato  varchar(200),
    numero_cand          varchar(10),
    sigla_partido        varchar(20),
    total_votos          bigint,
    cd_cargo             bigint,
    sigla_uf             varchar(2),
    cd_municipio         bigint,
    num_turno            varchar(5),
    cd_eleicao           bigint,
    ano_eleicao          bigint
) PARTITION BY LIST (uf);
CREATE TABLE IF NOT EXISTS raiox.votos_partidos_:uf_lower PARTITION OF raiox.votos_partidos FOR VALUES IN (:'uf');

-- "Votos de legenda" por seção — usada por getVotosCandidato tipo 7 e
-- getDtColigacao no backend Node. No MySQL do AC só existia pra 2024.
-- FONTE: ainda não confirmada neste projeto (ver README — dataset
-- votacao_partido_munzona do TSE é só município/zona, não tem granularidade
-- de seção/local/bairro que esta tabela pede). Schema criado aqui pra manter
-- paridade com raiox-migracao-piloto; carga fica pendente até confirmar
-- fonte.
CREATE TABLE IF NOT EXISTS raiox.tse_votacaosecao_partido (
    uf                          varchar(2)   NOT NULL,
    id                          bigint       NOT NULL,
    ano_eleicao                 bigint       NOT NULL,
    nr_turno                    bigint       NOT NULL,
    cd_cargo                    bigint,
    cd_municipio                bigint,
    nr_zona                     bigint,
    nr_secao                    bigint,
    nr_local_votacao            bigint,
    nm_bairro                   varchar(150),
    sigla_partido                varchar(200),
    qt_votos                    bigint,
    sq_candidato                varchar(40)  NOT NULL,
    status                      smallint
) PARTITION BY LIST (uf);
CREATE TABLE IF NOT EXISTS raiox.tse_votacaosecao_partido_:uf_lower
    PARTITION OF raiox.tse_votacaosecao_partido FOR VALUES IN (:'uf') PARTITION BY LIST (ano_eleicao);
CREATE TABLE IF NOT EXISTS raiox.tse_votacaosecao_partido_default_:uf_lower
    PARTITION OF raiox.tse_votacaosecao_partido_:uf_lower DEFAULT;
CREATE INDEX IF NOT EXISTS tse_votacaosecao_partido_ano_turno_cargo_idx_:uf_lower
  ON raiox.tse_votacaosecao_partido_:uf_lower (ano_eleicao, nr_turno, cd_cargo);
