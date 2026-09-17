-- Tabelas agregadas: no MySQL de origem (piloto AC) vinham PRÉ-CALCULADAS
-- (ver raiox-migracao-piloto/sql/10_target_schema_draft.sql, comentário "já
-- vêm pré-calculadas no MySQL"). Aqui não existe MySQL — são todas
-- recalculadas a partir de raiox.tse_votacaosecao/tse_locais, que já foram
-- carregados por 20_transform.sql pro mesmo uf+ano.
--
-- Roda depois de 20_transform.sql, mesmos :uf/:uf_lower/:uf_ano/:ano.
-- Idempotente por (uf, ano): TRUNCATE na partição-folha do ano (raiox.
-- tabela_:uf_ano) + INSERT, igual ao resto do pipeline desde a introdução
-- do particionamento em 2 níveis (uf → ano_eleicao, ver sql/10_target_
-- schema.sql e sql/15_target_schema_year.sql) — cuidado ao editar, cada
-- TRUNCATE precisa continuar mirando a partição certa.
--
-- Fórmulas de validos/nulos/brancos/votantes/ausentes são as MESMAS
-- validadas em raiox-migracao-piloto/sql/50_backfill_votosvalidos_local_
-- bairro.sql (100% de acerto contra 2024/AC real), só generalizadas pra
-- rodar por uf+ano em vez de "só nos anos que faltam":
--   validos  = SUM(qt_votos) WHERE nr_votavel NOT IN (95,96,97)
--   nulos    = SUM(qt_votos) WHERE nr_votavel = 96
--   brancos  = SUM(qt_votos) WHERE nr_votavel = 95
--   votantes = SUM(qt_votos)
--   ausentes = eleitores_do_escopo (por tipo de cargo) - votantes
-- Mapeamento cd_cargo -> coluna de eleitores (mesmo de summary.service.ts
-- no raiox-votos-node):
--   1,2        -> qt_eleitor_eleicao_federal
--   3,5,6,7,8  -> qt_eleitor_eleicao_estadual
--   11,12,13   -> qt_eleitor_eleicao_municipal

-- ===================== tse_votos_candidato_cidade =====================
-- Confirmado contra produção (AC/2024, antes deste script existir): é uma
-- soma pura de qt_votos por sq_candidato+cidade, SEM excluir branco/nulo/
-- legenda (soma bate 100% com o total de tse_votacaosecao).
TRUNCATE raiox.tse_votos_candidato_cidade_:uf_ano;
INSERT INTO raiox.tse_votos_candidato_cidade (uf, id, ano_eleicao, nr_turno, sq_candidato, sg_uf, cd_municipio, nm_municipio, qt_votos)
SELECT :'uf', :ano::bigint * 1000000 + row_number() OVER (),
       ano_eleicao, nr_turno, sq_candidato, sg_uf, cd_municipio, nm_municipio, SUM(qt_votos)
FROM raiox.tse_votacaosecao
WHERE uf = :'uf' AND ano_eleicao = :ano
GROUP BY ano_eleicao, nr_turno, sq_candidato, sg_uf, cd_municipio, nm_municipio;

-- ===================== tse_votos_candidato_bairro =====================
-- Mesma soma, por bairro em vez de cidade. Contra produção AC/2024 a soma
-- fica ~0,06% abaixo do total (626 de 968414 votos) — diferença pré-
-- existente na fonte MySQL original, não introduzida aqui; não perseguida
-- byte-a-byte porque a lógica exata do MySQL não é conhecida (ver
-- 10_target_schema_draft.sql).
TRUNCATE raiox.tse_votos_candidato_bairro_:uf_ano;
INSERT INTO raiox.tse_votos_candidato_bairro (uf, id, ano_eleicao, nr_turno, sq_candidato, cd_municipio, nr_zona, nm_bairro, qt_votos)
SELECT :'uf', :ano::bigint * 1000000 + row_number() OVER (),
       ano_eleicao, nr_turno, sq_candidato, cd_municipio, nr_zona, nm_bairro, SUM(qt_votos)
FROM raiox.tse_votacaosecao
WHERE uf = :'uf' AND ano_eleicao = :ano
GROUP BY ano_eleicao, nr_turno, sq_candidato, cd_municipio, nr_zona, nm_bairro;

-- ===================== tse_votos_candidato_local =====================
TRUNCATE raiox.tse_votos_candidato_local_:uf_ano;
INSERT INTO raiox.tse_votos_candidato_local (uf, id, ano_eleicao, nr_turno, nr_zona, sq_candidato, cd_municipio, nm_bairro, nm_local_votacao, nr_local_votacao, qt_votos)
SELECT :'uf', :ano::bigint * 1000000 + row_number() OVER (),
       ano_eleicao, nr_turno, nr_zona, sq_candidato, cd_municipio, nm_bairro, nm_local_votacao, nr_local_votacao, SUM(qt_votos)
FROM raiox.tse_votacaosecao
WHERE uf = :'uf' AND ano_eleicao = :ano
GROUP BY ano_eleicao, nr_turno, nr_zona, sq_candidato, cd_municipio, nm_bairro, nm_local_votacao, nr_local_votacao;

-- ===================== tse_votosvalidos_eleicao (nível UF inteira) =====
TRUNCATE raiox.tse_votosvalidos_eleicao_:uf_ano;
INSERT INTO raiox.tse_votosvalidos_eleicao (
    uf, id, ano_eleicao, nr_turno, cd_cargo, validos, nulos, brancos, votantes,
    total_eleitores_federal, total_eleitores_estadual, total_eleitores_municipal
)
WITH votos AS (
    SELECT ano_eleicao, nr_turno, cd_cargo,
           SUM(CASE WHEN nr_votavel NOT IN (95, 96, 97) THEN qt_votos ELSE 0 END) AS validos,
           SUM(CASE WHEN nr_votavel = 96 THEN qt_votos ELSE 0 END)               AS nulos,
           SUM(CASE WHEN nr_votavel = 95 THEN qt_votos ELSE 0 END)               AS brancos,
           SUM(qt_votos)                                                        AS votantes
    FROM raiox.tse_votacaosecao
    WHERE uf = :'uf' AND ano_eleicao = :ano AND status = 1
    GROUP BY ano_eleicao, nr_turno, cd_cargo
),
eleitores AS (
    SELECT ano_eleicao,
           SUM(qt_eleitor_eleicao_federal)   AS federal,
           SUM(qt_eleitor_eleicao_estadual)  AS estadual,
           SUM(qt_eleitor_eleicao_municipal) AS municipal
    FROM (
        SELECT DISTINCT ano_eleicao, cd_municipio, nr_zona, nr_secao,
               qt_eleitor_eleicao_federal, qt_eleitor_eleicao_estadual, qt_eleitor_eleicao_municipal
        FROM raiox.tse_locais
        WHERE uf = :'uf' AND ano_eleicao = :ano
    ) t
    GROUP BY ano_eleicao
)
SELECT
    :'uf', :ano::bigint * 1000000 + row_number() OVER (ORDER BY v.nr_turno, v.cd_cargo),
    v.ano_eleicao, v.nr_turno, v.cd_cargo, v.validos, v.nulos, v.brancos, v.votantes,
    e.federal, e.estadual, e.municipal
FROM votos v
LEFT JOIN eleitores e ON e.ano_eleicao = v.ano_eleicao;

-- ===================== tse_votosvalidos_cidade =====================
TRUNCATE raiox.tse_votosvalidos_cidade_:uf_ano;
INSERT INTO raiox.tse_votosvalidos_cidade (
    uf, id, ano_eleicao, nr_turno, cd_cargo, cd_municipio, validos, nulos, brancos, ausentes, votantes
)
WITH votos AS (
    SELECT ano_eleicao, nr_turno, cd_cargo, cd_municipio,
           SUM(CASE WHEN nr_votavel NOT IN (95, 96, 97) THEN qt_votos ELSE 0 END) AS validos,
           SUM(CASE WHEN nr_votavel = 96 THEN qt_votos ELSE 0 END)               AS nulos,
           SUM(CASE WHEN nr_votavel = 95 THEN qt_votos ELSE 0 END)               AS brancos,
           SUM(qt_votos)                                                        AS votantes
    FROM raiox.tse_votacaosecao
    WHERE uf = :'uf' AND ano_eleicao = :ano AND status = 1
    GROUP BY ano_eleicao, nr_turno, cd_cargo, cd_municipio
),
eleitores AS (
    SELECT ano_eleicao, cd_municipio,
           SUM(qt_eleitor_eleicao_federal)   AS federal,
           SUM(qt_eleitor_eleicao_estadual)  AS estadual,
           SUM(qt_eleitor_eleicao_municipal) AS municipal
    FROM (
        SELECT DISTINCT ano_eleicao, cd_municipio, nr_zona, nr_secao,
               qt_eleitor_eleicao_federal, qt_eleitor_eleicao_estadual, qt_eleitor_eleicao_municipal
        FROM raiox.tse_locais
        WHERE uf = :'uf' AND ano_eleicao = :ano
    ) t
    GROUP BY ano_eleicao, cd_municipio
)
SELECT
    :'uf', :ano::bigint * 1000000 + row_number() OVER (ORDER BY v.nr_turno, v.cd_cargo, v.cd_municipio),
    v.ano_eleicao, v.nr_turno, v.cd_cargo, v.cd_municipio, v.validos, v.nulos, v.brancos,
    (CASE
        WHEN v.cd_cargo IN (1, 2) THEN e.federal
        WHEN v.cd_cargo IN (3, 5, 6, 7, 8) THEN e.estadual
        WHEN v.cd_cargo IN (11, 12, 13) THEN e.municipal
    END - v.votantes) AS ausentes,
    v.votantes
FROM votos v
LEFT JOIN eleitores e ON e.ano_eleicao = v.ano_eleicao AND e.cd_municipio = v.cd_municipio;

-- ===================== tse_votosvalidos_bairro =====================
-- Fórmula idêntica a raiox-migracao-piloto/sql/50_backfill_votosvalidos_
-- local_bairro.sql (validada 100% contra 2024/AC real), só trocando o
-- filtro "anos que faltam" por uf+ano fixo.
TRUNCATE raiox.tse_votosvalidos_bairro_:uf_ano;
INSERT INTO raiox.tse_votosvalidos_bairro (
    uf, id, ano_eleicao, nr_turno, cd_cargo, cd_municipio, nm_bairro, validos, nulos, brancos, ausentes, votantes
)
WITH votos AS (
    SELECT ano_eleicao, nr_turno, cd_cargo, cd_municipio, nm_bairro,
           SUM(CASE WHEN nr_votavel NOT IN (95, 96, 97) THEN qt_votos ELSE 0 END) AS validos,
           SUM(CASE WHEN nr_votavel = 96 THEN qt_votos ELSE 0 END)               AS nulos,
           SUM(CASE WHEN nr_votavel = 95 THEN qt_votos ELSE 0 END)               AS brancos,
           SUM(qt_votos)                                                        AS votantes
    FROM raiox.tse_votacaosecao
    WHERE uf = :'uf' AND ano_eleicao = :ano AND status = 1
    GROUP BY ano_eleicao, nr_turno, cd_cargo, cd_municipio, nm_bairro
),
eleitores AS (
    SELECT ano_eleicao, cd_municipio, nm_bairro,
           SUM(qt_eleitor_eleicao_federal)   AS federal,
           SUM(qt_eleitor_eleicao_estadual)  AS estadual,
           SUM(qt_eleitor_eleicao_municipal) AS municipal
    FROM (
        SELECT DISTINCT ano_eleicao, cd_municipio, nm_bairro, nr_zona, nr_secao,
               qt_eleitor_eleicao_federal, qt_eleitor_eleicao_estadual, qt_eleitor_eleicao_municipal
        FROM raiox.tse_locais
        WHERE uf = :'uf' AND ano_eleicao = :ano
    ) t
    GROUP BY ano_eleicao, cd_municipio, nm_bairro
)
SELECT
    :'uf', :ano::bigint * 1000000 + row_number() OVER (ORDER BY v.nr_turno, v.cd_cargo, v.cd_municipio, v.nm_bairro),
    v.ano_eleicao, v.nr_turno, v.cd_cargo, v.cd_municipio, v.nm_bairro, v.validos, v.nulos, v.brancos,
    (CASE
        WHEN v.cd_cargo IN (1, 2) THEN e.federal
        WHEN v.cd_cargo IN (3, 5, 6, 7, 8) THEN e.estadual
        WHEN v.cd_cargo IN (11, 12, 13) THEN e.municipal
    END - v.votantes) AS ausentes,
    v.votantes
FROM votos v
LEFT JOIN eleitores e ON e.ano_eleicao = v.ano_eleicao AND e.cd_municipio = v.cd_municipio AND e.nm_bairro IS NOT DISTINCT FROM v.nm_bairro;

-- ===================== tse_votosvalidos_local =====================
TRUNCATE raiox.tse_votosvalidos_local_:uf_ano;
INSERT INTO raiox.tse_votosvalidos_local (
    uf, id, ano_eleicao, nr_turno, cd_cargo, nr_zona, cd_municipio, nm_bairro, nm_local_votacao, nr_local_votacao,
    validos, nulos, brancos, ausentes, votantes
)
WITH votos AS (
    SELECT ano_eleicao, nr_turno, cd_cargo, cd_municipio, nr_zona, nr_local_votacao,
           (array_agg(nm_bairro))[1]        AS nm_bairro,
           nm_local_votacao,
           SUM(CASE WHEN nr_votavel NOT IN (95, 96, 97) THEN qt_votos ELSE 0 END) AS validos,
           SUM(CASE WHEN nr_votavel = 96 THEN qt_votos ELSE 0 END)               AS nulos,
           SUM(CASE WHEN nr_votavel = 95 THEN qt_votos ELSE 0 END)               AS brancos,
           SUM(qt_votos)                                                        AS votantes
    FROM raiox.tse_votacaosecao
    WHERE uf = :'uf' AND ano_eleicao = :ano AND status = 1
    GROUP BY ano_eleicao, nr_turno, cd_cargo, cd_municipio, nr_zona, nr_local_votacao, nm_local_votacao
),
eleitores AS (
    SELECT ano_eleicao, cd_municipio, nr_zona, nr_local_votacao, nm_local_votacao,
           SUM(qt_eleitor_eleicao_federal)   AS federal,
           SUM(qt_eleitor_eleicao_estadual)  AS estadual,
           SUM(qt_eleitor_eleicao_municipal) AS municipal
    FROM (
        SELECT DISTINCT ano_eleicao, cd_municipio, nr_zona, nr_local_votacao, nm_local_votacao,
               nr_secao, qt_eleitor_eleicao_federal, qt_eleitor_eleicao_estadual, qt_eleitor_eleicao_municipal
        FROM raiox.tse_locais
        WHERE uf = :'uf' AND ano_eleicao = :ano
    ) t
    GROUP BY ano_eleicao, cd_municipio, nr_zona, nr_local_votacao, nm_local_votacao
)
SELECT
    :'uf', :ano::bigint * 1000000 + row_number() OVER (ORDER BY v.nr_turno, v.cd_cargo, v.cd_municipio, v.nr_zona, v.nr_local_votacao, v.nm_local_votacao),
    v.ano_eleicao, v.nr_turno, v.cd_cargo, v.nr_zona, v.cd_municipio, v.nm_bairro, v.nm_local_votacao, v.nr_local_votacao,
    v.validos, v.nulos, v.brancos,
    (CASE
        WHEN v.cd_cargo IN (1, 2) THEN e.federal
        WHEN v.cd_cargo IN (3, 5, 6, 7, 8) THEN e.estadual
        WHEN v.cd_cargo IN (11, 12, 13) THEN e.municipal
    END - v.votantes) AS ausentes,
    v.votantes
FROM votos v
LEFT JOIN eleitores e
       ON e.ano_eleicao = v.ano_eleicao AND e.cd_municipio = v.cd_municipio
      AND e.nr_zona = v.nr_zona AND e.nr_local_votacao = v.nr_local_votacao AND e.nm_local_votacao = v.nm_local_votacao;

-- ===================== tse_votacaosecao_partido =====================
-- Descoberta: NÃO precisa de um dataset novo. Voto de legenda já vem dentro
-- de votacao_secao — nas eleições proporcionais (vereador), quando o
-- eleitor digita só o número do partido (2 dígitos), o TSE grava a linha
-- com sq_candidato = '-3' (sentinela — igual a '-1' pra branco/nulo) e
-- nr_votavel = número do partido. Confirmado contra a produção anterior
-- (migrada via MySQL, AC/2024): 7895 linhas, bate exato.
-- sigla_partido não existe em votacao_secao (só nm_votavel, nome completo)
-- — resolvida via join com consulta_cand (que tem nr_partido/sg_partido).
-- Só verificado pra 2024/AC — reconfira o sentinela '-3' ao carregar o
-- 1º ano/UF novo (pode não ser estável entre anos).
TRUNCATE raiox.tse_votacaosecao_partido_:uf_ano;
INSERT INTO raiox.tse_votacaosecao_partido (
    uf, id, ano_eleicao, nr_turno, cd_cargo, cd_municipio, nr_zona, nr_secao,
    nr_local_votacao, nm_bairro, sigla_partido, qt_votos, sq_candidato, status
)
SELECT :'uf', :ano::bigint * 1000000 + row_number() OVER (),
       v.ano_eleicao, v.nr_turno, v.cd_cargo, v.cd_municipio, v.nr_zona, v.nr_secao,
       v.nr_local_votacao, v.nm_bairro, p.sg_partido, v.qt_votos, v.sq_candidato, v.status
FROM raiox.tse_votacaosecao v
LEFT JOIN (
    SELECT DISTINCT nr_partido, sg_partido FROM raiox_tse_raw.consulta_cand_:ano
) p ON p.nr_partido::bigint = v.nr_votavel
WHERE v.uf = :'uf' AND v.ano_eleicao = :ano AND v.sq_candidato = '-3';

-- ===================== votos_partidos =====================
-- Confirmado contra a produção anterior: SEMPRE vazia (0 linhas, mesmo antes
-- desta rodada) — não é regressão, é o estado real de origem. Nada a
-- carregar aqui.
