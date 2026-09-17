#!/usr/bin/env python3
"""Filtra um CSV do TSE por valor exato de uma coluna (1-indexed), preservando
registros CSV corretamente — inclusive quando um campo entre aspas contém
quebra de linha literal embutida (endereços de local de votação, por
exemplo). Existe porque o filtro anterior era `awk -F';' '$N==valor'`, que
processa o arquivo linha física por linha física sem entender quoting de
CSV: um campo com \n embutido vira duas "linhas" pro awk, corrompendo o
registro e produzindo um CSV que o `\\copy` do Postgres rejeita com
"unquoted newline found in data" (RFC4180 aceita esse \n; awk não).

Le e escreve em latin1 (não cp1252) de propósito — latin1 é bijetivo sobre
os 256 valores de byte possíveis, então nunca lança exceção de decode
mesmo nos bytes indefinidos em WIN1252 que o TSE por vezes despeja nesses
arquivos (ver 02_load_raw.sh); a limpeza desses bytes acontece depois, no
load_csv() via `tr -d`. Aqui só precisamos separar corretamente os
registros e comparar a coluna-alvo — não corrigir encoding.

Uso: filter_csv_col.py <arquivo_entrada> <arquivo_saida> <coluna_1indexed> <valor>
"""
import csv
import sys


def main() -> int:
    if len(sys.argv) != 5:
        print(f"uso: {sys.argv[0]} <entrada> <saida> <coluna_1indexed> <valor>", file=sys.stderr)
        return 2

    in_path, out_path, col_arg, valor = sys.argv[1:5]
    col_idx = int(col_arg) - 1
    if col_idx < 0:
        print("coluna deve ser >= 1", file=sys.stderr)
        return 2

    # newline='' + writer com lineterminator='\n': deixa o módulo csv decidir
    # quando quotar (inclusive por causa de \n embutido) em vez de deixar o
    # runtime traduzir \r\n, o que bagunçaria a contagem de bytes no meio de
    # um campo quotado.
    with open(in_path, "r", encoding="latin1", newline="") as fin, \
         open(out_path, "w", encoding="latin1", newline="") as fout:
        reader = csv.reader(fin, delimiter=";", quotechar='"')
        writer = csv.writer(fout, delimiter=";", quotechar='"', lineterminator="\n")

        header = next(reader)
        writer.writerow(header)
        if col_idx >= len(header):
            print(f"coluna {col_arg} fora do header ({len(header)} colunas)", file=sys.stderr)
            return 2

        n = 0
        for row in reader:
            if len(row) > col_idx and row[col_idx] == valor:
                writer.writerow(row)
                n += 1
        print(f"{n} linhas mantidas", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
