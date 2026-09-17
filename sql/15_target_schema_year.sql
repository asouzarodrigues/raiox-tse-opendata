-- Cria a partição-FOLHA de um ano específico, dentro da partição da UF
-- (que sql/10_target_schema.sql já deixou particionada por ano_eleicao).
-- Roda uma vez por (uf, ano) — dentro do loop de anos de
-- scripts/03_transform.sh, depois de 10_target_schema.sql (que só cuida do
-- nível uf) e antes de 20_transform.sql.
--
-- Parametrizado por :uf_lower (nível uf, ex. "sp") e :uf_ano (nível folha,
-- ex. "sp_2018" — pré-combinado no shell, não concatenado aqui: psql -v faz
-- match guloso de ":var" até o próximo caractere não-identificador, então
-- ":uf_lower_:ano" colado tentaria resolver uma variável só chamada
-- "uf_lower_" e quebraria — mesmo bug já documentado em
-- sql/10_target_schema.sql). :ano é o número puro, sem aspas (FOR VALUES IN
-- espera o tipo da coluna, bigint aqui).
--
-- Tabelas sem ano_eleicao (tse_cidades, votos_partidos) não entram aqui —
-- continuam só com partição por uf, criada direto em 10_target_schema.sql.
CREATE TABLE IF NOT EXISTS raiox.tse_eleicoes_:uf_ano
  PARTITION OF raiox.tse_eleicoes_:uf_lower FOR VALUES IN (:ano);

CREATE TABLE IF NOT EXISTS raiox.tse_cargos_:uf_ano
  PARTITION OF raiox.tse_cargos_:uf_lower FOR VALUES IN (:ano);

CREATE TABLE IF NOT EXISTS raiox.tse_candidatos_:uf_ano
  PARTITION OF raiox.tse_candidatos_:uf_lower FOR VALUES IN (:ano);

CREATE TABLE IF NOT EXISTS raiox.tse_votacaosecao_:uf_ano
  PARTITION OF raiox.tse_votacaosecao_:uf_lower FOR VALUES IN (:ano);

CREATE TABLE IF NOT EXISTS raiox.tse_locais_:uf_ano
  PARTITION OF raiox.tse_locais_:uf_lower FOR VALUES IN (:ano);

CREATE TABLE IF NOT EXISTS raiox.tse_votos_candidato_cidade_:uf_ano
  PARTITION OF raiox.tse_votos_candidato_cidade_:uf_lower FOR VALUES IN (:ano);

CREATE TABLE IF NOT EXISTS raiox.tse_votos_candidato_bairro_:uf_ano
  PARTITION OF raiox.tse_votos_candidato_bairro_:uf_lower FOR VALUES IN (:ano);

CREATE TABLE IF NOT EXISTS raiox.tse_votos_candidato_local_:uf_ano
  PARTITION OF raiox.tse_votos_candidato_local_:uf_lower FOR VALUES IN (:ano);

CREATE TABLE IF NOT EXISTS raiox.tse_votosvalidos_eleicao_:uf_ano
  PARTITION OF raiox.tse_votosvalidos_eleicao_:uf_lower FOR VALUES IN (:ano);

CREATE TABLE IF NOT EXISTS raiox.tse_votosvalidos_cidade_:uf_ano
  PARTITION OF raiox.tse_votosvalidos_cidade_:uf_lower FOR VALUES IN (:ano);

CREATE TABLE IF NOT EXISTS raiox.tse_votosvalidos_bairro_:uf_ano
  PARTITION OF raiox.tse_votosvalidos_bairro_:uf_lower FOR VALUES IN (:ano);

CREATE TABLE IF NOT EXISTS raiox.tse_votosvalidos_local_:uf_ano
  PARTITION OF raiox.tse_votosvalidos_local_:uf_lower FOR VALUES IN (:ano);

CREATE TABLE IF NOT EXISTS raiox.tse_votacaosecao_partido_:uf_ano
  PARTITION OF raiox.tse_votacaosecao_partido_:uf_lower FOR VALUES IN (:ano);
