-- Exterior (ZZ) de Presidente 2022 — só totais, como já existe para 2026
-- (decisão de 2026-10-08, docs/decisions/JOURNAL.md do workspace): uma linha
-- por candidato e turno em tse_candidatos (uf 'ZZ') e o resumo por turno em
-- tse_votosvalidos_eleicao (uf 'ZZ'). Sem tabelas por seção/cidade.
--
-- Fontes (TSE, dadosabertos), conferidas uma contra a outra:
--   - votacao_secao_2022_BR.zip, linhas SG_UF = 'ZZ' (não existe arquivo só
--     do ZZ): votos por candidato, brancos (95) e nulos (96) por turno.
--   - detalhe_votacao_munzona_2022.zip (..._BR.csv), SG_UF = 'ZZ', CD_CARGO 1:
--     QT_APTOS (eleitorado) e os mesmos válidos/brancos/nulos — batem exatos.
-- Fórmulas iguais às do 25_aggregate.sql: validos exclui 95/96/97, votantes
-- = soma de tudo.
--
-- Conferência: banco (27 UFs) + este ZZ = total oficial do TSE.
--   1º turno: 117.935.194 + 294.525 = 118.229.719 válidos
--   2º turno: 118.254.184 + 298.169 = 118.552.353 válidos
--
-- Descritivos dos candidatos (nome, partido, situação, coligação...) copiados
-- das linhas de SP do mesmo turno: para Presidente são iguais em todas as UFs.
-- total_votos é o do turno da linha (ver 40_fix_total_votos_2turno.sql).
--
-- Idempotente: apaga o ZZ/2022 antes de inserir.
-- Reverter: os dois DELETE abaixo, sozinhos.
--
--   psql "$DATABASE_URL" -f sql/41_exterior_2022_totais.sql

BEGIN;

CREATE TABLE IF NOT EXISTS raiox.tse_candidatos_zz_2022
  PARTITION OF raiox.tse_candidatos_zz FOR VALUES IN (2022);
CREATE TABLE IF NOT EXISTS raiox.tse_votosvalidos_eleicao_zz_2022
  PARTITION OF raiox.tse_votosvalidos_eleicao_zz FOR VALUES IN (2022);

DELETE FROM raiox.tse_candidatos WHERE uf = 'ZZ' AND ano_eleicao = 2022;
DELETE FROM raiox.tse_votosvalidos_eleicao WHERE uf = 'ZZ' AND ano_eleicao = 2022;

WITH zz (nr_turno, sq_candidato, votos) AS (VALUES
    (1, 280001607829, 138933),
    (1, 280001618036, 122548),
    (1, 280001612393, 13341),
    (1, 280001607833, 13167),
    (1, 280001603612, 3780),
    (1, 280001644128, 753),
    (1, 280001600167, 618),
    (1, 280001607831, 464),
    (1, 280001734029, 344),
    (1, 280001602702, 319),
    (1, 280001677435, 258),
    (2, 280001607829, 152905),
    (2, 280001618036, 145264)
)
INSERT INTO raiox.tse_candidatos (
    uf, id, sq_candidato, nome_candidato, nome_urna_candidato, numero_cand,
    sigla_partido, total_votos, cd_sit_tot_turno, desc_sit_cand_tot, cd_cargo,
    descricao_cargo, sigla_uf, cd_municipio, num_turno, cd_eleicao,
    ano_eleicao, nome_foto, sq_coligacao, nm_coligacao, ds_composicao_coligacao,
    cd_sit_candidatura, ds_sit_candidatura, rodou_rot, cd_detalhe_situacao_cand,
    ds_detalhe_situacao_cand
)
SELECT 'ZZ', 2022 * 1000000 + row_number() OVER (ORDER BY zz.nr_turno, zz.votos DESC),
       sp.sq_candidato, sp.nome_candidato, sp.nome_urna_candidato, sp.numero_cand,
       sp.sigla_partido, zz.votos, sp.cd_sit_tot_turno, sp.desc_sit_cand_tot, sp.cd_cargo,
       sp.descricao_cargo, sp.sigla_uf, sp.cd_municipio, sp.num_turno, sp.cd_eleicao,
       sp.ano_eleicao, sp.nome_foto, sp.sq_coligacao, sp.nm_coligacao, sp.ds_composicao_coligacao,
       sp.cd_sit_candidatura, sp.ds_sit_candidatura, sp.rodou_rot, sp.cd_detalhe_situacao_cand,
       sp.ds_detalhe_situacao_cand
  FROM zz
  JOIN raiox.tse_candidatos sp
    ON sp.uf = 'SP' AND sp.ano_eleicao = 2022 AND sp.cd_cargo = 1
   AND sp.sq_candidato = zz.sq_candidato::text AND sp.num_turno = zz.nr_turno::text;

INSERT INTO raiox.tse_votosvalidos_eleicao (
    uf, id, ano_eleicao, nr_turno, cd_cargo, validos, nulos, brancos, votantes,
    total_eleitores_federal, total_eleitores_estadual, total_eleitores_municipal
) VALUES
    ('ZZ', 2022000001, 2022, 1, 1, 294525, 4650, 4857, 304032, 695355, 0, 0),
    ('ZZ', 2022000002, 2022, 2, 1, 298169, 6079, 5900, 310148, 695578, 0, 0);

-- Trava: 13 candidatos-turno e os válidos batendo com a soma dos candidatos.
DO $$
DECLARE n int; v1 bigint; v2 bigint;
BEGIN
  SELECT count(*) INTO n FROM raiox.tse_candidatos WHERE uf = 'ZZ' AND ano_eleicao = 2022;
  SELECT sum(total_votos) FILTER (WHERE num_turno = '1'), sum(total_votos) FILTER (WHERE num_turno = '2')
    INTO v1, v2 FROM raiox.tse_candidatos WHERE uf = 'ZZ' AND ano_eleicao = 2022;
  IF n <> 13 OR v1 <> 294525 OR v2 <> 298169 THEN
    RAISE EXCEPTION 'ZZ 2022 inconsistente: % linhas, turno1 %, turno2 %', n, v1, v2;
  END IF;
END $$;

COMMIT;
