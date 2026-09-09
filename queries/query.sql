WITH state_move AS (
SELECT
    property_id,
    fecha_LPA,
    rn,
    state
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
      AND pb.mf = 0
      AND pb.pais_id = 1
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
 FROM 
 churn_logic 
 WHERE (heredado = 0 OR heredado IS NULL)
 	AND busqueda_activa = 0
 ),
visitas AS (
    SELECT
        v.property_id,
        SUM(v.visits_amount) AS visitas_pi_dia,
        DATE(v.date_from)    AS observation_date,
        CASE
            WHEN v.date_from <= DATE_ADD(pr.fecha_LPA, INTERVAL 7 DAY)  THEN 'visitas_semana_1'
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
    LEFT JOIN previonatalia pr
        ON v.property_id = pr.property_id
    WHERE v.date_from >= '2025-05-05'
      AND v.property_id > 0
      AND v.date_from <= pr.event_date
    GROUP BY v.property_id, DATE(v.date_from), visits
),
postvisitas AS (
SELECT
    pr.property_id,
    pr.unit_id,
    pr.created,
    pr.acepta_mascotas,
    pr.m2_utiles,
    pr.piso,
    pr.edificio,
    pr.comuna,
    pr.sector_provincia,
    pr.nombre_tipologia,
    pr.fecha_LPA,
    pr.first_time_rented,
    pr.inicio_contrato,
    pr.monto_arriendo,
    pr.fecha_desactivacion,
    pr.churn,
    pr.event_date,
    pr.actual_activa,
    pr.ha_sido_arrendada,
    pr.owner_id,
    pr.monto_depto,
    pr.renter_id,
    pr.heredado,
    pr.days_to_event,
    SUM(CASE WHEN v.visits = 'visitas_semana_1'   THEN v.visitas_pi_dia END)  AS visitas_semana_1,
    SUM(CASE WHEN v.visits = 'visitas_semana_2'   THEN v.visitas_pi_dia END)  AS visitas_semana_2,
    SUM(CASE WHEN v.visits = 'visitas_semana_3'   THEN v.visitas_pi_dia END)  AS visitas_semana_3,
    SUM(CASE WHEN v.visits = 'visitas_semana_4'   THEN v.visitas_pi_dia END)  AS visitas_semana_4,
    SUM(CASE WHEN v.visits = 'visitas_semana_5'   THEN v.visitas_pi_dia END)  AS visitas_semana_5,
    SUM(CASE WHEN v.visits = 'visitas_semana_6'   THEN v.visitas_pi_dia END)  AS visitas_semana_6,
    SUM(CASE WHEN v.visits = 'visitas_semana_7'   THEN v.visitas_pi_dia END)  AS visitas_semana_7,
    SUM(CASE WHEN v.visits = 'visitas_semana_8'   THEN v.visitas_pi_dia END)  AS visitas_semana_8,
    SUM(CASE WHEN v.visits = 'visitas_semana_9mas' THEN v.visitas_pi_dia END) AS visitas_semana_9mas,
    MIN(DATE(v.observation_date))              AS first_visit_obs,
    MAX(DATE(v.observation_date))              AS last_visit_obs,
    COUNT(DISTINCT DATE(v.observation_date))   AS dias_con_observacion
FROM visitas v
LEFT JOIN previonatalia pr
    ON v.property_id = pr.property_id
WHERE v.property_id IS NOT NULL
  AND pr.property_id > 0
GROUP BY
    pr.property_id,
    pr.unit_id,
    pr.created,
    pr.acepta_mascotas,
    pr.m2_utiles,
    pr.piso,
    pr.edificio,
    pr.comuna,
    pr.sector_provincia,
    pr.nombre_tipologia,
    pr.fecha_LPA,
    pr.first_time_rented,
    pr.inicio_contrato,
    pr.fecha_desactivacion,
    pr.churn,
    pr.event_date,
    pr.actual_activa,
    pr.ha_sido_arrendada,
    pr.owner_id,
    pr.monto_depto,
    pr.renter_id,
    pr.monto_arriendo,
    pr.heredado,
    pr.days_to_event
),
reservas AS (
SELECT 
	r.property_id,
	COUNT(DISTINCT r.reserva_id) AS reservas
FROM bi_assetplan.bi_DimReservas r
INNER JOIN postvisitas pn
	ON pn.property_id = r.property_id
    AND r.fecha <  pn.event_date
GROUP BY r.property_id
),
leads AS (
SELECT 
	dla.property_id,
    COUNT(DISTINCT dla.lead_id) AS leads
FROM bi_assetplan.bi_DimLeadAttemps dla
INNER JOIN postvisitas pn
	ON pn.property_id = dla.property_id
    AND dla.created_at >= pn.fecha_LPA
    AND dla.created_at <  pn.event_date
GROUP BY dla.property_id
),
publicacion_precio AS (
    SELECT
        property_id,
        precio,
        precio_desde,
        fecha_LPA
    FROM (
        SELECT
            hpp.property_id,
            hpp.precio,
            hpp.precio_desde,
            pn.fecha_LPA,
            ROW_NUMBER() OVER (
                PARTITION BY hpp.property_id          -- ← solo property_id
                ORDER BY ABS(DATEDIFF(pn.fecha_LPA, hpp.precio_desde))
            ) AS rn
        FROM (
            SELECT
                hp.property_id,
                hp.monto_depto AS precio,
                hp.created_at  AS precio_desde
            FROM assetplan_rentas.historical_pricing hp
            WHERE hp.monto_depto > 1
        ) hpp
        INNER JOIN postvisitas pn
                ON pn.property_id = hpp.property_id
    ) ranked
    WHERE rn = 1
),
pricing_dedup AS (
    SELECT
        property_id,
        precio_recomendado_actual,
        owner_type,
        uf_m2,
        precio_recomendado_ml,
        ggcc
    FROM (
        SELECT
            property_id,
            precio_recomendado_actual,
            price,
            uf_m2,
            precio_recomendado_ml,
            owner_type,
            ggcc,
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
    pp.precio,
    pp.precio_desde AS fecha_publicacion_precio
FROM postvisitas pn
LEFT JOIN reservas r
	ON r.property_id = pn.property_id
LEFT JOIN leads l
	ON l.property_id = pn.property_id
LEFT JOIN publicacion_precio pp
	ON pp.property_id = pn.property_id
)
SELECT
	f.*,
    pp.precio_recomendado_actual AS precio_actual,
    pp.uf_m2,
    pp.precio_recomendado_ml AS precio_ml,
    pp.owner_type,
    pp.ggcc
FROM finally f
LEFT JOIN pricing_dedup pp
	ON f.property_id = pp.property_id