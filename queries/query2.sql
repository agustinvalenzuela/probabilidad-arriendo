-- ============================================================================
-- Precio de OFERTA del primer arriendo vs. precio recomendado ML
-- Grano: 1 fila por property_id (primer LPA -> primer evento: contrato o churn)
-- ----------------------------------------------------------------------------
-- Cambio principal vs. el query original:
--   publicacion_precio (1 precio elegido por cercania a fecha_LPA) se reemplaza
--   por interseccion de intervalos:
--       ventana [fecha_LPA, event_date)  x  is_publishable = 1  x  tramos de precio
--   ponderando por dias de exposicion real.
--
-- Se producen 3 precios por unidad, cada uno para un uso distinto:
--   precio_oferta_inicial  -> ex-ante, limpio. Para EVALUAR el ML / predecir.
--   precio_ponderado_pub   -> descriptivo. "a que precio estuvo en el mercado".
--   precio_oferta_final    -> comportamiento. Cuanto tuvo que ceder.
--
-- Se corrigen ademas 4 bugs del original que sesgaban la muestra de precios
-- (marcados con [FIX] mas abajo). Ver seccion CHECKS al final.
-- ============================================================================

WITH state_move AS (
    -- Primer periodo "Lista para arrendar" de cada property
    SELECT property_id, fecha_LPA, rn, state
    FROM (
        SELECT
            pm.property_id,
            pm.fecha_inicio AS fecha_LPA,
            ROW_NUMBER() OVER (PARTITION BY pm.property_id ORDER BY pm.fecha_inicio) AS rn,
            ev.nombre AS state
        FROM assetplan_rentas.property_state_movements AS pm
        INNER JOIN assetplan_rentas.estados_vacios AS ev
                ON pm.estado_vacios = ev.id
        WHERE ev.nombre = 'Lista para arrendar'
    ) t
    WHERE rn = 1
),
props_base AS (
    SELECT
        pb.property_id,
        pb.unit_id,
        pb.created,
        pb.acepta_mascotas,
        pb.m2_utiles,
        pb.piso,
        pb.edificio,
        pb.comuna,
        pb.sector_provincia,
        pb.nombre_tipologia,
        sm.fecha_LPA,
        sm.state,
        pb.first_time_rented,
        pb.fecha_desactivacion,
        pb.actual_activa,
        pb.ha_sido_arrendada,
        pb.owner_id,
        pb.monto_depto,
        sm.rn
    FROM bi_assetplan.bi_DimProperties pb
    LEFT JOIN state_move sm
           ON pb.property_id = sm.property_id
    WHERE pb.unit_type = 'Appartment'
      AND pb.mf       = 0
      AND pb.pais_id  = 1
      AND pb.created >= '2025-01-01'
      AND pb.sector_provincia IN (
            'Santiago - Centro', 'Santiago - Surponiente', 'Santiago - Nororiente',
            'Santiago - Sur', 'Santiago - Suroriente', 'Santiago - Norte', 'Santiago - Norponiente'
          )
),
primer_contrato AS (
    SELECT
        property_id,
        renter_id,
        inicio_contrato,
        fecha_inicio,
        monto_arriendo,
        CASE
            WHEN fecha_inicio < inicio_contrato THEN 1
            ELSE heredado
        END AS heredado
    FROM (
        SELECT
            property_id,
            renter_id,
            created_at AS inicio_contrato,
            fecha_inicio,
            heredado,
            monto_arriendo,
            ROW_NUMBER() OVER (
                PARTITION BY property_id
                ORDER BY created_at
            ) AS rn
        FROM bi_assetplan.bi_DimContratos
    ) t
    WHERE rn = 1
),
churn_logic AS (
    SELECT
        pb.property_id,
        pb.unit_id,
        pb.created,
        pb.acepta_mascotas,
        pb.m2_utiles,
        pb.piso,
        pb.edificio,
        pb.comuna,
        pb.sector_provincia,
        pb.nombre_tipologia,
        pb.fecha_LPA,
        pb.first_time_rented,
        pc.inicio_contrato,
        pc.monto_arriendo,
        pb.fecha_desactivacion,
        CASE
            WHEN pb.fecha_desactivacion > '0000-00-00'
             AND pc.inicio_contrato IS NULL
                THEN 1
            ELSE 0
        END AS churn,
        CASE
            WHEN pb.fecha_desactivacion > '0000-00-00'
             AND pc.inicio_contrato IS NULL
                THEN pb.fecha_desactivacion
            ELSE pc.inicio_contrato
        END AS event_date,
        pb.actual_activa,
        pb.ha_sido_arrendada,
        pb.owner_id,
        pb.monto_depto,
        pc.renter_id,
        pc.heredado,
        CASE
            WHEN pb.fecha_desactivacion = '0000-00-00'
             AND pc.inicio_contrato IS NULL
                THEN 1
            ELSE 0
        END AS busqueda_activa
    FROM props_base pb
    LEFT JOIN primer_contrato pc
           ON pb.property_id = pc.property_id
),
previonatalia AS (
    SELECT DISTINCT
        *,
        DATEDIFF(event_date, fecha_LPA) AS days_to_event
    FROM churn_logic
    WHERE (heredado = 0 OR heredado IS NULL)
      AND busqueda_activa = 0
),
-- ---------------------------------------------------------------------------
-- VISITAS
-- [FIX 1] Se agrega el limite inferior v.date_from >= pr.fecha_LPA. Sin el,
--         cualquier visita ANTERIOR al LPA caia en el bucket visitas_semana_1
--         (porque date_from <= fecha_LPA + 7 tambien es cierto para fechas previas).
-- [FIX 2] Se usa < event_date (no <=), consistente con el CTE de leads.
-- [FIX 3] INNER JOIN explicito: el LEFT JOIN original ya se comportaba como
--         INNER por el predicado en el WHERE. Se hace visible la intencion.
-- ---------------------------------------------------------------------------
visitas AS (
    SELECT
        v.property_id,
        DATE(v.date_from)    AS observation_date,
        SUM(v.visits_amount) AS visitas_pi_dia,
        CASE
            WHEN v.date_from <= DATE_ADD(pr.fecha_LPA, INTERVAL  7 DAY) THEN 'visitas_semana_1'
            WHEN v.date_from <= DATE_ADD(pr.fecha_LPA, INTERVAL 14 DAY) THEN 'visitas_semana_2'
            WHEN v.date_from <= DATE_ADD(pr.fecha_LPA, INTERVAL 21 DAY) THEN 'visitas_semana_3'
            WHEN v.date_from <= DATE_ADD(pr.fecha_LPA, INTERVAL 28 DAY) THEN 'visitas_semana_4'
            WHEN v.date_from <= DATE_ADD(pr.fecha_LPA, INTERVAL 35 DAY) THEN 'visitas_semana_5'
            WHEN v.date_from <= DATE_ADD(pr.fecha_LPA, INTERVAL 42 DAY) THEN 'visitas_semana_6'
            WHEN v.date_from <= DATE_ADD(pr.fecha_LPA, INTERVAL 49 DAY) THEN 'visitas_semana_7'
            WHEN v.date_from <= DATE_ADD(pr.fecha_LPA, INTERVAL 56 DAY) THEN 'visitas_semana_8'
            ELSE 'visitas_semana_9mas'
        END AS visits
    FROM assetplan_rentas.property_publication_metrics v
    INNER JOIN previonatalia pr
            ON v.property_id = pr.property_id
    WHERE v.date_from >= '2025-05-05'
      AND v.property_id > 0
      AND v.date_from >= pr.fecha_LPA
      AND v.date_from <  pr.event_date
    GROUP BY v.property_id, DATE(v.date_from), visits
),
visitas_agg AS (
    -- Pivot de visitas a nivel property. Reemplaza el GROUP BY gigante del
    -- CTE postvisitas original.
    SELECT
        property_id,
        SUM(CASE WHEN visits = 'visitas_semana_1'    THEN visitas_pi_dia END) AS visitas_semana_1,
        SUM(CASE WHEN visits = 'visitas_semana_2'    THEN visitas_pi_dia END) AS visitas_semana_2,
        SUM(CASE WHEN visits = 'visitas_semana_3'    THEN visitas_pi_dia END) AS visitas_semana_3,
        SUM(CASE WHEN visits = 'visitas_semana_4'    THEN visitas_pi_dia END) AS visitas_semana_4,
        SUM(CASE WHEN visits = 'visitas_semana_5'    THEN visitas_pi_dia END) AS visitas_semana_5,
        SUM(CASE WHEN visits = 'visitas_semana_6'    THEN visitas_pi_dia END) AS visitas_semana_6,
        SUM(CASE WHEN visits = 'visitas_semana_7'    THEN visitas_pi_dia END) AS visitas_semana_7,
        SUM(CASE WHEN visits = 'visitas_semana_8'    THEN visitas_pi_dia END) AS visitas_semana_8,
        SUM(CASE WHEN visits = 'visitas_semana_9mas' THEN visitas_pi_dia END) AS visitas_semana_9mas,
        MIN(observation_date)            AS first_visit_obs,
        MAX(observation_date)            AS last_visit_obs,
        COUNT(DISTINCT observation_date) AS dias_con_observacion
    FROM visitas
    GROUP BY property_id
),
-- ---------------------------------------------------------------------------
-- [FIX 4] Direccion del join invertida. El original hacia
--         FROM visitas v LEFT JOIN previonatalia pr, lo que ELIMINABA toda
--         property sin registros de visita. Como postvisitas es la base de
--         todo lo que viene despues (incluido el precio), eso introducia un
--         sesgo de seleccion justo en las unidades que menos se publicaron.
--         Ahora previonatalia es la tabla base y las visitas se agregan.
-- ---------------------------------------------------------------------------
postvisitas AS (
    SELECT
        pr.*,
        COALESCE(va.visitas_semana_1,    0) AS visitas_semana_1,
        COALESCE(va.visitas_semana_2,    0) AS visitas_semana_2,
        COALESCE(va.visitas_semana_3,    0) AS visitas_semana_3,
        COALESCE(va.visitas_semana_4,    0) AS visitas_semana_4,
        COALESCE(va.visitas_semana_5,    0) AS visitas_semana_5,
        COALESCE(va.visitas_semana_6,    0) AS visitas_semana_6,
        COALESCE(va.visitas_semana_7,    0) AS visitas_semana_7,
        COALESCE(va.visitas_semana_8,    0) AS visitas_semana_8,
        COALESCE(va.visitas_semana_9mas, 0) AS visitas_semana_9mas,
        va.first_visit_obs,
        va.last_visit_obs,
        COALESCE(va.dias_con_observacion, 0) AS dias_con_observacion,
        CASE WHEN va.property_id IS NULL THEN 1 ELSE 0 END AS sin_datos_visitas
    FROM previonatalia pr
    LEFT JOIN visitas_agg va
           ON va.property_id = pr.property_id
    WHERE pr.property_id > 0
),
reservas AS (
    SELECT
        r.property_id,
        COUNT(DISTINCT r.reserva_id) AS reservas
    FROM bi_assetplan.bi_DimReservas r
    INNER JOIN postvisitas pn
            ON pn.property_id = r.property_id
           AND r.fecha >= pn.fecha_LPA        -- limite inferior, faltaba en el original
           AND r.fecha <  pn.event_date
    GROUP BY r.property_id
),
leads AS (
    SELECT
        dla.property_id,
        COUNT(DISTINCT dla.lead_id) AS leads
    FROM bi_assetplan.bi_DimLeadAttemps dla
    INNER JOIN postvisitas pn
            ON pn.property_id  = dla.property_id
           AND dla.created_at >= pn.fecha_LPA
           AND dla.created_at <  pn.event_date
    GROUP BY dla.property_id
),
ventana AS (
    -- La ventana de oferta que llevo al primer arriendo (o al churn).
    -- Se excluyen ventanas invalidas (evento anterior o igual al LPA); ver CHECK A.
    SELECT
        pn.property_id,
        pn.fecha_LPA  AS win_inicio,
        pn.event_date AS win_fin
    FROM postvisitas pn
    WHERE pn.fecha_LPA  IS NOT NULL
      AND pn.event_date IS NOT NULL
      AND pn.event_date > pn.fecha_LPA
),
publicado_periods AS (
    -- Vigencia de is_publishable segun el log de cambios.
    -- OJO: si el log solo registra cambios y no existe fila inicial, el estado
    -- previo al primer registro es invisible. Ver CHECK B.
    SELECT
        property_id,
        is_publishable,
        created_at AS fecha_desde,
        COALESCE(
            LEAD(created_at) OVER (PARTITION BY property_id ORDER BY created_at),
            NOW()
        ) AS fecha_hasta
    FROM assetplan_rentas.property_publishable_history
),
publicado_activo AS (
    SELECT property_id, fecha_desde, fecha_hasta
    FROM publicado_periods
    WHERE is_publishable = 1
      AND fecha_hasta > fecha_desde
),
ventana_publicada AS (
    -- Interseccion 1: ventana de oferta  x  tramos publicables
    SELECT
        w.property_id,
        GREATEST(w.win_inicio, pub.fecha_desde) AS pub_inicio,
        LEAST(w.win_fin,       pub.fecha_hasta) AS pub_fin
    FROM ventana w
    INNER JOIN publicado_activo pub
            ON pub.property_id  = w.property_id
           AND pub.fecha_desde  < w.win_fin
           AND pub.fecha_hasta  > w.win_inicio
),
pricing_periods AS (
    -- Vigencia de cada precio: desde su created_at hasta el created_at siguiente.
    -- El filtro monto_depto > 1 se aplica ANTES del LEAD, por lo que un registro
    -- "sin precio" no abre un hueco: extiende la vigencia del precio anterior.
    SELECT
        property_id,
        monto_depto AS precio,
        created_at  AS precio_desde,
        COALESCE(
            LEAD(created_at) OVER (PARTITION BY property_id ORDER BY created_at),
            NOW()
        ) AS precio_hasta
    FROM assetplan_rentas.historical_pricing
    WHERE monto_depto > 1
),
solapes AS (
    -- Interseccion 2: precios x ventana. Se calculan DOS alcances en paralelo:
    --   'publicado' = ventana ∩ publicable  -> el precio de oferta real
    --   'ventana'   = ventana completa      -> control, para medir cuanto
    --                                          impacta el filtro de publicable
    SELECT
        'publicado' AS scope,
        vp.property_id,
        p.precio,
        GREATEST(vp.pub_inicio, p.precio_desde) AS ov_ini,
        LEAST(vp.pub_fin,       p.precio_hasta) AS ov_fin
    FROM ventana_publicada vp
    INNER JOIN pricing_periods p
            ON p.property_id  = vp.property_id
           AND p.precio_desde < vp.pub_fin
           AND p.precio_hasta > vp.pub_inicio
    UNION ALL
    SELECT
        'ventana' AS scope,
        w.property_id,
        p.precio,
        GREATEST(w.win_inicio, p.precio_desde) AS ov_ini,
        LEAST(w.win_fin,       p.precio_hasta) AS ov_fin
    FROM ventana w
    INNER JOIN pricing_periods p
            ON p.property_id  = w.property_id
           AND p.precio_desde < w.win_fin
           AND p.precio_hasta > w.win_inicio
),
solapes_dias AS (
    SELECT
        scope,
        property_id,
        precio,
        ov_ini,
        GREATEST(TIMESTAMPDIFF(SECOND, ov_ini, ov_fin), 0) / 86400.0 AS dias
    FROM solapes
),
solapes_marcados AS (
    -- Trayectoria de precio dentro de la ventana. El WHERE se evalua antes de
    -- las window functions, asi que primero/ultimo ignoran tramos de largo cero.
    SELECT
        sd.*,
        FIRST_VALUE(sd.precio) OVER (
            PARTITION BY sd.scope, sd.property_id ORDER BY sd.ov_ini ASC
        ) AS precio_primero,
        FIRST_VALUE(sd.precio) OVER (
            PARTITION BY sd.scope, sd.property_id ORDER BY sd.ov_ini DESC
        ) AS precio_ultimo
    FROM solapes_dias sd
    WHERE sd.dias > 0
),
precio_agg AS (
    SELECT
        scope,
        property_id,
        ROUND(SUM(dias), 2)                                        AS dias_con_precio,
        ROUND(SUM(precio * dias) / NULLIF(SUM(dias), 0), 0)        AS precio_ponderado,
        MAX(precio_primero)    AS precio_primero,
        MAX(precio_ultimo)     AS precio_ultimo,
        MIN(precio)            AS precio_min,
        MAX(precio)            AS precio_max,
        COUNT(DISTINCT precio) AS n_precios_distintos
    FROM solapes_marcados
    GROUP BY scope, property_id
),
precio_oferta AS (
    -- Pivot de los dos alcances a una sola fila por property
    SELECT
        property_id,
        -- alcance 'publicado': el precio de oferta efectivo
        MAX(CASE WHEN scope = 'publicado' THEN precio_primero      END) AS precio_oferta_inicial,
        MAX(CASE WHEN scope = 'publicado' THEN precio_ponderado    END) AS precio_ponderado_pub,
        MAX(CASE WHEN scope = 'publicado' THEN precio_ultimo       END) AS precio_oferta_final,
        MAX(CASE WHEN scope = 'publicado' THEN precio_min          END) AS precio_oferta_min,
        MAX(CASE WHEN scope = 'publicado' THEN precio_max          END) AS precio_oferta_max,
        MAX(CASE WHEN scope = 'publicado' THEN n_precios_distintos END) AS n_precios_oferta,
        MAX(CASE WHEN scope = 'publicado' THEN dias_con_precio     END) AS dias_publicado_con_precio,
        -- alcance 'ventana': control sin filtro de publicable
        MAX(CASE WHEN scope = 'ventana'   THEN precio_primero      END) AS precio_ventana_inicial,
        MAX(CASE WHEN scope = 'ventana'   THEN precio_ponderado    END) AS precio_ponderado_ventana,
        MAX(CASE WHEN scope = 'ventana'   THEN dias_con_precio     END) AS dias_ventana_con_precio
    FROM precio_agg
    GROUP BY property_id
),
-- ---------------------------------------------------------------------------
-- Prediccion ML anclada EX-ANTE a fecha_LPA (la informacion que existia al
-- momento de decidir el precio), con fallback a la ultima disponible + flag.
-- ---------------------------------------------------------------------------
pred_ex_ante AS (
    SELECT property_id, precio_recomendado_ml, precio_recomendado_actual,
           uf_m2, ggcc, owner_type, pricing_date
    FROM (
        SELECT
            p.property_id,
            p.precio_recomendado_ml,
            p.precio_recomendado_actual,
            p.uf_m2,
            p.ggcc,
            p.owner_type,
            p.pricing_date,
            ROW_NUMBER() OVER (
                PARTITION BY p.property_id
                ORDER BY p.pricing_date DESC, p.updated_at DESC, p.created_at DESC
            ) AS rn
        FROM bi_assetplan.aa_pmPricingExplainabilityPredictions p
        INNER JOIN postvisitas pn
                ON pn.property_id   = p.property_id
               AND p.pricing_date  <= pn.fecha_LPA
    ) t
    WHERE rn = 1
),
pred_ultima AS (
    SELECT property_id, precio_recomendado_ml, precio_recomendado_actual,
           uf_m2, ggcc, owner_type, pricing_date
    FROM (
        SELECT
            property_id,
            precio_recomendado_actual,
            uf_m2,
            precio_recomendado_ml,
            owner_type,
            ggcc,
            pricing_date,
            ROW_NUMBER() OVER (
                PARTITION BY property_id
                ORDER BY pricing_date DESC, updated_at DESC, created_at DESC
            ) AS rn
        FROM bi_assetplan.aa_pmPricingExplainabilityPredictions
    ) t
    WHERE rn = 1
),
finally AS (
    SELECT
        pn.*,
        COALESCE(r.reservas, 0) AS reservas,
        COALESCE(l.leads,    0) AS leads,
        po.precio_oferta_inicial,
        po.precio_ponderado_pub,
        po.precio_oferta_final,
        po.precio_oferta_min,
        po.precio_oferta_max,
        po.n_precios_oferta,
        po.dias_publicado_con_precio,
        po.precio_ventana_inicial,
        po.precio_ponderado_ventana,
        po.dias_ventana_con_precio
    FROM postvisitas pn
    LEFT JOIN reservas r      ON r.property_id  = pn.property_id
    LEFT JOIN leads    l      ON l.property_id  = pn.property_id
    LEFT JOIN precio_oferta po ON po.property_id = pn.property_id
)
SELECT
    f.*,
    -- ---- Cobertura / calidad del precio ------------------------------------
    ROUND(f.dias_publicado_con_precio
          / NULLIF(TIMESTAMPDIFF(SECOND, f.fecha_LPA, f.event_date) / 86400.0, 0), 3)
        AS cobertura_publicacion,
    CASE WHEN f.precio_oferta_inicial IS NULL THEN 1 ELSE 0 END AS sin_precio_oferta,
    -- ---- Comportamiento de precio ------------------------------------------
    ROUND(1 - f.precio_oferta_final / NULLIF(f.precio_oferta_inicial, 0), 4) AS pct_bajada,
    -- ---- Referencia ML (ex-ante con fallback) ------------------------------
    COALESCE(pea.precio_recomendado_ml, pu.precio_recomendado_ml)         AS precio_ml,
    CASE WHEN pea.precio_recomendado_ml IS NOT NULL THEN 1 ELSE 0 END     AS ml_es_ex_ante,
    COALESCE(pea.pricing_date, pu.pricing_date)                          AS ml_pricing_date,
    COALESCE(pea.precio_recomendado_actual, pu.precio_recomendado_actual) AS precio_actual,
    COALESCE(pea.uf_m2,      pu.uf_m2)                                   AS uf_m2,
    COALESCE(pea.ggcc,       pu.ggcc)                                    AS ggcc,
    COALESCE(pea.owner_type, pu.owner_type)                              AS owner_type,
    ROUND(f.precio_oferta_inicial
          / NULLIF(COALESCE(pea.precio_recomendado_ml, pu.precio_recomendado_ml), 0), 4)
        AS ratio_oferta_inicial,
    ROUND(LN(f.precio_oferta_inicial
          / NULLIF(COALESCE(pea.precio_recomendado_ml, pu.precio_recomendado_ml), 0)), 4)
        AS log_ratio_oferta_inicial,
    ROUND(LN(f.precio_ponderado_pub
          / NULLIF(COALESCE(pea.precio_recomendado_ml, pu.precio_recomendado_ml), 0)), 4)
        AS log_ratio_ponderado,
    -- monto_arriendo = precio de CIERRE del contrato. Solo existe si arrendo.
    -- El gap contra la oferta inicial mide cuanto se negocio.
    ROUND(f.monto_arriendo / NULLIF(f.precio_oferta_inicial, 0), 4) AS ratio_cierre_vs_oferta
FROM finally f
LEFT JOIN pred_ex_ante pea ON pea.property_id = f.property_id
LEFT JOIN pred_ultima  pu  ON pu.property_id  = f.property_id
ORDER BY f.property_id;


-- ============================================================================
-- CHECKS antes de confiar en el output
-- ============================================================================

-- A) Ventanas invalidas: event_date <= fecha_LPA. Estas properties quedan sin
--    precio de oferta (sin_precio_oferta = 1). Si son muchas, revisar la logica
--    de heredado / event_date, porque significa que el contrato se creo antes
--    de que la unidad estuviera lista para arrendar.
-- SELECT COUNT(*) AS ventanas_invalidas
-- FROM ( ...previonatalia... ) x
-- WHERE event_date <= fecha_LPA OR event_date IS NULL OR fecha_LPA IS NULL;

-- B) Estado inicial del log de publicable. Si esto devuelve muchas filas,
--    dias_publicado_con_precio esta subestimado y conviene usar el alcance
--    'ventana' (precio_ponderado_ventana) como referencia principal.
-- SELECT COUNT(*) FROM (
--   SELECT property_id,
--          SUBSTRING_INDEX(GROUP_CONCAT(is_publishable ORDER BY created_at), ',', 1) AS primer_estado
--   FROM assetplan_rentas.property_publishable_history
--   GROUP BY property_id
-- ) t WHERE primer_estado = '0';

-- C) Cobertura ex-ante del ML. Si ml_es_ex_ante = 1 es raro, entonces
--    aa_pmPricingExplainabilityPredictions es un snapshot que se sobreescribe:
--    no hay backtest posible, solo un analisis de concordancia. Hay que
--    presentarlo asi, no como "desempeno del modelo".
-- SELECT ml_es_ex_ante, COUNT(*) FROM (<query>) q GROUP BY ml_es_ex_ante;

-- D) Impacto del filtro de publicable. Si estas dos columnas son casi iguales,
--    el filtro no aporta y conviene simplificar al alcance 'ventana'.
-- SELECT
--   AVG(dias_publicado_con_precio / NULLIF(dias_ventana_con_precio,0)) AS ratio_dias,
--   AVG(ABS(precio_ponderado_pub - precio_ponderado_ventana)
--       / NULLIF(precio_ponderado_ventana,0))                          AS gap_relativo
-- FROM (<query>) q WHERE dias_ventana_con_precio > 0;

-- E) Comparabilidad de unidades: confirmar que historical_pricing.monto_depto y
--    precio_recomendado_ml son ambos NETOS de gastos comunes. La tabla de
--    pricing trae ggcc por separado, lo que lo sugiere, pero hay que verificarlo.

-- F) Duplicados: previonatalia usa SELECT DISTINCT *, lo que enmascara posibles
--    duplicados de primer_contrato / state_move. Verificar el grano:
-- SELECT COUNT(*) AS filas, COUNT(DISTINCT property_id) AS properties FROM (<query>) q;