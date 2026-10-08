-- Correção pontual (2026-10-08): tse_candidatos.total_votos das linhas de
-- 2º turno passa a ser o total DO 2º TURNO. Antes as duas linhas do candidato
-- (uma por turno) traziam o 1º turno — convenção herdada do MySQL, que o
-- 20_transform.sql copiava. A partir desta data o 20_transform.sql já grava
-- o turno certo; este script corrige o que foi carregado antes.
--
-- Fonte: tse_votos_candidato_cidade (já correta por turno). Só mexe em linha
-- que tem soma lá — vices/suplentes (cd_cargo 2, 4, 12) não têm voto próprio
-- nessa tabela e ficam como estão. Idempotente.
--
-- Simulação em 2026-10-08: 674 linhas de titular (cargos 1, 3, 11; 2012–2024).
--
-- Reverter: copiar de volta o total da linha de 1º turno do mesmo
-- (uf, ano_eleicao, sq_candidato).
--
--   psql "$DATABASE_URL" -f sql/40_fix_total_votos_2turno.sql

BEGIN;

WITH s AS (
    SELECT uf, ano_eleicao, sq_candidato, SUM(qt_votos)::bigint AS total
      FROM raiox.tse_votos_candidato_cidade
     WHERE nr_turno = 2
     GROUP BY uf, ano_eleicao, sq_candidato
)
UPDATE raiox.tse_candidatos c
   SET total_votos = s.total
  FROM s
 WHERE c.num_turno = '2'
   AND s.uf = c.uf
   AND s.ano_eleicao = c.ano_eleicao
   AND s.sq_candidato = c.sq_candidato
   AND c.total_votos IS DISTINCT FROM s.total;

COMMIT;
