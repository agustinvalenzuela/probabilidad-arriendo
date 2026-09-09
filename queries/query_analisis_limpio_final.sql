WITH
mov AS (
    SELECT
        pm.property_id,
        pm.fecha_inicio,
        pm.estado_vacios AS estado
    FROM assetplan_rentas.property_state_movements pm
    WHERE pm.estado_vacios IN (8, 13)
),
lpa AS (
    SELECT property_id, MIN(fecha_inicio) AS fecha_LPA
    FROM mov
    WHERE estado = 8
      AND fecha_inicio >= '2025-07-01'
    GROUP BY property_id
),
chk AS (
    SELECT m.property_id, MIN(m.fecha_inicio) AS fecha_check_in
    FROM mov m
    INNER JOIN lpa l ON l.property_id = m.property_id
    WHERE m.estado = 13
      AND m.fecha_inicio >= l.fecha_LPA
    GROUP BY m.property_id
),
ctr AS (
    SELECT
        property_id, renter_id, inicio_contrato, monto_arriendo,
        CASE WHEN fecha_inicio < inicio_contrato THEN 1 ELSE heredado END AS heredado
    FROM (
        SELECT
            c.property_id, c.renter_id,
            c.created_at AS inicio_contrato,
            c.fecha_inicio, c.heredado, c.monto_arriendo,
            ROW_NUMBER() OVER (PARTITION BY c.property_id
                               ORDER BY c.created_at) AS rn
        FROM bi_assetplan.bi_DimContratos c
        INNER JOIN lpa l ON l.property_id = c.property_id
        WHERE c.created_at >= l.fecha_LPA
    ) t
    WHERE rn = 1
),
prop AS (
    SELECT
        property_id, unit_id, edificio, barrio, comuna, sector_provincia,
        nombre_tipologia, m2_utiles, piso, acepta_mascotas, owner_id,
        first_time_rented, ha_sido_arrendada, actual_activa,
        created, fecha_desactivacion,
        dormitorios_tip, banos_tip, tipologia_origen
    FROM (
        SELECT
            p.property_id, p.unit_id, p.edificio, p.barrio, p.comuna,
            p.sector_provincia, p.nombre_tipologia, p.m2_utiles, p.piso,
            p.acepta_mascotas, p.owner_id, p.first_time_rented,
            p.ha_sido_arrendada, p.actual_activa, p.created,
            p.fecha_desactivacion,
            CASE
                WHEN LOWER(TRIM(p.nombre_tipologia)) REGEXP 'studio|estudio|loft' THEN 0
                ELSE CAST(NULLIF(REGEXP_REPLACE(
                        REGEXP_SUBSTR(p.nombre_tipologia, '[0-9]+[[:space:]]*[Dd]'),
                        '[^0-9]', ''), '') AS UNSIGNED)
            END AS dormitorios_tip,
            CASE
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
          AND p.created >= '2025-07-01'
          AND p.sector_provincia IN (
                'Santiago - Centro', 'Santiago - Surponiente', 'Santiago - Nororiente',
                'Santiago - Sur', 'Santiago - Suroriente', 'Santiago - Norte',
                'Santiago - Norponiente'
              )
    ) t
    WHERE rn = 1
),
vis AS (
    SELECT
        l.property_id,
        SUM(CASE WHEN m.date_from <  l.fecha_LPA + INTERVAL  7 DAY
                 THEN m.visits_amount END)                     AS visitas_sem_1,
        SUM(CASE WHEN m.date_from >= l.fecha_LPA + INTERVAL  7 DAY
                  AND m.date_from <  l.fecha_LPA + INTERVAL 14 DAY
                 THEN m.visits_amount END)                     AS visitas_sem_2,
        SUM(CASE WHEN m.date_from >= l.fecha_LPA + INTERVAL 14 DAY
                  AND m.date_from <  l.fecha_LPA + INTERVAL 21 DAY
                 THEN m.visits_amount END)                     AS visitas_sem_3,
        SUM(CASE WHEN m.date_from >= l.fecha_LPA + INTERVAL 21 DAY
                  AND m.date_from <  l.fecha_LPA + INTERVAL 28 DAY
                 THEN m.visits_amount END)                     AS visitas_sem_4,
        SUM(CASE WHEN m.date_from >= l.fecha_LPA + INTERVAL 28 DAY
                 THEN m.visits_amount END)                     AS visitas_sem5_a_90,
        SUM(m.visits_amount)                                   AS visitas_90d,
        COUNT(DISTINCT DATE(m.date_from))                      AS dias_con_observacion,
        MIN(DATE(m.date_from))                                 AS first_visit_obs,
        MAX(DATE(m.date_from))                                 AS last_visit_obs
    FROM lpa l
    INNER JOIN assetplan_rentas.property_publication_metrics m
            ON m.property_id  = l.property_id
           AND m.property_id  > 0
           AND m.date_from   >= l.fecha_LPA
           AND m.date_from   <  l.fecha_LPA + INTERVAL 90 DAY
           AND m.date_from   >= '2025-07-01'
    GROUP BY l.property_id
),
lds AS (
    SELECT
        l.property_id,
        COUNT(DISTINCT dla.lead_id)                            AS leads_90d,
        COUNT(DISTINCT CASE WHEN dla.created_at < l.fecha_LPA + INTERVAL 7 DAY
                            THEN dla.lead_id END)              AS d0_7_leads
    FROM lpa l
    INNER JOIN bi_assetplan.bi_DimLeadAttemps dla
            ON dla.property_id  = l.property_id
           AND dla.created_at  >= l.fecha_LPA
           AND dla.created_at  <  l.fecha_LPA + INTERVAL 90 DAY
           AND dla.created_at  >= '2025-07-01'
    GROUP BY l.property_id
),
res AS (
    SELECT
        l.property_id,
        COUNT(DISTINCT CASE WHEN r.fecha < l.fecha_LPA + INTERVAL 90 DAY
                            THEN r.reserva_id END)             AS reservas_90d,
        COUNT(DISTINCT CASE WHEN r.fecha < l.fecha_LPA + INTERVAL 7 DAY
                            THEN r.reserva_id END)             AS d0_7_reservas,
        MIN(r.fecha)                                           AS fecha_primera_reserva,
        MAX(CASE WHEN c.inicio_contrato IS NULL OR r.fecha < c.inicio_contrato
                 THEN r.fecha END)                             AS fecha_ultima_reserva_pre_contrato,
        COUNT(DISTINCT CASE WHEN c.inicio_contrato IS NULL OR r.fecha < c.inicio_contrato
                            THEN r.reserva_id END)             AS n_reservas_pre_contrato
    FROM lpa l
    INNER JOIN bi_assetplan.bi_DimReservas r
            ON r.property_id = l.property_id
           AND r.fecha      >= l.fecha_LPA
           AND r.fecha      >= '2025-07-01'
    LEFT JOIN ctr c ON c.property_id = l.property_id
    GROUP BY l.property_id
),
ml AS (
    SELECT property_id, precio_recomendado_ml, precio_recomendado_actual,
           uf_m2, ggcc, owner_type, dormitorios, banos, estudio, pricing_date
    FROM (
        SELECT
            property_id, precio_recomendado_ml, precio_recomendado_actual,
            uf_m2, ggcc, owner_type, dormitorios,
            `baños` AS banos,
            estudio,
            pricing_date,
            ROW_NUMBER() OVER (PARTITION BY property_id
                               ORDER BY pricing_date DESC, updated_at DESC,
                                        created_at DESC) AS rn
        FROM bi_assetplan.aa_pmPricingExplainabilityPredictions
    ) t
    WHERE rn = 1
),
uni AS (
    SELECT
        p.*,
        l.fecha_LPA,
        k.fecha_check_in,
        rs.fecha_primera_reserva,
        rs.fecha_ultima_reserva_pre_contrato,
        rs.n_reservas_pre_contrato,
        rs.reservas_90d,
        rs.d0_7_reservas,
        c.renter_id, c.inicio_contrato, c.monto_arriendo, c.heredado,
        CASE WHEN p.fecha_desactivacion > '0000-00-00'
             THEN p.fecha_desactivacion END                    AS fecha_baja,
        CASE
            WHEN c.inicio_contrato IS NOT NULL
                THEN LEAST(COALESCE(rs.fecha_primera_reserva, c.inicio_contrato),
                           c.inicio_contrato)
            WHEN p.fecha_desactivacion > '0000-00-00' THEN p.fecha_desactivacion
        END                                                    AS event_date,
        CASE
            WHEN c.inicio_contrato IS NOT NULL
             AND rs.fecha_primera_reserva IS NOT NULL
             AND rs.fecha_primera_reserva < c.inicio_contrato   THEN 'reserva'
            WHEN c.inicio_contrato IS NOT NULL                  THEN 'contrato'
            WHEN p.fecha_desactivacion > '0000-00-00'           THEN 'churn'
        END                                                    AS origen_event_date
    FROM prop p
    LEFT JOIN lpa l ON l.property_id = p.property_id
    LEFT JOIN chk k ON k.property_id = p.property_id
    LEFT JOIN res rs ON rs.property_id = p.property_id
    LEFT JOIN ctr c ON c.property_id = p.property_id
),
salida AS (
    SELECT
        u.property_id,
        u.unit_id,
        u.owner_id,
        u.edificio                                             AS grupo_edificio,
        u.comuna,
        u.barrio,
        u.sector_provincia,
        u.nombre_tipologia,
        COALESCE(m.dormitorios, u.dormitorios_tip)             AS dormitorios,
        COALESCE(m.banos,       u.banos_tip)                   AS banos,
        COALESCE(m.estudio,
                 CASE WHEN u.tipologia_origen = 'estudio' THEN 1 ELSE 0 END
        )                                                      AS estudio,
        NULLIF(u.m2_utiles, 0)                                 AS m2_utiles,
        ROUND(NULLIF(u.m2_utiles, 0)
              / NULLIF(COALESCE(m.dormitorios, u.dormitorios_tip), 0), 1)
                                                               AS m2_por_dormitorio,
        u.piso,
        u.acepta_mascotas,
        u.first_time_rented,
        u.ha_sido_arrendada,
        m.owner_type,
        m.ggcc,
        (SELECT hp.monto_depto
           FROM assetplan_rentas.historical_pricing hp
          WHERE hp.property_id = u.property_id
            AND hp.monto_depto > 1
            AND hp.created_at <= u.fecha_LPA
          ORDER BY hp.created_at DESC LIMIT 1)                 AS precio_lpa,
        (SELECT hp.monto_depto
           FROM assetplan_rentas.historical_pricing hp
          WHERE hp.property_id = u.property_id
            AND hp.monto_depto > 1
            AND hp.created_at >  u.fecha_LPA
            AND hp.created_at <  COALESCE(u.event_date,
                                          u.fecha_LPA + INTERVAL 90 DAY)
          ORDER BY hp.created_at ASC LIMIT 1)                  AS precio_post,
        (SELECT COUNT(*)
           FROM assetplan_rentas.historical_pricing hp
          WHERE hp.property_id = u.property_id
            AND hp.monto_depto > 1
            AND hp.created_at <= u.fecha_LPA)                  AS n_registros_precio_previos,
        u.fecha_LPA,
        u.created                                              AS fecha_creacion,
        DATEDIFF(u.fecha_LPA, u.created)                       AS dias_habilitacion,
        DATE_FORMAT(u.fecha_LPA, '%Y-%m')                      AS cohorte_lpa,
        MONTH(u.fecha_LPA)                                     AS mes_lpa,
        YEAR(u.fecha_LPA)                                      AS year_lpa,
        QUARTER(u.fecha_LPA)                                   AS trimestre_lpa,
        DAYOFWEEK(u.fecha_LPA)                                 AS dow_lpa,
        COALESCE(vi.visitas_sem_1, 0)                          AS d0_7_visitas,
        COALESCE(ld.d0_7_leads,    0)                          AS d0_7_leads,
        COALESCE(u.d0_7_reservas, 0)                           AS d0_7_reservas,
        CASE
            WHEN u.event_date IS NULL
              OR u.event_date >= u.fecha_LPA + INTERVAL 7 DAY
            THEN 1 ELSE 0
        END                                                    AS sobrevive_d7,
        DATEDIFF(u.event_date, u.fecha_LPA)                    AS no_modelo_days_to_event,
        DATEDIFF(COALESCE(u.event_date, CURDATE()), u.fecha_LPA)
                                                               AS no_modelo_dias_observados,
        CASE WHEN u.event_date IS NULL THEN 1 ELSE 0 END       AS no_modelo_censurada,
        CASE
            WHEN u.inicio_contrato IS NOT NULL THEN 'arriendo'
            WHEN u.fecha_baja      IS NOT NULL THEN 'churn'
            ELSE 'sin evento'
        END                                                    AS no_modelo_tipo_evento,
        CASE
            WHEN u.inicio_contrato IS NULL AND u.fecha_baja IS NOT NULL
            THEN 1 ELSE 0
        END                                                    AS no_modelo_churn,
        u.fecha_check_in                                       AS no_modelo_fecha_check_in,
        DATEDIFF(u.fecha_check_in, u.fecha_LPA)                AS no_modelo_days_to_check_in,
        DATEDIFF(u.fecha_check_in, u.inicio_contrato)          AS no_modelo_dias_contrato_a_check_in,
        CASE
            WHEN u.fecha_check_in IS NOT NULL
             AND u.inicio_contrato IS NOT NULL
             AND u.fecha_check_in < u.inicio_contrato
            THEN 1 ELSE 0
        END                                                    AS flag_check_in_previo_al_contrato,
        u.fecha_primera_reserva                                AS no_modelo_fecha_primera_reserva,
        DATEDIFF(u.fecha_primera_reserva, u.fecha_LPA)         AS no_modelo_days_to_reserva,
        DATEDIFF(u.inicio_contrato, u.fecha_primera_reserva)   AS no_modelo_dias_reserva_a_contrato,
        u.fecha_ultima_reserva_pre_contrato                    AS no_modelo_fecha_ultima_reserva_pre_contrato,
        COALESCE(u.n_reservas_pre_contrato, 0)                 AS no_modelo_n_reservas_pre_contrato,
        DATEDIFF(u.inicio_contrato, u.fecha_LPA)               AS no_modelo_days_to_contrato,
        u.origen_event_date                                    AS no_modelo_origen_event_date,
        u.event_date                                           AS no_modelo_event_date,
        u.inicio_contrato                                      AS no_modelo_inicio_contrato,
        u.fecha_baja                                           AS no_modelo_fecha_baja,
        u.monto_arriendo                                       AS no_modelo_monto_arriendo,
        u.renter_id                                            AS no_modelo_renter_id,
        u.actual_activa                                        AS no_modelo_actual_activa,
        CASE
            WHEN u.inicio_contrato IS NOT NULL AND u.fecha_baja IS NOT NULL
            THEN DATEDIFF(u.fecha_baja, u.inicio_contrato)
        END                                                    AS no_modelo_dias_contrato_a_baja,
        COALESCE(vi.visitas_sem_1,        0)                   AS no_modelo_visitas_sem_1,
        COALESCE(vi.visitas_sem_2,        0)                   AS no_modelo_visitas_sem_2,
        COALESCE(vi.visitas_sem_3,        0)                   AS no_modelo_visitas_sem_3,
        COALESCE(vi.visitas_sem_4,        0)                   AS no_modelo_visitas_sem_4,
        COALESCE(vi.visitas_sem5_a_90,    0)                   AS no_modelo_visitas_sem5_a_90,
        COALESCE(vi.visitas_90d,          0)                   AS no_modelo_visitas_90d,
        COALESCE(vi.dias_con_observacion, 0)                   AS no_modelo_dias_con_observacion,
        vi.first_visit_obs                                     AS no_modelo_first_visit_obs,
        vi.last_visit_obs                                      AS no_modelo_last_visit_obs,
        COALESCE(ld.leads_90d,    0)                           AS no_modelo_leads_90d,
        COALESCE(u.reservas_90d, 0)                            AS no_modelo_reservas_90d,
        CASE WHEN vi.property_id IS NULL THEN 1 ELSE 0 END     AS flag_sin_datos_visitas,
        (SELECT hp.monto_depto
           FROM assetplan_rentas.historical_pricing hp
          WHERE hp.property_id = u.property_id
            AND hp.monto_depto > 1
            AND hp.created_at <  COALESCE(u.event_date,
                                          u.fecha_LPA + INTERVAL 90 DAY)
          ORDER BY hp.created_at DESC LIMIT 1)                 AS no_modelo_precio_cierre,
        (SELECT COUNT(DISTINCT ROUND(hp.monto_depto / 5000) * 5000)
           FROM assetplan_rentas.historical_pricing hp
          WHERE hp.property_id = u.property_id
            AND hp.monto_depto > 1
            AND hp.created_at >= u.fecha_LPA
            AND hp.created_at <  COALESCE(u.event_date,
                                          u.fecha_LPA + INTERVAL 90 DAY))
                                                               AS no_modelo_n_precios_ventana,
        m.precio_recomendado_ml                                AS precio_ml_expost,
        m.precio_recomendado_actual                            AS precio_ml_actual,
        m.pricing_date                                         AS ml_pricing_date,
        m.uf_m2,
        CASE WHEN m.pricing_date <= u.fecha_LPA THEN 1 ELSE 0 END
                                                               AS flag_ml_es_ex_ante,
        u.heredado,
        u.tipologia_origen,
        CASE WHEN m.dormitorios IS NOT NULL THEN 'pricing'
             WHEN u.dormitorios_tip IS NOT NULL THEN 'tipologia'
             ELSE 'sin dato' END                               AS origen_dormitorios,
        CASE WHEN m.banos IS NOT NULL THEN 'pricing'
             WHEN u.banos_tip IS NOT NULL THEN 'tipologia'
             ELSE 'sin dato' END                               AS origen_banos,
        CASE
            WHEN COALESCE(m.estudio, 0) = 1
             AND u.tipologia_origen = 'estudio'                 THEN 0
            WHEN m.dormitorios IS NOT NULL AND u.dormitorios_tip IS NOT NULL
             AND m.dormitorios <> u.dormitorios_tip THEN 1
            WHEN m.banos IS NOT NULL AND u.banos_tip IS NOT NULL
             AND m.banos <> u.banos_tip THEN 1
            WHEN m.estudio IS NOT NULL
             AND (m.estudio <> 0) <> (u.tipologia_origen = 'estudio') THEN 1
            ELSE 0
        END                                                    AS flag_discrepancia_tipologia,
        CASE
            WHEN u.event_date IS NOT NULL AND u.event_date < u.fecha_LPA
            THEN 1 ELSE 0
        END                                                    AS flag_evento_previo_lpa
    FROM uni u
    LEFT JOIN vis vi ON vi.property_id = u.property_id
    LEFT JOIN lds ld ON ld.property_id = u.property_id
    LEFT JOIN ml  m  ON m.property_id  = u.property_id
),
derivadas AS (
    SELECT
        s.*,
        COALESCE(s.precio_lpa, s.precio_post)                  AS precio_oferta,
        CASE
            WHEN s.precio_lpa IS NULL AND s.precio_post IS NOT NULL
            THEN 1 ELSE 0
        END                                                    AS flag_precio_posterior_al_lpa,
        ROUND(COALESCE(s.precio_lpa, s.precio_post)
              / NULLIF(s.m2_utiles, 0), 0)                     AS precio_m2,
        ROUND(1 - s.no_modelo_precio_cierre
                  / NULLIF(COALESCE(s.precio_lpa, s.precio_post), 0), 4)
                                                               AS no_modelo_pct_bajada,
        ROUND(s.no_modelo_monto_arriendo
              / NULLIF(COALESCE(s.precio_lpa, s.precio_post), 0), 4)
                                                               AS no_modelo_ratio_cierre_vs_oferta,
        CASE
            WHEN s.no_modelo_n_precios_ventana = 0 THEN NULL
            WHEN s.no_modelo_n_precios_ventana = 1 THEN 1
            ELSE 0
        END                                                    AS no_modelo_precio_plano,
        ROUND(COALESCE(s.precio_lpa, s.precio_post)
              / NULLIF(GREATEST(s.precio_ml_expost, 0), 0), 4) AS ratio_ml,
        ROUND(LN(NULLIF(GREATEST(
                  COALESCE(s.precio_lpa, s.precio_post)
                  / NULLIF(GREATEST(s.precio_ml_expost, 0), 0)
              , 0), 0)), 4)                                    AS log_ratio_ml,
        CASE
            WHEN s.fecha_LPA IS NULL                        THEN 'sin fecha LPA'
            WHEN s.heredado = 1                             THEN 'contrato heredado'
            WHEN s.no_modelo_event_date IS NOT NULL
             AND s.no_modelo_event_date <= s.fecha_LPA      THEN 'ventana invalida'
            WHEN COALESCE(s.precio_lpa, s.precio_post) IS NULL
                                                            THEN 'sin historical_pricing'
            ELSE 'analizable'
        END                                                    AS motivo_exclusion
    FROM salida s
)
SELECT
    d.*,
    COUNT(d.log_ratio_ml) OVER (
        PARTITION BY d.comuna, d.nombre_tipologia, d.cohorte_lpa
    )                                                          AS n_segmento,
    ROUND(d.log_ratio_ml - AVG(d.log_ratio_ml) OVER (
        PARTITION BY d.comuna, d.nombre_tipologia, d.cohorte_lpa
    ), 4)                                                      AS log_ratio_centrado
FROM derivadas d
ORDER BY d.fecha_LPA, d.property_id;
