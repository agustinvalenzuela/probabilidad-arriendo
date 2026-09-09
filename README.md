# probabilidad-arriendo

Modelo de **velocidad de colocación** de unidades de arriendo: para cada unidad publicada,
estima la probabilidad de que **pase de 20 días** sin arrendarse y su posición relativa
dentro de la cartera.

El entregable no es un pronóstico de días. Es una **alerta de unidad lenta**: una probabilidad
calibrada y un decil de riesgo con los que priorizar la cola de trabajo comercial.

---

## Resultado en una línea

| Modelo | Cuándo se calcula | AUC@20 (validación *forward*) |
|---|---|---|
| Baseline (tabla dinámica comuna × tipología) | — | 0,586 |
| Día 0 · gap hedónico | al publicar la unidad | 0,681 |
| **Día 7 · demanda observada + gap** | una semana después | **0,722** ← desplegado |

El salto lo aporta la **demanda de la primera semana** (+0,094 de AUC). El gap de precio, dentro
del modelo del día 7, aporta +0,003. La lectura honesta es que el modelo desplegado **no es una
herramienta de pricing: es una alerta**. Lo que sabe es que una unidad que en su primera semana
no generó visitas se va a demorar.

Todas las cifras vienen de **validación forward por cohorte** (entrenar con el pasado, predecir
el mes siguiente). El mismo modelo daba AUC 0,767 con CV aleatoria y 0,731 con `GroupKFold` por
edificio; los 0,062 de diferencia son fuga entre unidades del mismo edificio más deriva
temporal. Se reporta siempre el forward.

---

## Cómo funciona

Arquitectura de **dos etapas**, siguiendo a Andersson (JSAI 2025):

1. **Precio de referencia hedónico.** Un modelo predice `log(precio_oferta)` desde los
   atributos de la unidad (m², dormitorios, baños, piso, gastos comunes, tipología, comuna,
   barrio, edificio). El residuo es el **gap hedónico**:

   ```
   gap = log(precio publicado) − log(precio esperado para esta unidad)
   ```

   Positivo = la unidad está publicada por encima de lo que sus atributos justifican.
   El motor (Ridge o gradient boosting) se elige por **MAPE fuera de pliegue del propio
   precio**, nunca por lo que rinde después en velocidad. Se reajusta **dentro de cada fold**:
   ajustarlo sobre todos los datos sería fuga.

2. **Modelo de duración AFT log-normal.**

   ```
   log T = Xβ + σ·ε,   ε ~ N(0,1)   ⟹   P(T ≤ h) = Φ((log h − Xβ) / σ)
   ```

   La censura entra en la verosimilitud: una unidad todavía en mercado aporta `P(T > t)`, lo
   que permite usar las ~740 filas censuradas que un OLS tendría que botar (el OLS ingenuo
   predice **24,4 días menos** que el AFT). Un solo ajuste entrega la curva completa para
   cualquier horizonte.

3. **Recalibración de Platt**, estimada también hacia adelante. Sin ella las pendientes de
   calibración quedaban entre 0,487 y 0,725: el score servía para ordenar, pero el número no se
   podía publicar como probabilidad.

**Geografía anidada.** 72 comunas → 241 barrios → 1.766 edificios se codifican con un target
encoder **jerárquico**: cada nivel se encoge hacia su padre, no hacia la media global. Con ~2
observaciones por edificio, hacia qué media se encoge es la decisión que importa.

**El churn no es censura.** El desenlace tiene tres estados —`arriendo`, `churn` (baja
definitiva) y `sigue`—. El churn es un desenlace observado y **negativo**; tratarlo como "aún no
sabemos" infla la probabilidad de arriendo justo en los segmentos lentos.

### La restricción que define el diseño

El ML de pricing interno **no emite recomendación ex-ante**: el 96,1% de `precio_ml_expost` se
calculó después del hecho, con 82,7% de cobertura. Al puntuar una unidad el día que se publica
ese número no existe, así que `gap_centrado`, `log_ratio_ml`, `ratio_ml` y `precio_ml_expost`
están **prohibidos** en el pipeline productivo (hay un `assert` que lo verifica). El gap
hedónico es el reemplazo construido en casa, con cobertura completa y sin depender de nadie.

---

## Qué devuelve

`ScorerArriendo.predecir(df)` entrega cuatro columnas:

| columna | qué es | cómo se usa |
|---|---|---|
| `p_lento_20d` | probabilidad calibrada de **pasar** de 20 días | el número que se muestra |
| `decil_riesgo` | 1 = más rápida, 10 = más lenta | ordena la cola de trabajo |
| `dias_p50` | mediana predicha | **solo diagnóstico interno** |
| `dias_p10`, `dias_p90` | intervalo del 80% | acompaña siempre a `dias_p50` |

**Regla de uso: se publica probabilidad y decil, nunca un día.** Con σ = 1,335 el intervalo
p10–p90 abarca un factor de ~5×, y el error absoluto mediano en días es ~20 contra una mediana
de 29. El modelo **ordena bien y estima días mal**, y eso no es corregible: el techo del
C-index para este tipo de dato ronda 0,66–0,71 porque el desenlace *es* una espera aleatoria.

Interpretación: `p_lento_20d = 0,72` significa que, entre las unidades con ese score, alrededor
de 72 de cada 100 pasan de 20 días sin colocarse. El decil 10 concentra las más lentas:
intervenir ahí en lugar de al azar reduce ~4× las intervenciones que caen sobre unidades que se
habrían arrendado igual.

---

## Estructura del repositorio

```
├── modelo_productivo.ipynb          ← el pipeline desplegable (11 pasos)
├── modelo_arriendo_final_1.ipynb    ← cuaderno de investigación (18 pasos)
├── analisis_variables_final.ipynb   ← análisis exploratorio de variables
├── diagnostico_gap_ml.ipynb         ← diagnóstico del gap del ML de pricing
├── data_arriendo.ipynb              ← exploración inicial de los datos
├── modelo arriendo.py               ← prototipo previo (logística ridge a 15 días)
├── utils.py                         ← Engine SQLAlchemy + loader de queries
├── queries/                         ← SQL de extracción
├── econometria_arriendo_v2.tex/.pdf ← nota metodológica formal
├── scorer_arriendo.joblib           ← artefacto entrenado
└── requirements.txt
```

### Los cuadernos, en orden

| Cuaderno | Qué hace |
|---|---|
| `data_arriendo.ipynb` | Primera exploración: grano, cobertura, qué tablas sirven. |
| `diagnostico_gap_ml.ipynb` | ¿El gap del ML de pricing mueve el tiempo de colocación? Prueba el supuesto que después obliga a construir el gap hedónico. |
| `analisis_variables_final.ipynb` | Inventario y peaje de exclusiones, univariado, bivariado, precio, demanda y ventana landmark, deriva temporal, colinealidad. No entrena nada. |
| `modelo_arriendo_final_1.ipynb` | Compara cuatro familias (logística ridge, AFT log-normal, hazard discreto con riesgos competitivos, cota superior no lineal), elige el horizonte con datos, mide el techo y hace ablaciones. Conclusión: el gradient boosting no le gana al lineal (+0,003 de AUC, y pierde en C-index e IBS). |
| `modelo_productivo.ipynb` | **No compara nada.** Toma esas conclusiones y construye los dos modelos desplegables, con validación forward, recalibración, artefacto serializado, panel de monitoreo y una sección para puntuar una unidad que todavía no se publica. |

### Las queries

`queries/query_analisis_final_v2.sql` es **la query vigente**: una sola sentencia, un
`property_id` por fila, 8.440 filas × 93 columnas. Reemplaza a `query.sql`, `query2.sql`,
`query3.sql`, `query4.sql` y a las versiones `_limpio`, que se conservan como historial.

El filtro que hace posible todo lo demás es `p.created >= '2025-07-01'`:
`property_publication_metrics` arranca el 2025-07-23, y con el universo anterior había cohortes
enteras cuyas visitas eran cero por ausencia de tabla, no por ausencia de demanda. Alineando el
universo con la cobertura de la fuente, un cero en visitas vuelve a significar lo que dice — y
de paso las tres tablas de eventos se pueden podar por fecha antes de cualquier join.

---

## Cómo correrlo

```bash
git clone https://github.com/agustinvalenzuela/probabilidad-arriendo.git
cd probabilidad-arriendo

python -m venv .venv && source .venv/bin/activate    # Windows: .venv\Scripts\activate
pip install -r requirements.txt

cp .env.example .env      # y completar las credenciales
```

`.env`:

```
DATABASE_USERNAME=...
DATABASE_PASSWORD=...
DATABASE_HOST=...
DATABASE_NAME=assetplan_rentas
```

`utils.py` levanta el engine (`Engine()`), URL-encodea la contraseña y expone
`load_sql_query("archivo.sql")`, que lee desde `queries/`. Después:

```python
from utils import Engine, load_sql_query
import pandas as pd

engine = Engine()
df = pd.read_sql(load_sql_query("query_analisis_final_v2.sql"), engine.engine)
```

Y se abre `modelo_productivo.ipynb`, que corre de punta a punta (~20 s la extracción).

**Sobre `scorer_arriendo.joblib`:** `joblib` serializa **por referencia a la clase**. Para
cargarlo fuera del cuaderno, `ScorerArriendo`, `PrecioReferencia` y `TargetEncoderJerarquico`
tienen que estar en un módulo importable. Moverlas a un `.py` es el paso pendiente para
desplegar sin el notebook.

---

## Monitoreo y reentrenamiento

La validación forward **es** el backtest de producción: cada mes que cierra se convierte en un
fold de test nuevo. No hay que construir nada aparte.

- **Reentrenar mensualmente.** La deriva está medida: las visitas de la primera semana se mueven
  entre 4,7 y 13,3 por cohorte. Un modelo congelado se degrada.
- **Alarma automática** si el AUC de la cohorte nueva cae bajo el baseline de la tabla dinámica
  (0,586). Dos meses seguidos = el modelo dejó de aportar.
- **Revisar la calibración cada vez.** Es lo primero que se rompe cuando cambia la mezcla de
  cartera, y se arregla reajustando Platt sin tocar el modelo.
- **Cobertura.** ~9% de las unidades que llegan a LPA no tienen historial de precio y no se
  pueden puntuar. Necesitan una regla de *fallback* explícita, no un `NaN` silencioso.
- Un salto en `sd(gap_hedonico)` indica que cambió la política de precios: hay que reajustar el
  referente antes que el modelo.

---

## Lo que el modelo NO es

**No es causal.** El gap hedónico mide asociación entre precio relativo y velocidad, con el
precio fijado por un proceso que mira la misma información que predice la velocidad — la
endogeneidad que Stein (1993) formaliza. **Bajar el precio de una unidad no produce
necesariamente el cambio de velocidad que el coeficiente sugiere.** Para afirmar eso haría falta
variación exógena de precios, o sea un experimento.

**No predice días.** Probabilidad y decil, nunca un número de días suelto.

**No aplica a todo el stock.** Cubre unidades que llegan a LPA con historial de precio: ~91% de
las que llegan a LPA, y algo más de la mitad del universo. Además, 1.733 unidades llegaron a
"Arrendado" sin pasar nunca por "Lista para arrendar" —entraron ya ocupadas o asignadas sin
ciclo de publicación— y quedan fuera por definición.

**Es más débil justo donde más se lo querría:** para un edificio nuevo sin historial, el target
encoding cae al promedio global.

---

## Pendientes conocidos

1. **`piso = 0`** en el 30,8% de la muestra, y es la única variable con signo invertido. Si es
   "sin dato", el modelo está aprendiendo ruido con forma de planta baja. Se resuelve
   preguntando a quien mantiene `bi_DimProperties`, no con estadística.
2. **Primera vs. última reserva.** El 6,0% de las arrendadas tiene dos o más reservas antes del
   contrato; usar la última atrasa el cierre 18 días de mediana. Es una línea en el `CASE` de
   `event_date`.
3. **El centrado del gap** está arreglado en pandas, no en la query. Quien use la query sin el
   cuaderno lee la columna mala.
4. **Nombre de la columna de salida:** `ScorerArriendo.predecir` la emite como `p_rapido_20d`
   mientras el resto del cuaderno y esta documentación la leen como `p_lento_20d`. Unificar
   antes de exportar el scorer a un módulo.
5. **Lo que subiría el techo** (el cuaderno de investigación muestra que estamos al 87% del
   máximo alcanzable con esta información, así que no hay ganancia en cambiar de modelo):
   orientación, vista y un `piso` confiable —los tres ausentes de `bi_DimProperties`— y una
   medida de *tightness* real (visitas por unidad disponible en el barrio, en vez de contar
   solo unidades).

---

## Documentación metodológica

`econometria_arriendo_v2.pdf` es la nota formal: especificación AFT log-normal, efectos
marginales sobre días y sobre la probabilidad publicada, verosimilitud censurada, y el
**inventario completo de sesgos** —siete corregidos dentro del modelo y tres que quedan vivos—.
Los dos sesgos vivos que afectan al coeficiente de precio atenúan hacia cero, de modo que la
estimación es plausiblemente una **cota inferior** del efecto del sobreprecio. Muestra de
estimación: n = 3.889 unidades en 14 cohortes mensuales, σ̂ = 1,335.

Incluye el tratamiento del **regresor generado**: el gap hedónico no es un dato observado sino
el residuo de un modelo estimado con la misma muestra, lo que rompe dos cosas distintas —la
varianza de la segunda etapa (bootstrap de dos etapas, por edificio) y el sesgo de atenuación
por error de medición (razón de confiabilidad λ̂ identificada con la dispersión del propio
bootstrap)—. El bootstrap **no** corrige la atenuación; son remedios separados.

### Referencias

- Andersson (JSAI 2025) — arquitectura de dos etapas, precio esperado y desviación relativa.
- Allen, Rutherford & Thomson (2009) — elasticidad del sobreprecio sobre el tiempo de venta.
- Stein (1993) — endogeneidad del precio de lista.
- Díaz & Jerez (2010) — búsqueda competitiva: el precio actúa a través de las visitas.
- van Smeden et al. (2019) — tamaño de muestra y *shrinkage* en modelos logísticos.
- Gdakowicz & Putek-Szeląg (2025) — atributos significativos dentro de un mismo conjunto habitacional.
- Pagan (1984) — regresores generados.

---

Proyecto interno **Assetplan** · *Predicción de tiempo de arriendo*
