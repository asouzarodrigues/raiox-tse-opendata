-- Exterior (ZZ) de Presidente 2014 e 2018 — só totais, mesmo formato do
-- 41_exterior_2022_totais.sql (decisão de 2026-10-08, docs/decisions/
-- JOURNAL.md do workspace). Uma linha por candidato e turno em tse_candidatos
-- (uf 'ZZ') e o resumo por turno em tse_votosvalidos_eleicao (uf 'ZZ').
--
-- Fontes (TSE, dadosabertos), arquivo "_BR" (cargos federais) de cada ano,
-- linhas SG_UF = 'ZZ' e CD_CARGO = 1:
--   - votacao_candidato_munzona_<ano>.zip: QT_VOTOS_NOMINAIS por candidato
--     (o votacao_secao de 2014/2018 vem vazio no CDN). O de 2014 tem fim de
--     linha \r\n — tirar o \r antes de ler a última coluna.
--   - detalhe_votacao_munzona_<ano>.zip: QT_APTOS, QT_COMPARECIMENTO,
--     QT_VOTOS_NOMINAIS_VALIDOS, QT_VOTOS_BRANCOS, QT_TOTAL_VOTOS_NULOS.
-- Em cada ano e turno: soma dos candidatos = válidos do detalhe, e
-- válidos + brancos + nulos = comparecimento.
--
-- Conferência contra o oficial (banco com 27 UFs + este ZZ):
--   2014: Dilma 43.243.315 + 24.353 = 43.267.668 (1º) | 54.470.059 + 31.059 = 54.501.118 (2º)
--   2018: Bolsonaro 49.163.320 + 113.690 = 49.277.010 (1º) | 57.666.176 + 131.671 = 57.797.847 (2º)
--
-- Descritivos copiados das linhas de SP do mesmo ano e turno (iguais em todas
-- as UFs para Presidente). total_votos é o do turno da linha.
-- Idempotente: apaga o ZZ dos dois anos antes de inserir.
-- Reverter: os DELETE abaixo, sozinhos.
--
--   psql "$DATABASE_URL" -f sql/42_exterior_2014_2018_totais.sql

BEGIN;

CREATE TABLE IF NOT EXISTS raiox.tse_candidatos_zz_2014
  PARTITION OF raiox.tse_candidatos_zz FOR VALUES IN (2014);
CREATE TABLE IF NOT EXISTS raiox.tse_candidatos_zz_2018
  PARTITION OF raiox.tse_candidatos_zz FOR VALUES IN (2018);
CREATE TABLE IF NOT EXISTS raiox.tse_votosvalidos_eleicao_zz_2014
  PARTITION OF raiox.tse_votosvalidos_eleicao_zz FOR VALUES IN (2014);
CREATE TABLE IF NOT EXISTS raiox.tse_votosvalidos_eleicao_zz_2018
  PARTITION OF raiox.tse_votosvalidos_eleicao_zz FOR VALUES IN (2018);

DELETE FROM raiox.tse_candidatos WHERE uf = 'ZZ' AND ano_eleicao IN (2014, 2018);
DELETE FROM raiox.tse_votosvalidos_eleicao WHERE uf = 'ZZ' AND ano_eleicao IN (2014, 2018);

WITH zz (ano, nr_turno, sq_candidato, votos) AS (VALUES
    (2014, 1, 280000000085, 65713),
    (2014, 1, 280000000121, 34527),
    (2014, 1, 280000000083, 24353),
    (2014, 1, 280000000043, 3474),
    (2014, 1, 280000000061, 2067),
    (2014, 1, 280000000065, 906),
    (2014, 1, 280000000001, 648),
    (2014, 1, 280000000021, 436),
    (2014, 1, 280000000067, 281),
    (2014, 1, 280000000041, 261),
    (2014, 1, 280000000081, 73),
    (2014, 2, 280000000085, 104121),
    (2014, 2, 280000000083, 31059),
    (2018, 1, 280000614517, 113690),
    (2018, 1, 280000605589, 28073),
    (2018, 1, 280000629808, 19540),
    (2018, 1, 280000607640, 13637),
    (2018, 1, 280000602477, 6668),
    (2018, 1, 280000622171, 4961),
    (2018, 1, 280000618462, 2733),
    (2018, 1, 280000601016, 1274),
    (2018, 1, 280000602500, 1172),
    (2018, 1, 280000622281, 952),
    (2018, 1, 280000601173, 349),
    (2018, 1, 280000624085, 179),
    (2018, 1, 280000624082, 153),
    (2018, 2, 280000614517, 131671),
    (2018, 2, 280000629808, 53730)
)
INSERT INTO raiox.tse_candidatos (
    uf, id, sq_candidato, nome_candidato, nome_urna_candidato, numero_cand,
    sigla_partido, total_votos, cd_sit_tot_turno, desc_sit_cand_tot, cd_cargo,
    descricao_cargo, sigla_uf, cd_municipio, num_turno, cd_eleicao,
    ano_eleicao, nome_foto, sq_coligacao, nm_coligacao, ds_composicao_coligacao,
    cd_sit_candidatura, ds_sit_candidatura, rodou_rot, cd_detalhe_situacao_cand,
    ds_detalhe_situacao_cand
)
SELECT 'ZZ', zz.ano * 1000000 + row_number() OVER (PARTITION BY zz.ano ORDER BY zz.nr_turno, zz.votos DESC),
       sp.sq_candidato, sp.nome_candidato, sp.nome_urna_candidato, sp.numero_cand,
       sp.sigla_partido, zz.votos, sp.cd_sit_tot_turno, sp.desc_sit_cand_tot, sp.cd_cargo,
       sp.descricao_cargo, sp.sigla_uf, sp.cd_municipio, sp.num_turno, sp.cd_eleicao,
       sp.ano_eleicao, sp.nome_foto, sp.sq_coligacao, sp.nm_coligacao, sp.ds_composicao_coligacao,
       sp.cd_sit_candidatura, sp.ds_sit_candidatura, sp.rodou_rot, sp.cd_detalhe_situacao_cand,
       sp.ds_detalhe_situacao_cand
  FROM zz
  JOIN raiox.tse_candidatos sp
    ON sp.uf = 'SP' AND sp.ano_eleicao = zz.ano AND sp.cd_cargo = 1
   AND sp.sq_candidato = zz.sq_candidato::text AND sp.num_turno = zz.nr_turno::text;

INSERT INTO raiox.tse_votosvalidos_eleicao (
    uf, id, ano_eleicao, nr_turno, cd_cargo, validos, nulos, brancos, votantes,
    total_eleitores_federal, total_eleitores_estadual, total_eleitores_municipal
) VALUES
    ('ZZ', 2014000001, 2014, 1, 1, 132739, 3929, 4833, 141501, 353504, 0, 0),
    ('ZZ', 2014000002, 2014, 2, 1, 135180, 3534, 3159, 141873, 353536, 0, 0),
    ('ZZ', 2018000001, 2018, 1, 1, 193381, 4339, 5046, 202766, 500340, 0, 0),
    ('ZZ', 2018000002, 2018, 2, 1, 185401, 8524, 7241, 201166, 500347, 0, 0);

-- Trava: nº de linhas e soma dos candidatos = válidos, por ano e turno.
DO $$
DECLARE r record; esperado int;
BEGIN
  FOR r IN
    SELECT v.ano_eleicao, v.nr_turno, v.validos, count(c.*) AS n, coalesce(sum(c.total_votos), 0) AS soma
      FROM raiox.tse_votosvalidos_eleicao v
      LEFT JOIN raiox.tse_candidatos c
        ON c.uf = 'ZZ' AND c.ano_eleicao = v.ano_eleicao AND c.num_turno = v.nr_turno::text
     WHERE v.uf = 'ZZ' AND v.ano_eleicao IN (2014, 2018)
     GROUP BY 1, 2, 3
  LOOP
    esperado := CASE WHEN r.nr_turno = 2 THEN 2 WHEN r.ano_eleicao = 2014 THEN 11 ELSE 13 END;
    IF r.soma <> r.validos OR r.n <> esperado THEN
      RAISE EXCEPTION 'ZZ % turno % inconsistente: % linhas, soma % x válidos %', r.ano_eleicao, r.nr_turno, r.n, r.soma, r.validos;
    END IF;
  END LOOP;
END $$;

COMMIT;
