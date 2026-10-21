# ============================================================
# 05_analisis.R
# TFM - Comparación de Chatbots clínicos en la práctica farmacéutica
#
# Implementa el apartado 5.6 de la memoria sobre el DATASET FINAL
# (n=100: 50 contraindicaciones + 50 interacciones).
#
# Entradas:
#   - puntuaciones.json           (salida de 03_arbitro_claude.py)
#   - revision_manual_muestra.xlsx (rellenada a mano, para el Kappa)
#
# Salidas (carpeta results/):
#   - descriptivos.csv
#   - boxplot_puntuacion_total.png
#   - radar_perfil_modelos.png
#   - heatmap_errores_por_categoria.png
#   - puntos_medias_ic95.png
#   - test_wilcoxon.csv
#   - kappa_arbitro.txt
# ============================================================

paquetes <- c("jsonlite", "dplyr", "tidyr", "ggplot2", "fmsb", "rstatix", "irr", "readxl")
instalar_si_falta <- paquetes[!paquetes %in% installed.packages()[, "Package"]]
if (length(instalar_si_falta) > 0) install.packages(instalar_si_falta)

library(jsonlite)
library(dplyr)
library(tidyr)
library(ggplot2)
library(fmsb)
library(rstatix)
library(irr)
library(readxl)

dir.create("results", showWarnings = FALSE)

# ---- 1. Cargar puntuaciones del árbitro ----
raw <- fromJSON("puntuaciones.json", simplifyDataFrame = FALSE)

# Los nombres reales de los modelos A y B (p.ej. "gpt-5.6-sol",
# "gemini-3.1-pro-preview") se guardan por caso en respuestas.json, no en
# puntuaciones.json. Los recuperamos de ahí en vez de escribirlos a mano
# aquí, para que el script no quede desfasado la próxima vez que cambien
# los modelos evaluados (ya ha pasado una vez: GPT-4o y Gemini 1.5 Pro
# fueron retirados durante este mismo piloto).
ruta_respuestas <- "respuestas.json"
if (file.exists(ruta_respuestas)) {
  respuestas_raw <- fromJSON(ruta_respuestas, simplifyDataFrame = FALSE)
  MODELO_A_LABEL <- respuestas_raw[[1]]$respuesta_modelo_A$modelo
  MODELO_B_LABEL <- respuestas_raw[[1]]$respuesta_modelo_B$modelo
  if (is.null(MODELO_A_LABEL)) MODELO_A_LABEL <- "Modelo A"
  if (is.null(MODELO_B_LABEL)) MODELO_B_LABEL <- "Modelo B"
} else {
  message("AVISO: no se encontró respuestas.json; no se pueden recuperar los ",
          "nombres reales de los modelos. Se usan etiquetas genéricas.")
  MODELO_A_LABEL <- "Modelo A"
  MODELO_B_LABEL <- "Modelo B"
}
cat("Etiquetas de modelo usadas en los resultados: ", MODELO_A_LABEL, " / ", MODELO_B_LABEL, "\n", sep = "")

extraer_fila <- function(caso, modelo_key, modelo_label) {
  ev <- caso[[modelo_key]]
  p <- ev$puntuaciones
  if (is.null(p)) return(NULL)
  data.frame(
    id_caso = caso$id_caso,
    categoria = caso$categoria,
    modelo = modelo_label,
    precision_clinica = p$precision_clinica$puntuacion,
    seguridad = p$seguridad$puntuacion,
    ausencia_alucinacion = p$ausencia_alucinacion$puntuacion
  )
}

filas <- list()
for (caso in raw) {
  filas[[length(filas) + 1]] <- extraer_fila(caso, "evaluacion_modelo_A", MODELO_A_LABEL)
  filas[[length(filas) + 1]] <- extraer_fila(caso, "evaluacion_modelo_B", MODELO_B_LABEL)
}
df <- bind_rows(filas) %>%
  mutate(puntuacion_total = precision_clinica + seguridad + ausencia_alucinacion)

cat("Casos cargados:", nrow(df) / 2, "(por modelo:", nrow(df), "filas)\n")

# ---- 2. Estadística descriptiva (5.6.1) ----
descriptivos <- df %>%
  pivot_longer(cols = c(precision_clinica, seguridad, ausencia_alucinacion, puntuacion_total),
               names_to = "dimension", values_to = "puntuacion") %>%
  group_by(modelo, dimension) %>%
  summarise(
    media = mean(puntuacion, na.rm = TRUE),
    sd = sd(puntuacion, na.rm = TRUE),
    mediana = median(puntuacion, na.rm = TRUE),
    IQR = IQR(puntuacion, na.rm = TRUE),
    n = sum(!is.na(puntuacion)),
    .groups = "drop"
  )
print(descriptivos)
write.csv(descriptivos, "results/descriptivos.csv", row.names = FALSE)

# Boxplot comparativo de puntuación total
p_box <- ggplot(df, aes(x = modelo, y = puntuacion_total, fill = modelo)) +
  geom_boxplot() +
  labs(title = "Puntuación total por modelo (n = 100 casos)",
       subtitle = "Rango posible: 3-15",
       x = NULL, y = "Puntuación total") +
  theme_minimal()
ggsave("results/boxplot_puntuacion_total.png", p_box, width = 7, height = 5, dpi = 150)

# ---- 3. Comparación entre modelos: Wilcoxon pareado + Bonferroni (5.6.2) ----
df_wide <- df %>%
  select(id_caso, modelo, precision_clinica, seguridad, ausencia_alucinacion) %>%
  pivot_longer(cols = c(precision_clinica, seguridad, ausencia_alucinacion),
               names_to = "dimension", values_to = "puntuacion") %>%
  pivot_wider(names_from = modelo, values_from = puntuacion)

resultados_wilcox <- df_wide %>%
  group_by(dimension) %>%
  summarise(
    n_pares = sum(!is.na(.data[[MODELO_A_LABEL]]) & !is.na(.data[[MODELO_B_LABEL]])),
    p_valor = tryCatch(
      wilcox.test(.data[[MODELO_A_LABEL]], .data[[MODELO_B_LABEL]], paired = TRUE, exact = FALSE)$p.value,
      error = function(e) NA_real_
    ),
    .groups = "drop"
  ) %>%
  mutate(p_ajustado_bonferroni = p.adjust(p_valor, method = "bonferroni"))

# Tamaño del efecto (r de Rosenthal) con rstatix, si hay suficientes datos
efecto <- tryCatch({
  df_wide %>%
    pivot_longer(cols = c(all_of(MODELO_A_LABEL), all_of(MODELO_B_LABEL)), names_to = "modelo", values_to = "puntuacion") %>%
    group_by(dimension) %>%
    wilcox_effsize(puntuacion ~ modelo, paired = TRUE)
}, error = function(e) {
  message("rstatix no pudo calcular el tamaño del efecto (", e$message, "); se calcula r = |Z|/sqrt(N) a partir del p-valor")
  resultados_tmp <- df_wide %>% group_by(dimension) %>%
    summarise(n = sum(!is.na(.data[[MODELO_A_LABEL]]) & !is.na(.data[[MODELO_B_LABEL]])),
              p = wilcox.test(.data[[MODELO_A_LABEL]], .data[[MODELO_B_LABEL]], paired = TRUE, exact = FALSE)$p.value,
              .groups = "drop") %>%
    mutate(r_rosenthal = abs(qnorm(p / 2)) / sqrt(n))
  resultados_tmp
})

print(resultados_wilcox)
write.csv(resultados_wilcox, "results/test_wilcoxon.csv", row.names = FALSE)
if (!is.null(efecto)) write.csv(efecto, "results/tamano_efecto_rosenthal.csv", row.names = FALSE)


# ---- 4. Análisis por categoría clínica (5.6.4) ----
comparacion_categoria <- df %>%
  group_by(modelo) %>%
  do({
    tryCatch({
      test <- wilcox.test(puntuacion_total ~ categoria, data = ., exact = FALSE)
      data.frame(p_valor = test$p.value)
    }, error = function(e) data.frame(p_valor = NA_real_))
  })
print(comparacion_categoria)
write.csv(comparacion_categoria, "results/comparacion_por_categoria.csv", row.names = FALSE)

# ---- 5. Visualizaciones adicionales (5.6.5) ----

# Radar chart: perfil medio por dimensión y modelo
radar_data <- descriptivos %>%
  filter(dimension != "puntuacion_total") %>%
  select(modelo, dimension, media) %>%
  pivot_wider(names_from = dimension, values_from = media)

radar_df <- as.data.frame(radar_data[,-1])
rownames(radar_df) <- radar_data$modelo
radar_df <- rbind(rep(5, ncol(radar_df)), rep(1, ncol(radar_df)), radar_df)

png("results/radar_perfil_modelos.png", width = 900, height = 800, res = 150)
radarchart(radar_df, axistype = 1,
           pcol = c("#2b8cbe", "#e34a33"), plwd = 2,
           title = "Perfil medio por dimensión (n = 100)")
legend("topright", legend = rownames(radar_df)[-c(1,2)], col = c("#2b8cbe", "#e34a33"), lty = 1, lwd = 2, bty = "n")
dev.off()

# Heatmap: puntuación total media por categoría y modelo
heat_data <- df %>%
  group_by(modelo, categoria) %>%
  summarise(media_total = mean(puntuacion_total, na.rm = TRUE), .groups = "drop")

p_heat <- ggplot(heat_data, aes(x = categoria, y = modelo, fill = media_total)) +
  geom_tile() +
  geom_text(aes(label = round(media_total, 2)), color = "white") +
  scale_fill_gradient(low = "#d73027", high = "#1a9850", limits = c(3, 15)) +
  labs(title = "Puntuación total media por categoría y modelo",
       x = NULL, y = NULL, fill = "Puntuación\nmedia") +
  theme_minimal()
ggsave("results/heatmap_errores_por_categoria.png", p_heat, width = 7.5, height = 4.5, dpi = 150)

# Puntos con IC95%
puntos_ic <- df %>%
  pivot_longer(cols = c(precision_clinica, seguridad, ausencia_alucinacion),
               names_to = "dimension", values_to = "puntuacion") %>%
  group_by(modelo, dimension) %>%
  summarise(
    media = mean(puntuacion, na.rm = TRUE),
    se = sd(puntuacion, na.rm = TRUE) / sqrt(sum(!is.na(puntuacion))),
    .groups = "drop"
  ) %>%
  mutate(ic_inf = media - 1.96 * se, ic_sup = media + 1.96 * se)

p_ic <- ggplot(puntos_ic, aes(x = dimension, y = media, color = modelo)) +
  geom_point(position = position_dodge(width = 0.3), size = 3) +
  geom_errorbar(aes(ymin = ic_inf, ymax = ic_sup), width = 0.15,
                position = position_dodge(width = 0.3)) +
  labs(title = "Puntuación media por dimensión con IC95% (n = 100)",
       x = NULL, y = "Puntuación (1-5)") +
  theme_minimal()
ggsave("results/puntos_medias_ic95.png", p_ic, width = 7, height = 5, dpi = 150)

# ---- 6. Concordancia del árbitro: Kappa ponderado de Cohen (5.6.3) ----
ruta_manual <- "revision_manual_muestra.xlsx"
if (file.exists(ruta_manual)) {
  manual <- read_excel(ruta_manual)
  manual_completa <- manual %>% filter(!is.na(precision_clinica_A))

  if (nrow(manual_completa) > 0) {
    sink("results/kappa_arbitro.txt")
    for (dim_manual in c("precision_clinica", "seguridad", "alucinacion")) {
      for (modelo_letra in c("A", "B")) {
        col_manual <- paste0(dim_manual, "_", modelo_letra)
        dim_json <- if (dim_manual == "alucinacion") "ausencia_alucinacion" else dim_manual
        modelo_json <- if (modelo_letra == "A") MODELO_A_LABEL else MODELO_B_LABEL

        comparables <- df %>%
          filter(modelo == modelo_json, id_caso %in% manual_completa$id_caso) %>%
          select(id_caso, arbitro = all_of(dim_json)) %>%
          inner_join(manual_completa %>% select(id_caso, humano = all_of(col_manual)), by = "id_caso")

        if (nrow(comparables) >= 3) {
          k <- tryCatch(
            kappa2(comparables[, c("arbitro", "humano")], weight = "equal"),
            error = function(e) NULL
          )
          cat(sprintf("\n%s (%s): n=%d\n", dim_manual, modelo_json, nrow(comparables)))
          if (!is.null(k)) {
            cat(sprintf("  Kappa ponderado = %.3f (p=%.4f)\n", k$value, k$p.value))
          } else {
            cat("  No se pudo calcular (verificar variabilidad de las puntuaciones)\n")
          }
        }
      }
    }
    # ---- Concordancia global (todas las dimensiones y modelos juntos) ----
    # Con casi todas las puntuaciones en 5, el Kappa por dimensión no es
    # interpretable (paradoja de la prevalencia: Feinstein y Cicchetti, 1990).
    # Se añade el acuerdo observado y el coeficiente AC2 de Gwet (pesos lineales),
    # robusto a esa paradoja (Gwet, 2008).
    pares <- list()
    for (dim_manual in c("precision_clinica", "seguridad", "alucinacion")) {
      for (modelo_letra in c("A", "B")) {
        dim_json <- if (dim_manual == "alucinacion") "ausencia_alucinacion" else dim_manual
        modelo_json <- if (modelo_letra == "A") MODELO_A_LABEL else MODELO_B_LABEL
        pares[[length(pares) + 1]] <- df %>%
          filter(modelo == modelo_json, id_caso %in% manual_completa$id_caso) %>%
          select(id_caso, arbitro = all_of(dim_json)) %>%
          inner_join(manual_completa %>% select(id_caso, humano = all_of(paste0(dim_manual, "_", modelo_letra))), by = "id_caso")
      }
    }
    todo <- bind_rows(pares) %>% mutate(arbitro = as.integer(arbitro), humano = as.integer(humano))
    n_tot <- nrow(todo)
    acuerdo_exacto <- mean(todo$arbitro == todo$humano)
    acuerdo_1 <- mean(abs(todo$arbitro - todo$humano) <= 1)
    q <- 5; cats <- 1:5
    w <- 1 - abs(outer(cats, cats, "-")) / (q - 1)
    pa <- mean(w[cbind(todo$humano, todo$arbitro)])
    pik <- sapply(cats, function(k) (sum(todo$humano == k) + sum(todo$arbitro == k)) / (2 * n_tot))
    pe <- sum(w) / (q * (q - 1)) * sum(pik * (1 - pik))
    ac2 <- (pa - pe) / (1 - pe)
    k_glob <- tryCatch(kappa2(todo[, c("arbitro", "humano")], weight = "equal"), error = function(e) NULL)
    cat("\n=== CONCORDANCIA GLOBAL (", n_tot, " pares árbitro-humano) ===\n", sep = "")
    cat(sprintf("  Acuerdo exacto: %.1f%%\n", 100 * acuerdo_exacto))
    cat(sprintf("  Acuerdo +/-1 punto: %.1f%%\n", 100 * acuerdo_1))
    cat(sprintf("  AC2 de Gwet (pesos lineales): %.3f\n", ac2))
    if (!is.null(k_glob)) cat(sprintf("  Kappa ponderado global: %.3f (no interpretable por la paradoja de la prevalencia)\n", k_glob$value))
    cat("  Distribución humano:  ", paste(table(factor(todo$humano, levels = 1:5)), collapse = " "), "(1..5)\n")
    cat("  Distribución árbitro: ", paste(table(factor(todo$arbitro, levels = 1:5)), collapse = " "), "(1..5)\n")
    sink()
    cat("Kappa calculado -> results/kappa_arbitro.txt\n")
  } else {
    cat("\nAVISO: 'revision_manual_muestra.xlsx' existe pero está sin rellenar.\n")
    cat("Complétalo (columnas *_A y *_B, 1-5) para poder calcular el Kappa.\n")
  }
} else {
  cat("\nAVISO: no se encontró revision_manual_muestra.xlsx.\n")
  cat("Ejecuta antes 04_muestra_revision_manual.py y rellénalo a mano\n")
  cat("para poder calcular la concordancia del árbitro (apartado 5.6.3).\n")
}

cat("\n=== Análisis completado. Revisa la carpeta results/ ===\n")
