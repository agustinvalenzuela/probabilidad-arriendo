WITH lpa AS (
    -- Primer periodo "Lista para arrendar" de cada property
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
    WHERE rn = 1
),
contrato AS (
    -- Primer contrato de cada property
    SELECT
        property_id, renter_id, inicio_contrato, monto_arriendo,
        CASE WHEN fecha_inicio < inicio_contrato THEN 1 ELSE heredado END AS heredado
    FROM (
        SELECT
            property_id, renter_id, created_at AS inicio_contrato, fecha_inicio,
            heredado, monto_arriendo,
            ROW_NUMBER() OVER (PARTITION BY property_id ORDER BY created_at) AS rn
        FROM bi_assetplan.bi_DimContratos
    ) t
    WHERE rn = 1
),
base AS (
    -- [F2] Una fila por property, sin DISTINCT.
    SELECT
        p.property_id, p.unit_id, p.created, p.acepta_mascotas, p.m2_utiles,
        p.piso, p.edificio, p.barrio, p.comuna, p.sector_provincia, p.nombre_tipologia,
        p.owner_id, p.first_time_rented, p.ha_sido_arrendada, p.actual_activa,
        p.monto_depto, p.fecha_desactivacion,
        l.fecha_LPA,
        c.renter_id, c.inicio_contrato, c.monto_arriendo, c.heredado,
        CASE WHEN c.inicio_contrato IS NULL THEN 1 ELSE 0 END AS churn,
        COALESCE(c.inicio_contrato, p.fecha_desactivacion)     AS event_date,
        DATEDIFF(COALESCE(c.inicio_contrato, p.fecha_desactivacion), l.fecha_LPA)
            AS days_to_event
    FROM bi_assetplan.bi_DimProperties p
    LEFT JOIN lpa      l ON l.property_id = p.property_id
    LEFT JOIN contrato c ON c.property_id = p.property_id
    WHERE p.unit_type = 'Appartment'
      AND p.mf       = 0
      AND p.pais_id  = 1
      AND p.created >= '2025-01-01'
      AND p.sector_provincia IN (
            'Santiago - Centro', 'Santiago - Surponiente', 'Santiago - Nororiente',
            'Santiago - Sur', 'Santiago - Suroriente', 'Santiago - Norte',
            'Santiago - Norponiente'
          )
      AND (c.heredado = 0 OR c.heredado IS NULL)
      AND NOT (c.inicio_contrato IS NULL AND p.fecha_desactivacion = '0000-00-00')
),
precio AS (
    -- [F1] Lookups point-in-time. Reemplaza toda la maquinaria de intervalos.
    --   precio_inicial : ultimo precio VIGENTE al salir al mercado.
    --                    Si el historial parte despues del LPA, cae al primer
    --                    precio dentro de la ventana (recupera filas que antes
    --                    quedaban sin precio) y lo marca en el flag.
    --   precio_cierre  : ultimo precio antes del evento (arriendo o churn).
    --   n_precios_ventana : sobre el precio REDONDEADO a 5.000, para no contar
    --                    reajuste UF como decision de pricing. El check G daba
    --                    5,2 cambios/mes con 1,65% de dispersion: era ruido.
    SELECT
        b.property_id,
        (SELECT hp.monto_depto
           FROM assetplan_rentas.historical_pricing hp
          WHERE hp.property_id = b.property_id
            AND hp.monto_depto > 1
            AND hp.created_at <= b.fecha_LPA
          ORDER BY hp.created_at DESC
          LIMIT 1) AS precio_antes_lpa,
        (SELECT hp.monto_depto
           FROM assetplan_rentas.historical_pricing hp
          WHERE hp.property_id = b.property_id
            AND hp.monto_depto > 1
            AND hp.created_at >  b.fecha_LPA
            AND hp.created_at <  b.event_date
          ORDER BY hp.created_at ASC
          LIMIT 1) AS precio_primero_en_ventana,
        (SELECT hp.monto_depto
           FROM assetplan_rentas.historical_pricing hp
          WHERE hp.property_id = b.property_id
            AND hp.monto_depto > 1
            AND hp.created_at <  b.event_date
          ORDER BY hp.created_at DESC
          LIMIT 1) AS precio_cierre,
        (SELECT COUNT(DISTINCT ROUND(hp.monto_depto / 5000) * 5000)
           FROM assetplan_rentas.historical_pricing hp
          WHERE hp.property_id = b.property_id
            AND hp.monto_depto > 1
            AND hp.created_at >= b.fecha_LPA
            AND hp.created_at <  b.event_date) AS n_precios_ventana
    FROM base b
    WHERE b.fecha_LPA  IS NOT NULL
      AND b.event_date IS NOT NULL
      AND b.event_date > b.fecha_LPA
),
visitas AS (
    -- [F3] Limite inferior >= fecha_LPA y < event_date.
    SELECT
        v.property_id,
        SUM(CASE WHEN v.date_from <= b.fecha_LPA + INTERVAL  7 DAY THEN v.visits_amount END) AS visitas_sem_1,
        SUM(CASE WHEN v.date_from >  b.fecha_LPA + INTERVAL  7 DAY
                  AND v.date_from <= b.fecha_LPA + INTERVAL 14 DAY THEN v.visits_amount END) AS visitas_sem_2,
        SUM(CASE WHEN v.date_from >  b.fecha_LPA + INTERVAL 14 DAY
                  AND v.date_from <= b.fecha_LPA + INTERVAL 21 DAY THEN v.visits_amount END) AS visitas_sem_3,
        SUM(CASE WHEN v.date_from >  b.fecha_LPA + INTERVAL 21 DAY
                  AND v.date_from <= b.fecha_LPA + INTERVAL 28 DAY THEN v.visits_amount END) AS visitas_sem_4,
        SUM(CASE WHEN v.date_from >  b.fecha_LPA + INTERVAL 28 DAY THEN v.visits_amount END)  AS visitas_post_sem4,
        SUM(v.visits_amount)                  AS visitas_total,
        COUNT(DISTINCT DATE(v.date_from))     AS dias_con_observacion,
        MIN(DATE(v.date_from))                AS first_visit_obs,
        MAX(DATE(v.date_from))                AS last_visit_obs
    FROM assetplan_rentas.property_publication_metrics v
    INNER JOIN base b
            ON b.property_id = v.property_id
    WHERE v.property_id > 0
      AND v.date_from >= b.fecha_LPA
      AND v.date_from <  b.event_date
    GROUP BY v.property_id
),
reservas AS (
    -- [F5] Limite inferior, que faltaba en el original.
    SELECT r.property_id, COUNT(DISTINCT r.reserva_id) AS reservas
    FROM bi_assetplan.bi_DimReservas r
    INNER JOIN base b
            ON b.property_id = r.property_id
           AND r.fecha >= b.fecha_LPA
           AND r.fecha <  b.event_date
    GROUP BY r.property_id
),
leads AS (
    SELECT dla.property_id, COUNT(DISTINCT dla.lead_id) AS leads
    FROM bi_assetplan.bi_DimLeadAttemps dla
    INNER JOIN base b
            ON b.property_id   = dla.property_id
           AND dla.created_at >= b.fecha_LPA
           AND dla.created_at <  b.event_date
    GROUP BY dla.property_id
),
ml AS (
    -- Ultima prediccion disponible. Es EX-POST: el check C mostro cobertura
    -- ex-ante ~0%. El nombre de la columna lo deja explicito.
    SELECT property_id, precio_recomendado_ml, precio_recomendado_actual,
           uf_m2, ggcc, owner_type, pricing_date
    FROM (
        SELECT
            property_id, precio_recomendado_ml, precio_recomendado_actual,
            uf_m2, ggcc, owner_type, pricing_date,
            ROW_NUMBER() OVER (
                PARTITION BY property_id
                ORDER BY pricing_date DESC, updated_at DESC, created_at DESC
            ) AS rn
        FROM bi_assetplan.aa_pmPricingExplainabilityPredictions
    ) t
    WHERE rn = 1
),
salida AS (
    SELECT
        b.property_id, b.unit_id, b.created, b.acepta_mascotas, b.m2_utiles,
        b.piso, b.edificio, b.barrio, b.comuna, b.sector_provincia, b.nombre_tipologia,
        b.owner_id, b.first_time_rented, b.ha_sido_arrendada, b.actual_activa,
        b.fecha_LPA, b.event_date, b.days_to_event, b.churn, b.heredado,
        b.renter_id, b.inicio_contrato, b.fecha_desactivacion,
        b.monto_arriendo, b.monto_depto,
        DATE_FORMAT(b.fecha_LPA, '%Y-%m') AS mes_LPA,
        -- ---- Precio de oferta ----------------------------------------------
        COALESCE(pz.precio_antes_lpa, pz.precio_primero_en_ventana) AS precio_oferta,
        CASE
            WHEN pz.precio_antes_lpa IS NULL
             AND pz.precio_primero_en_ventana IS NOT NULL THEN 1
            ELSE 0
        END AS precio_oferta_es_posterior_al_lpa,
        pz.precio_cierre,
        COALESCE(pz.n_precios_ventana, 0) AS n_precios_ventana,
        CASE
            WHEN pz.n_precios_ventana IS NULL OR pz.n_precios_ventana = 0 THEN NULL
            WHEN pz.n_precios_ventana = 1 THEN 1
            ELSE 0
        END AS precio_plano,
        ROUND(1 - pz.precio_cierre
                  / NULLIF(COALESCE(pz.precio_antes_lpa, pz.precio_primero_en_ventana), 0), 4)
            AS pct_bajada,
        -- [F7] Por que falta el precio. NO filtrar sin reportar el sesgo.
        CASE
            WHEN b.fecha_LPA IS NULL                      THEN 'sin fecha LPA'
            WHEN b.event_date IS NULL                     THEN 'sin event_date'
            WHEN b.event_date <= b.fecha_LPA              THEN 'ventana invalida'
            WHEN COALESCE(pz.precio_antes_lpa, pz.precio_primero_en_ventana) IS NULL
                                                          THEN 'sin historical_pricing'
            ELSE 'con precio'
        END AS motivo_sin_precio,
        -- ---- Demanda -------------------------------------------------------
        COALESCE(vi.visitas_sem_1, 0)        AS visitas_sem_1,
        COALESCE(vi.visitas_sem_2, 0)        AS visitas_sem_2,
        COALESCE(vi.visitas_sem_3, 0)        AS visitas_sem_3,
        COALESCE(vi.visitas_sem_4, 0)        AS visitas_sem_4,
        COALESCE(vi.visitas_post_sem4, 0)    AS visitas_post_sem4,
        COALESCE(vi.visitas_total, 0)        AS visitas_total,
        COALESCE(vi.dias_con_observacion, 0) AS dias_con_observacion,
        vi.first_visit_obs,
        vi.last_visit_obs,
        CASE WHEN vi.property_id IS NULL THEN 1 ELSE 0 END AS sin_datos_visitas,
        COALESCE(rs.reservas, 0) AS reservas,
        COALESCE(ld.leads,    0) AS leads,
        -- ---- Referencia ML (ex-post) ---------------------------------------
        m.precio_recomendado_ml     AS precio_ml_expost,
        m.pricing_date              AS ml_pricing_date,
        m.precio_recomendado_actual AS precio_actual,
        m.uf_m2, m.ggcc, m.owner_type,
        -- [F6] LN blindado: GREATEST manda los <=0 a 0 y NULLIF los pasa a
        -- NULL, asi el argumento es > 0 o NULL, nunca 0 ni negativo.
        ROUND(COALESCE(pz.precio_antes_lpa, pz.precio_primero_en_ventana)
              / NULLIF(GREATEST(m.precio_recomendado_ml, 0), 0), 4) AS ratio_ml,
        ROUND(LN(NULLIF(GREATEST(
                  COALESCE(pz.precio_antes_lpa, pz.precio_primero_en_ventana)
                  / NULLIF(GREATEST(m.precio_recomendado_ml, 0), 0)
              , 0), 0)), 4) AS log_ratio_ml,
        ROUND(b.monto_arriendo
              / NULLIF(GREATEST(COALESCE(pz.precio_antes_lpa, pz.precio_primero_en_ventana), 0), 0), 4)
            AS ratio_cierre_vs_oferta
    -- [F4] base es la conductora. Todo lo demas entra por LEFT JOIN, asi que
    -- ninguna property se pierde por no tener visitas, precio o prediccion.
    FROM base b
    LEFT JOIN precio   pz ON pz.property_id = b.property_id
    LEFT JOIN visitas  vi ON vi.property_id = b.property_id
    LEFT JOIN reservas rs ON rs.property_id = b.property_id
    LEFT JOIN leads    ld ON ld.property_id = b.property_id
    LEFT JOIN ml       m  ON m.property_id  = b.property_id
)
SELECT
    s.*,
    -- [F8] Gap centrado en su celda comuna x tipologia x mes: absorbe la deriva
    -- de mercado entre fecha_LPA y la fecha de la prediccion. Descartar celdas
    -- con n_segmento chico antes de interpretar.
    COUNT(s.log_ratio_ml) OVER (
        PARTITION BY s.comuna, s.nombre_tipologia, s.mes_LPA
    ) AS n_segmento,
    ROUND(s.log_ratio_ml - AVG(s.log_ratio_ml) OVER (
        PARTITION BY s.comuna, s.nombre_tipologia, s.mes_LPA
    ), 4) AS log_ratio_centrado,
    (s.precio_oferta + s.ggcc) / (s.precio_ml_expost + s.ggcc) AS ratio
FROM salida s
ORDER BY s.property_id;