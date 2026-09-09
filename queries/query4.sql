-- ============================================================================
-- Tabla base para el modelo: universo + target a 20 dias + precio ex-ante.
-- ----------------------------------------------------------------------------
-- Esta version NO calcula las features de contexto (comparables, competencia
-- de edificio, historial). Esas se construyen en pandas, en features_contexto.py
-- Por que se saco eso de SQL: las tres necesitan self-joins con ventana movil.
-- Sobre ~5.600 filas eso son decenas de millones de comparaciones intermedias
-- que MySQL materializa en el tmpdir local de la instancia, y ahi aparece el
-- error 1114 "table is full". En pandas, con searchsorted sobre arreglos
-- ordenados, las mismas features son O(n log n) y tardan milisegundos.
-- Sin tablas temporales, sin variables @, sin self-joins, sin ALTER.
-- Para cambiar el horizonte del target: buscar y reemplazar "INTERVAL 20 DAY".
-- ----------------------------------------------------------------------------
-- DURACION DE LA VACANCIA (agregado en esta version)
-- ----------------------------------------------------------------------------
-- El evento que termina la vacancia es el CONTRATO si existe; si no existe pero
-- la unidad fue desactivada, el evento es el churn. Si no ocurrio ninguno de
-- los dos, la unidad sigue en el mercado y NO tiene duracion: tiene una
-- duracion censurada por la derecha.
-- Por eso se entregan cuatro columnas y no una:
--   no_modelo_days_to_event   dias de fecha_LPA al evento. NULL si no hubo.
--   no_modelo_tipo_evento     'arriendo' | 'churn' | 'sin evento'
--   no_modelo_dias_observados dias de fecha_LPA al evento, o a HOY si no hubo.
--                             Nunca es NULL: es el tiempo bajo observacion.
--   no_modelo_censurada       1 = sigue buscando, la duracion real es MAYOR
--                             que dias_observados.
-- El par (dias_observados, censurada) es lo que consume un Kaplan-Meier o un
-- Cox en Python. Usar solo days_to_event y descartar los NULL vuelve a meter
-- el sesgo de seleccion que nos costo encontrar: las unidades mas lentas son
-- justamente las que no tienen evento todavia.
-- Todas van con prefijo no_modelo_ porque miran despues de fecha_LPA y por lo
-- tanto NO pueden entrar como features del clasificador a 20 dias.
-- ============================================================================
WITH lpa AS (
    SELECT property_id, fecha_LPA
    FROM (
        SELECT
            pm.property_id,
            pm.fecha_inicio AS fecha_LPA,
            ROW_NUMBER() OVER (PARTITION BY pm.property_id ORDER BY pm.fecha_inicio) AS rn
        FROM assetplan_rentas.property_state_movements pm
        INNER JOIN assetplan_rentas.estados_vacios ev
                ON ev.id = pm.estado_vacios
        WHERE ev.nombre = 'Lista para arrendar'
    ) t
    WHERE rn = 1 AND fecha_LPA IS NOT NULL
),
ctr AS (
    SELECT
        property_id, inicio_contrato, monto_arriendo,
        CASE WHEN fecha_inicio < inicio_contrato THEN 1 ELSE heredado END AS heredado
    FROM (
        SELECT
            property_id, created_at AS inicio_contrato, fecha_inicio, heredado, monto_arriendo,
            ROW_NUMBER() OVER (PARTITION BY property_id ORDER BY created_at) AS rn
        FROM bi_assetplan.bi_DimContratos
    ) t
    WHERE rn = 1
),
prop AS (
    -- Deduplicacion defensiva por si bi_DimProperties trae mas de una fila por
    -- property_id.
    -- DORMITORIOS, BANOS Y ESTUDIO: la fuente principal es
    -- aa_pmPricingExplainabilityPredictions (CTE `pricing_attrs` mas abajo).
    -- Son atributos fisicos de la unidad, no salidas del modelo, asi que
    -- tomarlos de un snapshot actual NO es fuga temporal: un departamento no
    -- cambia de dormitorios entre su fecha_LPA y hoy. Mismo argumento que ggcc.
    -- Lo que sigue es el RESPALDO, parseado del texto de nombre_tipologia, para
    -- las unidades que no tengan fila en esa tabla. Reglas ajustadas a los
    -- valores reales de la columna (12.309 filas):
    --   1D1B  4.775 | 2D2B 2.524 | 2D1B 2.138 -> patron NdMb, se parsea entero
    --   1D2B     14 |
    --   3D    1.838 -> dormitorios 3, banos DESCONOCIDO por esta via. Es el
    --                  hueco que la columna `baños` de pricing viene a llenar.
    --   Estudio 887 -> dormitorios 0, banos 1. Lo segundo era un supuesto de
    --                  dominio; ahora manda la columna `estudio` de pricing.
    --   Otro     84 |
    --   (vacio)  49 -> ambos NULL.
    --
    -- Cobertura del respaldo por si solo: dormitorios 98,9% | banos 84,0%.
    SELECT
        property_id, unit_id, edificio, comuna, sector_provincia, nombre_tipologia,
        m2_utiles, piso, acepta_mascotas, owner_id, first_time_rented,
        created, fecha_desactivacion,
        dormitorios_tip,
        banos_tip,
        tipologia_origen
    FROM (
        SELECT
            p.property_id, p.unit_id, p.edificio, p.comuna, p.sector_provincia,
            p.nombre_tipologia, p.m2_utiles, p.piso, p.acepta_mascotas, p.owner_id,
            p.first_time_rented, p.created, p.fecha_desactivacion,
            CASE
                WHEN LOWER(TRIM(p.nombre_tipologia)) REGEXP 'studio|estudio|loft' THEN 0
                ELSE CAST(NULLIF(REGEXP_REPLACE(
                        REGEXP_SUBSTR(p.nombre_tipologia, '[0-9]+[[:space:]]*[Dd]'),
                        '[^0-9]', ''), '') AS UNSIGNED)
            END AS dormitorios_tip,
            CASE
                -- Supuesto de dominio, no parseo: un estudio tiene un bano.
                WHEN LOWER(TRIM(p.nombre_tipologia)) REGEXP 'studio|estudio|loft' THEN 1
                ELSE CAST(NULLIF(REGEXP_REPLACE(
                        REGEXP_SUBSTR(p.nombre_tipologia, '[0-9]+[[:space:]]*[Bb]'),
                        '[^0-9]', ''), '') AS UNSIGNED)
            END AS banos_tip,
            CASE
                WHEN LOWER(TRIM(p.nombre_tipologia)) REGEXP 'studio|estudio|loft'
                    THEN 'estudio'
                WHEN p.nombre_tipologia REGEXP '[0-9]+[[:space:]]*[Dd]'
                 AND p.nombre_tipologia REGEXP '[0-9]+[[:space:]]*[Bb]'
                    THEN 'D y B'
                WHEN p.nombre_tipologia REGEXP '[0-9]+[[:space:]]*[Dd]'
                    THEN 'solo D'
                ELSE 'sin info'
            END AS tipologia_origen,
            ROW_NUMBER() OVER (PARTITION BY p.property_id ORDER BY p.created) AS rn
        FROM bi_assetplan.bi_DimProperties p
        WHERE p.unit_type = 'Appartment'
          AND p.mf       = 0
          AND p.pais_id  = 1
          AND p.created >= '2025-01-01'
          AND p.sector_provincia IN (
                'Santiago - Centro', 'Santiago - Surponiente', 'Santiago - Nororiente',
                'Santiago - Sur', 'Santiago - Suroriente', 'Santiago - Norte',
                'Santiago - Norponiente'
              )
    ) t
    WHERE rn = 1
),
uni AS (
    -- Universo elegible + TARGET + fecha del evento.
    -- Sin filtro busqueda_activa: con horizonte fijo, una unidad que lleva 200
    -- dias sin arrendar es un 0 observado, no un dato censurado PARA EL TARGET
    -- BINARIO. Para la duracion continua si esta censurada, y de eso se encargan
    -- las columnas dias_observados / censurada.
    -- Elegibilidad por TIEMPO: solo unidades cuyo resultado a 20 dias ya ocurrio.
    SELECT
        p.property_id, p.unit_id, p.edificio, p.comuna, p.sector_provincia,
        p.nombre_tipologia, p.dormitorios_tip, p.banos_tip, p.tipologia_origen,
        p.m2_utiles, p.piso, p.acepta_mascotas, p.owner_id,
        p.first_time_rented, p.created AS fecha_creacion, p.fecha_desactivacion,
        l.fecha_LPA, c.inicio_contrato, c.monto_arriendo,
        -- Fecha de desactivacion normalizada: la base usa la fecha cero como
        -- "no desactivada", que no es NULL y por lo tanto pasa las comparaciones.
        CASE
            WHEN p.fecha_desactivacion IS NOT NULL
             AND p.fecha_desactivacion > '0000-00-00'
            THEN p.fecha_desactivacion
        END AS fecha_baja,
        -- EVENTO QUE TERMINA LA VACANCIA. El contrato manda; el churn solo
        -- cuenta cuando no hubo contrato. Si no hay ninguno, queda NULL y la
        -- observacion es censurada.
        CASE
            WHEN c.inicio_contrato IS NOT NULL
                THEN c.inicio_contrato
            WHEN p.fecha_desactivacion IS NOT NULL
             AND p.fecha_desactivacion > '0000-00-00'
                THEN p.fecha_desactivacion
        END AS event_date,
        CASE
            WHEN c.inicio_contrato IS NOT NULL
             AND c.inicio_contrato >= l.fecha_LPA
             AND c.inicio_contrato <  DATE_ADD(l.fecha_LPA, INTERVAL 20 DAY)
            THEN 1 ELSE 0
        END AS y,
        CASE
            WHEN c.inicio_contrato IS NOT NULL AND c.inicio_contrato < l.fecha_LPA
            THEN 1 ELSE 0
        END AS flag_contrato_previo_lpa,
        DATEDIFF(l.fecha_LPA, p.created)  AS dias_habilitacion,
        MONTH(l.fecha_LPA)                AS mes_lpa,
        YEAR(l.fecha_LPA)                 AS year_lpa,
        QUARTER(l.fecha_LPA)              AS trimestre_lpa,
        DAYOFWEEK(l.fecha_LPA)            AS dow_lpa,
        DATE_FORMAT(l.fecha_LPA, '%Y-%m') AS cohorte_lpa
    FROM prop p
    INNER JOIN lpa l ON l.property_id = p.property_id
    LEFT  JOIN ctr c ON c.property_id = p.property_id
    WHERE (c.heredado = 0 OR c.heredado IS NULL)
      AND l.fecha_LPA <= DATE_SUB(CURDATE(), INTERVAL 20 DAY)
),
pricing_attrs AS (
    -- Atributos ESTRUCTURALES de la unidad: no cambian en el tiempo, asi que
    -- tomarlos del snapshot actual no introduce fuga.
    -- precio_recomendado_ml y uf_m2 quedan FUERA a proposito: esas si son
    -- salidas del modelo, con fecha posterior al LPA.
    -- La ñ va entre backticks y se aliasa a ASCII (banos) para que el CSV y
    -- pandas no dependan de la codificacion del cliente.
    SELECT property_id, owner_type, ggcc, dormitorios, banos, estudio
    FROM (
        SELECT property_id, owner_type, ggcc, dormitorios,
               `baños` AS banos, estudio,
               ROW_NUMBER() OVER (PARTITION BY property_id
                                  ORDER BY pricing_date DESC, updated_at DESC) AS rn
        FROM bi_assetplan.aa_pmPricingExplainabilityPredictions
    ) t
    WHERE rn = 1
)
SELECT
    u.property_id,
    u.y,
    u.fecha_LPA,
    u.cohorte_lpa,
    u.edificio AS grupo_edificio,
    u.comuna,
    u.sector_provincia,
    u.nombre_tipologia,
    COALESCE(o.dormitorios, u.dormitorios_tip)        AS dormitorios,
    COALESCE(o.banos,       u.banos_tip)              AS banos,
    -- Flag propio de la tabla de pricing. El respaldo lee 'Estudio' del texto.
    COALESCE(o.estudio,
             CASE WHEN u.tipologia_origen = 'estudio' THEN 1 ELSE 0 END)
                                                      AS estudio,
    -- De donde salio cada valor. Util como categoria y como QA.
    CASE
        WHEN o.dormitorios IS NOT NULL THEN 'pricing'
        WHEN u.dormitorios_tip IS NOT NULL THEN 'tipologia'
        ELSE 'sin dato'
    END                                               AS origen_dormitorios,
    CASE
        WHEN o.banos IS NOT NULL THEN 'pricing'
        WHEN u.banos_tip IS NOT NULL THEN 'tipologia'
        ELSE 'sin dato'
    END                                               AS origen_banos,
    -- Discrepancia entre las dos fuentes donde ambas existen. Deberia ser 0.
    CASE
        WHEN o.dormitorios IS NOT NULL AND u.dormitorios_tip IS NOT NULL
         AND o.dormitorios <> u.dormitorios_tip THEN 1
        WHEN o.banos IS NOT NULL AND u.banos_tip IS NOT NULL
         AND o.banos <> u.banos_tip THEN 1
        -- estudio segun pricing pero la tipologia dice otra cosa, o al reves.
        -- El CASE interno evita depender de que estudio venga como 0/1 exacto.
        WHEN o.estudio IS NOT NULL
         AND (o.estudio <> 0) <> (u.tipologia_origen = 'estudio') THEN 1
        ELSE 0
    END                                               AS flag_discrepancia_tipologia,
    u.tipologia_origen,
    u.acepta_mascotas,
    u.first_time_rented,
    o.owner_type,
    u.mes_lpa,
    u.year_lpa,
    u.trimestre_lpa,
    u.dow_lpa,
    u.m2_utiles,
    ROUND(u.m2_utiles / NULLIF(COALESCE(o.dormitorios, u.dormitorios_tip), 0), 1)
                                                      AS m2_por_dormitorio,
    u.piso,
    u.dias_habilitacion,
    o.ggcc,
    -- Precio vigente AL SALIR A LPA. Solo registros anteriores o iguales a
    -- fecha_LPA: nada de mirar hacia adelante dentro de la ventana del target.
    (SELECT hp.monto_depto
       FROM assetplan_rentas.historical_pricing hp
      WHERE hp.property_id = u.property_id
        AND hp.monto_depto BETWEEN 150000 AND 2500000
        AND hp.created_at <= u.fecha_LPA
      ORDER BY hp.created_at DESC
      LIMIT 1) AS precio_lpa,
    (SELECT COUNT(*)
       FROM assetplan_rentas.historical_pricing hp
      WHERE hp.property_id = u.property_id
        AND hp.monto_depto BETWEEN 150000 AND 2500000
        AND hp.created_at <= u.fecha_LPA) AS n_registros_precio,
    -- =====================================================================
    -- DURACION DE LA VACANCIA. Todas no_modelo_: miran despues de fecha_LPA.
    -- =====================================================================
    -- Dias hasta el evento que termino la vacancia (contrato o churn).
    -- NULL cuando la unidad sigue en el mercado.
    DATEDIFF(u.event_date, u.fecha_LPA)               AS no_modelo_days_to_event,
    CASE
        WHEN u.inicio_contrato IS NOT NULL THEN 'arriendo'
        WHEN u.fecha_baja      IS NOT NULL THEN 'churn'
        ELSE 'sin evento'
    END                                               AS no_modelo_tipo_evento,
    -- Tiempo bajo observacion: al evento, o a HOY si todavia no hubo. Nunca
    -- NULL. Este es el que va al analisis de supervivencia, junto al flag.
    DATEDIFF(COALESCE(u.event_date, CURDATE()), u.fecha_LPA)
                                                      AS no_modelo_dias_observados,
    CASE WHEN u.event_date IS NULL THEN 1 ELSE 0 END  AS no_modelo_censurada,
    -- Duraciones negativas: el evento ocurrio ANTES del LPA. Son datos
    -- inconsistentes, no vacancias cortas. Hay que excluirlas o corregirlas
    -- antes de modelar la duracion; el target binario no las toca porque
    -- exige inicio_contrato >= fecha_LPA.
    CASE
        WHEN u.event_date IS NOT NULL AND u.event_date < u.fecha_LPA
        THEN 1 ELSE 0
    END                                               AS flag_evento_previo_lpa,
    -- Churn posterior a un arriendo: la unidad se arrendo y despues salio del
    -- inventario. Es normal, pero conviene poder identificarlo.
    CASE
        WHEN u.inicio_contrato IS NOT NULL AND u.fecha_baja IS NOT NULL
        THEN DATEDIFF(u.fecha_baja, u.inicio_contrato)
    END                                               AS no_modelo_dias_contrato_a_baja,
    -- Resto de columnas de diagnostico
    u.inicio_contrato                     AS no_modelo_inicio_contrato,
    u.fecha_baja                          AS no_modelo_fecha_baja,
    u.monto_arriendo                      AS no_modelo_monto_arriendo,
    u.flag_contrato_previo_lpa,
    CASE
        WHEN u.y = 1                       THEN 'arrendo <= 20d'
        WHEN u.inicio_contrato IS NOT NULL THEN 'arrendo despues de 20d'
        WHEN u.fecha_baja      IS NOT NULL THEN 'desactivada sin arrendar'
        ELSE 'sigue buscando'
    END                                   AS no_modelo_desenlace
FROM uni u
LEFT JOIN pricing_attrs o ON o.property_id = u.property_id
ORDER BY u.fecha_LPA, u.property_id;
-- ============================================================================
-- Verificaciones, sobre el resultado exportado:
--   SELECT COUNT(*), COUNT(DISTINCT property_id), AVG(y)   -> tasa base 25-30%
--   GROUP BY no_modelo_desenlace                           -> de donde salen los 0
--   GROUP BY no_modelo_tipo_evento                         -> mezcla de eventos
--   AVG(no_modelo_censurada)                               -> % aun en mercado
--   SUM(flag_evento_previo_lpa)                            -> deberia ser bajo
--   SUM(flag_discrepancia_tipologia)                       -> deberia ser 0
--   GROUP BY origen_dormitorios, origen_banos              -> de donde salio cada uno
--   GROUP BY cohorte_lpa                                   -> deriva temporal
--
-- Consistencia que debe cumplirse siempre:
--   no_modelo_tipo_evento = 'sin evento'  <=>  no_modelo_censurada = 1
--                                         <=>  no_modelo_days_to_event IS NULL
--   SELECT no_modelo_tipo_evento, no_modelo_censurada, COUNT(*),
--          SUM(no_modelo_days_to_event IS NULL) AS sin_duracion
--   FROM (<query>) q GROUP BY 1, 2;
-- ============================================================================