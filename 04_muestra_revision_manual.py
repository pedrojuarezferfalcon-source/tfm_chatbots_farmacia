"""
04_muestra_revision_manual.py
================================
TFM - Comparación de Chatbots clínicos en la práctica farmacéutica

Genera la muestra aleatoria ESTRATIFICADA del 10% de los casos para la
revisión manual del autor (apartado 5.5.3.ii de la memoria), necesaria
después para calcular el Kappa ponderado de Cohen entre el árbitro y el
autor (apartado 5.6.3).

Con 35 casos piloto, el 10% son ~4 casos (se reparten proporcionalmente
entre Interacciones y Contraindicaciones). En la entrega final con n=100
serán 10 casos, como especifica la memoria.

Salida: revision_manual_muestra.xlsx -> el autor rellena manualmente las
columnas de puntuación (1-5) por dimensión para el modelo A y el modelo B,
sin ver las puntuaciones del árbitro, y luego se compara con
puntuaciones.json en el script de análisis (04_analisis.R).

USO:
    python 04_muestra_revision_manual.py
"""

import json
import random
from pathlib import Path

import openpyxl

RESPUESTAS_JSON = Path(__file__).parent / "respuestas.json"
OUT_XLSX = Path(__file__).parent / "revision_manual_muestra.xlsx"

FRACCION = 0.10
SEED = 42  # fijar semilla para reproducibilidad (documentar en la memoria)


def main():
    casos = json.loads(RESPUESTAS_JSON.read_text(encoding="utf-8"))
    random.seed(SEED)

    por_categoria = {}
    for c in casos:
        por_categoria.setdefault(c["categoria"], []).append(c)

    muestra = []
    for categoria, lista in por_categoria.items():
        n = max(1, round(len(lista) * FRACCION))
        muestra.extend(random.sample(lista, n))

    print(f"Muestra de revisión manual: {len(muestra)} de {len(casos)} casos ({FRACCION:.0%})")
    for c in muestra:
        print(f"  - {c['id_caso']} ({c['categoria']})")

    wb = openpyxl.Workbook()
    ws = wb.active
    ws.title = "revision_manual"
    cols = [
        "id_caso", "categoria", "prompt", "ground_truth",
        "respuesta_modelo_A", "precision_clinica_A", "seguridad_A", "alucinacion_A",
        "respuesta_modelo_B", "precision_clinica_B", "seguridad_B", "alucinacion_B",
        "notas",
    ]
    ws.append(cols)
    for c in muestra:
        ws.append([
            c["id_caso"], c["categoria"], c["prompt"], c["ground_truth"],
            c["respuesta_modelo_A"].get("texto"), None, None, None,
            c["respuesta_modelo_B"].get("texto"), None, None, None,
            "",
        ])
    for col_cells in ws.columns:
        ws.column_dimensions[col_cells[0].column_letter].width = 35
    wb.save(OUT_XLSX)
    print(f"\nEscrito: {OUT_XLSX}")
    print("Rellena las columnas de puntuación (1-5) SIN mirar puntuaciones.json,")
    print("y luego pasa el fichero a 04_analisis.R para calcular el Kappa de Cohen.")


if __name__ == "__main__":
    main()
