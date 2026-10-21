"""
02_llamar_modelos.py
=====================
TFM - Comparación de Chatbots clínicos en la práctica farmacéutica

Ejecuta, para cada prompt generado en el paso 1, llamadas independientes
(sin memoria conversacional) a las APIs de dos modelos evaluados.

NOTA IMPORTANTE (piloto intermedio, 09/2026): la memoria especifica GPT-4o
y Gemini 1.5 Pro, pero AMBOS han sido retirados por sus proveedores (GPT-4o
sin acceso por API desde feb-2026; Gemini 1.5 Pro ya no figura en la tabla
de precios de Google). Este script usa por defecto sus sucesores actuales:
  - gpt-5.6-sol (OpenAI)         -> variable MODELO_A_ID
  - gemini-3.1-pro-preview (Google) -> variable MODELO_B_ID
Verifica en la documentación oficial de cada proveedor si estos IDs siguen
vigentes en el momento en que ejecutes el script (los nombres de modelo
cambian con frecuencia); si no, ajusta las variables de entorno
MODELO_A_ID / MODELO_B_ID sin tocar el resto del código. Esta sustitución
debe documentarse como nota metodológica en la memoria (5.1/5.5.1).

Parámetros fijados en la memoria (5.5.1): temperature = 0.0, top_p = 1.0,
max_tokens = 800.

NOTA IMPORTANTE #2 (piloto intermedio, detectada tras revisar respuestas.json
del alumno): tanto gpt-5.6-sol como gemini-3.1-pro-preview son modelos "de
razonamiento": generan una cadena de pensamiento interna ANTES de la
respuesta visible, y ese razonamiento consume del MISMO presupuesto de
tokens que max_tokens/max_output_tokens. Con 800 tokens, en Gemini el
razonamiento se comía casi todo el presupuesto y dejaba solo ~30 tokens
para la respuesta visible (frases cortadas a media oración); en GPT
ocasionalmente vaciaba también la respuesta. Es un comportamiento del
proveedor, no de este script ni del prompt.
Para que el piloto sea utilizable, este script usa un presupuesto de
tokens MAYOR que el 5.5.1 (ver MAX_TOKENS_A / MAX_TOKENS_B más abajo,
ajustables por variable de entorno) y, para Gemini, pide un nivel de
razonamiento bajo cuando el SDK lo soporta. Esta desviación debe
documentarse en la memoria junto a la nota de sustitución de modelos.

Guarda las respuestas en formato JSON con la estructura descrita en 5.5.2:
id de caso, categoría, prompt, respuesta modelo A, respuesta modelo B,
respuesta de referencia (ground truth) y metadatos de la llamada.

REQUISITOS (instalar antes de ejecutar):
    pip install openai google-generativeai

VARIABLES DE ENTORNO NECESARIAS:
    export OPENAI_API_KEY="sk-..."
    export GOOGLE_API_KEY="..."

USO:
    python 02_llamar_modelos.py
"""

import json
import os
import time
from datetime import datetime, timezone
from pathlib import Path

IN_JSON = Path(__file__).parent / "prompts.json"
OUT_JSON = Path(__file__).parent / "respuestas.json"

# --- Configuración de modelos ---
# Por defecto se usan los sucesores actuales de GPT-4o y Gemini 1.5 Pro
# (ambos retirados por sus proveedores). Ver nota al inicio del fichero.
MODELO_A = os.environ.get("MODELO_A_ID", "gpt-5.6-sol")
MODELO_B = os.environ.get("MODELO_B_ID", "gemini-3.1-pro-preview")
TEMPERATURE = 0.0
TOP_P = 1.0

# Presupuesto de tokens por modelo. La memoria (5.5.1) fija 800 para ambos,
# pero estos modelos "piensan" internamente dentro de ese mismo presupuesto
# (ver nota arriba), así que se sube para dejar sitio a una respuesta visible
# completa. Ajustables por variable de entorno si hace falta más margen.
MAX_TOKENS_A = int(os.environ.get("MAX_TOKENS_A", "1600"))
MAX_TOKENS_B = int(os.environ.get("MAX_TOKENS_B", "4000"))

CONTROL_CALIDAD_MIN_TOKENS = 50  # apartado 5.5.3 (i)

SYSTEM_PROMPT = (
    "Eres un asistente de información farmacéutica. Responde a la consulta "
    "del farmacéutico de forma clara, profesional y clínicamente prudente."
)


def contar_tokens_aprox(texto: str) -> int:
    # aproximación simple (no requiere tokenizer específico); suficiente para
    # el control de calidad de longitud mínima del apartado 5.5.3
    return len(texto.split())


def llamar_gpt4o(prompt: str) -> dict:
    from openai import OpenAI

    client = OpenAI(api_key=os.environ["OPENAI_API_KEY"])
    t0 = time.time()

    # NOTA: los modelos actuales de OpenAI (sucesores de gpt-4o) ya no
    # aceptan "max_tokens" en /chat/completions (piden "max_completion_tokens"),
    # y algunos modelos nuevos tampoco aceptan "temperature"/"top_p" con
    # valores distintos del por defecto. En vez de fallar directamente, si la
    # API rechaza alguno de estos parámetros lo quitamos y reintentamos, para
    # que el pipeline no se rompa cada vez que OpenAI cambia su API.
    kwargs = {
        "model": MODELO_A,
        "messages": [
            {"role": "system", "content": SYSTEM_PROMPT},
            {"role": "user", "content": prompt},
        ],
        "temperature": TEMPERATURE,
        "top_p": TOP_P,
        "max_completion_tokens": MAX_TOKENS_A,
    }

    parametros_omitidos = []
    for intento in range(4):
        try:
            resp = client.chat.completions.create(**kwargs)
            break
        except Exception as e:
            mensaje = str(e)
            quitado = False
            for parametro in ("temperature", "top_p", "max_completion_tokens"):
                if parametro in mensaje and parametro in kwargs:
                    del kwargs[parametro]
                    parametros_omitidos.append(parametro)
                    quitado = True
                    break
            if not quitado:
                raise
    else:
        raise RuntimeError(f"No se pudo llamar a {MODELO_A} tras varios reintentos")

    texto = resp.choices[0].message.content
    resultado = {
        "texto": texto,
        "modelo": MODELO_A,
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "latencia_s": round(time.time() - t0, 2),
        "tokens_completado": getattr(resp.usage, "completion_tokens", None),
        "tokens_prompt": getattr(resp.usage, "prompt_tokens", None),
    }
    if parametros_omitidos:
        resultado["parametros_omitidos_por_incompatibilidad"] = parametros_omitidos
        print(f"    (aviso: {MODELO_A} no acepta {parametros_omitidos}, se omitieron)")
    return resultado


def llamar_gemini(prompt: str) -> dict:
    import google.generativeai as genai

    genai.configure(api_key=os.environ["GOOGLE_API_KEY"])
    model = genai.GenerativeModel(MODELO_B, system_instruction=SYSTEM_PROMPT)
    t0 = time.time()

    # gemini-3.x razona internamente ("thinking") antes de responder, y ese
    # razonamiento cuenta dentro de max_output_tokens (ver nota al inicio del
    # fichero). Intentamos pedir un nivel de razonamiento bajo para dejar más
    # margen a la respuesta visible; si el SDK instalado no reconoce ese
    # parámetro (versión antigua de google-generativeai), lo quitamos y
    # confiamos solo en el presupuesto ampliado (MAX_TOKENS_B).
    config_kwargs = {
        "temperature": TEMPERATURE,
        "top_p": TOP_P,
        "max_output_tokens": MAX_TOKENS_B,
        "thinking_config": {"thinking_level": "low"},
    }

    parametros_omitidos = []
    resp = None
    for _ in range(4):
        try:
            resp = model.generate_content(
                prompt,
                generation_config=genai.types.GenerationConfig(**config_kwargs),
            )
            break
        except TypeError as e:
            # el SDK local no reconoce ese parámetro del constructor
            mensaje = str(e)
            quitado = False
            for parametro in ("thinking_config", "top_p", "temperature"):
                if parametro in mensaje and parametro in config_kwargs:
                    del config_kwargs[parametro]
                    parametros_omitidos.append(parametro)
                    quitado = True
                    break
            if not quitado:
                raise
        except Exception as e:
            # la API (no el SDK local) rechaza el parámetro
            mensaje = str(e)
            quitado = False
            for parametro in ("thinking_config", "thinking_level", "top_p", "temperature"):
                if parametro in mensaje and "thinking_config" in config_kwargs:
                    del config_kwargs["thinking_config"]
                    parametros_omitidos.append("thinking_config")
                    quitado = True
                    break
            if not quitado:
                raise
    if resp is None:
        raise RuntimeError(f"No se pudo llamar a {MODELO_B} tras varios reintentos")

    # Si aun así la respuesta viene vacía o muy corta (thinking agotó el
    # presupuesto igualmente), lo dejamos constar explícitamente en vez de
    # devolver texto vacío sin más explicación.
    try:
        texto = resp.text
    except Exception:
        texto = None

    finish_reason = None
    try:
        finish_reason = resp.candidates[0].finish_reason.name
    except Exception:
        pass

    usage = getattr(resp, "usage_metadata", None)
    resultado = {
        "texto": texto,
        "modelo": MODELO_B,
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "latencia_s": round(time.time() - t0, 2),
        "tokens_completado": getattr(usage, "candidates_token_count", None) if usage else None,
        "tokens_pensamiento": getattr(usage, "thoughts_token_count", None) if usage else None,
        "tokens_prompt": getattr(usage, "prompt_token_count", None) if usage else None,
        "finish_reason": finish_reason,
    }
    if parametros_omitidos:
        resultado["parametros_omitidos_por_incompatibilidad"] = parametros_omitidos
        print(f"    (aviso: {MODELO_B} no acepta {parametros_omitidos}, se omitieron)")
    if finish_reason == "MAX_TOKENS" and (not texto or len(texto.split()) < CONTROL_CALIDAD_MIN_TOKENS):
        print(f"    (aviso: {MODELO_B} agotó max_output_tokens={MAX_TOKENS_B} sin completar la respuesta; "
              f"sube MAX_TOKENS_B si esto se repite mucho)")
    return resultado


def main():
    casos = json.loads(IN_JSON.read_text(encoding="utf-8"))

    if OUT_JSON.exists():
        resultados_previos = json.loads(OUT_JSON.read_text(encoding="utf-8"))
        # Un caso solo cuenta como "hecho" si AMBOS modelos respondieron sin
        # error; si alguno falló (p.ej. el error de max_tokens visto antes),
        # se descarta ese registro y se reintenta el caso completo al
        # relanzar el script, en vez de quedarse "atascado" para siempre.
        resultados = []
        ya_hechos = set()
        reintentar = 0
        for r in resultados_previos:
            texto_a = r.get("respuesta_modelo_A", {}).get("texto")
            texto_b = r.get("respuesta_modelo_B", {}).get("texto")
            # Se exige además la longitud mínima del control de calidad
            # 5.5.3(i): así, las respuestas cortadas a ~30 tokens por el
            # bug de "thinking" (ver nota al inicio del fichero) no cuentan
            # como "hechas" y se reintentan automáticamente al relanzar,
            # aunque no estén vacías del todo.
            ok_a = bool(texto_a) and contar_tokens_aprox(texto_a) >= CONTROL_CALIDAD_MIN_TOKENS
            ok_b = bool(texto_b) and contar_tokens_aprox(texto_b) >= CONTROL_CALIDAD_MIN_TOKENS
            if ok_a and ok_b:
                resultados.append(r)
                ya_hechos.add(r["id_caso"])
            else:
                reintentar += 1
        print(f"Reanudando: {len(ya_hechos)} casos completos, {reintentar} para reintentar")
    else:
        resultados = []
        ya_hechos = set()

    alertas_calidad = []

    for i, caso in enumerate(casos, 1):
        if caso["id_caso"] in ya_hechos:
            continue

        print(f"[{i}/{len(casos)}] Caso {caso['id_caso']} ({caso['categoria']}) ...")

        try:
            resp_a = llamar_gpt4o(caso["prompt"])
        except Exception as e:
            print(f"  ERROR GPT-4o: {e}")
            resp_a = {"texto": None, "modelo": MODELO_A, "error": str(e)}

        try:
            resp_b = llamar_gemini(caso["prompt"])
        except Exception as e:
            print(f"  ERROR Gemini: {e}")
            resp_b = {"texto": None, "modelo": MODELO_B, "error": str(e)}

        # Control de calidad 5.5.3(i): longitud mínima
        for etiqueta, r in (("A", resp_a), ("B", resp_b)):
            if r.get("texto") and contar_tokens_aprox(r["texto"]) < CONTROL_CALIDAD_MIN_TOKENS:
                alertas_calidad.append((caso["id_caso"], etiqueta))
                print(f"  AVISO: respuesta {etiqueta} muy corta (<{CONTROL_CALIDAD_MIN_TOKENS} tokens aprox.)")

        resultados.append(
            {
                "id_caso": caso["id_caso"],
                "categoria": caso["categoria"],
                "prompt": caso["prompt"],
                "ground_truth": caso["ground_truth"],
                "respuesta_modelo_A": resp_a,
                "respuesta_modelo_B": resp_b,
                "url_o_referencia": caso.get("url_o_referencia"),
            }
        )

        # guardado incremental por si se corta la ejecución a mitad
        OUT_JSON.write_text(json.dumps(resultados, ensure_ascii=False, indent=2), encoding="utf-8")

    print(f"\nCompletado. {len(resultados)} casos guardados en {OUT_JSON}")
    if alertas_calidad:
        print(f"\nATENCION: {len(alertas_calidad)} respuestas marcadas por posible longitud insuficiente:")
        for id_caso, etiqueta in alertas_calidad:
            print(f"  - Caso {id_caso}, modelo {etiqueta}")


if __name__ == "__main__":
    for var in ("OPENAI_API_KEY", "GOOGLE_API_KEY"):
        if not os.environ.get(var):
            raise SystemExit(f"Falta la variable de entorno {var}. Ejemplo: export {var}='...'")
    main()
