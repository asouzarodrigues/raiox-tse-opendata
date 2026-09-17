-- Checagem de sanidade pós-carga: contagens e somas em raiox pra uma
-- uf+ano, sem comparar contra outro schema (não existe mais raiox_tse
-- separado — o pipeline grava direto em raiox agora, ver JOURNAL 2026-08-22).
-- Rode com: psql "$DATABASE_URL" -v uf=AC -v ano=2024 -f sql/30_validate.sql
SELECT 'tse_votacaosecao'          AS tabela, count(*) AS linhas, sum(qt_votos) AS soma_votos FROM raiox.tse_votacaosecao          WHERE uf = :'uf' AND ano_eleicao = :ano
UNION ALL SELECT 'tse_votacaosecao_sem_bairro', count(*) FILTER (WHERE nm_bairro IS NULL), NULL FROM raiox.tse_votacaosecao WHERE uf = :'uf' AND ano_eleicao = :ano
-- deve ser 0: sq_candidato só fica NULL se o CASE de fallback (anos sem a
-- coluna nativa, ver sql/20_transform.sql) não conseguiu casar nem
-- candidato nem partido pra alguma linha — investigar se aparecer > 0.
UNION ALL SELECT 'tse_votacaosecao_sqcand_nulo', count(*) FILTER (WHERE sq_candidato IS NULL), NULL FROM raiox.tse_votacaosecao WHERE uf = :'uf' AND ano_eleicao = :ano
UNION ALL SELECT 'tse_candidatos',              count(*), sum(total_votos)                  FROM raiox.tse_candidatos              WHERE uf = :'uf' AND ano_eleicao = :ano
UNION ALL SELECT 'tse_locais',                  count(*), NULL                              FROM raiox.tse_locais                  WHERE uf = :'uf' AND ano_eleicao = :ano
UNION ALL SELECT 'tse_votos_candidato_cidade',  count(*), sum(qt_votos)                      FROM raiox.tse_votos_candidato_cidade  WHERE uf = :'uf' AND ano_eleicao = :ano
UNION ALL SELECT 'tse_votos_candidato_bairro',  count(*), sum(qt_votos)                      FROM raiox.tse_votos_candidato_bairro  WHERE uf = :'uf' AND ano_eleicao = :ano
UNION ALL SELECT 'tse_votos_candidato_local',   count(*), sum(qt_votos)                      FROM raiox.tse_votos_candidato_local   WHERE uf = :'uf' AND ano_eleicao = :ano
UNION ALL SELECT 'tse_votosvalidos_eleicao',    count(*), sum(validos)                       FROM raiox.tse_votosvalidos_eleicao    WHERE uf = :'uf' AND ano_eleicao = :ano
UNION ALL SELECT 'tse_votosvalidos_cidade',     count(*), sum(validos)                       FROM raiox.tse_votosvalidos_cidade     WHERE uf = :'uf' AND ano_eleicao = :ano
UNION ALL SELECT 'tse_votosvalidos_bairro',     count(*), sum(validos)                       FROM raiox.tse_votosvalidos_bairro     WHERE uf = :'uf' AND ano_eleicao = :ano
UNION ALL SELECT 'tse_votosvalidos_local',      count(*), sum(validos)                       FROM raiox.tse_votosvalidos_local      WHERE uf = :'uf' AND ano_eleicao = :ano;
