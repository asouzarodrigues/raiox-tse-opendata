#!/usr/bin/env bash
# Carrega os CSVs baixados em tabelas RAW (1:1, tudo texto) no schema
# $RAW_SCHEMA — mesmo padrão do raiox-migracao-piloto (Stage A): não tenta
# tipar/limpar na carga, só espelha o CSV. Tipagem e join acontecem no
# 03_transform.sql.
#
# Tabela por dataset/ano (ex.: votacao_secao_2024), colunas descobertas
# dinamicamente a partir do header do próprio CSV — como o formato do TSE
# muda de coluna entre anos, isso evita ter que manter uma lista manual.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$DIR"
set -a; source .env; set +a
# psql (libpq) instalado via `brew install libpq` — é keg-only, não entra no
# PATH por padrão.
export PATH="/opt/homebrew/opt/libpq/bin:$PATH"

psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -c "CREATE SCHEMA IF NOT EXISTS $RAW_SCHEMA;" >/dev/null

load_csv() {
  local file="$1" table="$2"
  echo "== carregando $table <- $file =="
  local header coldefs c cl
  header=$(head -1 "$file" | tr -d '\r')
  coldefs=""
  IFS=';' read -ra cols <<< "$header"
  for c in "${cols[@]}"; do
    c="${c//\"/}"
    cl=$(echo "$c" | tr '[:upper:]' '[:lower:]')
    coldefs="$coldefs, \"$cl\" text"
  done
  coldefs="${coldefs:2}"
  psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -c "DROP TABLE IF EXISTS $RAW_SCHEMA.\"$table\"; CREATE TABLE $RAW_SCHEMA.\"$table\" ($coldefs);" >/dev/null
  # Alguns CSVs do TSE trazem bytes indefinidos em WIN1252 intercalados no
  # meio de nomes (ex.: 0x81 solto entre "F\xC1" e "TIMA" em vez de
  # "FÁTIMA") — corrupção pontual da própria exportação do TSE, não erro de
  # escolha de encoding (0x81/0x8D/0x8F/0x90/0x9D nunca são caracteres
  # válidos em WIN1252, então um COPY com ENCODING WIN1252 morre nelas:
  # "character with byte sequence 0x81 ... has no equivalent in encoding
  # UTF8"). Filtra esses 5 bytes antes do \copy (via STDIN em vez de FROM
  # arquivo) — remove só o lixo, preserva acentuação normal (Á, Ç etc.
  # continuam mapeando certo).
  LC_ALL=C tr -d '\201\215\217\220\235' < "$file" | \
    psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -c "\copy $RAW_SCHEMA.\"$table\" FROM STDIN WITH (FORMAT csv, DELIMITER ';', HEADER true, QUOTE '\"', ENCODING 'WIN1252')"
  n=$(psql "$DATABASE_URL" -tAc "SELECT count(*) FROM $RAW_SCHEMA.\"$table\"")
  echo "   -> $n linhas"
}

# Índice DEPOIS da carga (nunca antes — manter índice atualizado durante o
# \copy só deixa ele mais lento à toa). Só cria se a coluna existir na
# tabela — formato do TSE muda de ano pra ano (ver sql/20_transform.sql), e
# aqui não é diferente. Índice de expressão porque 20_transform.sql faz
# JOIN com ::bigint (não ::text) nessas colunas — índice normal na coluna
# texto não seria usado nesse tipo de comparação.
index_if_cols_exist() {
  local table="$1" idxname="$2" expr="$3"; shift 3
  local col missing=0
  for col in "$@"; do
    psql "$DATABASE_URL" -tAc \
      "SELECT 1 FROM information_schema.columns WHERE table_schema='$RAW_SCHEMA' AND table_name='$table' AND column_name='$col'" \
      | grep -q 1 || { missing=1; break; }
  done
  if [ "$missing" -eq 1 ]; then
    echo "   -> pulei índice $idxname (coluna ausente neste formato de ano)"
    return 0
  fi
  psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -c \
    "CREATE INDEX IF NOT EXISTS \"$idxname\" ON $RAW_SCHEMA.\"$table\" ($expr);" >/dev/null
  echo "   -> índice $idxname ok"
}

for ano in $ANOS; do
  f="data/raw/votacao_secao/$ano/votacao_secao_${ano}_${UF}.csv"
  estadual_ok=0
  if [ -f "$f" ]; then
    load_csv "$f" "votacao_secao_${ano}"
    estadual_ok=1
  else
    # Sem arquivo = sem eleição pra essa uf+ano (ex.: DF em ano municipal —
    # não tem municípios, 01_download.sh já nem tenta baixar). Não cria
    # tabela raw nenhuma pra esse ano; 03_transform.sh detecta essa ausência
    # e pula transform/aggregate pra esse ano (ver comentário lá).
    echo "== votacao_secao_${ano}: sem CSV pra uf=$UF (sem eleição nesse ano/uf), pulando =="
  fi

  # Presidente/Vice — arquivo NACIONAL (votacao_secao_${ano}_BR.csv, baixado
  # só em ano de eleição geral por 01_download.sh). Filtra por SG_UF (coluna
  # 11 no header do TSE) ANTES do \copy — carregar as 27 UFs pra usar 1 não
  # faz sentido (arquivo tem ~9M+ linhas/ano). Quando não existe (ano
  # municipal, sem eleição federal), cria uma tabela vazia com as MESMAS
  # colunas de votacao_secao_$ano — sql/20_transform.sql faz UNION ALL das
  # duas sempre, sem precisar saber se o ano teve presidente ou não.
  if [ "$estadual_ok" -eq 1 ]; then
    fbr="data/raw/votacao_secao/$ano/votacao_secao_${ano}_BR.csv"
    if [ -f "$fbr" ]; then
      ffiltrado="data/raw/votacao_secao/$ano/votacao_secao_${ano}_BR_${UF}.csv"
      if [ ! -s "$ffiltrado" ]; then
        echo "== filtrando federal (BR) $ano por uf=$UF =="
        # python (não awk): awk filtra linha física por linha física e não
        # entende quoting de CSV, então um campo entre aspas com \n embutido
        # (acontece em endereço de local de votação — ver
        # eleitorado_locais_votacao abaixo, mesmo risco aqui) corrompe o
        # registro. Ver scripts/lib/filter_csv_col.py.
        python3 "$DIR/scripts/lib/filter_csv_col.py" "$fbr" "$ffiltrado" 11 "$UF"
      fi
      load_csv "$ffiltrado" "votacao_secao_federal_${ano}"
    else
      psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -c \
        "DROP TABLE IF EXISTS $RAW_SCHEMA.\"votacao_secao_federal_${ano}\"; CREATE TABLE $RAW_SCHEMA.\"votacao_secao_federal_${ano}\" (LIKE $RAW_SCHEMA.\"votacao_secao_${ano}\");" >/dev/null
      echo "== votacao_secao_federal_${ano}: vazia (ano municipal, sem eleição federal) =="
    fi
  fi

  f="data/raw/consulta_cand/$ano/consulta_cand_${ano}_${UF}.csv"
  if [ -f "$f" ]; then
    load_csv "$f" "consulta_cand_${ano}"
    # usada em sql/20_transform.sql pra achar sq_candidato quando o
    # votacao_secao daquele ano não traz a coluna nativa (ver ano 2018).
    index_if_cols_exist "consulta_cand_${ano}" "cc_${ano}_cand_idx" \
      "nr_candidato, cd_cargo, sg_uf" nr_candidato cd_cargo sg_uf
    index_if_cols_exist "consulta_cand_${ano}" "cc_${ano}_partido_idx" \
      "nr_partido" nr_partido

    # Candidatos a Presidente/Vice já vêm DENTRO do mesmo zip nacional de
    # consulta_cand (consulta_cand_${ano}_BR.csv, um arquivo pequeno — só
    # não é filtrado por UF porque candidatura federal não é por estado).
    # Só existe em ano de eleição geral, igual o BR de votacao_secao acima.
    fbr="data/raw/consulta_cand/$ano/consulta_cand_${ano}_BR.csv"
    if [ -f "$fbr" ]; then
      load_csv "$fbr" "consulta_cand_federal_${ano}"
    else
      psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -c \
        "DROP TABLE IF EXISTS $RAW_SCHEMA.\"consulta_cand_federal_${ano}\"; CREATE TABLE $RAW_SCHEMA.\"consulta_cand_federal_${ano}\" (LIKE $RAW_SCHEMA.\"consulta_cand_${ano}\");" >/dev/null
      echo "== consulta_cand_federal_${ano}: vazia (ano municipal, sem eleição federal) =="
    fi
  fi

  # eleitorado_locais_votacao é NACIONAL (não vem separado por UF dentro do
  # zip, diferente de consulta_cand) — filtra por SG_UF (coluna 7 do header
  # do TSE) ANTES do \copy, mesma lógica do federal de votacao_secao/
  # consulta_cand acima. Sem isso, toda UF processada no mesmo ano
  # recarregava o Brasil inteiro pro staging (~400MB/ano, ~1-2M linhas) só
  # pra filtrar depois no 20_transform.sql (WHERE l.sg_uf = :uf, que
  # continua lá como cinto-e-suspensório) — puro desperdício de tempo/IO.
  # Filtrado fica em cache (nome com _UF.csv) — se já existir (solto manual
  # ou de uma rodada anterior), não regenera.
  #
  # python, não awk: DS_ENDERECO desse dataset às vezes traz quebra de
  # linha literal DENTRO do campo entre aspas (endereço multi-linha) — CSV
  # válido (RFC4180), mas awk processa linha física por linha física sem
  # entender quoting, corta o registro no meio e o \copy do Postgres rejeita
  # depois com "unquoted newline found in data" (visto em RN/2024). Ver
  # scripts/lib/filter_csv_col.py.
  fnac="data/raw/eleitorado_locais_votacao/$ano/eleitorado_local_votacao_${ano}.csv"
  f="data/raw/eleitorado_locais_votacao/$ano/eleitorado_local_votacao_${ano}_${UF}.csv"
  if [ ! -s "$f" ] && [ -f "$fnac" ]; then
    echo "== filtrando eleitorado_locais_votacao $ano por uf=$UF =="
    python3 "$DIR/scripts/lib/filter_csv_col.py" "$fnac" "$f" 7 "$UF"
  fi
  if [ -f "$f" ]; then
    load_csv "$f" "eleitorado_locais_votacao_${ano}"
    # usada no join de bairro/local dentro de sql/20_transform.sql.
    index_if_cols_exist "eleitorado_locais_votacao_${ano}" "elv_${ano}_join_idx" \
      "sg_uf, ((cd_municipio)::bigint), ((nr_zona)::bigint), ((nr_secao)::bigint)" \
      sg_uf cd_municipio nr_zona nr_secao
  fi
done

echo "Feito."
