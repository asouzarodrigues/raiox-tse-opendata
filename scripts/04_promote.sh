#!/usr/bin/env bash
# Promove pra PRODUÇÃO real do Neon os anos de $UF já transformados no
# piloto local (schema `raiox`) pelo 03_transform.sh. Passo seguinte na
# cadeia 01 (download) -> 02 (load raw) -> 03 (transform local) -> 04
# (promove). Não altera o piloto local nem o staging (raiox_tse_raw) — só
# lê de raiox local e escreve na produção.
#
# Uso: scripts/04_promote.sh [ano ano ...]   (default: $ANOS do .env)
# Pré-requisito: PROD_DATABASE_URL no .env — connection string DIRECT da
# produção real (nunca a pooled, nunca um branch de teste/simulação).
#
# Duas categorias de tabela em sql/10_target_schema.sql:
#  - 1 nível (só uf): tse_cidades, votos_partidos — promovidas 1x, fora do
#    loop de ano (mesmo dado serve pra todos os anos daquela UF).
#  - 2 níveis (uf + ano_eleicao): as outras 12 tabelas TSE — promovidas por
#    ano.
# candidato_resumo/pergunta_resposta_cache (cache de IA) ficam de fora de
# propósito: são tabelas globais, não particionadas por UF — promoção cega
# por cima arriscaria colidir com o que já existe em produção pra outros
# estados. Se precisar levar cache de IA, é decisão à parte, manual.
#
# Reexecução é segura: TRUNCATE nas tabelas-folha de produção antes de
# restaurar (evita a duplicação silenciosa que já vimos com pg_restore em
# tabela sem PK — ver JOURNAL do raiox-migracao-piloto).
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$DIR"
set -a; source .env; set +a
export PATH="/opt/homebrew/opt/libpq/bin:$PATH"

: "${PROD_DATABASE_URL:?defina PROD_DATABASE_URL no .env (connection DIRECT da produção real)}"
if [[ "$PROD_DATABASE_URL" == *simulacao* || "$PROD_DATABASE_URL" == *backup* || "$PROD_DATABASE_URL" == "$DATABASE_URL" ]]; then
  echo "ERRO: PROD_DATABASE_URL parece um branch de teste/backup, ou igual ao DATABASE_URL local." >&2
  exit 1
fi

anos="${*:-$ANOS}"
echo "== Promovendo UF=$UF pra produção, anos: $anos =="

echo "== [1/5] estrutura da UF em produção (idempotente) =="
psql "$PROD_DATABASE_URL" -v ON_ERROR_STOP=1 -v uf="$UF" -v uf_lower="$UF_LOWER" -f sql/10_target_schema.sql

echo "== [2/5] partições dos anos em produção (idempotente) =="
for ano in $anos; do
  uf_ano="${UF_LOWER}_${ano}"
  psql "$PROD_DATABASE_URL" -v ON_ERROR_STOP=1 -v uf_lower="$UF_LOWER" -v uf_ano="$uf_ano" -v ano="$ano" -f sql/15_target_schema_year.sql
done

TABLES_2NIVEIS="tse_eleicoes tse_cargos tse_candidatos tse_votacaosecao tse_votos_candidato_cidade tse_votos_candidato_bairro tse_votos_candidato_local tse_locais tse_votosvalidos_eleicao tse_votosvalidos_cidade tse_votosvalidos_bairro tse_votosvalidos_local tse_votacaosecao_partido"

leaves=("tse_cidades_${UF_LOWER}" "votos_partidos_${UF_LOWER}")
for ano in $anos; do
  for t in $TABLES_2NIVEIS; do
    leaves+=("${t}_${UF_LOWER}_${ano}")
  done
done

echo "== [3/5] limpando (TRUNCATE) ${#leaves[@]} tabelas-folha em produção antes de restaurar =="
truncate_sql=""
for leaf in "${leaves[@]}"; do
  truncate_sql="${truncate_sql}TRUNCATE TABLE raiox.\"${leaf}\";"$'\n'
done
psql "$PROD_DATABASE_URL" -v ON_ERROR_STOP=1 -c "$truncate_sql"

echo "== [4/5] dump (só dado) do piloto local -> restore em produção =="
tflags=()
for leaf in "${leaves[@]}"; do
  tflags+=(-t "raiox.${leaf}")
done
DUMPFILE="/tmp/promote_${UF_LOWER}_$$.dump"
pg_dump "$DATABASE_URL" -Fc --data-only --schema=raiox "${tflags[@]}" -f "$DUMPFILE"
pg_restore --no-owner --no-privileges --disable-triggers -j 4 -d "$PROD_DATABASE_URL" "$DUMPFILE"
rm -f "$DUMPFILE"

echo "== [5/5] validação: contagem de linhas, local vs produção, tabela a tabela =="
fail=0
for leaf in "${leaves[@]}"; do
  local_n=$(psql "$DATABASE_URL" -tA -c "SELECT count(*) FROM raiox.\"$leaf\";")
  prod_n=$(psql "$PROD_DATABASE_URL" -tA -c "SELECT count(*) FROM raiox.\"$leaf\";")
  if [[ "$local_n" == "$prod_n" ]]; then
    echo "  OK   $leaf: $local_n"
  else
    echo "  DIVERGE $leaf: local=$local_n producao=$prod_n"
    fail=1
  fi
done

if [[ "$fail" == "1" ]]; then
  echo ""
  echo "ATENÇÃO: divergências acima — não considerar a promoção concluída até investigar."
  exit 1
fi
echo ""
echo "Feito. UF=$UF (anos: $anos) promovido pra produção com sucesso."
