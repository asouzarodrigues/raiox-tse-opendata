-- Correção pontual (2026-10-08): eleitorado e abstenção inflados em todos os
-- anos e cargos. Ver docs/decisions/JOURNAL.md (workspace) do mesmo dia.
--
-- Causa: raiox.tse_locais tem uma linha por seção POR TURNO, e os agregados
-- somavam os dois turnos (o 25_aggregate.sql só fazia DISTINCT, que não
-- separa turno quando o eleitorado da seção muda de um turno pro outro). Nos
-- anos migrados do MySQL o valor já chegou errado de lá. Efeito: eleitorado
-- ~1,5–2× e abstenção alta demais — negativa em 2014, onde o eleitorado
-- estadual veio zerado. O 25_aggregate.sql já foi corrigido (eleitores do
-- turno da linha); este script corrige o que está gravado.
--
-- Fontes:
--   - Resumo por UF e cidade: eleitorado apto OFICIAL do TSE
--     (detalhe_votacao_munzona), via data/aptos_munzona.csv gerado por
--     scripts/06_aptos_oficiais.sh. Exato em todos os anos.
--   - Bairro e local: tse_locais só do turno da linha (o TSE não publica
--     eleitorado abaixo de zona). Exato em 2022/2024; em 2018 bate em ~92% dos
--     municípios; nos anos antigos tse_locais está incompleta — onde o
--     eleitorado do turno sai MENOR que os votantes (seções faltando), a
--     linha não é alterada.
-- Em todo nível: ausentes = eleitorado - comparecimento (votantes não mudam).
-- comparecimento = votantes, EXCETO Senado (cargo 5) nos anos de 2 vagas
-- (2010, 2018, 2026...: ano % 8 = 2): cada eleitor dá 2 votos, e votantes
-- (soma de qt_votos) é exatamente 2x o comparecimento oficial — conferido em
-- todos os municípios de 2018 e 2026. Ali comparecimento = votantes / 2.
-- 2014, bairro/local: tse_locais veio com eleitorado estadual zerado; usa o
-- federal no lugar (diferem só pelo voto em trânsito, que é só Presidente:
-- ~0,1%). Local casa por (município, zona, nº do local), sem o nome, que
-- varia entre as fontes.
--
-- Backup: os valores antigos vão para raiox_backup.eleitorado_20261008_*
-- (criadas só na 1ª execução — rodar de novo não sobrescreve o backup).
-- Reverter: UPDATE ... FROM raiox_backup.eleitorado_20261008_<nível> pela
-- chave (uf, ano_eleicao, id).
--
-- Rodar da raiz do repo (o \copy lê caminho relativo):
--   scripts/06_aptos_oficiais.sh
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f sql/43_fix_eleitorado.sql

BEGIN;

CREATE TEMP TABLE aptos_oficial (
    ano bigint, nr_turno bigint, cd_cargo bigint, uf text, cd_municipio bigint,
    aptos bigint, comparecimento bigint
) ON COMMIT DROP;
\copy aptos_oficial FROM 'data/aptos_munzona.csv' WITH (FORMAT csv, DELIMITER ';')

-- ===================== backup =====================
CREATE SCHEMA IF NOT EXISTS raiox_backup;
CREATE TABLE IF NOT EXISTS raiox_backup.eleitorado_20261008_eleicao AS
    SELECT uf, ano_eleicao, id, total_eleitores_federal, total_eleitores_estadual, total_eleitores_municipal
      FROM raiox.tse_votosvalidos_eleicao;
CREATE TABLE IF NOT EXISTS raiox_backup.eleitorado_20261008_cidade AS
    SELECT uf, ano_eleicao, id, ausentes FROM raiox.tse_votosvalidos_cidade;
CREATE TABLE IF NOT EXISTS raiox_backup.eleitorado_20261008_bairro AS
    SELECT uf, ano_eleicao, id, ausentes FROM raiox.tse_votosvalidos_bairro;
CREATE TABLE IF NOT EXISTS raiox_backup.eleitorado_20261008_local AS
    SELECT uf, ano_eleicao, id, ausentes FROM raiox.tse_votosvalidos_local;

-- ===================== resumo por UF (oficial) =====================
-- Só a coluna que o backend lê para o cargo da linha (summary.service.ts):
-- 1,2 -> federal | 3,5,6,7,8 -> estadual | 11,12,13 -> municipal.
WITH ofi AS (
    SELECT ano, nr_turno, cd_cargo, uf, SUM(aptos) AS aptos
      FROM aptos_oficial GROUP BY 1, 2, 3, 4
)
UPDATE raiox.tse_votosvalidos_eleicao v
   SET total_eleitores_federal   = CASE WHEN v.cd_cargo IN (1, 2) THEN o.aptos ELSE v.total_eleitores_federal END,
       total_eleitores_estadual  = CASE WHEN v.cd_cargo IN (3, 5, 6, 7, 8) THEN o.aptos ELSE v.total_eleitores_estadual END,
       total_eleitores_municipal = CASE WHEN v.cd_cargo IN (11, 12, 13) THEN o.aptos ELSE v.total_eleitores_municipal END
  FROM ofi o
 WHERE o.ano = v.ano_eleicao AND o.nr_turno = v.nr_turno AND o.cd_cargo = v.cd_cargo AND o.uf = v.uf
   AND o.aptos IS DISTINCT FROM CASE
         WHEN v.cd_cargo IN (1, 2) THEN v.total_eleitores_federal
         WHEN v.cd_cargo IN (3, 5, 6, 7, 8) THEN v.total_eleitores_estadual
         WHEN v.cd_cargo IN (11, 12, 13) THEN v.total_eleitores_municipal
       END;

-- ===================== cidade (oficial) =====================
UPDATE raiox.tse_votosvalidos_cidade c
   SET ausentes = o.aptos - (CASE WHEN c.cd_cargo = 5 AND c.ano_eleicao % 8 = 2 THEN c.votantes / 2 ELSE c.votantes END)
  FROM aptos_oficial o
 WHERE o.ano = c.ano_eleicao AND o.nr_turno = c.nr_turno AND o.cd_cargo = c.cd_cargo
   AND o.uf = c.uf AND o.cd_municipio = c.cd_municipio
   AND c.ausentes IS DISTINCT FROM o.aptos - (CASE WHEN c.cd_cargo = 5 AND c.ano_eleicao % 8 = 2 THEN c.votantes / 2 ELSE c.votantes END);

-- ===================== bairro (tse_locais do turno) =====================
WITH eleitores AS (
    SELECT uf, ano_eleicao, nr_turno, cd_municipio, nm_bairro,
           SUM(qt_eleitor_eleicao_federal)   AS federal,
           SUM(qt_eleitor_eleicao_estadual)  AS estadual,
           SUM(qt_eleitor_eleicao_municipal) AS municipal
      FROM (
          SELECT DISTINCT uf, ano_eleicao, nr_turno, cd_municipio, nm_bairro, nr_zona, nr_secao,
                 qt_eleitor_eleicao_federal, qt_eleitor_eleicao_estadual, qt_eleitor_eleicao_municipal
            FROM raiox.tse_locais
      ) t
     GROUP BY 1, 2, 3, 4, 5
), novo AS (
    SELECT b.uf, b.ano_eleicao, b.id,
           CASE WHEN b.cd_cargo IN (1, 2) THEN e.federal
                WHEN b.cd_cargo IN (3, 5, 6, 7, 8) THEN COALESCE(NULLIF(e.estadual, 0), e.federal)
                WHEN b.cd_cargo IN (11, 12, 13) THEN e.municipal END AS eleit,
           (CASE WHEN b.cd_cargo = 5 AND b.ano_eleicao % 8 = 2 THEN b.votantes / 2 ELSE b.votantes END) AS comparecimento
      FROM raiox.tse_votosvalidos_bairro b
      JOIN eleitores e
        ON e.uf = b.uf AND e.ano_eleicao = b.ano_eleicao AND e.nr_turno = b.nr_turno
       AND e.cd_municipio = b.cd_municipio AND e.nm_bairro IS NOT DISTINCT FROM b.nm_bairro
)
UPDATE raiox.tse_votosvalidos_bairro b
   SET ausentes = n.eleit - n.comparecimento
  FROM novo n
 WHERE n.uf = b.uf AND n.ano_eleicao = b.ano_eleicao AND n.id = b.id
   AND n.eleit >= n.comparecimento
   AND b.ausentes IS DISTINCT FROM n.eleit - n.comparecimento;

-- ===================== local (tse_locais do turno) =====================
WITH eleitores AS (
    SELECT uf, ano_eleicao, nr_turno, cd_municipio, nr_zona, nr_local_votacao,
           SUM(qt_eleitor_eleicao_federal)   AS federal,
           SUM(qt_eleitor_eleicao_estadual)  AS estadual,
           SUM(qt_eleitor_eleicao_municipal) AS municipal
      FROM (
          SELECT DISTINCT uf, ano_eleicao, nr_turno, cd_municipio, nr_zona, nr_local_votacao,
                 nr_secao, qt_eleitor_eleicao_federal, qt_eleitor_eleicao_estadual, qt_eleitor_eleicao_municipal
            FROM raiox.tse_locais
      ) t
     GROUP BY 1, 2, 3, 4, 5, 6
), novo AS (
    SELECT l.uf, l.ano_eleicao, l.id,
           CASE WHEN l.cd_cargo IN (1, 2) THEN e.federal
                WHEN l.cd_cargo IN (3, 5, 6, 7, 8) THEN COALESCE(NULLIF(e.estadual, 0), e.federal)
                WHEN l.cd_cargo IN (11, 12, 13) THEN e.municipal END AS eleit,
           (CASE WHEN l.cd_cargo = 5 AND l.ano_eleicao % 8 = 2 THEN l.votantes / 2 ELSE l.votantes END) AS comparecimento
      FROM raiox.tse_votosvalidos_local l
      JOIN eleitores e
        ON e.uf = l.uf AND e.ano_eleicao = l.ano_eleicao AND e.nr_turno = l.nr_turno
       AND e.cd_municipio = l.cd_municipio AND e.nr_zona = l.nr_zona
       AND e.nr_local_votacao = l.nr_local_votacao
)
UPDATE raiox.tse_votosvalidos_local l
   SET ausentes = n.eleit - n.comparecimento
  FROM novo n
 WHERE n.uf = l.uf AND n.ano_eleicao = l.ano_eleicao AND n.id = l.id
   AND n.eleit >= n.comparecimento
   AND l.ausentes IS DISTINCT FROM n.eleit - n.comparecimento;

COMMIT;
