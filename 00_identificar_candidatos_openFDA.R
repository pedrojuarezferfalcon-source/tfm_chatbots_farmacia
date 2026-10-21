# ============================================================
# TFM - Comparación de Chatbots clínicos en la práctica farmacéutica
# Script: 00_identificar_candidatos_openFDA.R
#
# Objetivo:
#   Identificar, de forma automatizada, candidatos de casos clínicos
#   (interacciones medicamentosas y contraindicaciones) a partir de
#   openFDA/FAERS que cumplan los criterios de inclusión definidos
#   en el apartado 5.3.1 de la Metodología:
#     - >= 10 notificaciones "serious" en los últimos 5 años
#
#   NO sustituye la validación manual del apartado 5.3.3 (ground truth):
#   este script produce una LISTA DE CANDIDATOS que después hay que
#   contrastar con ficha técnica / DrugBank para confirmar que
#   realmente son una interacción o contraindicación documentada.
#
# Autor: Pedro Juárez Fernández-Falcón
# ============================================================

# ---- 0. Paquetes ----
paquetes <- c("httr2", "jsonlite", "dplyr", "purrr", "lubridate", "tidyr")
instalar_si_falta <- paquetes[!paquetes %in% installed.packages()[, "Package"]]
if (length(instalar_si_falta) > 0) install.packages(instalar_si_falta)

library(httr2)
library(jsonlite)
library(dplyr)
library(purrr)
library(lubridate)
library(tidyr)

# ---- 1. Configuración general ----

# Conseguir API key gratuita en https://open.fda.gov/apis/authentication/
# Sin key: 40 peticiones/min, 1000/día. Con key: 240/min, 120000/día.
OPENFDA_API_KEY <- "TU_API_KEY_AQUI"

BASE_URL <- "https://api.fda.gov/drug/event.json"

FECHA_FIN    <- Sys.Date()
FECHA_INICIO <- FECHA_FIN %m-% years(5)
RANGO_FECHAS <- sprintf('[%s TO %s]',
                         format(FECHA_INICIO, "%Y%m%d"),
                         format(FECHA_FIN, "%Y%m%d"))

MIN_NOTIFICACIONES <- 10     # criterio de inclusión, apartado 5.3.1
N_TOP_FARMACOS      <- 40    # nº de fármacos "semilla" a explorar para pares de interacción
LIMITE_REGISTROS_POR_FARMACO <- 200  # muestra de registros por fármaco para minar pares

# Pausa entre llamadas para respetar el rate limit (ajusta si tienes API key)
PAUSA_ENTRE_LLAMADAS <- if (OPENFDA_API_KEY == "TU_API_KEY_AQUI") 1.6 else 0.3

# ---- 2. Función genérica de consulta a openFDA ----
# Devuelve la lista ya parseada (o NULL si no hay resultados / hay error)
consultar_openfda <- function(search_query, limit = 100, skip = 0, count_field = NULL) {

  req <- request(BASE_URL) |>
    req_url_query(search = search_query, limit = limit, skip = skip) |>
    req_error(is_error = function(resp) FALSE)  # gestionamos los errores a mano

  if (!is.null(count_field)) {
    req <- req |> req_url_query(count = count_field)
  }
  if (OPENFDA_API_KEY != "TU_API_KEY_AQUI" && nzchar(OPENFDA_API_KEY)) {
    req <- req |> req_url_query(api_key = OPENFDA_API_KEY)
  }

  resp <- tryCatch(req_perform(req), error = function(e) NULL)
  Sys.sleep(PAUSA_ENTRE_LLAMADAS)

  if (is.null(resp)) return(NULL)

  estado <- resp_status(resp)
  if (estado == 404) return(NULL)   # openFDA devuelve 404 si no hay coincidencias
  if (estado == 429) {
    message("Rate limit alcanzado, esperando 30s...")
    Sys.sleep(30)
    return(consultar_openfda(search_query, limit, skip, count_field))
  }
  if (estado != 200) {
    message("Error HTTP ", estado, " en la consulta: ", search_query)
    return(NULL)
  }

  resp_body_json(resp, simplifyVector = FALSE)
}

# ============================================================
# PARTE A: CANDIDATOS DE CONTRAINDICACIONES
# ============================================================
# Proxy MedDRA: "Product use in condition contraindicated"
# Se agrega directamente por fármaco con el endpoint "count" de openFDA
# (mucho más eficiente que descargar registro a registro).

cat("=== PARTE A: Identificando candidatos de CONTRAINDICACIONES ===\n")

query_contraindicacion <- sprintf(
  'patient.reaction.reactionmeddrapt.exact:"Product use in condition contraindicated" AND serious:1 AND receivedate:%s',
  RANGO_FECHAS
)

resultado_contra <- consultar_openfda(
  search_query = query_contraindicacion,
  count_field  = "patient.drug.medicinalproduct.exact"
)

candidatos_contraindicaciones <- if (!is.null(resultado_contra)) {
  map_dfr(resultado_contra$results, ~ tibble(
    farmaco          = .x$term,
    n_notificaciones = .x$count
  )) |>
    filter(n_notificaciones >= MIN_NOTIFICACIONES) |>
    arrange(desc(n_notificaciones))
} else {
  tibble(farmaco = character(), n_notificaciones = integer())
}

cat("Candidatos de contraindicación encontrados:", nrow(candidatos_contraindicaciones), "\n")

# Para cada fármaco candidato, extraemos una muestra de indicaciones/condiciones
# clínicas asociadas, para tener contexto al redactar el escenario clínico (5.3.2)
obtener_contexto_clinico <- function(farmaco) {
  q <- sprintf(
    'patient.drug.medicinalproduct.exact:"%s" AND patient.reaction.reactionmeddrapt.exact:"Product use in condition contraindicated" AND serious:1 AND receivedate:%s',
    farmaco, RANGO_FECHAS
  )
  res <- consultar_openfda(q, limit = 5)
  if (is.null(res)) return(NA_character_)

  indicaciones <- map(res$results, function(r) {
    drugs <- r$patient$drug
    inds <- map_chr(drugs, ~ .x$drugindication %||% NA_character_)
    inds[!is.na(inds)]
  }) |> unlist() |> unique()

  if (length(indicaciones) == 0) return(NA_character_)
  paste(head(indicaciones, 3), collapse = " | ")
}

if (nrow(candidatos_contraindicaciones) > 0) {
  candidatos_contraindicaciones <- candidatos_contraindicaciones |>
    mutate(condiciones_clinicas_ejemplo = map_chr(farmaco, obtener_contexto_clinico))
}

# ============================================================
# PARTE B: CANDIDATOS DE INTERACCIONES MEDICAMENTOSAS
# ============================================================
# Proxy MedDRA: "Drug interaction"
# openFDA no permite agregar directamente PARES de fármacos, así que:
#   1) Identificamos los fármacos más frecuentes en notificaciones de
#      "Drug interaction" (vía count).
#   2) Para cada uno, descargamos una muestra de registros y extraemos
#      qué otros fármacos aparecen en el mismo informe.
#   3) Contamos la co-ocurrencia de pares y filtramos por el umbral.

cat("\n=== PARTE B: Identificando candidatos de INTERACCIONES ===\n")

query_interaccion_base <- sprintf(
  'patient.reaction.reactionmeddrapt.exact:"Drug interaction" AND serious:1 AND receivedate:%s',
  RANGO_FECHAS
)

resultado_farmacos_interaccion <- consultar_openfda(
  search_query = query_interaccion_base,
  count_field  = "patient.drug.medicinalproduct.exact"
)

farmacos_semilla <- if (!is.null(resultado_farmacos_interaccion)) {
  map_chr(resultado_farmacos_interaccion$results, ~ .x$term) |> head(N_TOP_FARMACOS)
} else {
  character()
}

cat("Fármacos semilla a explorar:", length(farmacos_semilla), "\n")

# Extrae, para un fármaco dado, los pares (fármaco_semilla, fármaco_coreportado)
# a partir de una muestra de notificaciones de "Drug interaction"
extraer_pares_para_farmaco <- function(farmaco) {
  q <- sprintf(
    'patient.drug.medicinalproduct.exact:"%s" AND patient.reaction.reactionmeddrapt.exact:"Drug interaction" AND serious:1 AND receivedate:%s',
    farmaco, RANGO_FECHAS
  )
  res <- consultar_openfda(q, limit = LIMITE_REGISTROS_POR_FARMACO)
  if (is.null(res)) return(tibble(farmaco_a = character(), farmaco_b = character(), safetyreportid = character()))

  map_dfr(res$results, function(r) {
    id <- r$safetyreportid %||% NA_character_
    drugs <- map_chr(r$patient$drug, ~ .x$medicinalproduct %||% NA_character_)
    drugs <- unique(drugs[!is.na(drugs)])
    if (length(drugs) < 2) return(NULL)

    # Todas las combinaciones de pares dentro del mismo informe
    combn(drugs, 2, simplify = FALSE) |>
      map_dfr(~ tibble(farmaco_a = .x[1], farmaco_b = .x[2], safetyreportid = id))
  })
}

pares_brutos <- map_dfr(farmacos_semilla, extraer_pares_para_farmaco)

candidatos_interacciones <- pares_brutos |>
  # Normalizamos el orden del par para no contar A-B y B-A por separado
  mutate(
    par_ordenado_a = pmin(farmaco_a, farmaco_b),
    par_ordenado_b = pmax(farmaco_a, farmaco_b)
  ) |>
  distinct(par_ordenado_a, par_ordenado_b, safetyreportid) |>
  count(par_ordenado_a, par_ordenado_b, name = "n_notificaciones") |>
  filter(n_notificaciones >= MIN_NOTIFICACIONES) |>
  arrange(desc(n_notificaciones)) |>
  rename(farmaco_a = par_ordenado_a, farmaco_b = par_ordenado_b)

cat("Candidatos de interacción encontrados:", nrow(candidatos_interacciones), "\n")

# ============================================================
# PARTE C: EXPORTAR RESULTADOS
# ============================================================

dir.create("candidatos_openfda", showWarnings = FALSE)

write.csv(candidatos_contraindicaciones,
          "candidatos_openfda/candidatos_contraindicaciones.csv",
          row.names = FALSE, fileEncoding = "UTF-8")

write.csv(candidatos_interacciones,
          "candidatos_openfda/candidatos_interacciones.csv",
          row.names = FALSE, fileEncoding = "UTF-8")

cat("\n=== HECHO ===\n")
cat("Revisa manualmente los CSV generados en candidatos_openfda/\n")
cat("Contrasta cada candidato con ficha técnica / DrugBank (apartado 5.3.3)\n")
cat("antes de incorporarlo definitivamente al dataset de 100 escenarios.\n")
