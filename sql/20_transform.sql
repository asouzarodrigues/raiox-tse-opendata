-- Popula raiox.* (schema de PRODUÇÃO) a partir das tabelas RAW de UMA UF e
-- UM ano (:uf/:uf_lower/:ano, via psql -v). Roda depois de 10_target_schema.sql
-- (garante que a partição da UF existe) e antes de 25_aggregate.sql (que
-- depende de tse_votacaosecao/tse_locais já carregados pra esse uf+ano).
--
-- Idempotente por (uf, ano): TRUNCATE na partição-folha do ano
-- (raiox.tabela_:uf_ano, criada por sql/15_target_schema_year.sql — precisa
-- rodar antes deste) + INSERT (exceto tse_cidades, que não tem ano_eleicao
-- — ver nota lá embaixo, continua sendo append-only com dedup).
-- Insere direto nas tabelas-mãe particionadas (raiox.tse_votacaosecao etc.);
-- o Postgres roteia pra partição certa sozinho a partir de uf + ano_eleicao.
-- TRUNCATE em vez de DELETE de propósito: recarregar o mesmo ano é rotina
-- (a cada eleição nova, e sempre que um bug pede reprocessar) — DELETE numa
-- tabela compartilhada entre anos deixa linha morta pra trás; TRUNCATE na
-- partição do ano é instantâneo e não gera bloat nenhum.
--
-- id sintético: ano*1000000 + row_number() garante que anos diferentes nunca
-- colidem de id DENTRO da mesma uf. Não há risco de colisão ENTRE UFs porque
-- a PK (quando existe) é (uf, id) — ids repetidos em UFs diferentes são
-- esperados e corretos.

-- ===================== tse_eleicoes / tse_cargos (dimensão, por ano) =====
-- cd_tipo_eleicao='2' (ELEIÇÃO ORDINÁRIA) em tudo abaixo — '1' é ELEIÇÃO
-- EXTRAORDINÁRIA (suplementar: 1 cd_eleicao por município que teve
-- prefeito cassado/etc, cada uma com seu próprio ds_eleicao). Sem esse
-- filtro, tse_eleicoes trazia uma linha PRA CADA suplementar (achado em
-- PR/2016: 13 extraordinárias vs 1 ordinária) — poluía o seletor do app com
-- eleição de município específico. Filtrado aqui na origem, não só
-- escondido do seletor: extraordinária nunca fica acessível por nenhum
-- id_eleicao, então nem faz sentido importar o voto dela (ver tse_votacaosecao
-- abaixo, mesmo filtro).
--
-- votacao_secao_federal_:ano = Presidente/Vice (UNION ALL abaixo) — TSE
-- publica a votação federal num arquivo NACIONAL separado do estadual (ver
-- 01_download.sh/02_load_raw.sh); em ano municipal essa tabela existe mas
-- vazia (nenhuma linha, UNION ALL não muda nada). ds_eleicao do TSE não
-- varia por turno (mesmo texto pros dois, ex.: "ELEIÇÕES GERAIS ESTADUAIS
-- 2018") — sem o turno concatenado, o app não consegue distinguir as duas
-- linhas no campo de seleção (usa ds_eleicao como rótulo). DISTINCT ON
-- prioriza o texto NÃO-federal (estadual/municipal) quando os dois
-- coexistem no mesmo turno (ex.: 2022 turno 1 tem "Eleições Gerais
-- Estaduais 2022" E "Eleição Geral Federal 2022" pro mesmo turno — fica só
-- o primeiro, Presidente entra junto via tse_cargos). Concatenado " | Nº
-- turno" no mesmo padrão que o AC já usa (herdado do pipeline antigo) —
-- nome original preservado, só com o turno na frente. Fonte é sempre o
-- texto cru do TSE (raiox_tse_raw), então reprocessar o mesmo ano não
-- concatena de novo por cima.
-- Normalização de caixa: o CSV nacional de Presidente/Vice
-- (votacao_secao_*_BR.csv) vem com ds_cargo/ds_eleicao TODO EM MAIÚSCULAS
-- ("PRESIDENTE", "ELEIÇÃO GERAL FEDERAL 2022"), enquanto o CSV estadual usa
-- Title Case ("Governador", "Eleições Gerais Estaduais 2022") — achado em
-- produção (PR/2022: "PRESIDENTE" destoando de "Governador"/"Senador" no
-- mesmo seletor). INITCAP() sem condição quebraria os nomes de eleição
-- suplementar que já existem em produção de outras UFs (ex.: "Eleição
-- Suplementar São Tomé/PR" -> "Eleição Suplementar São Tomé/Pr": destrói a
-- sigla da UF depois da barra, e em "Suplementar de Cruzeiro do Iguaçu/PR"
-- capitalizaria as preposições "de"/"do" também). Por isso só normaliza
-- quando a string de origem está
-- INTEIRAMENTE em maiúsculas (texto = upper(texto)) — pega exatamente o
-- caso do arquivo federal (e cargos antigos de outras UF/anos que também
-- vieram em CAPS), sem tocar em texto que já está correto ou tem formato
-- irregular (siglas, abreviações, nomes próprios compostos).
TRUNCATE raiox.tse_eleicoes_:uf_ano;
INSERT INTO raiox.tse_eleicoes (uf, id, ano_eleicao, nr_turno, ds_eleicao)
SELECT :'uf', :ano::bigint * 1000000 + row_number() OVER (), d.ano_eleicao::bigint, d.nr_turno::int,
       CASE WHEN d.ds_eleicao = upper(d.ds_eleicao) THEN initcap(d.ds_eleicao) ELSE d.ds_eleicao END
       || ' | ' || d.nr_turno || '° turno'
FROM (
    SELECT DISTINCT ON (x.ano_eleicao, x.nr_turno) x.ano_eleicao, x.nr_turno, x.ds_eleicao
    FROM (
        SELECT ano_eleicao, nr_turno, ds_eleicao, tp_abrangencia
          FROM raiox_tse_raw.votacao_secao_:ano
         WHERE cd_tipo_eleicao = '2'
        UNION ALL
        SELECT ano_eleicao, nr_turno, ds_eleicao, tp_abrangencia
          FROM raiox_tse_raw.votacao_secao_federal_:ano
         WHERE cd_tipo_eleicao = '2'
    ) x
    ORDER BY x.ano_eleicao, x.nr_turno, (x.tp_abrangencia = 'F') -- false (0) antes de true (1)
) d;

TRUNCATE raiox.tse_cargos_:uf_ano;
INSERT INTO raiox.tse_cargos (uf, id, ano_eleicao, nr_turno, cd_cargo, ds_cargo)
SELECT :'uf', :ano::bigint * 1000000 + row_number() OVER (), d.ano_eleicao::bigint, d.nr_turno::int, d.cd_cargo::bigint,
       CASE WHEN d.ds_cargo = upper(d.ds_cargo) THEN initcap(d.ds_cargo) ELSE d.ds_cargo END
FROM (
    SELECT DISTINCT ano_eleicao, nr_turno, cd_cargo, ds_cargo
    FROM (
        SELECT ano_eleicao, nr_turno, cd_cargo, ds_cargo FROM raiox_tse_raw.votacao_secao_:ano WHERE cd_tipo_eleicao = '2'
        UNION ALL
        SELECT ano_eleicao, nr_turno, cd_cargo, ds_cargo FROM raiox_tse_raw.votacao_secao_federal_:ano WHERE cd_tipo_eleicao = '2'
    ) x
) d;

-- tse_cidades NÃO tem ano_eleicao (município é estável entre eleições) —
-- por isso não é DELETE+INSERT por ano, é append-only com dedup: só insere
-- município que ainda não existe pra essa uf. Id parte do maior id já usado
-- pela uf, pra não colidir com o que já foi inserido em rodadas anteriores.
INSERT INTO raiox.tse_cidades (uf, id, sg_uf, cd_municipio, nm_municipio)
SELECT :'uf', (SELECT COALESCE(MAX(id), 0) FROM raiox.tse_cidades WHERE uf = :'uf') + row_number() OVER (),
       sg_uf, cd_municipio::bigint, nm_municipio
FROM (SELECT DISTINCT sg_uf, cd_municipio, nm_municipio FROM raiox_tse_raw.votacao_secao_:ano) d
WHERE NOT EXISTS (
    SELECT 1 FROM raiox.tse_cidades t
    WHERE t.uf = :'uf' AND t.cd_municipio = d.cd_municipio::bigint
);

-- ===================== tse_votacaosecao =====================
-- status: sempre 1 na produção migrada (conferido — não existe status != 1
-- em nenhuma UF/ano já migrado). O dataset público de votação por seção do
-- TSE só publica seções já apuradas, então 1 é o valor correto aqui, não um
-- palpite.
--
-- DRIFT REAL DE FORMATO (achado processando SP/2018): antes de um certo ano
-- (2018 confirmado, anos entre 2018-2024 não testados ainda) o dataset
-- votacao_secao NÃO tem as colunas sq_candidato/nr_local_votacao/
-- nm_local_votacao/ds_local_votacao_endereco — só nr_votavel (número) e
-- nm_votavel (nome). Em vez de um script por formato de ano, o SELECT usa
-- to_jsonb(v)->>'coluna' pra ler essas colunas SÓ SE existirem (retorna NULL
-- se não existir, sem quebrar o parse) — e cai pro fallback quando faltam:
--   - nr_local_votacao/nm_local_votacao/ds_local_votacao_endereco: vêm de
--     eleitorado_locais_votacao (l), já joinado pro nm_bairro mesmo.
--   - sq_candidato: derivado casando nr_votavel com consulta_cand por
--     (nr_candidato, cd_cargo, sg_uf) — cobre eleição geral (SP/2018: sem
--     corrida municipal, número de candidato já é único por cargo+UF; se
--     algum ano tiver corrida municipal sem sq_candidato nativo, reconfira
--     se precisa também de cd_municipio no join). 95/96 (branco/nulo) viram
--     '-1', voto de legenda (nr_votavel bate com nr_partido mas não com
--     nenhum nr_candidato) vira '-3' — mesmo sentinela usado nos anos que já
--     têm sq_candidato nativo (ver 25_aggregate.sql).
TRUNCATE raiox.tse_votacaosecao_:uf_ano;
-- v_json calculado 1x por linha (CTE) em vez de 4x no SELECT abaixo —
-- to_jsonb() numa linha com dezenas de colunas não é grátis, e cada
-- chamada solta no SELECT list é recomputada do zero (Postgres não faz
-- eliminação de subexpressão comum aqui). Achado processando PR/2024
-- (2,2M linhas, ~100% CPU sem espera de I/O/lock — não era o SSD nem
-- plano de query ruim, estatística do planner já estava correta).
--
-- src UNE estadual + federal (Presidente/Vice — ver nota em tse_eleicoes
-- acima) e já filtra cd_tipo_eleicao='2' (só ordinária, sem suplementar).
-- v.* NÃO dá pra usar direto num UNION ALL entre as duas tabelas — anos
-- diferentes têm colunas diferentes (ver DRIFT REAL DE FORMATO abaixo), e
-- nada garante que o arquivo estadual e o federal do MESMO ano tenham
-- exatamente o mesmo formato. Por isso a lista explícita só com as colunas
-- que SEMPRE existem nos dois; as que variam (sq_candidato/nr_local_votacao/
-- nm_local_votacao/ds_local_votacao_endereco) continuam lidas via
-- v_json->>'col' mais abaixo, já era assim antes desta mudança.
WITH src AS (
    SELECT to_jsonb(v) AS v_json, v.dt_geracao, v.hh_geracao, v.ano_eleicao,
           v.dt_eleicao, v.nr_turno, v.cd_tipo_eleicao, v.nm_tipo_eleicao,
           v.cd_eleicao, v.ds_eleicao, v.nm_ue, v.nm_municipio, v.nm_votavel,
           v.tp_abrangencia, v.sg_uf, v.sg_ue, v.cd_municipio, v.nr_zona,
           v.nr_secao, v.cd_cargo, v.ds_cargo, v.nr_votavel, v.qt_votos
      FROM raiox_tse_raw.votacao_secao_:ano v
     WHERE v.cd_tipo_eleicao = '2'
    UNION ALL
    SELECT to_jsonb(v) AS v_json, v.dt_geracao, v.hh_geracao, v.ano_eleicao,
           v.dt_eleicao, v.nr_turno, v.cd_tipo_eleicao, v.nm_tipo_eleicao,
           v.cd_eleicao, v.ds_eleicao, v.nm_ue, v.nm_municipio, v.nm_votavel,
           v.tp_abrangencia, v.sg_uf, v.sg_ue, v.cd_municipio, v.nr_zona,
           v.nr_secao, v.cd_cargo, v.ds_cargo, v.nr_votavel, v.qt_votos
      FROM raiox_tse_raw.votacao_secao_federal_:ano v
     WHERE v.cd_tipo_eleicao = '2'
), cand_all AS (
    -- Presidente/Vice tem candidatura registrada com sg_uf='BR' (não a UF de
    -- quem votou) — ver join abaixo. Mesmo motivo pro drift de formato:
    -- coluna explícita em vez de c.*.
    SELECT sq_candidato, nm_candidato, nm_urna_candidato, nr_candidato, sg_partido,
           cd_sit_tot_turno, ds_sit_tot_turno, cd_cargo, ds_cargo, sg_uf, sg_ue,
           nr_turno, cd_eleicao, ano_eleicao, sq_coligacao, nm_coligacao,
           ds_composicao_coligacao, cd_situacao_candidatura, ds_situacao_candidatura
      FROM raiox_tse_raw.consulta_cand_:ano
     WHERE cd_tipo_eleicao = '2'
    UNION ALL
    SELECT sq_candidato, nm_candidato, nm_urna_candidato, nr_candidato, sg_partido,
           cd_sit_tot_turno, ds_sit_tot_turno, cd_cargo, ds_cargo, sg_uf, sg_ue,
           nr_turno, cd_eleicao, ano_eleicao, sq_coligacao, nm_coligacao,
           ds_composicao_coligacao, cd_situacao_candidatura, ds_situacao_candidatura
      FROM raiox_tse_raw.consulta_cand_federal_:ano
     WHERE cd_tipo_eleicao = '2'
)
INSERT INTO raiox.tse_votacaosecao (
    uf, id, dt_geracao, hh_geracao, ano_eleicao, dt_eleicao, nr_turno,
    cd_tipo_eleicao, nm_tipo_eleicao, cd_eleicao, ds_eleicao, nm_ue,
    nm_municipio, nm_votavel, tp_abrangencia, sg_uf, sg_ue, cd_municipio,
    nr_zona, nr_secao, nr_local_votacao, cd_cargo, ds_cargo, nr_votavel,
    qt_votos, sq_candidato, nm_local_votacao, ds_local_votacao_endereco,
    nm_bairro, status
)
SELECT
    :'uf', :ano::bigint * 1000000 + row_number() OVER (),
    to_date(v.dt_geracao, 'DD/MM/YYYY')            AS dt_geracao,
    v.hh_geracao::time                             AS hh_geracao,
    v.ano_eleicao::bigint                          AS ano_eleicao,
    to_date(v.dt_eleicao, 'DD/MM/YYYY')            AS dt_eleicao,
    v.nr_turno::bigint                             AS nr_turno,
    v.cd_tipo_eleicao::bigint                      AS cd_tipo_eleicao,
    v.nm_tipo_eleicao                              AS nm_tipo_eleicao,
    v.cd_eleicao::bigint                           AS cd_eleicao,
    v.ds_eleicao                                   AS ds_eleicao,
    v.nm_ue                                        AS nm_ue,
    v.nm_municipio                                 AS nm_municipio,
    v.nm_votavel                                   AS nm_votavel,
    v.tp_abrangencia                               AS tp_abrangencia,
    v.sg_uf                                        AS sg_uf,
    CASE WHEN v.sg_ue ~ '^[0-9]+$' THEN v.sg_ue::bigint ELSE NULL END AS sg_ue, -- em eleição geral (governador/senador/deputado) sg_ue vem com a sigla da UF ("SP"), não um código numérico de município; NULL nesse caso em vez de quebrar o cast
    v.cd_municipio::bigint                         AS cd_municipio,
    v.nr_zona::bigint                              AS nr_zona,
    v.nr_secao::bigint                             AS nr_secao,
    COALESCE(NULLIF(v.v_json->>'nr_local_votacao', '')::bigint, l.nr_local_votacao::bigint) AS nr_local_votacao,
    v.cd_cargo::bigint                             AS cd_cargo,
    v.ds_cargo                                     AS ds_cargo,
    v.nr_votavel::bigint                           AS nr_votavel,
    v.qt_votos::bigint                             AS qt_votos,
    COALESCE(
        v.v_json->>'sq_candidato',
        CASE
            WHEN v.nr_votavel IN ('95', '96') THEN '-1'
            WHEN cand.sq_candidato IS NOT NULL THEN cand.sq_candidato
            WHEN party.nr_partido IS NOT NULL THEN '-3'
            -- '-2': achado em PR/2014 (8.366 linhas, todas Deputado
            -- Estadual) — número votável de 5 dígitos (formato de
            -- candidato, não os 2 dígitos de um voto de legenda comum)
            -- que não bate com NENHUM candidato nem partido em
            -- consulta_cand. Não é branco/nulo (não é 95/96) nem legenda
            -- (não é um nr_partido válido) — é inconsistência real do
            -- dado do TSE entre os dois arquivos (candidatura removida da
            -- lista de candidatos, voto ficou registrado). Sentinela
            -- própria pra não confundir com os outros dois casos nem
            -- travar a carga inteira por causa de uma fração pequena de
            -- linhas.
            ELSE '-2'
        END
    )                                               AS sq_candidato,
    COALESCE(v.v_json->>'nm_local_votacao', l.nm_local_votacao) AS nm_local_votacao,
    COALESCE(v.v_json->>'ds_local_votacao_endereco', l.ds_endereco) AS ds_local_votacao_endereco,
    l.nm_bairro                                    AS nm_bairro,
    1::smallint                                    AS status
FROM src v
LEFT JOIN raiox_tse_raw.eleitorado_locais_votacao_:ano l
       ON l.sg_uf                = v.sg_uf
      AND l.cd_municipio::bigint = v.cd_municipio::bigint  -- cast os dois lados: um dataset traz zero à esquerda em texto, o outro não
      AND l.nr_zona::bigint      = v.nr_zona::bigint
      AND l.nr_secao::bigint     = v.nr_secao::bigint
      -- CRÍTICO: eleitorado_locais_votacao tem 1 linha por seção POR TURNO
      -- (achado em SP/2018, que teve 2º turno de governador — cada seção
      -- aparecia 2x, uma por turno). Sem esse filtro, toda linha de
      -- votacao_secao casava com as 2 linhas de turno e DUPLICAVA a tabela
      -- inteira (36,4M em vez de 19,3M reais — comparado contra o MySQL de
      -- produção). AC/2024 (só 1 turno, eleição municipal) nunca expôs
      -- esse bug porque só existia 1 linha por seção lá.
      AND l.nr_turno::bigint     = v.nr_turno::bigint
LEFT JOIN cand_all cand
       ON cand.nr_candidato = v.nr_votavel
      AND cand.cd_cargo     = v.cd_cargo
      -- Presidente/Vice (cd_cargo 1/2): candidatura é registrada com
      -- sg_uf='BR' em consulta_cand (candidato não é "do estado", é
      -- nacional), mas v.sg_uf aqui é sempre a UF de quem votou (a seção
      -- fica num estado, sempre) — as strings nunca bateriam ("PR" vs
      -- "BR"). cd_cargo já restringe pro cargo certo, então aceitar 'BR'
      -- como alternativa é seguro (não existe candidato estadual com
      -- sg_uf='BR' cruzando por engano).
      AND cand.sg_uf IN (v.sg_uf, 'BR')
      -- CRÍTICO (achado em PR/2024): em eleição MUNICIPAL (cd_cargo 11
      -- Prefeito / 13 Vereador), nr_candidato só é único dentro da mesma
      -- cidade+cargo — o mesmo número de urna se repete em cidades
      -- diferentes (confirmado: número 55123/vereador batia com 333
      -- candidatos diferentes em PR, um por cidade que usou aquele
      -- número). Sem casar também por sg_ue (unidade eleitoral — código
      -- do município em eleição municipal, mesmo campo que votacao_secao
      -- já usa pra isso), cada voto casava com TODOS os candidatos
      -- daquele número no estado inteiro, um fan-out gigante (tabela
      -- chegou a 29GB pra um resultado que devia ficar ~1GB).
      --
      -- MAS (achado em PR/2014, quebrado pelo fix acima): em eleição
      -- GERAL (Presidente/Governador/Senador/Deputados — cd_cargo fora de
      -- 11/13), sg_ue significa outra coisa em cada tabela — em
      -- votacao_secao é sempre o código do município de onde o voto foi
      -- registrado (a seção fica numa cidade, sempre), mas em
      -- consulta_cand pra esses cargos é a SIGLA DA UF ("PR"), porque o
      -- candidato se registra pro estado inteiro, não por cidade — as
      -- strings nunca batem ("74012" vs "PR"), toda linha desses cargos
      -- ficava sem match. Confirmado: tp_abrangencia inconsistente entre
      -- os dois datasets pra usar como critério ("F" em votacao_secao,
      -- "FEDERAL" em consulta_cand) — cd_cargo é o campo estável do TSE
      -- pra decidir isso, funciona em qualquer ano/formato.
      AND (v.cd_cargo NOT IN ('11', '13') OR cand.sg_ue = v.sg_ue)
      -- MESMO bug do join com eleitorado_locais_votacao acima:
      -- consulta_cand tem 1 linha por candidato POR TURNO quando ele vai
      -- pro 2º turno (status "2º TURNO" na linha do turno 1, status final
      -- tipo "ELEITO" na linha do turno 2 — mesmo sq_candidato, mesmo
      -- número). Sem isso, cada voto casava com as 2 linhas do candidato,
      -- duplicando de novo (achado depois do fix acima: sobrava 399.604
      -- linhas extras em SP/2018 mesmo já filtrando nr_turno em l).
      AND cand.nr_turno     = v.nr_turno
      -- Restava ainda uma sobra menor (14.341 linhas): colisão de número de
      -- urna entre um candidato REAL e uma candidatura invalidada
      -- ('#NULO#' — com # no final, formato visto em SP/2018; em 2024/AC
      -- era '#NULO' sem o # final, ver filtro de tse_candidatos abaixo).
      -- Padrão com % pra cobrir os dois formatos.
      AND cand.ds_sit_tot_turno NOT ILIKE '#NULO%'
LEFT JOIN (SELECT DISTINCT nr_partido FROM raiox_tse_raw.consulta_cand_:ano) party
       ON party.nr_partido = v.nr_votavel;

-- (índices em tse_votacaosecao_:uf_lower já criados por 10_target_schema.sql)

-- ===================== tse_locais =====================
-- 1:1 com o dataset eleitorado_locais_votacao (colunas praticamente idênticas
-- ao schema alvo). cd_eleicao não existe nesse dataset (só aa_eleicao/
-- ano_eleicao) — fica NULL, mesmo padrão de "não force um número" já usado
-- no piloto original pra ausentes.
TRUNCATE raiox.tse_locais_:uf_ano;
INSERT INTO raiox.tse_locais (
    uf, id, dt_geracao, hh_geracao, ano_eleicao, dt_eleicao, cd_eleicao,
    ds_eleicao, nr_turno, sg_uf, cd_municipio, nm_municipio, nr_zona,
    nr_secao, cd_tipo_secao_agregada, ds_tipo_secao_agregada,
    nr_secao_principal, nr_local_votacao, nm_local_votacao, cd_tipo_local,
    ds_tipo_local, ds_endereco, nm_bairro, nr_cep, nr_telefone_local,
    nr_latitude, nr_longitude, cd_situ_local_votacao, ds_situ_local_votacao,
    cd_situ_zona, ds_situ_zona, cd_situ_secao, ds_situ_secao,
    cd_situ_localidade, ds_situ_localidade, cd_situ_secao_acessibilidade,
    ds_situ_secao_acessibilidade, qt_eleitor_secao,
    qt_eleitor_eleicao_federal, qt_eleitor_eleicao_estadual,
    qt_eleitor_eleicao_municipal, nr_local_votacao_original,
    nm_local_votacao_original, ds_endereco_locvt_original
)
SELECT
    :'uf', :ano::bigint * 1000000 + row_number() OVER (),
    to_date(l.dt_geracao, 'DD/MM/YYYY'), l.hh_geracao::time,
    l.aa_eleicao::bigint, to_date(l.dt_eleicao, 'DD/MM/YYYY'), NULL::bigint,
    l.ds_eleicao, l.nr_turno::bigint, l.sg_uf, l.cd_municipio::bigint,
    l.nm_municipio, l.nr_zona::bigint, l.nr_secao::bigint,
    NULLIF(l.cd_tipo_secao_agregada, '')::int, l.ds_tipo_secao_agregada,
    NULLIF(l.nr_secao_principal, '')::bigint, l.nr_local_votacao::bigint,
    l.nm_local_votacao, NULLIF(l.cd_tipo_local, '')::int, l.ds_tipo_local,
    l.ds_endereco, l.nm_bairro, l.nr_cep, l.nr_telefone_local, l.nr_latitude,
    l.nr_longitude, NULLIF(l.cd_situ_local_votacao, '')::int,
    l.ds_situ_local_votacao, NULLIF(l.cd_situ_zona, '')::int, l.ds_situ_zona,
    NULLIF(l.cd_situ_secao, '')::int, l.ds_situ_secao,
    NULLIF(l.cd_situ_localidade, '')::int, l.ds_situ_localidade,
    NULLIF(l.cd_situ_secao_acessibilidade, '')::int,
    l.ds_situ_secao_acessibilidade, NULLIF(l.qt_eleitor_secao, '')::bigint,
    NULLIF(l.qt_eleitor_eleicao_federal, '')::bigint,
    NULLIF(l.qt_eleitor_eleicao_estadual, '')::bigint,
    NULLIF(l.qt_eleitor_eleicao_municipal, '')::bigint,
    l.nr_local_votacao_original, l.nm_local_votacao_original,
    l.ds_endereco_locvt_original
FROM raiox_tse_raw.eleitorado_locais_votacao_:ano l
-- eleitorado_locais_votacao é um dataset NACIONAL (não vem dividido por UF
-- como os outros dois) — se o CSV carregado no raw não tiver sido filtrado
-- antes (ver 02_load_raw.sh: usa o arquivo _UF.csv se existir, senão cai
-- pro nacional inteiro), este WHERE evita gravar as outras 26 UFs com
-- uf=:'uf' por engano.
WHERE l.sg_uf = :'uf';

-- ===================== tse_candidatos =====================
-- total_votos: não vem no consulta_cand cru, mas é 100% derivável somando
-- qt_votos de tse_votacaosecao pro mesmo sq_candidato — fecha um gap que
-- existia na versão anterior deste script (README antigo apontava isso como
-- faltante).
-- cd_municipio: consulta_cand não traz esse campo (só sg_ue, que é o código
-- da UNIDADE ELEITORAL — é o município em eleição municipal, mas é a UF em
-- eleição estadual/federal). Fica NULL de propósito em vez de assumir errado
-- pros cargos estaduais/federais; mesmo gap já documentado antes.
TRUNCATE raiox.tse_candidatos_:uf_ano;
-- cand_all UNE estadual + federal (Presidente/Vice) e filtra
-- cd_tipo_eleicao='2' — mesmo motivo/mesma UNION de tse_votacaosecao acima
-- (candidato de eleição extraordinária/suplementar não entra: não tem voto
-- nenhum associado, já que tse_votacaosecao também filtra isso).
WITH cand_all AS (
    SELECT sq_candidato, nm_candidato, nm_urna_candidato, nr_candidato, sg_partido,
           cd_sit_tot_turno, ds_sit_tot_turno, cd_cargo, ds_cargo, sg_uf, sg_ue,
           nr_turno, cd_eleicao, ano_eleicao, sq_coligacao, nm_coligacao,
           ds_composicao_coligacao, cd_situacao_candidatura, ds_situacao_candidatura
      FROM raiox_tse_raw.consulta_cand_:ano
     WHERE cd_tipo_eleicao = '2'
    UNION ALL
    SELECT sq_candidato, nm_candidato, nm_urna_candidato, nr_candidato, sg_partido,
           cd_sit_tot_turno, ds_sit_tot_turno, cd_cargo, ds_cargo, sg_uf, sg_ue,
           nr_turno, cd_eleicao, ano_eleicao, sq_coligacao, nm_coligacao,
           ds_composicao_coligacao, cd_situacao_candidatura, ds_situacao_candidatura
      FROM raiox_tse_raw.consulta_cand_federal_:ano
     WHERE cd_tipo_eleicao = '2'
)
INSERT INTO raiox.tse_candidatos (
    uf, id, sq_candidato, nome_candidato, nome_urna_candidato, numero_cand,
    sigla_partido, total_votos, cd_sit_tot_turno, desc_sit_cand_tot, cd_cargo,
    descricao_cargo, sigla_uf, cd_municipio, num_turno, cd_eleicao,
    ano_eleicao, nome_foto, sq_coligacao, nm_coligacao, ds_composicao_coligacao,
    cd_sit_candidatura, ds_sit_candidatura, rodou_rot, cd_detalhe_situacao_cand,
    ds_detalhe_situacao_cand
)
SELECT
    :'uf', :ano::bigint * 1000000 + row_number() OVER (),
    c.sq_candidato               AS sq_candidato,
    c.nm_candidato                AS nome_candidato,
    c.nm_urna_candidato           AS nome_urna_candidato,
    c.nr_candidato                AS numero_cand,
    c.sg_partido                  AS sigla_partido,
    COALESCE(vt.total_votos, 0)   AS total_votos,
    c.cd_sit_tot_turno::bigint    AS cd_sit_tot_turno,
    c.ds_sit_tot_turno            AS desc_sit_cand_tot,
    c.cd_cargo::bigint            AS cd_cargo,
    c.ds_cargo                    AS descricao_cargo,
    c.sg_uf                       AS sigla_uf,
    NULL::bigint                  AS cd_municipio,
    c.nr_turno                    AS num_turno,
    c.cd_eleicao::bigint          AS cd_eleicao,
    c.ano_eleicao::bigint         AS ano_eleicao,
    NULL::varchar                 AS nome_foto,
    c.sq_coligacao                AS sq_coligacao,
    c.nm_coligacao                AS nm_coligacao,
    c.ds_composicao_coligacao     AS ds_composicao_coligacao,
    c.cd_situacao_candidatura     AS cd_sit_candidatura,
    c.ds_situacao_candidatura     AS ds_sit_candidatura,
    NULL::boolean                 AS rodou_rot,
    NULL::bigint                  AS cd_detalhe_situacao_cand,
    NULL::varchar                 AS ds_detalhe_situacao_cand
FROM cand_all c
LEFT JOIN (
    -- lê de raiox.tse_votacaosecao (já carregado acima, nesta mesma rodada),
    -- não da tabela raw: a raw pode não ter sq_candidato nativo (anos sem
    -- essa coluna, ver bloco anterior) — o já-carregado sempre tem, porque
    -- foi resolvido no INSERT de tse_votacaosecao.
    -- total_votos = votos do candidato NO TURNO DA LINHA (cada candidato
    -- que foi ao 2º turno tem uma linha por turno). Até 2026-10-08 era
    -- sempre o 1º turno nas duas linhas (convenção herdada do MySQL); isso
    -- fazia o getVotos por UF mostrar o 1º turno no 2º e o crescimento
    -- 1º→2º de ia/facts.ts dar zero. Ver sql/40_fix_total_votos_2turno.sql
    -- e docs/decisions/JOURNAL.md (workspace) do mesmo dia.
    SELECT sq_candidato, nr_turno, SUM(qt_votos) AS total_votos
    FROM raiox.tse_votacaosecao
    WHERE uf = :'uf' AND ano_eleicao = :ano
    GROUP BY sq_candidato, nr_turno
) vt ON vt.sq_candidato = c.sq_candidato AND vt.nr_turno = c.nr_turno::bigint
-- '#NULO'/'#NULO#' = candidatura sem situação de totalização (indeferida/
-- cancelada antes da apuração — nunca entrou na votação). Descoberto
-- comparando contagem contra o schema `raiox` já validado (AC/2024):
-- excluir isso fechou 2311 -> 2195, batendo exato. Formato varia por
-- ano/UF: 2024/AC usa '#NULO' (sem # no final), SP/2018 usa '#NULO#' (com)
-- — confirmado comparando contra o MySQL de produção. Padrão com % cobre
-- os dois.
WHERE c.ds_sit_tot_turno NOT ILIKE '#NULO%';
