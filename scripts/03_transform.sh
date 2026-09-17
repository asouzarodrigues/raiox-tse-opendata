#!/usr/bin/env bash
# Migração real: aplica 10_target_schema.sql (garante schema+partição da UF,
# idempotente) e roda 20_transform.sql + 25_aggregate.sql pro(s) ano(s)
# passado(s) em $1 (default: cada ano em $ANOS). Escreve DIRETO em `raiox`
# (mesmo schema de produção) — ver docs/decisions/JOURNAL.md.
#
# Reprocessar uma UF que já existe (ex.: AC, migrado originalmente via
# MySQL) SOBRESCREVE os dados dela pro(s) ano(s) passado(s). Comportamento
# aceito deliberadamente — sem lock/guarda.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$DIR"
set -a; source .env; set +a
export PATH="/opt/homebrew/opt/libpq/bin:$PATH"

echo "== schema alvo (uf=$UF) =="
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -v uf="$UF" -v uf_lower="$UF_LOWER" -f sql/10_target_schema.sql

anos="${1:-$ANOS}"
for ano in $anos; do
  uf_ano="${UF_LOWER}_${ano}"
  echo "== partição do ano (uf=$UF ano=$ano) =="
  # Roda SEMPRE, mesmo quando o ano não tem dado (ver skip abaixo): deixa a
  # partição-folha vazia mas existente, pra 04_promote.sh conseguir referenciá-la
  # (pg_dump -t falha se a tabela não existir, mesmo pra dump de 0 linhas).
  psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -v uf_lower="$UF_LOWER" -v uf_ano="$uf_ano" -v ano="$ano" -f sql/15_target_schema_year.sql

  # 20_transform.sql assume que raiox_tse_raw.votacao_secao_$ano existe —
  # 02_load_raw.sh só cria essa tabela quando havia um CSV pra carregar.
  # Combinação sem eleição nenhuma (ex.: DF em ano municipal — sem
  # municípios, sem prefeito/vereador, sem arquivo no CDN) não tem CSV, não
  # tem tabela raw, e SELECT FROM tabela inexistente quebra o script (achado
  # processando DF/2012). Detecta pela existência da tabela em vez de
  # hardcodar "UF=DF" aqui: cobre qualquer UF/ano sem dado, não só esse caso.
  tem_dado=$(psql "$DATABASE_URL" -tAc "SELECT to_regclass('${RAW_SCHEMA}.votacao_secao_${ano}') IS NOT NULL")
  if [ "$tem_dado" != "t" ]; then
    echo "== uf=$UF ano=$ano: sem dado bruto (raiox_tse_raw.votacao_secao_${ano} não existe) — pulando transform/aggregate =="
    continue
  fi

  echo "== transformando uf=$UF ano=$ano =="
  psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -v uf="$UF" -v uf_lower="$UF_LOWER" -v uf_ano="$uf_ano" -v ano="$ano" -f sql/20_transform.sql
  echo "== agregando uf=$UF ano=$ano =="
  psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -v uf="$UF" -v uf_lower="$UF_LOWER" -v uf_ano="$uf_ano" -v ano="$ano" -f sql/25_aggregate.sql
done
echo "Feito."
