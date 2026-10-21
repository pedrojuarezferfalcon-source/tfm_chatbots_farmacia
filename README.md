# Comparación de chatbots clínicos en la práctica farmacéutica

Material suplementario del Trabajo de Fin de Máster (Máster en Bioinformática, Universidad Europea, 2026).

- **Autor:** Pedro Juárez Fernández-Falcón
- **Tutor:** Javier Escalera Orobón

Pipeline reproducible que evalúa dos chatbots de IA generativa (`gpt-5.6-sol`, de OpenAI, y `gemini-3.1-pro-preview`, de Google) en 100 escenarios de asesoramiento farmacéutico: 50 contraindicaciones y 50 interacciones medicamentosas. Un tercer modelo (`claude-sonnet-4-5`, de Anthropic) actúa como árbitro (*LLM-as-a-Judge*) y puntúa cada respuesta de 1 a 5 en precisión clínica, seguridad y ausencia de alucinación. La metodología completa está en el capítulo 5 de la memoria.

## Contenido del repositorio

| Fichero / carpeta | Descripción | Anexo de la memoria |
|---|---|---|
| `00_identificar_candidatos_openFDA.R` | Consulta la API de openFDA/FAERS y genera los listados de candidatos a contraindicación e interacción (≥ 10 notificaciones graves en 5 años) | II |
| `plantilla_validacion_casos.xlsx` | Dataset de validación: 100 escenarios, fuentes y respuestas de referencia | I |
| `01_generar_prompts.py` | Genera los prompts estandarizados y el ground truth a partir de la plantilla | II |
| `02_llamar_modelos.py` | Consulta los dos modelos evaluados (ejecución reanudable) | II |
| `03_arbitro_claude.py` | Evaluación de cada respuesta por el árbitro con la rúbrica de 3 dimensiones | II |
| `04_muestra_revision_manual.py` | Genera la muestra estratificada del 10% para la revisión manual | II |
| `05_analisis.R` | Estadística descriptiva, Wilcoxon pareado + Bonferroni, tamaño del efecto, concordancia (Kappa ponderado y AC2 de Gwet) y figuras | II |
| `prompts.json`, `prompts_preview.xlsx` | Prompts generados | III |
| `respuestas.json` | Respuestas completas de ambos modelos y metadatos de cada llamada | III |
| `puntuaciones.json` | Puntuaciones y razonamientos del árbitro | III |
| `revision_manual_muestra.xlsx` | Revisión manual cumplimentada (10 escenarios) | IV |
| `results/` | Salidas del análisis estadístico (n = 100) | IV |
| `piloto_n35/` | Resultados del piloto intermedio (n = 35), conservados como referencia histórica | — |

## Requisitos

- Python ≥ 3.11: `pip install -r requirements.txt`
- R ≥ 4.4 (el script `05_analisis.R` instala automáticamente los paquetes que falten)
- Claves de API de OpenAI, Google y Anthropic, solo si se quieren repetir las llamadas a los modelos. Los resultados ya están incluidos, así que el análisis puede reproducirse sin claves ejecutando únicamente `05_analisis.R`.

## Ejecución

Las claves se definen como variables de entorno y **nunca se escriben en el código**:

```bash
export OPENAI_API_KEY="..."
export GOOGLE_API_KEY="..."
export ANTHROPIC_API_KEY="..."
```

En Windows (PowerShell): `$env:OPENAI_API_KEY="..."`, etc.

```bash
Rscript 00_identificar_candidatos_openFDA.R   # opcional: regenera los candidatos de openFDA
python 01_generar_prompts.py
python 02_llamar_modelos.py
python 04_muestra_revision_manual.py   # después, rellenar a mano revision_manual_muestra.xlsx
python 03_arbitro_claude.py
Rscript 05_analisis.R                  # o abrir pipeline_tfm.Rproj en RStudio y ejecutar el script
```

Los identificadores de modelo pueden cambiarse con las variables de entorno `MODELO_A_ID`, `MODELO_B_ID` y `MODELO_ARBITRO_ID`.

## Notas de reproducibilidad

- `00_identificar_candidatos_openFDA.R` genera los listados de candidatos en `candidatos_openfda/`. Esos candidatos se depuraron, se diversificaron por área terapéutica y se verificaron manualmente en las fichas técnicas (CIMA) y en Drugs.com hasta obtener la plantilla de validación. Como FAERS se actualiza trimestralmente y el script usa una ventana de 5 años hasta la fecha de ejecución, una nueva ejecución dará recuentos algo distintos.

- Los modelos especificados en el diseño original (GPT-4o, Gemini 1.5 Pro y Claude 3.5 Sonnet) habían sido retirados en el momento de la ejecución y se sustituyeron por sus sucesores.
- Las API actuales no permiten fijar `temperature`, y Gemini no aceptó `thinking_config`. El pipeline repite la llamada omitiendo el parámetro y lo registra en el campo `parametros_omitidos_por_incompatibilidad` de cada respuesta, por lo que una nueva ejecución puede no reproducir exactamente las mismas respuestas.
- La edad y el sexo de los prompts son sintéticos (pseudoaleatorios con semilla = identificador del caso). No hay datos de pacientes reales.

## Licencia

Código bajo licencia MIT (ver `LICENSE`). Los datos de FAERS proceden de openFDA (dominio público). Las fichas técnicas citadas son propiedad de sus titulares y se referencian a través de CIMA (AEMPS).
