"""
modelo_arriendo_15d.py
======================

Modelo de probabilidad de que una unidad se arriende ANTES de los 15 días
desde fecha_LPA.

Diseño guiado por van Smeden et al. (2019), "Sample size for binary logistic
prediction models: Beyond events per variable criteria" (Stat Methods Med Res):

  * Se usa LOGÍSTICA CON SHRINKAGE (Ridge / penalización L2) en vez de ML pura.
    En tus celdas por subgrupo aparecían `Singular matrix`, `PerfectSeparation`
    y `overflow in exp`: son exactamente las patologías de muestra chica/dispersa
    (issues 2-4 del paper). El shrinkage mantiene los coeficientes finitos y
    mejora el error de predicción fuera de muestra.
  * Se EVALÚA FUERA DE MUESTRA con validación cruzada: Brier (análogo real del
    rMSPE/MAPE del paper, que requiere la "probabilidad verdadera" simulada),
    AUC (discriminación), pendiente de calibración (CS) y calibración-en-grande
    (CIL). El paper insiste en que el EPV solo no predice el desempeño; se
    reportan N, fracción de eventos, P y EPV solo como contexto.
  * NO se hace backward elimination (el paper muestra que empeora la predicción).
    Si quieres selección de variables, usa Lasso (penalty='l1') cambiando un flag.

Nota causal importante (consistente con lo que ya tenías mapeado):
  `visitas`, `leads` y `reservas` se ACUMULAN durante la ventana de predicción y
  son post-LPA. Para un score que se calcula el día 0 (en LPA) son fuga de
  información / mediadores y NO deben entrar. Por eso el set de features por
  defecto es solo de línea base (lo conocido en LPA). Hay un modo "landmark"
  opcional (FeatureMode.LANDMARK_DIA7) que usa SOLO las visitas de la semana 1
  (días 1-7, ya realizadas) para predecir el arriendo en los días 8-15.

Uso típico en el notebook:

    from modelo_arriendo_15d import entrenar_y_evaluar, predecir_proba

    res = entrenar_y_evaluar(dataframe)          # imprime métricas, devuelve dict
    dataframe['prob_arriendo_15d'] = predecir_proba(res['modelo'], dataframe)
"""

from __future__ import annotations

from dataclasses import dataclass
from enum import Enum

import numpy as np
import pandas as pd

from sklearn.compose import ColumnTransformer
from sklearn.pipeline import Pipeline
from sklearn.preprocessing import StandardScaler, OneHotEncoder
from sklearn.impute import SimpleImputer
from sklearn.linear_model import LogisticRegression
from sklearn.model_selection import StratifiedKFold, cross_val_predict, GridSearchCV
from sklearn.metrics import roc_auc_score, brier_score_loss, log_loss


HORIZONTE_DIAS = 15
MIN_OBS_CELDA = 30        # celdas sector|tipología con menos obs -> "Otras"
SEMILLA = 42


class FeatureMode(str, Enum):
    """Qué información usa el modelo."""
    LPA = "lpa"                 # solo línea base (día 0). Sin fuga. Por defecto.
    LANDMARK_DIA7 = "landmark"  # añade visitas de semana 1 para predecir días 8-15


# ---------------------------------------------------------------------------
# 1. Construcción del target y de las features
# ---------------------------------------------------------------------------
def construir_target(df: pd.DataFrame, horizonte: int = HORIZONTE_DIAS) -> pd.Series:
    """target = 1 si la unidad se arrendó/desactivó en <= `horizonte` días."""
    d = pd.to_numeric(df["days_to_event"], errors="coerce")
    target = (d <= horizonte).astype("float")
    target[d.isna()] = np.nan          # sin fecha de evento -> no se puede etiquetar
    return target


def construir_features(df: pd.DataFrame, modo: FeatureMode = FeatureMode.LPA):
    """
    Devuelve (X, num_cols, cat_cols).

    Variables de LÍNEA BASE (conocidas en LPA):
        mes_LPA, acepta_mascotas, m2_utiles (+sqr),
        piso (+sqr), precio_diezmil, precio_m2_miles (+sqr),
        precio_faltante (indicador), owner_type (si existe), sector_tipo.
    En modo LANDMARK_DIA7 se añade visitas_semana_1 (días 1-7).
    """
    X = pd.DataFrame(index=df.index)

    # --- temporales ---
    lpa = pd.to_datetime(df["fecha_LPA"], errors="coerce")
    X["mes_LPA"] = lpa.dt.month

    # --- estructurales ---
    X["acepta_mascotas"] = pd.to_numeric(df["acepta_mascotas"], errors="coerce")
    m2 = pd.to_numeric(df["m2_utiles"], errors="coerce").replace(0, np.nan)
    X["m2_utiles"] = m2
    X["m2_utiles_sqr"] = m2 ** 2
    piso = pd.to_numeric(df["piso"], errors="coerce")
    X["piso"] = piso
    X["piso_sqr"] = piso ** 2

    # --- precio: indicador de faltante + imputación (válido para PREDICCIÓN) ---
    # Ojo: el faltante es estructural a nivel edificio y está asociado al target,
    # así que el propio indicador es informativo. NO interpretes el coef de precio
    # de forma causal; aquí solo nos interesa predecir.
    precio = pd.to_numeric(df["precio"], errors="coerce").replace(0, np.nan)
    X["precio_faltante"] = precio.isna().astype("float")
    X["precio_diezmil"] = precio / 10_000
    precio_m2_miles = (precio / m2) / 1_000
    X["precio_m2_miles"] = precio_m2_miles
    X["precio_m2_miles_sqr"] = precio_m2_miles ** 2

    # --- owner_type (opcional, puede no venir en la query) ---
    if "owner_type" in df.columns:
        X["owner_type"] = np.where(df["owner_type"] == "new", 1.0, 0.0)

    # --- interacción comuna x tipología con agrupación de celdas chicas ---
    sector_tipo = (
        df["sector_provincia"].astype(str) + " | " + df["nombre_tipologia"].astype(str)
    )
    conteo = sector_tipo.value_counts()
    chicas = conteo[conteo < MIN_OBS_CELDA].index
    X["sector_tipo"] = sector_tipo.where(~sector_tipo.isin(chicas), "Otras")

    # --- modo landmark: visitas de la semana 1 (días 1-7), ya realizadas ---
    if modo == FeatureMode.LANDMARK_DIA7:
        v1 = pd.to_numeric(df.get("visitas_semana_1"), errors="coerce").fillna(0)
        X["visitas_semana_1"] = v1
        X["visitas_semana_1_sqr"] = v1 ** 2

    num_cols = [c for c in X.columns if c != "sector_tipo"]
    cat_cols = ["sector_tipo"]
    return X, num_cols, cat_cols


# ---------------------------------------------------------------------------
# 2. Pipeline de modelo (Ridge logístico con CV interna del penalizador)
# ---------------------------------------------------------------------------
def construir_pipeline(num_cols, cat_cols, penalty: str = "l2") -> GridSearchCV:
    """
    penalty='l2'  -> Ridge logístico (recomendado por el paper: mejor AUC y
                     menor error de predicción de los métodos de shrinkage).
    penalty='l1'  -> Lasso (shrinkage + selección de variables).
    El parámetro de regularización C se elige por CV interna (neg_log_loss),
    vía GridSearchCV (estable entre versiones de scikit-learn).
    """
    pre = ColumnTransformer(
        transformers=[
            ("num", Pipeline([
                ("imp", SimpleImputer(strategy="median")),
                ("sc", StandardScaler()),
            ]), num_cols),
            ("cat", Pipeline([
                ("imp", SimpleImputer(strategy="most_frequent")),
                ("oh", OneHotEncoder(handle_unknown="ignore", drop="first")),
            ]), cat_cols),
        ],
        remainder="drop",
    )

    solver = "liblinear" if penalty == "l1" else "lbfgs"
    base = Pipeline([
        ("pre", pre),
        ("clf", LogisticRegression(penalty=penalty, solver=solver, max_iter=5_000)),
    ])

    grid = GridSearchCV(
        base,
        param_grid={"clf__C": np.logspace(-3, 2, 25)},  # fuerza de penalización
        cv=StratifiedKFold(5, shuffle=True, random_state=SEMILLA),
        scoring="neg_log_loss",
        n_jobs=-1,
        refit=True,
    )
    return grid


# ---------------------------------------------------------------------------
# 3. Métricas de calibración (paper: CS y CIL)
# ---------------------------------------------------------------------------
def _logit(p, eps=1e-12):
    p = np.clip(p, eps, 1 - eps)
    return np.log(p / (1 - p))


def metricas_calibracion(y, p):
    """
    Pendiente de calibración (CS) e intercepto/CIL.
      CS  ~ 1  -> bien calibrado;  CS < 1 sobreajuste;  CS > 1 subajuste.
      CIL = mean(p) - mean(y) ~ 0 -> sin sesgo sistemático en el nivel.
    """
    from sklearn.linear_model import LogisticRegression
    z = _logit(p).reshape(-1, 1)
    cal = LogisticRegression(penalty=None, solver="lbfgs", max_iter=1000).fit(z, y)
    cs = float(cal.coef_[0, 0])
    intercepto = float(cal.intercept_[0])
    cil = float(np.mean(p) - np.mean(y))
    return cs, intercepto, cil


# ---------------------------------------------------------------------------
# 4. Entrenamiento + evaluación fuera de muestra
# ---------------------------------------------------------------------------
@dataclass
class Resultado:
    modelo: Pipeline
    modo: FeatureMode
    metricas: dict
    p_oos: np.ndarray
    y: np.ndarray
    index: pd.Index


def entrenar_y_evaluar(
    df: pd.DataFrame,
    modo: FeatureMode = FeatureMode.LPA,
    penalty: str = "l2",
    horizonte: int = HORIZONTE_DIAS,
    verbose: bool = True,
) -> dict:
    """
    Entrena el modelo y reporta desempeño fuera de muestra (CV anidada:
    cross_val_predict por fuera, selección de C por dentro).
    Devuelve un dict con el modelo final reajustado en todos los datos.
    """
    y_full = construir_target(df, horizonte)
    X_full, num_cols, cat_cols = construir_features(df, modo)

    # muestra utilizable: con etiqueta válida
    mask = y_full.notna()
    if (pd.to_numeric(df["days_to_event"], errors="coerce") < 0).any():
        n_neg = int((pd.to_numeric(df["days_to_event"], errors="coerce") < 0).sum())
        if verbose:
            print(f"[aviso] {n_neg} filas con days_to_event < 0 (evento antes de LPA); "
                  f"se etiquetan como target=1 pero conviene revisarlas en la query.")

    X = X_full[mask].copy()
    y = y_full[mask].astype(int).to_numpy()
    idx = X.index

    pipe = construir_pipeline(num_cols, cat_cols, penalty=penalty)

    # Probabilidades fuera de muestra (CV anidada: el grid de C se elige por
    # dentro, en cada fold de entrenamiento; cada fila se puntúa con un modelo
    # que NO la vio).
    cv_ext = StratifiedKFold(5, shuffle=True, random_state=SEMILLA)
    p_oos = cross_val_predict(
        pipe, X, y, cv=cv_ext, method="predict_proba", n_jobs=-1
    )[:, 1]

    # Modelo final reajustado en todos los datos (para producción)
    pipe.fit(X, y)
    mejor = pipe.best_estimator_

    # nº de parámetros estimados (ancho del diseño) para EPV
    P = mejor.named_steps["pre"].transform(X.iloc[:5]).shape[1]
    eventos = int(min(y.sum(), len(y) - y.sum()))
    epv = eventos / P if P else float("nan")

    cs, cal_int, cil = metricas_calibracion(y, p_oos)
    metr = {
        "n": int(len(y)),
        "fraccion_eventos": float(y.mean()),
        "P_parametros": int(P),
        "EPV": float(epv),
        "AUC": float(roc_auc_score(y, p_oos)),
        "Brier": float(brier_score_loss(y, p_oos)),
        "LogLoss": float(log_loss(y, p_oos)),
        "Calib_slope": cs,
        "Calib_intercept": cal_int,
        "CIL": cil,
        "C_elegido": float(pipe.best_params_["clf__C"]),
    }

    if verbose:
        print(f"=== Modelo P(arriendo <= {horizonte} días) | modo={modo.value} | "
              f"penalty={penalty} ===")
        print(f"n = {metr['n']}   fracción de eventos = {metr['fraccion_eventos']:.3f}   "
              f"P (parámetros) = {metr['P_parametros']}   EPV = {metr['EPV']:.1f}")
        print("--- desempeño fuera de muestra (5-fold CV) ---")
        print(f"AUC               = {metr['AUC']:.4f}   (discriminación; 0.5 = azar)")
        print(f"Brier             = {metr['Brier']:.4f}   (error de predicción; menor mejor)")
        print(f"LogLoss           = {metr['LogLoss']:.4f}")
        print(f"Calib. slope (CS) = {metr['Calib_slope']:.3f}   (~1 ideal; <1 sobreajuste)")
        print(f"Calib. intercept  = {metr['Calib_intercept']:.3f}")
        print(f"CIL               = {metr['CIL']:+.4f}   (~0 ideal; signo = sobre/subestima)")
        print(f"C (1/lambda) medio= {metr['C_elegido']:.4g}")

    return {
        "modelo": pipe,
        "modo": modo,
        "penalty": penalty,
        "horizonte": horizonte,
        "metricas": metr,
        "p_oos": p_oos,
        "y": y,
        "index": idx,
        "num_cols": num_cols,
        "cat_cols": cat_cols,
    }


# ---------------------------------------------------------------------------
# 5. Scoring de nuevas unidades
# ---------------------------------------------------------------------------
def predecir_proba(modelo: Pipeline, df: pd.DataFrame,
                   modo: FeatureMode = FeatureMode.LPA) -> pd.Series:
    """Devuelve P(arriendo <= horizonte) para cada fila de df."""
    X, _, _ = construir_features(df, modo)
    p = modelo.predict_proba(X)[:, 1]
    return pd.Series(p, index=df.index, name="prob_arriendo_15d")


# ---------------------------------------------------------------------------
# 6. Curva de calibración (opcional, para un plot rápido)
# ---------------------------------------------------------------------------
def tabla_calibracion(y, p, bins: int = 10) -> pd.DataFrame:
    """Agrupa por deciles de probabilidad predicha vs. tasa observada."""
    dfc = pd.DataFrame({"p": p, "y": y})
    dfc["bin"] = pd.qcut(dfc["p"], q=bins, duplicates="drop")
    g = dfc.groupby("bin", observed=True).agg(
        p_media=("p", "mean"), tasa_obs=("y", "mean"), n=("y", "size")
    )
    return g.reset_index(drop=True)
