# Comparación de chatbots clínicos en la práctica farmacéutica

Material suplementario del Trabajo de Fin de Máster (Máster en Bioinformática, Universidad Europea, 2026).

* **Autor:** Pedro Juárez Fernández-Falcón
* **Tutor:** Javier Escalera Orobón

Pipeline reproducible que evalúa dos chatbots de IA generativa (`gpt-5.6-sol`, de OpenAI, y `gemini-3.1-pro-preview`, de Google) en 100 escenarios de asesoramiento farmacéutico: 50 contraindicaciones y 50 interacciones medicamentosas. Un tercer modelo (`claude-sonnet-4-5`, de Anthropic) actúa como árbitro (*LLM-as-a-Judge*) y puntúa cada respuesta de 1 a 5 en precisión clínica, seguridad y ausencia de alucinación. La metodología completa está en el capítulo 5 de la memoria.

## Contenido del repositorio

|Fichero / carpeta|Descripción||
|-|-|-|
|`00\_identificar\_candidatos\_openFDA.R`|Consulta la API de openFDA/FAERS y genera los listados de candidatos a contraindicación e interacción (≥ 10 notificaciones graves en 5 años)||
|`plantilla\_validacion\_casos.xlsx`|Dataset de validación: 100 escenarios, fuentes y respuestas de referencia||
|`01\_generar\_prompts.py`|Genera los prompts estandarizados y el ground truth a partir de la plantilla||
|`02\_llamar\_modelos.py`|Consulta los dos modelos evaluados (ejecución reanudable)||
|`03\_arbitro\_claude.py`|Evaluación de cada respuesta por el árbitro con la rúbrica de 3 dimensiones||
|`04\_muestra\_revision\_manual.py`|Genera la muestra estratificada del 10% para la revisión manual||
|`05\_analisis.R`|Estadística descriptiva, Wilcoxon pareado + Bonferroni, tamaño del efecto, concordancia (Kappa ponderado y AC2 de Gwet) y figuras||
|`prompts.json`, `prompts\_preview.xlsx`|Prompts generados||
|`respuestas.json`|Respuestas completas de ambos modelos y metadatos de cada llamada||
|`puntuaciones.json`|Puntuaciones y razonamientos del árbitro||
|`revision\_manual\_muestra.xlsx`|Revisión manual cumplimentada (10 escenarios)||
|`results/`|Salidas del análisis estadístico (n = 100)||
|`piloto\_n35/`|Resultados del piloto intermedio (n = 35), conservados como referencia histórica||

## Requisitos

* Python ≥ 3.11: `pip install -r requirements.txt`
* R ≥ 4.4 (el script `05\_analisis.R` instala automáticamente los paquetes que falten)
* Claves de API de OpenAI, Google y Anthropic, solo si se quieren repetir las llamadas a los modelos. Los resultados ya están incluidos, así que el análisis puede reproducirse sin claves ejecutando únicamente `05\_analisis.R`.

## Ejecución

Las claves se definen como variables de entorno y **nunca se escriben en el código**:

```bash
export OPENAI\_API\_KEY="..."
export GOOGLE\_API\_KEY="..."
export ANTHROPIC\_API\_KEY="..."
```

En Windows (PowerShell): `$env:OPENAI\_API\_KEY="..."`, etc.

```bash
Rscript 00\_identificar\_candidatos\_openFDA.R   # opcional: regenera los candidatos de openFDA
python 01\_generar\_prompts.py
python 02\_llamar\_modelos.py
python 04\_muestra\_revision\_manual.py   # después, rellenar a mano revision\_manual\_muestra.xlsx
python 03\_arbitro\_claude.py
Rscript 05\_analisis.R                  # o abrir pipeline\_tfm.Rproj en RStudio y ejecutar el script
```

Los identificadores de modelo pueden cambiarse con las variables de entorno `MODELO\_A\_ID`, `MODELO\_B\_ID` y `MODELO\_ARBITRO\_ID`.

## Notas de reproducibilidad

* `00\_identificar\_candidatos\_openFDA.R` genera los listados de candidatos en `candidatos\_openfda/`. Esos candidatos se depuraron, se diversificaron por área terapéutica y se verificaron manualmente en las fichas técnicas (CIMA) y en Drugs.com hasta obtener la plantilla de validación. Como FAERS se actualiza trimestralmente y el script usa una ventana de 5 años hasta la fecha de ejecución, una nueva ejecución dará recuentos algo distintos.
* Los modelos especificados en el diseño original (GPT-4o, Gemini 1.5 Pro y Claude 3.5 Sonnet) habían sido retirados en el momento de la ejecución y se sustituyeron por sus sucesores.
* Las API actuales no permiten fijar `temperature`, y Gemini no aceptó `thinking\_config`. El pipeline repite la llamada omitiendo el parámetro y lo registra en el campo `parametros\_omitidos\_por\_incompatibilidad` de cada respuesta, por lo que una nueva ejecución puede no reproducir exactamente las mismas respuestas.
* La edad y el sexo de los prompts son sintéticos (pseudoaleatorios con semilla = identificador del caso). No hay datos de pacientes reales.

## Licencia

Código bajo licencia MIT (ver `LICENSE`). Los datos de FAERS proceden de openFDA (dominio público). Las fichas técnicas citadas son propiedad de sus titulares y se referencian a través de CIMA (AEMPS).

